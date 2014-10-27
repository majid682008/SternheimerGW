!
! Copyright (C) 2001-2008 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!-----------------------------------------------------------------------
  subroutine gwq_setup
!-----------------------------------------------------------------------
  !
  !  This subroutine prepares several variables which are needed in the
  !  GW !  program:
  !  1) computes the total local potential (external+scf) on the smooth
  !     grid to be used in h_psi and similiar
  !  2) computes dmuxc 3) with GC if needed
  !  4) set the inverse of every matrix invs
  !  5) for metals sets the occupied bands
  !  6) computes alpha_pv
  !  9) set the variables needed to deal with nlcc
  !
  ! LEGACY FROM THE PHONON STUFF
  !
  !  7) computes the variables needed to pass to the pattern representation
  !     u      the patterns
  !     t      the matrices of the small group of q on the pattern basis
  !     tmq    the matrix of the symmetry which sends q -> -q + G
  !     gi     the G associated to each symmetry operation
  !     gimq   the G of the q -> -q+G symmetry
  !     irgq   the small group indices
  !     nsymq  the order of the small group of q
  !     irotmq the index of the q->-q+G symmetry
  !     nirr   the number of irreducible representation
  !     npert  the dimension of each irreducible representation
  !     nmodes the number of modes
  !     minus_q true if there is a symmetry sending q -> -q+G
  !  8) for testing purposes it sets ubar
  !  10) set the variables needed for the partial computation
  !       of the dynamical matrix
  !
  !  IMPORTANT NOTE ABOUT SYMMETRIES:
  !  nrot  is the number of sym.ops. of the Bravais lattice
  !        read from data file, only used in set_default_pw
  !  nsym  is the number of sym.ops. of the crystal symmetry group
  !        read from data file, should never be changed
  !  nsymq is the number of sym.ops. of the small group of q
  !        it is calculated in set_defaults_pw for each q
  !  The matrices "s" of sym.ops are ordered as follows:
  !   first the nsymq sym.ops. of the small group of q
  !   (the ordering is done in subroutine copy_sym in set_defaults_pw),
  !   followed by the remaining nsym-nsymq sym.ops. of the crystal group,
  !   followed by the remaining nrot-nsym sym.ops. of the Bravais  group
  !

  USE kinds,         ONLY : DP
  USE ions_base,     ONLY : tau, nat, ntyp => nsp, ityp, pmass
  USE cell_base,     ONLY : at, bg  
  USE io_global,     ONLY : stdout
  USE ener,          ONLY : Ef
  USE klist,         ONLY : xk, lgauss, degauss, ngauss, nks, nelec
  USE ktetra,        ONLY : ltetra, tetra
  USE lsda_mod,      ONLY : nspin, lsda, starting_magnetization
  USE scf,           ONLY : v, vrs, vltot, rho, rho_core, kedtau
  USE gvect,         ONLY : nrxx, ngm
  USE gsmooth,       ONLY : doublegrid
  USE symm_base,     ONLY : nrot, nsym, s, ftau, irt, t_rev, time_reversal, &
                            sname, sr, invs, inverse_s, copy_sym
  USE uspp_param,    ONLY : upf
  USE spin_orb,      ONLY : domag
  USE constants,     ONLY : degspin, pi
  USE noncollin_module, ONLY : noncolin, m_loc, angle1, angle2, ux, nspin_mag
  USE wvfct,         ONLY : nbnd, et
  USE rap_point_group,      ONLY : code_group, nclass, nelem, elem, which_irr,&
                                  char_mat, name_rap, gname, name_class, ir_ram
  USE rap_point_group_is,   ONLY : code_group_is, gname_is
  USE nlcc_gw,       ONLY : drc, nlcc_any
  USE eqv,           ONLY : dmuxc
  USE control_gw,    ONLY : rec_code, lgamma_gamma, search_sym, start_irr, &
                            last_irr, niter_gw, alpha_mix, all_done, &
                            epsil, lgamma, recover, where_rec, alpha_pv, &
                            nbnd_occ, flmixdpot, reduce_io, rec_code_read, &
                            done_epsil, zeu, done_zeu, current_iq, u_from_file
  USE output,        ONLY : fildrho
  USE modes,         ONLY : u, ubar, npertx, npert, gi, gimq, nirr, &
                            t, tmq, irotmq, irgq, minus_q, &
                            nsymq, nmodes, rtau
  USE dynmat,        ONLY : dyn, dyn_rec, dyn00
  USE efield_mod,    ONLY : epsilon, zstareu
  USE qpoint,        ONLY : xq
  USE partial,       ONLY : comp_irr, atomo, nat_todo, list, nrapp, all_comp, &
                            done_irr
  USE gamma_gamma,   ONLY : has_equivalent, asr, nasr, n_diff_sites, &
                            equiv_atoms, n_equiv_atoms, with_symmetry
  USE gw_restart,    ONLY : gw_writefile, gw_readfile
  USE control_flags, ONLY : iverbosity, modenum, noinv
  USE disp,          ONLY : comp_irr_iq
  USE funct,         ONLY : dmxc, dmxc_spin, dmxc_nc, dft_is_gradient

