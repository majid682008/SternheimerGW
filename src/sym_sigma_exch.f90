SUBROUTINE sym_sigma_exch(ik0)
  USE kinds,         ONLY : DP
  USE constants,     ONLY : e2, fpi, RYTOEV, tpi, eps8, pi
  USE disp,          ONLY : nqs, nq1, nq2, nq3, wq, x_q, xk_kpoints, num_k_pts
  USE control_gw,    ONLY : eta, nbnd_occ, trunc_2d
  USE klist,         ONLY : wk, xk, nkstot, nks
  USE io_files,      ONLY : prefix, iunigk
  USE wvfct,         ONLY : nbnd, npw, npwx, igk, g2kin, et, ecutwfc
  USE symm_base,     ONLY : nsym, s, time_reversal, t_rev, ftau, invs, nrot
  USE cell_base,     ONLY : omega, tpiba2, at, bg, tpiba, alat
  USE eqv,           ONLY : evq, eprec
  USE units_gw,      ONLY : iunsex, lrsex, lrwfc, iuwfc
  USE qpoint,        ONLY : xq, npwq, igkq, nksq
  USE gwsigma,       ONLY : sigma_x_st, nbnd_sig
  USE buffers,       ONLY : save_buffer, get_buffer
  USE io_global,     ONLY : stdout, ionode_id, ionode
  USE gvect,         ONLY : nl, ngm, g, nlm, gstart, gl, igtongl
  USE mp,            ONLY : mp_sum, mp_barrier
  USE mp_pools,      ONLY : inter_pool_comm
  USE mp_world,      ONLY : nproc, mpime
IMPLICIT NONE
!ARRAYS to describe exchange operator.
  LOGICAL :: limit, lgamma
  REAL(DP) :: rcut, spal, zcut
  INTEGER :: ikmq, ik0, ik
  INTEGER :: ig, igp, ir, irp
  INTEGER :: iq, ipol, ibnd, jbnd, counter, ios
  REAL(DP) :: qg2, qg, qxy, qz
  COMPLEX(DP) :: ZDOTC
  COMPLEX(DP) :: czero, exch_element
!q-vector of coulomb potential xq_coul := k_{0} - xk(ik)
  REAL(DP) :: xq_coul(3)
!Arrays to handle case where nlsco does not contain all G vectors required for |k+G| < ecut
  INTEGER     :: igkq_ig(npwx) 
  INTEGER     :: igkq_tmp(npwx) 
  INTEGER     :: ikq
  COMPLEX(DP) :: sigma_band_ex(nbnd_sig, nbnd_sig)
  COMPLEX(DP), ALLOCATABLE :: sigma_ex(:,:)
  COMPLEX(DP), ALLOCATABLE :: greenf_na(:,:), greenf_nar(:,:)
  COMPLEX(DP), ALLOCATABLE :: barcoul(:,:), barcoulr(:,:)
  COMPLEX(DP), ALLOCATABLE :: sigma_g_ex(:,:)
  INTEGER, ALLOCATABLE  :: gmapsym(:,:)
  COMPLEX(DP), ALLOCATABLE  ::  eigv(:,:)
  REAL (DP)   :: xk1(3), aq(3)
  INTEGER     :: iq1
  LOGICAL     :: found_q, inv_q
  INTEGER     :: iqrec, nig0, isym
  REAL(DP)    :: sxq(3,48), xqs(3,48)
  INTEGER     :: imq, isq(48), nqstar, nkpts
  INTEGER     :: nsq(48), i, ikstar
  INTEGER     :: isymop
! Self-Energy grid:
! iGv
  CALL start_clock('sigma_exch')
  ALLOCATE ( sigma_ex    (sigma_x_st%dfftt%nnr, sigma_x_st%dfftt%nnr) )
!Technically only need gmapsym up to sigma_c_st%ngmt or ngmgrn...
  ALLOCATE ( gmapsym  (ngm, nrot)   )
  ALLOCATE ( eigv     (ngm, nrot)   )
  CALL gmap_sym(nrot, s, ftau, gmapsym, eigv, invs)
!set appropriate weights for points in the brillouin zone. 
!weights of all the k-points are in odd positions in list.  
  wq(:) = 0.0d0
