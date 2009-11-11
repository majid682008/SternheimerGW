  !
  !----------------------------------------------------------------
  program gwhs
  !----------------------------------------------------------------
  ! 
  ! pilot code the GW-HS method
  ! empirical pseudopotential method implementation
  ! for nonpolar tetrahedral semiconductors 
  !
  ! NOTE: I use only one G-grid. The reason is that, while V(G-G')
  ! has in principle components 2G_max, in the EPS scheme the  
  ! largest value happens for G2=11, therefore we can simply use
  ! the smooth grid...
  ! To perform a true scaling test we need to include the double
  ! grid (and count the operations on the smooth and on the dense
  ! grids).
  !
  ! IMPORTANT: every wfs has the same G-vects, I am not changing
  ! the cutoff for every k-point: |G|^2 is used instead of |k+G|^2
  ! so mind when using k beyond the first BZ
  !
  !----------------------------------------------------------------
  !
  use gspace
  use parameters
  use constants
  use kspace
  use imaxis
#ifdef __PARA
  USE para
  USE mp, ONLY: mp_bcast, mp_barrier, mp_end
  USE io_global, ONLY: ionode_id
  USE mp_global,  ONLY : nproc, mpime, nproc_pool, my_pool_id, me_pool
#endif
  implicit none
  !
  ! variables
  !
  integer :: root = 0 ! root node for broadcast
  integer :: ig, ik, ig1, ig2, iq, nk, ik0, i, j, k, ios, ioall
  integer :: iw, iwp, iw0, iw0pw, iw0mw, count, ipol, ir, iwim
  integer :: recl, unf_recl, irp, igp, rec0, igstart, igstop
  integer :: ngpool, ngr, igs, ibnd
  integer :: nwcoul, nwgreen, nwalloc, nwsigma
  integer, allocatable :: ind_w0mw (:,:), ind_w0pw (:,:)
  real(dbl) :: ui, uj, uk, wgreenmin, wgreenmax, w0mw, w0pw, v1
  real(dbl) :: gcutm, gcutms, arg, wp
  real(dbl) :: k0mq(3), kplusg(3), xk0(3,nk0), xxq(3), xq0(3)
  real(dbl), allocatable :: ss(:), vs(:)
  real(DP), parameter :: eps8 = 1.0D-8
  real(DP) :: et(nbnd_occ, nq)
  real(DP), allocatable :: eval_all(:)
  real(DP), allocatable :: g2kin (:)
  real(DP), allocatable :: wtmp(:), wcoul(:), wgreen(:), wsigma(:), w_ryd(:)
  complex(DP) :: cexpp, cexpm, cprefac
  complex(DP), allocatable :: psi(:,:), psi_all(:,:)
  complex(dbl), allocatable :: vr(:), aux(:)
  complex(dbl), allocatable :: scrcoul (:,:), greenfp (:,:), greenfm (:,:), sigma(:,:,:)
  complex(dbl), allocatable :: barcoul (:,:), greenf_na (:,:), sigma_ex(:,:)
  complex(dbl), allocatable :: scrcoul_g (:,:,:), greenf_g (:,:), sigma_g(:,:,:)
  complex(dbl), allocatable :: scrcoul_pade_g (:,:)
  complex(dbl), allocatable :: z(:), a(:)
  logical :: allowed, foundp, foundm
  CHARACTER (LEN=9)   :: code = 'GWHS'
  CHARACTER(len=3)  :: nd_nmbr = '000' ! node number (used only in parallel case)
  character (len=3) :: nd_nmbr0
  CHARACTER (LEN=6) :: version_number = '0.4.8'
  character (len=256) :: wfcfile
  real(kind=8) :: xr, xi, r1(3), r2(3)
  logical :: nanno
  real(dbl) :: qg2, rcut, spal
  !
  !
  ! start serial code OR initialize parallel environment
  !
  CALL startup( nd_nmbr, code, version_number )
  !
#ifdef __PARA
  if (me.ne.1.or.mypool.ne.1) open (unit=stdout,file='/dev/null',status='unknown')
#endif

  call start_clock ('GWHS')
  !
  !----------------------------------------------------------------
  ! DEFINE THE CRYSTAL LATTICE
  !----------------------------------------------------------------
  !
  !  direct lattice vectors (cart. coord. in units of a_0)
  !  [Yu and Cardona, pag 23]
  !
  at( :, 1) = (/ 0.0,  0.5,  0.5 /)  ! a1
  at( :, 2) = (/ 0.5,  0.0,  0.5 /)  ! a2
  at( :, 3) = (/ 0.5,  0.5,  0.0 /)  ! a3
  !     
  !  reciprocal lattice vectors (cart. coord. in units 2 pi/a_0)
  !
  bg( :, 1) = (/ -1.0,  1.0,  1.0 /)  ! b1
  bg( :, 2) = (/  1.0, -1.0,  1.0 /)  ! b2
  bg( :, 3) = (/  1.0,  1.0, -1.0 /)  ! b3
  !
  !  atomic coordinates (cart. coord. in units of a_0)
  !
  tau( :, 1) = (/  0.125,  0.125,  0.125 /)  
  tau( :, 2) = (/ -0.125, -0.125, -0.125 /)  
  !
  !----------------------------------------------------------------
  ! GENERATE THE G-VECTORS
  !----------------------------------------------------------------
  !
  ! the G^2 cutoff in units of 2pi/a_0
  ! Note that in Ry units the kinetic energy is G^2, not G^2/2
  ! (note for the Hamiltonian we need to double the size, 2Gmax, hence the factor 4)
  !
  gcutm = four * ecutwfc / tpiba2      
! gcutm = ecutwfc / tpiba2      
  !
  ! set the fft grid
  !
  ! estimate nr1 and check if it is an allowed value for FFT
  !
  nr1 = 1 + int (2 * sqrt (gcutm) * sqrt( at(1,1)**2 + at(2,1)**2 + at(3,1)**2 ) ) 
  nr2 = 1 + int (2 * sqrt (gcutm) * sqrt( at(1,2)**2 + at(2,2)**2 + at(3,2)**2 ) ) 
  nr3 = 1 + int (2 * sqrt (gcutm) * sqrt( at(1,3)**2 + at(2,3)**2 + at(3,3)**2 ) ) 
  !
  do while (.not.allowed(nr1)) 
    nr1 = nr1 + 1
  enddo
  do while (.not.allowed(nr2)) 
    nr2 = nr2 + 1
  enddo
  do while (.not.allowed(nr3)) 
    nr3 = nr3 + 1
  enddo
  !
  call ggen( gcutm)
  !
  !----------------------------------------------------------------
  ! FIND THE G-VECTORS FOR THE SMALL SIGMA CUTOFF
  !----------------------------------------------------------------
  !
  ! the G^2 cutoff in units of 2pi/a_0
  ! Note that in Ry units the kinetic energy is G^2, not G^2/2
  !
  gcutms = four * ecuts / tpiba2      
! gcutms = ecuts / tpiba2      
  !
  ! set the fft grid
  !
  ! estimate nr1 and check if it is an allowed value for FFT
  !
  nr1s = 1 + int (2 * sqrt (gcutms) * sqrt( at(1,1)**2 + at(2,1)**2 + at(3,1)**2 ) ) 
  nr2s = 1 + int (2 * sqrt (gcutms) * sqrt( at(1,2)**2 + at(2,2)**2 + at(3,2)**2 ) ) 
  nr3s = 1 + int (2 * sqrt (gcutms) * sqrt( at(1,3)**2 + at(2,3)**2 + at(3,3)**2 ) ) 
  !
  do while (.not.allowed(nr1s)) 
    nr1s = nr1s + 1
  enddo
  do while (.not.allowed(nr2s)) 
    nr2s = nr2s + 1
  enddo
  do while (.not.allowed(nr3s)) 
    nr3s = nr3s + 1
  enddo
  !
  call ggens ( gcutms )
  !
  !-----------------------------------------------------------------
  ! in the parallel case split the ngms G-vectors across pools
  !-----------------------------------------------------------------
  !
#ifdef __PARA
  !
  npool = nproc / nproc_pool
  if (npool.gt.1) then
    !
    ! number of g-vec per pool and reminder
    ngpool = ngms / npool
    ngr = ngms - ngpool * npool
    ! the reminder goes to the first ngr pools
    if ( my_pool_id < ngr ) ngpool = ngpool + 1
    !
    igs = ngpool * my_pool_id + 1
    if ( my_pool_id >= ngr ) igs = igs + ngr
    !
    !  the index of the first and the last g vec in this pool
    !
    igstart = igs
    igstop = igs - 1 + ngpool
    !
    write (stdout,'(/4x,"Max n. of PW perturbations per pool = ",i5)') igstop-igstart+1
    !
  else
#endif
    !
    igstart = 1
    igstop = ngms
    !
#ifdef __PARA
  endif
#endif
  !
  ! ----------------------------------------------------------------
  ! generate frequency bins 
  ! ----------------------------------------------------------------
  !
  ! Here I assume Sigma is needed for w0 between wsigmamin and wsigmamax
  ! The convolution requires W for positive frequencies w up to wcoulmax
  ! (even function - cf Shishkin and Kress) and the GF spanning w0+-w.
  ! Therefore the freq. range of GF is 
  ! from (wsigmamin-wcoulmax) to (wsigmamax+wcoulmax)
  ! the freq. dependence of the GF is inexpensive, so we use the same spacing
  ! 
  ! NB: I assume wcoulmax>0, wsigmamin=<0, wsigmamax>0 and zero of energy at the Fermi level
  !
  wgreenmin = wsigmamin-wcoulmax
  wgreenmax = wsigmamax+wcoulmax
  !
  nwalloc = 1 + ceiling( (wgreenmax-wgreenmin)/deltaw )
  allocate(wtmp(nwalloc), wcoul(nwalloc), wgreen(nwalloc), wsigma(nwalloc), w_ryd(nwalloc) )
  wcoul = zero
  wgreen = zero
  wsigma = zero
  !
  do iw = 1, nwalloc
    wtmp(iw) = wgreenmin + (wgreenmax-wgreenmin)/float(nwalloc-1)*float(iw-1)
  enddo
  ! align the bins with the zero of energy
  wtmp = wtmp - minval ( abs ( wgreen) )
  !
  nwgreen = 0
  nwcoul = 0
  nwsigma = 0
  !
  do iw = 1, nwalloc
    if ( ( wtmp(iw) .ge. wgreenmin ) .and. ( wtmp(iw) .le. wgreenmax) ) then
       nwgreen = nwgreen + 1
       wgreen(nwgreen) = wtmp(iw)
    endif
    if ( ( wtmp(iw) .ge. zero ) .and. ( wtmp(iw) .le. wcoulmax) ) then
       nwcoul = nwcoul + 1
       wcoul(nwcoul) = wtmp(iw)
    endif
    if ( ( wtmp(iw) .ge. wsigmamin ) .and. ( wtmp(iw) .le. wsigmamax) ) then
       nwsigma = nwsigma + 1
       wsigma(nwsigma) = wtmp(iw)
    endif
  enddo
  ! 
  ! now find the correspondence between the arrays
  ! This is needed for the convolution G(w0-w)W(w) at the end
  !
  allocate ( ind_w0mw (nwsigma,nwcoul), ind_w0pw (nwsigma,nwcoul) )
  !
  do iw0 = 1, nwsigma
    do iw = 1, nwcoul
      !
      w0mw = wsigma(iw0)-wcoul(iw)
      w0pw = wsigma(iw0)+wcoul(iw)
      !
      foundp = .false.
      foundm = .false.
      !
      do iwp = 1, nwgreen
        if ( abs(w0mw-wgreen(iwp)) .lt. 1.d-10 ) then
          foundm = .true.
          iw0mw = iwp
        endif
        if ( abs(w0pw-wgreen(iwp)) .lt. 1.d-10 ) then
          foundp = .true.
          iw0pw = iwp
        endif
      enddo
      !
      if ( ( .not. foundm ) .or. ( .not. foundp ) ) then
         call errore ('gwhs','frequency correspondence not found',1)
      else
         ind_w0mw(iw0,iw) = iw0mw 
         ind_w0pw(iw0,iw) = iw0pw 
      endif
      !
    enddo
  enddo
  !

  !
  ! read from file the frequencies on the imaginary axis (eV)
  ! (every node reads in parallel - it's a tiny file)
  !
  open ( 45, file = "./imfreq.dat", form = 'formatted', status = 'unknown')
  read (45, *)
  read (45, *) nwim
  allocate ( wim(nwim), z(nwim), a(nwim) )
  do iw = 1, nwim
    read (45,*) wim(iw)
    if (wim(iw).lt.0.d0) call error ('coulomb','imaginary frequencies must be positive',1)
  enddo
  if (nwim.gt.20) call error ('coulomb','too many imaginary frequencies',nwim)
  close(45)
  !
  


  !
  write (stdout,'(/4x,"nwcoul = ",i5,", nwgreen = ",i5,", nwsigma = ",i5/)') &
     nwcoul, nwgreen, nwsigma
  write (stdout,'(/4x,"wgreenmin = ",f6.1," eV, wgreenmax = ",f6.1," eV, wgreen_safe = ",f6.1/)') &
     wgreen(1), wgreen(nwgreen), wgreen_safe
  if ( wgreen(nwgreen) .lt. wgreen_safe ) call errore ('gwhs','Green''s function frequency grid too small',1)
  write (stdout,'(/4x,"eta = ",f6.1," eV, deltaw = ",f6.1," eV")') eta*ryd2ev, deltaw
  !----------------------------------------------------------------
  !
#ifdef __PARA
  if (me.eq.1.and.mypool.eq.1) then
#endif
    !
    ! read from file the k-points for the self-energy \Sigma(k)
    !
    open ( 44, file = "./klist.dat", form = 'formatted', status = 'unknown')
    do ik = 1, nk0
      read (44,*) xk0(1,ik), xk0(2,ik), xk0(3,ik) 
    enddo
    !
#ifdef __PARA
  endif
  !
  !  bcast everything to all nodes
  !
  call mp_bcast ( xk0, root)
#endif
  !
  if (tepm) then 
    !
    ! construct the empirical pseudopotential
    !
    write(stdout,'(/4x,"Using empirical pseudopotential"/)') 
    !
    allocate ( ss(ngm), vs(ngm) )
    do ig = 1, ngm
      arg = twopi * ( g(1,ig) * tau( 1, 1) + g(2,ig) * tau( 2, 1) + g(3,ig) * tau( 3, 1) )
      ss (ig) = cos ( arg )
    enddo
    vs = zero
    ! integer comparison - careful with other structures
    do ig = 1, ngm
      if     ( int ( gl(igtongl(ig)) ) .eq.  3 ) then
        vs (ig) =  v3
      elseif ( int ( gl(igtongl(ig)) ) .eq.  8 ) then
        vs (ig) =  v8
      elseif ( int ( gl(igtongl(ig)) ) .eq. 11 ) then
        vs (ig) =  v11
      endif
    enddo
    !
    ! the empirical pseudopotential in real space 
    ! for further use in h_psi
    !
    allocate ( vr(nr) )
    vr = czero
    do ig = 1, ngm
      vr ( nl ( ig ) ) = dcmplx ( ss (ig) * vs (ig), zero )
    enddo
    call cfft3 ( vr, nr1, nr2, nr3,  1)
    !
    deallocate ( ss, vs)
    !
  else
    !
    ! Read V+Vxc from local pseudopotential SCF calculation
    !
    write(stdout,'(/4x,"Using vloc from SCF calculation"/)') 
    !
    ! it is important to read vr(ir) as the ordering of the G vectors
    ! may be slightly different
    !
    allocate ( vr(nr) )
    vr = czero
#ifdef __PARA
    if (me.eq.1.and.mypool.eq.1) then
#endif
    open(unit=100,file='vloc.dat')
    rewind(100)
    !
    read (100,*) ! nrxx_, nr1_, nr2_, nr3_, nrx1_, nrx2_, nrx3_, ngm_
    ! include a test here to make sure that the sizes are the same
    !
    do ir = 1, nr
      read(100,*) v1
      vr(ir) = dcmplx (v1,0.d0)
    enddo
    close(100)
#ifdef __PARA
    endif
    ! use poolreduce to broadcast vr to each pool
    call poolreduce ( 2 * nr, vr)
#endif
    !
  endif
  !
  ! set to zero top of valence band by shifting the
  ! local potential
  vr = vr - eshift
  !
  allocate ( g2kin (ngm) )
  allocate ( aux (nrs) )
  allocate ( xq(3,nq), wq(nq), eval_occ(nbnd_occ,nq) )
  allocate ( gmap(ngm,27) )
  !
  ! generate the uniform {q} grid for the Coulomb interaction
  ! no symmetry-reduction for now - uniform and Gamma-centered
  ! (I was going insane with the folding of the MP mesh, I am not sure
  ! it's self-contained)
  !
  count = 0
  do i = 1, nq1
    ui = (i - 1.d0) / float (nq1)
!   ui = (q1 + 2.d0 * i - nq1 - 1.d0) / (2.d0 * nq1)
    do j = 1, nq2
      uj = (j - 1.d0) / float (nq2)
!     uj = (q2 + 2.d0 * j - nq2 - 1.d0) / (2.d0 * nq2)
      do k = 1, nq3
        uk = (k - 1.d0) / float (nq3)
!       uk = (q3 + 2.d0 * k - nq3 - 1.d0) / (2.d0 * nq3)
        count = count + 1
        xq (:, count) = ui * bg(:,1) + uj * bg(:,2) + uk * bg(:,3)
      enddo
    enddo
  enddo
  wq = one / float ( count )
  if (count.ne.nq) call error ('gwhs','q-point count',count)
  ! the {k} grid is taken to coincide with the {q} grid
  ! nks = 2 * nq
  allocate ( xk (3,nks), wk(nks) )
  !
  write(stdout,'(/4x,a)') repeat('-',67)
  write(stdout,'(4x,"Uniform q-point grid for the screened Coulomb interaction"/)') 
  do iq = 1, nq
     write ( stdout, '(4x,"q(",i3," ) = (",3f12.7," ), wq =",f12.7)') &
         iq, (xq (ipol, iq) , ipol = 1, 3) , wq (iq)
  enddo
  write(stdout,'(4x,a/)') repeat('-',67)
  !
  ! generate the occupied eigenstates on the uniform grid
  ! this will be needed for the screened Coulomb below
  !
  recl = 2 * nbnd_occ * ngm  ! 2 stands for complex
  unf_recl = DIRECT_IO_FACTOR * recl
  wfcfile = './silicon'//'.wfc'
#ifdef __PARA
  call set_ndnmbr ( mypool, me_pool, nprocp, npool, nd_nmbr0)
  wfcfile =  trim(wfcfile)//'.'//nd_nmbr0
#endif
  !
  open ( iunwfc, file = wfcfile, iostat = ios, form = 'unformatted', &
       status = 'unknown', access = 'direct', recl = unf_recl)
  !
  write(stdout,'(/4x,a)') repeat('-',67)
  write(stdout,'(4x,"Occupied eigenvalues (eV)")') 
  write(stdout,'(4x,a/)') repeat('-',67)
  !
  allocate ( psi (ngm, nbnd_occ) )
  do iq = 1, nq
    !
    ! the k-dependent kinetic energy in Ry
    ! [Eq. (14) of Ihm,Zunger,Cohen J Phys C 12, 4409 (1979)]
    !
    do ig = 1, ngm
      kplusg = xq(:, iq) + g(:,ig)
      g2kin ( ig ) = tpiba2 * dot_product ( kplusg, kplusg )
    enddo
    !
    call eigenstates2 ( xq(:, iq), vr, g2kin, psi, eval_occ(:,iq) ) 
    !
    !  direct write to file - take into account the k/k+q alternation
    !
    write ( iunwfc, rec = 2 * iq - 1, iostat = ios) psi
    !
    write ( stdout, '(4x,"k(",i3," )",10(3x,f7.3))') iq, eval_occ(:,iq)*ryd2ev
    !
  enddo
  deallocate( psi )
  write(stdout,'(4x,a/)') repeat('-',67)
  !
  ! here we generate the G-map for the folding into the first BZ
  !
  call refold ( )
  !
  allocate ( scrcoul (nrs, nrs) )
  allocate ( greenfp (nrs, nrs), greenfm (nrs, nrs) )
  allocate ( greenf_g (ngms, ngms) )
  allocate ( scrcoul_g (ngms, ngms, nwim) )
  allocate ( scrcoul_pade_g (ngms, ngms) )
  allocate ( barcoul(nrs, nrs), greenf_na(nrs,nrs), sigma_ex (nrs, nrs) )
  !
  ! prepare the unit to write the Coulomb potential
  ! each q-point is associated with one record
  !
! recl = 2 * nrs * nrs * nwcoul
! recl = 2 * ngms * ngms * nwcoul
  recl = 2 * ngms * ngms * nwim
  unf_recl = DIRECT_IO_FACTOR * recl
  open ( iuncoul, file = "./silicon.coul", iostat = ios, form = 'unformatted', &
       status = 'unknown', access = 'direct', recl = unf_recl)
  !
  ! prepare the unit to write the Green's function 
  ! each (k0-q)-point is associated with one record
  !
! recl = 2 * nrs * nrs * nwgreen
! recl = 2 * ngms * ngms * nwgreen
  recl = 2 * ngms * ngms 
  unf_recl = DIRECT_IO_FACTOR * recl
  open ( iungreen, file = "./silicon.green", iostat = ios, form = 'unformatted', &
       status = 'unknown', access = 'direct', recl = unf_recl)
  !
  ! prepare the unit to write the self-energy 
  ! each k0-point is associated with one record
  !
  recl = 2 * ngms * ngms * nwsigma
  unf_recl = DIRECT_IO_FACTOR * recl
  open ( iunsigma, file = "./silicon.sigma", iostat = ios, form = 'unformatted', &
       status = 'unknown', access = 'direct', recl = unf_recl)
  !
  write(stdout,'(4x,"Screened Coulomb interaction:")')
  !
  ! loop over {q} for the screened Coulomb interaction
  !
  do iq = 1, nq
    !
!   write(stdout,'(4x,3x,"iq = ",i3)') iq
    scrcoul_g = czero
    !
    if (igstart.eq.1) then
      !
      ! In the case (q=0, G=0) we perform a separate
      ! calculation for scrcoul(ig=1,:,:)
      ! (in the parallel case: only the processor having the G=0 vec)
      !
      xq0 = (/ 0.01 , 0.00, 0.00 /) ! this should be set from input
      if ( ( xq(1,iq)*xq(1,iq) + xq(2,iq)*xq(2,iq) + xq(3,iq)*xq(3,iq) ) .lt. 1.d-10 ) &
      call coulomb_q0G0 ( vr, xq0, nwim, wim, scrcoul_g )
    endif
    !
    ! the grids {k} and {k+q} for the dVscf will be obtained
    ! by shuffling the {q} grid
    !
    call coulomb ( vr, xq(:,iq), nwim, wim, scrcoul_g, igstart, igstop )
    !
#ifdef __PARA
    !
    ! use poolreduce to bring together the results from each pool
    !
    call poolreduce ( 2 * ngms * ngms * nwim, scrcoul_g)
    !
    if (me.eq.1.and.mypool.eq.1) then
#endif
      !
      write ( iuncoul, rec = iq, iostat = ios) scrcoul_g
      !
#ifdef __PARA
    endif
#endif
!   write (stdout,'(4x,"Written scrcoul for iq = ",i3)') iq
    !
  enddo 
  !
  write(stdout,'(4x,"Green''s function:")')
  ! loop over the {k0} set for the Self-Energy
  !
  do ik0 = 1, nk0
    !
    write(stdout,'(4x,"ik0 = ",i3)') ik0
    !
    ! loop over the {k0-q} grid for the Green's function
    !
    do iq = 1, nq
      !
!     write(stdout,'(4x,3x,"iq = ",i3)') iq
      !
      !  k0mq = k0 - q
      !
      k0mq = xk0(:,ik0) - xq(:,iq)
      !
      ! the k-dependent kinetic energy in Ry
      ! [Eq. (14) of Ihm,Zunger,Cohen J Phys C 12, 4409 (1979)]
      !
      do ig = 1, ngm
        kplusg = k0mq + g(:,ig)
        g2kin ( ig ) = tpiba2 * dot_product ( kplusg, kplusg )
      enddo
      !
      ! need to use multishift in green
      call green_linsys ( vr, g2kin, k0mq, nwgreen, wgreen, igstart, igstop, ik0, iq )
      !
      ! end loop on {k0-q} and {q}
    enddo 
    !
    ! end loop on {k0}
  enddo 
  !
  ! G TIMES W PRODUCT
  !
  call start_clock ('GW product')

  allocate ( sigma (nrs, nrs, nwsigma), stat = ioall )
! write(6,*) size(sigma), ioall
  allocate ( sigma_g (ngms, ngms, nwsigma) )

  !
  w_ryd = wcoul / ryd2ev
  do ik0 = 1, nk0 
    !
    write(stdout,'(4x,"Direct product GW for k0(",i3," ) = (",3f12.7," )")') &
      ik0, (xk0 (ipol, ik0) , ipol = 1, 3)
    !
    ! now sum over {q} the products G(k0-q)W(q) 
    !
    sigma = czero
    !
    do iq = 1, nq
      !
      write(stdout,'(4x,"Summing iq = ",i4)') iq
      !
      ! read Pade coefficients of screened coulomb interaction (W-v) and broadcast
      ! 
#ifdef __PARA
      scrcoul_g = czero
      if (me.eq.1.and.mypool.eq.1) then
#endif
        read ( iuncoul, rec = iq, iostat = ios) scrcoul_g
#ifdef __PARA
      endif
      ! use poolreduce to broadcast the results to every pool
      call poolreduce ( 2 * ngms * ngms * nwim, scrcoul_g)
#endif
      !
      ! combine Green's function and screened Coulomb ( sum_q wq = 1 )
      !
      do iw = 1, nwcoul
        !
        ! generate coulomb interaction W-v in real space for iw (scrcoul)
        !
        ! 1. Pade continuation
        !
        do ig = 1, ngms
          do igp = 1, ngms
            !
            do iwim = 1, nwim
               z(iwim) = dcmplx( 0.d0, wim(iwim)/ryd2ev)
               a(iwim) = scrcoul_g (ig,igp,iwim)
            enddo 
            !
            call pade_eval ( nwim, z, a, dcmplx( w_ryd(iw), eta), scrcoul_pade_g (ig,igp))
            !
          enddo 
        enddo 
        !
        ! 2. fft to real space
        !
        call fft6_g2r ( scrcoul_pade_g, scrcoul)
        !
     
        !
!        cexpm = exp ( -ci * eta * w_ryd(iw) )
!        cexpp = exp (  ci * eta * w_ryd(iw) )
        ! the convergence factor should be dimensionless! it is only for
        ! carrying out analytical calculations I believe, here it does not matter
        !
        ! simpson quadrature: int_w1^wN f(w)dw = deltaw * 
        !   [ 1/3 ( f1 + fN ) + 4/3 sum_even f_even + 2/3 sum_odd f_odd ]
        ! (does not seem very important cosidered that we truncate 
        !  the integration at an arbitrary frequency)
        !
        cprefac = deltaw/ryd2ev * wq (iq) * ci / twopi
   !
   ! a simple test on int_0^1 sin(x)dx seems to say that this is not effective
   ! we should anyway get the same effect when using a smearing on the green's function
   !     if ( iw/2*2.eq.iw ) then
   !        cprefac = cprefac * 4.d0/3.d0
   !     else
   !        cprefac = cprefac * 2.d0/3.d0
   !     endif
   !     if ( (iw.eq.1) .or. (iw.eq.nwcoul) ) cprefac = cprefac * 1.d0/3.d0
        !
        do iw0 = 1, nwsigma
          !
          iw0mw = ind_w0mw (iw0,iw)
          iw0pw = ind_w0pw (iw0,iw)
          !
          ! generate green's function in real space for iw0mw (greenfm)
          !
#ifdef __PARA
          greenf_g = czero
          if (me.eq.1.and.mypool.eq.1) then
#endif
          rec0 = (iw0mw-1) * nk0 * nq + (ik0-1) * nq + (iq-1) + 1
          read ( iungreen, rec = rec0, iostat = ios) greenf_g
#ifdef __PARA
          endif
          ! use poolreduce to broadcast the results to every pool
          call poolreduce ( 2 * ngms * ngms, greenf_g )
#endif
          ! greenf_g is ngms*ngms, greenf is nrs*nrs
          !
          call fft6_g2r ( greenf_g, greenfm )
          !
          ! generate green's function in real space for iw0pw (greenfp)
          !
#ifdef __PARA
          greenf_g = czero
          if (me.eq.1.and.mypool.eq.1) then
#endif
          rec0 = (iw0pw-1) * nk0 * nq + (ik0-1) * nq + (iq-1) + 1
          read ( iungreen, rec = rec0, iostat = ios) greenf_g
#ifdef __PARA
          endif
          ! use poolreduce to broadcast the results to every pool
          call poolreduce ( 2 * ngms * ngms, greenf_g )
#endif
          ! greenf_g is ngms*ngms, greenf is nrs*nrs
          !
          call fft6_g2r ( greenf_g, greenfp )
          !
          sigma (:,:,iw0) = sigma (:,:,iw0) + cprefac * ( greenfp + greenfm ) * scrcoul 
          !
        enddo
        !
      enddo
      ! sigma in Ry here
      !
      ! end loop on {k0-q} and {q}
    enddo 

    !
    ! EXCHANGE PART OF THE SELF-ENERGY
    !
    sigma_ex = czero
    allocate ( psi_all (ngm, nbnd), eval_all(nbnd) )
    !
    do iq = 1, nq
      !
      ! NON-ANALYTIC PART OF THE GREEN'S FUNCTION
      !
      k0mq = xk0(:,ik0) - xq(:,iq)
      !
      ! the k-dependent kinetic energy in Ry
      ! [Eq. (14) of Ihm,Zunger,Cohen J Phys C 12, 4409 (1979)]
      !
      do ig = 1, ngm
        kplusg = k0mq + g(:,ig)
        g2kin ( ig ) = tpiba2 * dot_product ( kplusg, kplusg )
      enddo
      !
      ! this should be replaced by a solution of only the occ states - temporary
      call  eigenstates_all ( vr, g2kin, psi_all, eval_all )
      !
      greenf_na = czero
      do ig = igstart, igstop 
        do igp = 1, ngms
          do ibnd = 1, nbnd_occ
            ! no spin factor here! in <nk|Sigma|nk> only states of the same spin couple
            ! [cf HL86]
!           greenf_na (ig,igp) = greenf_na (ig,igp) + &
!             2.d0 * twopi * ci * psi_all(ig,ibnd)*conjg(psi_all(igp,ibnd)) 
            greenf_na (ig,igp) = greenf_na (ig,igp) + &
              twopi * ci * psi_all(ig,ibnd)*conjg(psi_all(igp,ibnd)) 
          enddo
        enddo
      enddo
      !
#ifdef __PARA
      ! use poolreduce to bring together the results from each pool
      call poolreduce ( 2 * nrs * nrs, greenf_na)
#endif
      !
      do ig = 1, ngms
        aux = czero
        do igp = 1, ngms
          aux(nls(igp)) = greenf_na(ig,igp)
        enddo
        call cfft3s ( aux, nr1s, nr2s, nr3s,  1)
        greenf_na(ig,1:nrs) = aux / omega
      enddo
      !
      ! the conjg/conjg is to calculate sum_G f(G) exp(-iGr)
      ! following teh convention set in the paper
      ! [because the standard transform is sum_G f(G) exp(iGr) ]
      !
      do irp = 1, nrs
        aux = czero
        do ig = 1, ngms
          aux(nls(ig)) = conjg ( greenf_na(ig,irp) )
        enddo
        call cfft3s ( aux, nr1s, nr2s, nr3s,  1)
        greenf_na(1:nrs,irp) = conjg ( aux )
      enddo
      !
      ! COULOMB EXCHANGE TERM
      !
      rcut = (float(3)/float(4)/pi*omega*float(nq1*nq2*nq3))**(float(1)/float(3))
      xq0 = (/ 0.01 , 0.00, 0.00 /) ! this should be set from input
      barcoul = 0.d0
      do ig = igstart, igstop
        !
        xxq = xq(:,iq)
        qg2 = (g(1,ig)+xxq(1))**2.d0 + (g(2,ig)+xxq(2))**2.d0 + (g(3,ig)+xxq(3))**2.d0
        if (qg2 < 1.d-8) xxq = xq0
        qg2 = (g(1,ig)+xxq(1))**2.d0 + (g(2,ig)+xxq(2))**2.d0 + (g(3,ig)+xxq(3))**2.d0
        ! Spencer/Alavi factor
        spal = one - cos ( rcut * tpiba * sqrt(qg2) )
        !
        barcoul (ig,ig) = e2 * fpi / (tpiba2*qg2) * spal 
        !
      enddo
#ifdef __PARA
      !
      ! use poolreduce to bring together the results from each pool
      call poolreduce ( 2 * nrs * nrs, barcoul)
      !
#endif
      !
      do ig = 1, ngms
        aux = czero
        do igp = 1, ngms
          aux(nls(igp)) = barcoul(ig,igp) 
        enddo
        call cfft3s ( aux, nr1s, nr2s, nr3s,  1) 
        barcoul(ig,1:nrs) = aux / omega
      enddo 
      !
      ! the conjg/conjg is to calculate sum_G f(G) exp(-iGr)
      ! following teh convention set in the paper
      ! [because the standard transform is sum_G f(G) exp(iGr) ]
      !
      do irp = 1, nrs
        aux = czero
        do ig = 1, ngms
          aux(nls(ig)) = conjg ( barcoul(ig,irp) )
        enddo
        call cfft3s ( aux, nr1s, nr2s, nr3s,  1)
        barcoul(1:nrs,irp) = conjg ( aux ) 
      enddo 
      !
      ! EXCHANGE PART OF SELF-ENERGY
      !
      sigma_ex = sigma_ex + wq (iq) * ci / twopi * greenf_na * barcoul 
      ! sigma in Ry here
      !
      ! end loop on {k0-q} and {q}
    enddo 
    !
    ! \Sigma = \Sigma^c + \Sigma^ex
    !
    do iw = 1, nwsigma
      sigma(:,:,iw) = sigma(:,:,iw) + sigma_ex 
    enddo
    !

    !
    ! Now we have summed over q in G(k0-q)W(q) and we can go back
    ! to G-space before calculating the sandwitches with the wavefunctions
    ! note: we go to SIZE order of G-vectors
    !
    do iw = 1, nwsigma
      do ir = 1, nrs
        aux = czero
        do irp = 1, nrs
          aux(irp) = sigma(ir,irp,iw)
        enddo
        call cfft3s ( aux, nr1s, nr2s, nr3s, -1)
        do igp = 1, ngms
          sigma (ir,igp,iw) = aux(nls(igp)) 
        enddo
      enddo
      !
      ! the conjg/conjg is to calculate sum_G f(G) exp(-iGr)
      ! following teh convention set in the paper
      ! [because the standard transform is sum_G f(G) exp(iGr) ]
      !
      do igp = 1, ngms
        aux = czero
        do ir = 1, nrs
          aux(ir) = conjg ( sigma(ir,igp,iw) ) 
        enddo
        call cfft3s ( aux, nr1s, nr2s, nr3s, -1)
        do ig = 1, ngms
          sigma (ig,igp,iw) = conjg ( aux(nls(ig)) ) * omega
        enddo
      enddo
    enddo
    !
    ! everything beyond ngms is garbage
    !
    do ig = ngms+1, nrs
     do igp = ngms+1, nrs
      do iw = 1, nwsigma
         sigma (ig,igp,iw) = czero
      enddo
     enddo
    enddo
    !
#ifdef __PARA
    if (me.eq.1.and.mypool.eq.1) then
#endif
      sigma_g = sigma(1:ngms,1:ngms,:)
      write ( iunsigma, rec = ik0, iostat = ios) sigma_g
#ifdef __PARA
    endif
#endif
    !
    ! end loop on {k0}
  enddo 
  ! 
  call stop_clock ('GW product')
  !
  ! CALCULATION OF THE MATRIX ELEMENTS
  !
  do ik0 = 1, nk0 
    call sigma_matel ( ik0, vr, xk0, nwsigma, wsigma)
  enddo
  !
!
! it looks like I have a problem in closing these
! files in parallel - tried several things (only headnode
! or everybody; only keep; keep some and delete some; all delete)
! should not matter that much as long as it finishes smoothly
!
! close (iuncoul, status = 'delete')
! close (iungreen, status = 'delete')
! close (iunsigma, status = 'keep')

  close (iunwfc, status = 'delete')
  !
  call stop_clock ('GWHS')
  !
  call print_clock('GWHS')
  call print_clock('coulomb')
  call print_clock('green_linsys')
  call print_clock('GW product')
  call print_clock('sigma_matel')
  !
  write(stdout,'(/4x,"End of program GWHS")')
  write(stdout,'(4x,a/)') repeat('-',67)
#ifdef __PARA
  call mp_barrier()
  call mp_end()
#endif
  !
  stop
  end program gwhs
  !----------------------------------------------------------------
  ! 