! USE ramanm,        ONLY : lraman, elop, ramtns, eloptns, done_lraman, &
!                           done_elop

  USE mp,            ONLY : mp_max, mp_min
  USE mp_global,     ONLY : inter_pool_comm, nimage

  implicit none

  real(DP) :: rhotot, rhoup, rhodw, target, small, fac, xmax, emin, emax
  ! total charge
  ! total up charge
  ! total down charge
  ! auxiliary variables used
  ! to set nbnd_occ in the metallic case
  ! minimum band energy
  ! maximum band energy

  real(DP) :: sr_is(3,3,48)

  integer :: ir, isym, jsym, irot, ik, ibnd, ipol, &
       mu, nu, imode0, irr, ipert, na, it, nt, is, js, nsym_is, last_irr_eff
  ! counters

  real(DP) :: auxdmuxc(4,4)
  real(DP), allocatable :: w2(:)

  logical :: sym (48), is_symmorgwic, magnetic_sym
  integer, allocatable :: ifat(:)
  integer :: ierr

  call start_clock ('gwq_setup')
  !
  ! 1) Computes the total local potential (external+scf) on the smooth grid
  !

  call set_vrs (vrs, vltot, v%of_r, kedtau, v%kin_r, nrxx, nspin, doublegrid)

  !
  ! 2) Set non linear core correction variables.
  !

  nlcc_any = ANY ( upf(1:ntyp)%nlcc )
  if (nlcc_any) allocate (drc( ngm, ntyp))    
  !
  !  3) If necessary calculate the local magnetization. This information is
  !      needed in find_sym
  !
  IF (.not.ALLOCATED(m_loc)) ALLOCATE( m_loc( 3, nat ) )
  IF (noncolin.and.domag) THEN
     DO na = 1, nat
        !
        m_loc(1,na) = starting_magnetization(ityp(na)) * &
                      SIN( angle1(ityp(na)) ) * COS( angle2(ityp(na)) )
        m_loc(2,na) = starting_magnetization(ityp(na)) * &
                      SIN( angle1(ityp(na)) ) * SIN( angle2(ityp(na)) )
        m_loc(3,na) = starting_magnetization(ityp(na)) * &
                      COS( angle1(ityp(na)) )
     END DO
     ux=0.0_DP
     if (dft_is_gradient()) call compute_ux(m_loc,ux,nat)
  ENDIF

  !
  ! 3) Computes the derivative of the xc potential
  !
  dmuxc(:,:,:) = 0.d0
  if (lsda) then
     do ir = 1, nrxx
        rhoup = rho%of_r (ir, 1) + 0.5d0 * rho_core (ir)
        rhodw = rho%of_r (ir, 2) + 0.5d0 * rho_core (ir)
        call dmxc_spin (rhoup, rhodw, dmuxc(ir,1,1), dmuxc(ir,2,1), &
                                      dmuxc(ir,1,2), dmuxc(ir,2,2) )
     enddo
  else
     IF (noncolin.and.domag) THEN
        do ir = 1, nrxx
           rhotot = rho%of_r (ir, 1) + rho_core (ir)
           call dmxc_nc (rhotot, rho%of_r(ir,2), rho%of_r(ir,3), rho%of_r(ir,4), auxdmuxc)
           DO is=1,nspin_mag
              DO js=1,nspin_mag
                 dmuxc(ir,is,js)=auxdmuxc(is,js)
              END DO
           END DO
        enddo
     ELSE
        do ir = 1, nrxx
           rhotot = rho%of_r (ir, 1) + rho_core (ir)
           if (rhotot.gt.1.d-30) dmuxc (ir, 1, 1) = dmxc (rhotot)
           if (rhotot.lt. - 1.d-30) dmuxc (ir, 1, 1) = - dmxc ( - rhotot)
        enddo
     END IF
  endif

  ! 3.1) Setup all gradient correction stuff
  ! call setup_dgc

  ! 4) Computes the inverse of each matrix of the crystal symmetry group

  !HL-
   call inverse_s ( )

  ! 5) Computes the number of occupied bands for each k point

  if (lgauss) then
     !
     ! discard conduction bands such that w0gauss(x,n) < small
     !
     ! hint:
     !   small = 1.0333492677046d-2  ! corresponds to 2 gaussian sigma
     !   small = 6.9626525973374d-5  ! corresponds to 3 gaussian sigma
     !   small = 6.3491173359333d-8  ! corresponds to 4 gaussian sigma
     !
     small = 6.9626525973374d-5
     !
     ! - appropriate limit for gaussian broadening (used for all ngauss)
     !
     xmax = sqrt ( - log (sqrt (pi) * small) )
     !
     ! - appropriate limit for Fermi-Dirac
     !
     if (ngauss.eq. - 99) then
        fac = 1.d0 / sqrt (small)
        xmax = 2.d0 * log (0.5d0 * (fac + sqrt (fac * fac - 4.d0) ) )
     endif
     target = ef + xmax * degauss
     do ik = 1, nks
        do ibnd = 1, nbnd
           if (et (ibnd, ik) .lt.target) nbnd_occ (ik) = ibnd
        enddo
        if (nbnd_occ (ik) .eq.nbnd) WRITE( stdout, '(5x,/,&
             &"Possibly too few bands at point ", i4,3f10.5)') &
             ik,  (xk (ipol, ik) , ipol = 1, 3)
     enddo
  else if (ltetra) then
     call errore('gwq_setup','phonon + tetrahedra not implemented', 1)
  else
     if (lsda) call infomsg('gwq_setup','occupation numbers probably wrong')
     if (noncolin) then
        nbnd_occ = nint (nelec) 
     else
        do ik = 1, nks
           nbnd_occ (ik) = nint (nelec) / degspin
