!------------------------------------------------------------------------------
!
! This file is part of the SternheimerGW code.
! 
! Copyright (C) 2010 - 2018
! Henry Lambert, Martin Schlipf, and Feliciano Giustino
!
! SternheimerGW is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! SternheimerGW is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with SternheimerGW. If not, see
! http://www.gnu.org/licenses/gpl.html .
!
!------------------------------------------------------------------------------ 
!> Provides a wrapper around the various routines to perform an analytic continuation.
!!
!! Depending on the setting either a Godby-Needs PP model, a Pade approximant,
!! or the AAA algorithm is used to expand the given quantity from a few points
!! to the whole complex plane.
MODULE analytic_module

  IMPLICIT NONE

  !> Use the Godby-Needs plasmon pole model.
  INTEGER, PARAMETER :: godby_needs = 1

  !> Use the conventional Pade approximation.
  INTEGER, PARAMETER :: pade_approx = 2

  !> Use the robust Pade approximation.
  INTEGER, PARAMETER :: pade_robust = 3

  !> Use the AAA rational approximation.
  INTEGER, PARAMETER :: aaa_approx = 4

  !> Use the AAA rational approximation and correct poles
  INTEGER, PARAMETER :: aaa_pole = 5

CONTAINS

!> Wrapper routine to evaluate the analytic continuation using different methods.
SUBROUTINE analytic_coeff(model_coul, thres, freq, scrcoul_g)

  USE analytic_aaa_module,ONLY : aaa_type => aaa_approx, aaa_generate, no_error
  USE freqbins_module,    ONLY : freqbins_type, freqbins_symm
  USE godby_needs_module, ONLY : godby_needs_coeffs
  USE kinds,              ONLY : dp
  USE pade_module,        ONLY : pade_coeff_robust

  !> The selected screening model.
  INTEGER, INTENT(IN)  :: model_coul

  !> The threshold determining the accuracy of the calculation.
  REAL(dp), INTENT(IN) :: thres

  !> The frequency grid used for the calculation.
  TYPE(freqbins_type), INTENT(IN) :: freq

  !> *on input*: the screened Coulomb interaction on the frequency grid<br>
  !! *on output*: the coefficients used to evaluate the screened Coulomb
  !! interaction at an arbitrary frequency
  COMPLEX(dp), INTENT(INOUT) :: scrcoul_g(:,:,:)

  !> frequency used for Pade coefficient (will be extended if frequency
  !! symmetry is used)
  COMPLEX(dp), ALLOCATABLE :: z(:)

  !> value of the screened Coulomb interaction on input mesh
  COMPLEX(dp), ALLOCATABLE :: u(:)

  !> coefficients of the Pade approximation
  COMPLEX(dp), ALLOCATABLE :: a(:)

  !> coefficients of the AAA approximation
  TYPE(aaa_type) aaa

  !> the number of G vectors in the correlation grid
  INTEGER :: num_g_corr

  !> loop variables for G and G'
  INTEGER :: ig, igp

  !> total number of frequencies
  INTEGER :: num_freq

  !> maximum number of polynomials generated by AAA
  INTEGER :: mmax

  !> actual number of polynomial generated by AAA
  INTEGER :: mm

  !> error flag for AAA algorithm
  INTEGER :: info

  !> complex constant of zero
  COMPLEX(dp), PARAMETER :: zero = CMPLX(0.0_dp, 0.0_dp, KIND = dp)

  ! initialize helper variable
  num_freq = SIZE(freq%solver)
  num_g_corr = SIZE(scrcoul_g, 1)

  ! sanity check for the array size
  IF (SIZE(scrcoul_g, 2) /= num_g_corr) &
    CALL errore(__FILE__, "input array should have same dimension for G and G'", 1)
  IF (SIZE(scrcoul_g, 3) /= freq%num_freq()) &
    CALL errore(__FILE__, "frequency dimension of Coulomb inconsistent with frequency mesh", 1)

  !
  ! analytic continuation to the complex plane
  !
  SELECT CASE (model_coul)

  !! 1. Godby-Needs plasmon-pole model - assumes that the function can be accurately
  !!    represented by a single pole and uses the value of the function at two
  !!    frequencies \f$\omega = 0\f$ and \f$\omega = \omega_{\text{p}}\f$ to determine
  !!    the parameters.
  CASE (godby_needs)
    CALL godby_needs_coeffs(AIMAG(freq%solver(2)), scrcoul_g)

  !! 2. Pade expansion - evaluate Pade coefficients for a continued fraction expansion
  !!    using a given frequency grid; symmetry may be used to extend the frequency grid
  !!    to more points.
  CASE (pade_approx) 

    ! allocate helper arrays
    ALLOCATE(u(freq%num_freq()))
    ALLOCATE(a(freq%num_freq()))

    ! use symmetry to extend the frequency mesh
    CALL freqbins_symm(freq, z, scrcoul_g)

    ! evalute Pade approximation for all G and G'
    DO igp = 1, num_g_corr
      DO ig = 1, num_g_corr

        ! set frequency and value used to determine the Pade coefficients
        u = scrcoul_g(ig, igp, :)

        ! evaluate the coefficients
        CALL pade_coeff(freq%num_freq(), z, u, a)

        ! store the coefficients in the same array
        scrcoul_g(ig, igp, :) = a

      END DO ! ig
    END DO ! igp

  !! 3. robust Pade expansion - evaluate Pade coefficients using a circular frequency
  !!    mesh in the complex plane
  CASE (pade_robust) 
    CALL pade_coeff_robust(freq%solver, thres, scrcoul_g)

  !! 4. AAA rational approximation - evaluate coefficient for a given frequency mesh
  CASE (aaa_approx, aaa_pole)

    ! use symmetry to extend the frequency mesh
    CALL freqbins_symm(freq, z, scrcoul_g)

    ! allocate helper array
    mmax = freq%num_freq() 
    ALLOCATE(u(mmax))

    ! note that AAA will generate 3 coefficients for every input point so
    ! that we can use at most 1/3 of the frequencies
    IF (model_coul == aaa_approx) mmax = mmax / 3

    ! evalute AAA approximation for all G and G'
    DO igp = 1, num_g_corr
      DO ig = 1, num_g_corr

        ! set frequency and value used to determine the Pade coefficients
        u = scrcoul_g(ig, igp, :)

        ! evaluate the coefficients
        CALL aaa_generate(thres, mmax, z, u, aaa, info)
        CALL errore(__FILE__, 'error occured in AAA approximation', info)

        IF (model_coul == aaa_approx) THEN
          ! determine number of polynomials generated
          mm = SIZE(aaa%position)

          ! store the coefficients in the same array
          scrcoul_g(ig, igp, :) = zero
          scrcoul_g(ig, igp, 0 * mmax + 1 : 0 * mmax + mm) = aaa%position
          scrcoul_g(ig, igp, 1 * mmax + 1 : 1 * mmax + mm) = aaa%value
          scrcoul_g(ig, igp, 2 * mmax + 1 : 2 * mmax + mm) = aaa%weight

        ELSE
          ! correct poles of AAA approximation
          CALL pole_correction(thres, aaa, scrcoul_g(ig, igp, :))
        END IF

      END DO ! ig
    END DO ! igp

  CASE DEFAULT
    CALL errore(__FILE__, "No screening model chosen!", 1)
  END SELECT