!check if we're looking at k = gamma.
  do iq = 1, nksq
        wq(iq) = 0.5d0*wk(iq)
  enddo

  rcut = (float(3)/float(4)/pi*omega*float(nq1*nq2*nq3))**(float(1)/float(3))
  WRITE(6,'("rcut ", f12.7)') rcut

  write(6,'(4x,"Sigma exchange for k",i3, 3f12.7)') ik0, (xk_kpoints(ipol, ik0), ipol=1,3)
  write(6,'(4x,"Occupied bands at Gamma: ",i3)') nbnd_occ(ik0)
  czero = (0.0d0, 0.0d0)
  sigma_ex(:,:) = (0.0d0, 0.0d0)
  DO iq = 1, nqs
     DO isymop = 1, nsym
        xq(:) = x_q(:,iq)
        CALL rotate(xq, aq, s, nsym, invs(isymop))
       !xq(:) = aq(:)
        xk1 = xk_kpoints(:,ik0) - aq(:)
        nig0  = 1
        call find_qG_ibz(xk1, s, iqrec, isym, nig0, found_q, inv_q)
        if(inv_q) write(1000+mpime, '("Need to use time reversal")')
        write(1000+mpime, '("xq point, iq")')
        write(1000+mpime, '(3f11.7, i4)') xq(:), iq
        write(1000+mpime, '("xk1 point, isymop")')
        write(1000+mpime, '(3f11.7, i4)') xk1(:), isymop
        write(1000+mpime, '("xk point IBZ, iqrec, isym, nig0")')
        write(1000+mpime, '(3f11.7, 3i4)') x_q(:, iqrec), iqrec, isym, nig0


        call get_buffer (evq, lrwfc, iuwfc, iqrec)
        IF (nksq.gt.1) THEN
            CALL gk_sort(x_q(1,iqrec), ngm, g, ( ecutwfc / tpiba2 ),&
                          npw, igk, g2kin )
        ENDIF
        npwq = npw
!Need a loop to find all plane waves below ecutsco when igkq 
!takes us outside of this sphere.  
        counter  = 0
        igkq_tmp = 0
        igkq_ig  = 0
        do ig = 1, npwq
           if((igk(ig).le.sigma_x_st%ngmt).and.((igk(ig)).gt.0)) then
               counter = counter + 1
               igkq_tmp (counter) = igk(ig)
               igkq_ig  (counter) = ig
           endif
        enddo
        allocate ( greenf_na   (sigma_x_st%ngmt, sigma_x_st%ngmt) )
