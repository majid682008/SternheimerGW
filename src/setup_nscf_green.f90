!------------------------------------------------------------------------------
!
! This file is part of the Sternheimer-GW code.
! Parts of this file are taken from the Quantum ESPRESSO software
! P. Giannozzi, et al, J. Phys.: Condens. Matter, 21, 395502 (2009)
!
! Copyright (C) 2010 - 2016 Quantum ESPRESSO group,
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
!> This routine initializes the global modules for the nscf run.
!!
!! For the calculation of \f$Sigma\f$, we want to convolute \f$G_{k - q}\f$
!! and \f$W_q\f$. Hence, we construct for a given k point and q grid all points
!! \f$k - q\f$ to evaluate the Green's function at these points.
!------------------------------------------------------------------------------ 
SUBROUTINE setup_nscf_green(kpt)

  !
  ! ... This routine initializes variables for the non-scf calculations at k 
  ! ... and k-q required by the linear response calculation at finite q.
  ! ... Here we find the symmetry group of the crystal that leaves
  ! ... the GW q-vector (xq) unchanged. 
  ! ... "nsym" crystal symmetries s, ftau, t_rev, "nrot" lattice symetries "s"
  ! ... "nkstot" k-points in the irreducible BZ wrt lattice symmetry
  ! ... Produced on output:
  ! ... symmetries ordered with the "nsymq" GW symmetries first
  ! ... "nkstot" k- and k+q-points in the IBZ calculated for the GW symmetries.)
  ! ... Misc. data needed for running the non-scf calculation
  !
  !----------------------------------------------------------------------------

  USE basis,              ONLY : natomwfc
  USE cell_base,          ONLY : at, bg
  USE constants,          ONLY : degspin
  USE control_flags,      ONLY : ethr, isolve, david, &
                                 use_para_diag, max_cg_iter
  USE disp,               ONLY : nqs, x_q, wq
  USE ions_base,          ONLY : nat, ityp
  USE kinds,              ONLY : dp
  USE klist,              ONLY : xk, wk, nks, nkstot, qnorm, nelec
  USE mp,                 ONLY : mp_sum
  USE mp_pools,           ONLY : inter_pool_comm, kunit
  USE noncollin_module,   ONLY : noncolin
  USE parameters,         ONLY : npk
  USE qpoint,             ONLY : nksq, ikks, ikqs
  USE symm_base,          ONLY : s, nsym, invs
  USE uspp_param,         ONLY : n_atom_wfc
  USE wvfct,              ONLY : nbnd, nbndx

  !
  IMPLICIT NONE
  !
  !> The point at which, we want to evaluate \f$\Sigma\f$
  REAL(dp), INTENT(IN) :: kpt(3)
  !
  !> Temporary array for the number of tasks
  INTEGER, ALLOCATABLE :: num_task(:)
  !
  !> first and last q point done on this process
  INTEGER iq_start, iq_stop
  !
  !> counter on the q points
  INTEGER iq
  !
  !> counter on the k points
  INTEGER ik
  !
  !> number of points in the star of q
  INTEGER num_star
  !
  !> counter on the points in the star
  INTEGER istar
  !
  !> index of +q for all symmetry operations
  INTEGER indx_sq(48)
  !
  !> index of -q if necessary
  INTEGER indx_mq
  !
  !> number of symmetry operations that lead to certain q point
  INTEGER num_symq(48)
  !
  !> the point in the star
  REAL(dp) star_xq(3, 48)
  !
  !> map to distribute the k points
  INTEGER,  ALLOCATABLE :: map(:)

  !
  ! ... threshold for diagonalization ethr - should be good for all cases
  !
  ethr= 1.0D-9 / nelec
  !
  ! ... variables for iterative diagonalization (Davidson is assumed)
  !
  isolve = 0
  david  = 4
  nbndx  = david*nbnd
  max_cg_iter = 20
  natomwfc    = n_atom_wfc(nat, ityp, noncolin)
  !
#ifdef __MPI
  IF (use_para_diag) CALL check_para_diag(nbnd)
#else
  use_para_diag = .FALSE.
#endif
  !
  ! ... Symmetry and k-point section
  !
  ! the first k-point is used for Sigma
  nkstot = 1
  xk(:, nkstot) = kpt
  wk(nkstot) = 0.0_dp
  !
  ! loop over all q-points
  DO iq = 1, nqs
    !
    ! determine the star of this q-point
    !
    CALL star_q(x_q(:,iq), at, bg, nsym, s, invs, num_star, star_xq, indx_sq, num_symq, indx_mq, .FALSE.)
    !
    DO istar = 1, num_star
      !
      ! for G, we need the eigenvalues at k - q
      nkstot = nkstot + 1
      xk(:, nkstot) = kpt - star_xq(:, istar)
      wk(nkstot) = wq(iq) / REAL(num_star, KIND=dp)
      !
    END DO ! istar
    ! 
  END DO ! iq
  !
  IF (nkstot > npk) CALL errore('setup', 'too many k points', nkstot)

  !
  ! distribute the k-points across the pool
  !
  ! k-points are distributed in batches of 1
  kunit = 1
  !
  ! distribute xk, wk, and map
  ALLOCATE(map(nkstot))
  map = [(ik, ik = 1, nkstot)]
  CALL divide_et_impera(xk, wk, map, .TRUE., nkstot, nks)

  !
  ! exclude the first k point which is not a k - q point
  nksq = COUNT(map(:nks) > 1)
  !
  ! allocate necessary arrays
  ALLOCATE(ikks(nksq), ikqs(nksq))
  !
  ! ikks is initialized to 0
  ikks = 0
  !
  iq = 0
  DO ik = 1, nks
    !
    ! set ikks if this process contains the element 1
    IF (map(ik) == 1) THEN
      !
      ikks = ik
      !
      ! do not copy the first element to config type
      CYCLE
      !
    END IF
    !
    iq = iq + 1
    ! set ikqs
    ikqs(iq) = ik
    !
  END DO ! iq

  !
  ! ...notice: qnorm is used by allocate_nlpot to determine
  ! the correct size of the interpolation table "qrad"
  !
  qnorm = SQRT(SUM(kpt(:)**2))
  !
  RETURN
  !
END SUBROUTINE setup_nscf_green