END SUBROUTINE analytic_coeff

!> Construct the screened Coulomb interaction for an arbitrary frequency.
SUBROUTINE analytic_eval(gmapsym, grid, freq_in, scrcoul_coeff, freq_out, scrcoul)

  USE control_gw,         ONLY : model_coul
  USE fft6_module,        ONLY : fft_map_generate
  USE freqbins_module,    ONLY : freqbins_type, freqbins_symm
  USE godby_needs_module, ONLY : godby_needs_model
  USE gvect,              ONLY : mill
  USE kinds,              ONLY : dp
  USE pade_module,        ONLY : pade_eval_robust
  USE sigma_grid_module,  ONLY : sigma_grid_type
  USE timing_module,      ONLY : time_construct_w

  !> The symmetry map from the irreducible point to the current one
  INTEGER,                  INTENT(IN)  :: gmapsym(:)

  !> the FFT grids on which the screened Coulomb interaction is evaluated
  TYPE(sigma_grid_type),    INTENT(IN)  :: grid

  !> the frequency grid on which W was evaluated
  TYPE(freqbins_type),      INTENT(IN)  :: freq_in

  !> the coefficients of the screened Coulomb potential used for the analytic continuation
  COMPLEX(dp),              INTENT(IN)  :: scrcoul_coeff(:,:,:)

  !> the frequency for which the screened Coulomb potential is evaluated
  COMPLEX(dp),              INTENT(IN)  :: freq_out

  !> The screened Coulomb interaction symmetry transformed and parallelized over images.
  !! The array is appropriately sized to do a FFT on the output.
  COMPLEX(dp), ALLOCATABLE, INTENT(OUT) :: scrcoul(:,:)

  !> Counter on the G and G' vector
  INTEGER ig, igp

  !> corresponding point to G' in global G list
  INTEGER igp_g

  !> allocation error flag
  INTEGER ierr

  !> helper array to extract the current coefficients
  COMPLEX(dp), ALLOCATABLE :: coeff(:)

  !> helper array for the frequencies
  COMPLEX(dp), ALLOCATABLE :: freq(:)

  !> symmetrized version of output frequency
  COMPLEX(dp) freq_sym

  !> complex constant of zero
  COMPLEX(dp), PARAMETER :: zero = CMPLX(0.0_dp, 0.0_dp, KIND = dp)

  !> the map from local to global G grid
  INTEGER, ALLOCATABLE :: fft_map(:)

  CALL start_clock(time_construct_w)

  !
  ! create and initialize output array
  ! allocate space so that we can perform an in-place FFT on the array
  !
  ALLOCATE(scrcoul(grid%corr_fft%nnr, grid%corr_par_fft%nnr), STAT = ierr)
  IF (ierr /= 0) THEN
    CALL errore(__FILE__, "allocation of screened Coulomb potential failed", 1)
    RETURN
  END IF
  scrcoul = zero

  ! helper array for frequencies in case of symmetry
  IF (model_coul == pade_approx) THEN
    CALL freqbins_symm(freq_in, freq)
  END IF

  ! symmetrize output frequency
  freq_sym = freq_in%symmetrize(freq_out)

  !
  ! construct screened Coulomb interaction
  !
  !! The screened Coulomb interaction is interpolated with either Pade or
  !! Godby-Needs analytic continuation. We only evaluate W at the irreducible
  !! mesh, but any other point may be obtained by
  !! \f{equation}{
  !!   W_{S q}(G, G') = W_{q}(S^{-1} G, S^{-1} G')~.
  !! \f}
  ALLOCATE(coeff(freq_in%num_freq()))

  ! create pointer from local to global grid
  CALL fft_map_generate(grid%corr_par_fft, mill, fft_map)

  DO igp = 1, grid%corr_par_fft%ngm
    !
    ! get the global corresponding index
    igp_g = fft_map(igp)

    DO ig = 1, grid%corr_fft%ngm

      ! symmetry transformation of the coefficients
      coeff = scrcoul_coeff(gmapsym(ig), gmapsym(igp_g), :)

      SELECT CASE (model_coul)

      CASE (pade_approx)
        !
        ! Pade analytic continuation
        CALL pade_eval(freq_in%num_freq(), freq, coeff, freq_sym, scrcoul(ig, igp))

      CASE (pade_robust)
        !
        ! robust Pade analytic continuation
        CALL pade_eval_robust(coeff, freq_sym, scrcoul(ig, igp))

      CASE (godby_needs)
        !
        ! Godby-Needs Pole model
        scrcoul(ig, igp) = godby_needs_model(freq_sym, coeff)

      CASE (aaa_approx)
        !
        ! AAA approximation
        scrcoul(ig, igp) = aaa_approx_eval(freq_sym, coeff)

      CASE (aaa_pole)
        !
        ! AAA approximation with pole removal
        scrcoul(ig, igp) = aaa_pole_eval(freq_sym, coeff)

      CASE DEFAULT
        CALL errore(__FILE__, "No screening model chosen!", 1)

      END SELECT

    END DO ! ig
  END DO ! igp

  CALL stop_clock(time_construct_w)