!psi_{k+q}(r)psi^{*}_{k+q}(r')
        greenf_na = (0.0d0, 0.0d0)
        do ig = 1, counter
           do igp = 1, counter
              do ibnd = 1, nbnd_occ(iq)
                greenf_na(igkq_tmp(ig), igkq_tmp(igp)) = greenf_na(igkq_tmp(ig), igkq_tmp(igp)) + &
                                                         tpi*(0.0d0, 1.0d0)*conjg(evq(igkq_ig(ig),ibnd))*(evq(igkq_ig(igp), ibnd))
             enddo
           enddo
        enddo
!Fourier transform of green's function
     ALLOCATE ( greenf_nar  (sigma_x_st%dfftt%nnr, sigma_x_st%dfftt%nnr)  )
     greenf_nar(:,:) = czero
     call fft6_g(greenf_na(1,1), greenf_nar(1,1), sigma_x_st, gmapsym, eigv(1,1), isym, nig0, 1)
     DEALLOCATE(greenf_na)
     ALLOCATE ( barcoul  (sigma_x_st%ngmt, sigma_x_st%ngmt) )
     rcut = (float(3)/float(4)/pi*omega*float(nq1*nq2*nq3))**(float(1)/float(3))
     barcoul(:,:) = (0.0d0,0.0d0)
     IF(.not.trunc_2d) THEN
        do ig = 1, sigma_x_st%ngmt
          qg = sqrt((g(1,ig)  + xq(1))**2.d0  + (g(2,ig) + xq(2))**2.d0  &
                  + (g(3,ig)  + xq(3))**2.d0)
          qg2 =     (g(1,ig)  + xq(1))**2.d0  + (g(2,ig) + xq(2))**2.d0  &
                 + ((g(3,ig)) + xq(3))**2.d0
          limit = (qg.lt.eps8)
          if(.not.limit) then
              spal = 1.0d0 - cos (rcut * tpiba * qg)
              barcoul (gmapsym(ig, invs(isymop)), gmapsym(ig,invs(isymop))) = e2 * fpi / (tpiba2*qg2) * dcmplx(spal, 0.0d0)
          else
              barcoul(gmapsym(ig, invs(isymop)), gmapsym(ig, invs(isymop))) = (fpi*e2*(rcut**2))/2
          endif
        enddo
     ELSE
        zcut = 0.50d0*sqrt(at(1,3)**2 + at(2,3)**2 + at(3,3)**2)*alat
        rcut = -2*pi*zcut**2
        DO ig = 1, sigma_x_st%ngmt
                qg2 = (g(1,ig) + xq(1))**2 + (g(2,ig) + xq(2))**2 + (g(3,ig)+xq(3))**2
                qxy  = sqrt((g(1,ig) + xq(1))**2 + (g(2,ig) + xq(2))**2)
                qz   = sqrt((g(3,ig) + xq(3))**2)
         IF(qxy.gt.eps8) then
                spal = 1.0d0 + EXP(-tpiba*qxy*zcut)*((qz/qxy)*sin(tpiba*qz*zcut) - cos(tpiba*qz*zcut))
                barcoul(gmapsym(ig,invs(isymop)), gmapsym(ig, invs(isymop))) = dcmplx(e2*fpi/(tpiba2*qg2)*spal, 0.0d0)
         ELSE IF(qxy.lt.eps8.and.qz.gt.eps8) then
                spal = 1.0d0 - cos(tpiba*qz*zcut) - tpiba*qz*zcut*sin(tpiba*qz*zcut)
                barcoul(gmapsym(ig,invs(isymop)), gmapsym(ig, invs(isymop))) = dcmplx(e2*fpi/(tpiba2*qg2)*spal, 0.0d0)
         ELSE  
                barcoul(gmapsym(ig,invs(isymop)), gmapsym(ig, invs(isymop))) = dcmplx(rcut, 0.0d0)
         ENDIF
        ENDDO
       ! DO ig = 1, sigma_x_st%ngmt
       !         qg2 = (g(1,ig) + xq(1))**2 + (g(2,ig) + xq(2))**2 + (g(3,ig)+xq(3))**2
       !         limit = (qg2.lt.eps8) 
       !    IF(.not.limit) then
       !         qxy  = sqrt((g(1,ig) + xq(1))**2 + (g(2,ig) + xq(2))**2)
       !         qz   = sqrt((g(3,ig) + xq(3))**2)
       !         spal = 1.0d0 - EXP(-tpiba*qxy*zcut)*cos(tpiba*qz*zcut)
       !         barcoul(gmapsym(ig,invs(isymop)), gmapsym(ig, invs(isymop))) = dcmplx(e2*fpi/(tpiba2*qg2)*spal, 0.0d0)
       !    ELSE  
       !         barcoul(ig, ig) = 0.0d0
       !    ENDIF
       ! ENDDO
     ENDIF
     ALLOCATE (barcoulr    (sigma_x_st%dfftt%nnr,  sigma_x_st%dfftt%nnr))
     barcoulr(:,:) = (0.0d0, 0.0d0)
     call fft6(barcoul(1,1), barcoulr(1,1), sigma_x_st, 1)
     DEALLOCATE(barcoul)
     if (.not.inv_q) sigma_ex = sigma_ex + wq(iq)*(1.0d0/dble(nsym))*(0.0d0,1.0d0)/tpi*greenf_nar*barcoulr
     if (inv_q)      sigma_ex = sigma_ex + wq(iq)*(1.0d0/dble(nsym))*conjg((0.0d0,1.0d0)/tpi*greenf_nar)*barcoulr
     DEALLOCATE(barcoulr)
     DEALLOCATE(greenf_nar)
   ENDDO
  ENDDO
  CALL mp_sum (sigma_ex, inter_pool_comm)  
  ALLOCATE ( sigma_g_ex  (sigma_x_st%ngmt, sigma_x_st%ngmt) )
  sigma_g_ex(:,:) = (0.0d0,0.0d0)
  call fft6(sigma_g_ex, sigma_ex, sigma_x_st, -1)
  CALL davcio(sigma_g_ex, lrsex, iunsex, ik0,  1)
  DEALLOCATE(sigma_g_ex)
  DEALLOCATE (sigma_ex)
  CALL stop_clock('sigma_exch')
END SUBROUTINE sym_sigma_exch