!HL writing out band numbers... why all four?
!           write(6,*) nbnd_occ(ik)
        enddo
     endif
  endif
  !
  ! 6) Computes alpha_pv
  !
  emin = et (1, 1)
  do ik = 1, nks
     do ibnd = 1, nbnd
        emin = min (emin, et (ibnd, ik) )
     enddo
  enddo

!@10TION@10TION
#ifdef __PARA
  ! find the minimum across pools
  call mp_min( emin, inter_pool_comm )
#endif
  if (lgauss) then
     emax = target
     alpha_pv = emax - emin
  else
     emax = et (1, 1)
     do ik = 1, nks
        do ibnd = 1, nbnd_occ(ik)
           emax = max (emax, et (ibnd, ik) )
        enddo
     enddo
#ifdef __PARA
     ! find the maximum across pools
     call mp_max( emax, inter_pool_comm )
#endif
     alpha_pv = 2.d0 * (emax - emin)
  endif
  ! avoid zero value for alpha_pv
  alpha_pv = max (alpha_pv, 1.0d-2)
  !
  ! 7) set all the variables needed to use the pattern representation
  !
  magnetic_sym = noncolin .AND. domag
  time_reversal = .NOT. noinv .AND. .NOT. magnetic_sym

  !  set the alpha_mix parameter
  !HL probably want restart functionality here.
  
  do it = 2, niter_gw
     if (alpha_mix (it) .eq.0.d0) alpha_mix (it) = alpha_mix (it - 1)
  enddo

!HL always reduce_io...
  !if (reduce_io) then
     flmixdpot = ' '
  !else
  !   flmixdpot = 'mixd'
  !endif

  where_rec='gwq_setup.'
  rec_code=-40
  CALL gw_writefile('data',0)

  CALL stop_clock ('gwq_setup')
  RETURN
END SUBROUTINE gwq_setup