END SUBROUTINE analytic_eval

!> wrapper routine to evaluate AAA approximation
FUNCTION aaa_approx_eval(freq_sym, coeff) RESULT (res)

  USE analytic_aaa_module,   ONLY: aaa_type => aaa_approx, aaa_evaluate
  USE analytic_array_module, ONLY: allocate_copy_from_to
  USE constants,             ONLY: eps12
  USE kinds,                 ONLY: dp

  !> frequency for which analytic continuation is evaluated
  COMPLEX(dp), INTENT(IN) :: freq_sym

  !> coefficients used to evaluate analytic continuation
  COMPLEX(dp), INTENT(IN) :: coeff(:)

  !> resulting analytic continuation
  COMPLEX(dp) res

  !> temporary array to store the result
  COMPLEX(dp), ALLOCATABLE :: tmp_res(:)

  !> coefficients stored as analytic continuation type
  TYPE(aaa_type) aaa

  !> maximum and actual number of points
  INTEGER mmax, mm

  mmax = SIZE(coeff) / 3
  mm = COUNT(ABS(coeff(2*mmax + 1:3*mmax)) > eps12)

  CALL allocate_copy_from_to(coeff(1:mm), aaa%position)
  CALL allocate_copy_from_to(coeff(mmax+1:mmax+mm), aaa%value)
  CALL allocate_copy_from_to(coeff(2*mmax+1:2*mmax+mm), aaa%weight)

  CALL aaa_evaluate(aaa, [freq_sym], tmp_res)
  res = tmp_res(1)

