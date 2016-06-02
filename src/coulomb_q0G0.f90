!------------------------------------------------------------------------------
!
! This file is part of the Sternheimer-GW code.
! 
! Copyright (C) 2010 - 2016 
! Henry Lambert, Martin Schlipf, and Feliciano Giustino
!
! Sternheimer-GW is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! Sternheimer-GW is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with Sternheimer-GW. If not, see
! http://www.gnu.org/licenses/gpl.html .
!
!------------------------------------------------------------------------------ 
SUBROUTINE coulomb_q0G0(iq, eps_m) 
!-----------------------------------------------------------------------
! This subroutine is the main driver of the COULOMB self consistent cycle
! which calculates the dielectric matrix by generating the density response
! to a charge dvbare(nl(ig)) = 1.00 + i*0.00 at a single fourier component (G).
! The dielectric matrix is given by:
! eps_{q}^{-1}(G,G',iw) = (\delta_{GG'} + drhoscfs^{scf}_{G,G',iw})
  USE cell_base,        ONLY : alat, tpiba2, omega
  USE constants,        ONLY : e2, fpi, RYTOEV, pi, eps8
  USE control_gw,       ONLY : zue, convt, rec_code, modielec, eta, godbyneeds, padecont,&
                               solve_direct, do_epsil, do_q0_only
  USE disp,             ONLY : nqs, nq1, nq2, nq3
  USE eqv_gw,           ONLY : drhoscfs, dvbare
  USE fft_base,         ONLY : dfftp, dffts
  USE fft_interfaces,   ONLY : invfft, fwfft
  USE freq_gw,          ONLY : fpol, fiu, nfs, nfsmax, nwcoul, wcoul
  USE gvecs,            ONLY : nls
  USE gvect,            ONLY : ngm, g, nl
  USE gwsigma,          ONLY : sigma_c_st
  USE gwsymm,           ONLY : ig_unique, ngmunique
  USE io_global,        ONLY : stdout, ionode
  USE ions_base,        ONLY : nat
  USE klist,            ONLY : lgauss
  USE kinds,            ONLY : DP
  USE lsda_mod,         ONLY : nspin
  USE noncollin_module, ONLY : noncolin, nspin_mag
  USE partial,          ONLY : done_irr, comp_irr
  USE paw_variables,    ONLY : okpaw
  USE qpoint,           ONLY : xq
  USE units_gw,         ONLY : iuncoul, lrcoul
  USE uspp,             ONLY : okvan
  USE uspp_param,       ONLY : nhm
  USE mp_world,         ONLY : mpime
  USE mp_pools,         ONLY : me_pool, root_pool, inter_pool_comm
  USE mp,               ONLY : mp_sum, mp_barrier
  USE mp_global,        ONLY : inter_image_comm, intra_image_comm, &
                               my_image_id, nimage, root_image

  IMPLICIT NONE

  REAL(DP) :: tcpu, get_clock
! timing variables
  REAL(DP) :: qg2, qg2coul
  INTEGER :: ig, igp, iw, npe, irr, icounter
  INTEGER :: igstart, igstop, igpert, isp
  COMPLEX(DP), allocatable :: drhoaux (:,:) 
  COMPLEX(DP) :: padapp, w
!HL temp variable for scrcoul to write to file.  
  COMPLEX(DP) :: cw
  COMPLEX(DP) :: eps_m(nfs)
  INTEGER :: unf_recl, recl, ios
  INTEGER :: iq, screening 
  LOGICAL :: exst
!again should decide if this should be allocated globally. 
  COMPLEX(DP) :: scrcoul(sigma_c_st%ngmt, sigma_c_st%ngmt, nfs, 1)
!modeps and spencer-alavi vars
  REAL(DP) :: wwp, eps0, q0, wwq, fac
  REAL(DP) :: qg, rcut, spal
! used to test the recover file
  EXTERNAL get_clock

if(solve_direct) then
  ALLOCATE (drhoscfs(dfftp%nnr, nfs, 1))    
else
!for self-consistent solution we only consider one
!frequency at a time. To save memory and time and lines of codes etc.
!we use the frequency variable for multishift as the nspin_mag var.
!to extend this to magnetic with multishift we need to add another
!dimension to drhoscfrs
  WRITE(stdout, '(4x,4x,"nspinmag", i4)') nspin_mag
  ALLOCATE (drhoscfs(dfftp%nnr, nspin_mag, 1))    
endif
irr=1
scrcoul(:,:,:,:) = (0.d0, 0.0d0)
!LOOP OVER ig, unique g vectors only. 
!g is sorted in magnitude order.
!WRITE(1000+mpime, '(2i4)') igstart, igstop
!     if (do_q0_only.and.ig.gt.1) CYCLE
    !qg2 = (g(1,ig_unique(1))+xq(1))**2+(g(2,ig_unique(1))+xq(2))**2+(g(3,ig_unique(1))+xq(3))**2
    qg2 = (g(1,1)+xq(1))**2+(g(2,1)+xq(2))**2+(g(3,1)+xq(3))**2
    if(qg2.lt.0.0001.AND.lgauss) then 
       write(6,'("Not calculating static electric field applied to metal, cycling coulomb")')
       WRITE(stdout, '(4x,4x,"inveps_{GG}(q,w) =   0.000000   0.0000000")')
       DEALLOCATE(drhoscfs)
       RETURN
    endif
    IF(solve_direct) THEN
       drhoscfs      = dcmplx(0.0d0, 0.0d0)
       dvbare(:)     = dcmplx(0.0d0, 0.0d0)
       dvbare (nls(1)) = dcmplx(1.d0, 0.d0)
       CALL invfft('Smooth', dvbare, dffts)
       CALL solve_lindir (dvbare, drhoscfs)
       CALL fwfft('Smooth', dvbare, dffts)
       DO iw = 1, nfs
          CALL fwfft('Dense', drhoscfs(:,iw,1), dffts)
          WRITE(stdout, '(4x,4x,"eps_{GG}(q,w) = ", 2f10.4)') drhoscfs(nls(1),iw,1) &
&                                                           + dvbare(nls(1))
          eps_m(iw) = drhoscfs(nls(1),iw,1) + 1.0d0
       ENDDO
    ELSE
     DO iw = 1, nfs
       drhoscfs      = dcmplx(0.0d0, 0.0d0)
       dvbare(:)     = dcmplx(0.0d0, 0.0d0)
       dvbare (nls(1)) = dcmplx(1.d0, 0.d0)
       CALL invfft('Smooth', dvbare, dffts)
       CALL solve_linter (dvbare, iw, drhoscfs)
       CALL fwfft('Smooth', dvbare, dffts)
       DO isp =1 , nspin_mag
          CALL fwfft('Dense', drhoscfs(:,isp,1), dffts)
       ENDDO
       IF(ionode) THEN
         WRITE(stdout, '(4x,4x,"inveps_{GG}(q,w) = ", 2f16.9)') drhoscfs(nls(1), 1, 1) + dvbare(nls(1))
       ENDIF
     !(eps_{M}^{-1} - 1)
       eps_m(iw) = drhoscfs(nls(1),1,1)
     ENDDO
    ENDIF
545 CONTINUE
tcpu = get_clock ('GW')
DEALLOCATE (drhoscfs)
RETURN
END SUBROUTINE coulomb_q0G0