END FUNCTION aaa_approx_eval

!> correct the poles of AAA by removing weak residual
SUBROUTINE pole_correction(thres, aaa, coeff)

  USE analytic_aaa_module, ONLY: aaa_type => aaa_approx, aaa_pole_residual, pole_residual, no_error
  USE kinds,               ONLY: dp

  !> threshold for removing a pole
  REAL(dp), INTENT(IN) :: thres

  !> the coefficients of the analytic continuation
  TYPE(aaa_type), INTENT(IN) :: aaa

  !> the poles and residuals of the analytic continuation
  COMPLEX(dp), INTENT(OUT) :: coeff(:)

  !> complex constant of zero
  COMPLEX(dp), PARAMETER :: zero = CMPLX(0.0_dp, 0.0_dp, KIND = dp)

  TYPE(pole_residual) pole_res
  INTEGER info, ipole, indx, half_size

  CALL aaa_pole_residual(aaa, pole_res, info)
  CALL errore(__FILE__, 'error determining the poles of the AAA approximation', info)

  half_size = SIZE(coeff) / 2
  IF (COUNT(ABS(pole_res%residual) > thres) > half_size) THEN
    CALL errore(__FILE__, &
      'two many relevant poles, try reducing the coulomb threshold or increasing the number of frequencies', 1)
  END IF

  coeff = zero ; indx = 0
  DO ipole = 1, SIZE(pole_res%residual)
    IF (ABS(pole_res%residual(ipole)) > thres) THEN
      indx = indx + 1
      coeff(indx) = pole_res%pole(ipole)
      coeff(indx + half_size) = pole_res%residual(ipole)
    END IF
  END DO

END SUBROUTINE pole_correction

!> evaluate value based on poles and residue 
FUNCTION aaa_pole_eval(freq_sym, coeff) RESULT (res)

  USE kinds, ONLY: dp

  !> frequency for which analytic continuation is evaluated
  COMPLEX(dp), INTENT(IN) :: freq_sym

  !> pole and residue of the analytic continuation
  COMPLEX(dp), INTENT(IN) :: coeff(:)

  !> resulting analytic continuation
  COMPLEX(dp) res

  !> complex constant of zero
  COMPLEX(dp), PARAMETER :: zero = CMPLX(0.0_dp, 0.0_dp, KIND = dp)

  COMPLEX(dp) residue, pole
  INTEGER num_pole, ipole, half_size

  half_size = SIZE(coeff) / 2
  num_pole = COUNT(ABS(coeff(half_size+1:)) > 0.0_dp)

  res = zero
  DO ipole = 1, num_pole
    pole = coeff(ipole)
    residue = coeff(ipole + half_size)
    res = res + residue / (freq_sym - pole)
  END DO

END FUNCTION aaa_pole_eval

END MODULE analytic_module
