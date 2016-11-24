!------------------------------------------------------------------------------
!
! This file is part of the Sternheimer-GW code.
! Parts of this file have been taken from the chebfun code.
! See http://www.chebfun.org/ for Chebfun information.
! 
! Copyright (C) 2010 - 2016 
! The University of Oxford and The Chebfun Developers,
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
!> Provides the routines to evaluate the Pade approximation to a function.
MODULE pade_module

  IMPLICIT NONE

  PRIVATE

  PUBLIC pade_robust

CONTAINS

  !> Pade approximation to a function.
  !!
  !! Constructs a Pade approximant to a function using the robust algorithm from
  !! [1] based on the SVD.
  !!
  !! This code is included in the Chebfun distribution for the convenience of
  !! readers of _Approximation Theory and Approximation Practice_, but it is not
  !! actually a Chebfun code. A Chebfun analogue is CHEBPADE.
  !!
  !! <h4>References:</h4>
  !! [1] P. Gonnet, S. Guettel, and L. N. Trefethen, "ROBUST PADE APPROXIMATION 
  !!     VIA SVD", SIAM Rev., 55:101-117, 2013.
  !!
  SUBROUTINE pade_robust(radius, func, deg_num, deg_den, coeff_num, coeff_den, tol_in)

    USE constants, ONLY: eps14
    USE kinds,     ONLY: dp

    !> The radius of the circle in the complex plane.
    REAL(dp),    INTENT(IN) :: radius

    !> The values of the function evaluated on a circle in the complex plane.
    !! The derivatives of the functions are computed via FFT.
    COMPLEX(dp), INTENT(IN) :: func(:)

    !> The degree of the numerator (must be positive)
    INTEGER,     INTENT(IN) :: deg_num

    !> The degree of the denominator (must be positive)
    INTEGER,     INTENT(IN) :: deg_den

    !> The Pade coefficient vector of the numerator
    COMPLEX(dp), ALLOCATABLE, INTENT(OUT) :: coeff_num(:)

    !> The Pade coefficient vector of the denominator
    COMPLEX(dp), ALLOCATABLE, INTENT(OUT) :: coeff_den(:)

    !> The optional **tol** argument specifies the relative tolerance; if
    !! omitted, it defaults to 1e-14. Set to 0 to turn off robustness.
    REAL(dp),    OPTIONAL,    INTENT(IN)  :: tol_in

    !> local variable for the tolerance
    REAL(dp) tol

    ! default value of tolerance 1e-14
    IF (PRESENT(tol_in)) THEN
      tol = tol_in
    ELSE
      tol = eps14
    END IF

    ! sanity check of the input
    IF (radius <= 0) &
      CALL errore(__FILE__, "radius in the complex plane must be > 0", 1)
    IF (deg_num < 0) &
      CALL errore(__FILE__, "degree of numerator must be positive", deg_num)
    IF (deg_den < 0) &
      CALL errore(__FILE__, "degree of denominator must be positive", deg_den)

  END SUBROUTINE pade_robust

  !> determine the derivatives of the function
  !!
  !! we use a FFT to evaluate the derivative of the function
  SUBROUTINE pade_derivative(radius, func, num_deriv, deriv)

    USE constants,  ONLY: eps14
    USE fft_scalar, ONLY: cft_1z
    USE kinds,      ONLY: dp

    !> The radius of the circle in the complex plane.
    REAL(dp),    INTENT(IN) :: radius

    !> The values of the function evaluated on a circle in the complex plane.
    COMPLEX(dp), INTENT(IN) :: func(:)

    !> The number of derivatives that should be generated
    INTEGER,     INTENT(IN) :: num_deriv

    !> The derivatives of the functions are computed via FFT.
    COMPLEX(dp), ALLOCATABLE, INTENT(OUT) :: deriv(:)

    !> use a backward FFT
    INTEGER,     PARAMETER :: backward = -1

    !> the number of FFTs done per call
    INTEGER,     PARAMETER :: num_fft = 1

    !> real constant of 1
    REAL(dp),    PARAMETER :: one = 1.0_dp

    !> complex constant of 0
    COMPLEX(dp), PARAMETER :: zero = CMPLX(0.0_dp, 0.0_dp, KIND=dp)

    !> the number of points in a FFT
    INTEGER num_point

    !> counter on the derivatives
    INTEGER ipoint

    !> rescale the derivatives if the radius is not 1.0
    REAL(dp) rescale

    !> work array for FFT
    COMPLEX(dp), ALLOCATABLE :: work(:)

    ! create array for FFT
    num_point = SIZE(func)
    ALLOCATE(work(num_point))

    ! evalute FFT of function
    ! work contains now the derivatives up to a factor
    CALL cft_1z(func, num_fft, num_point, num_point, backward, work)

    ! create array for the derivatives
    ALLOCATE(deriv(num_deriv))
    deriv = zero

    ! evaluate the derivatives (truncating or filling with zeros as needed)
    num_point = MIN(num_deriv, num_point)
    deriv(:num_point) = work(:num_point)

    ! rescale the derivatives by radius^(-order of derivative)
    IF (ABS(radius - one) > eps14) THEN
      !
      rescale = one
      DO ipoint = 2, num_point
        !
        rescale = rescale / radius
        deriv(ipoint) = deriv(ipoint) * rescale
        !
      END DO ! ipoint
    END IF ! radius /= 1

  END SUBROUTINE pade_derivative

  !> create a nonsymetric Toeplitz matrix (mathlab-like behavior)
  SUBROUTINE toeplitz_nonsym(col, row, matrix)

    USE constants, ONLY: eps14
    USE kinds,     ONLY: dp

    !> the first column of the matrix
    COMPLEX(dp), INTENT(IN) :: col(:)

    !> the first row of the matrix
    COMPLEX(dp), INTENT(IN) :: row(:)

    !> the resulting Toeplitz matrix
    COMPLEX(dp), ALLOCATABLE, INTENT(OUT) :: matrix(:,:)

    !> the number of row and colums
    INTEGER num_row, num_col

    !> counter on row and colums
    INTEGER irow, icol

    num_row = SIZE(row)
    num_col = SIZE(col)
    ALLOCATE(matrix(num_row, num_col))

    ! trivial case - zero length array
    IF (num_row == 0 .OR. num_col == 0) RETURN
    
    ! sanity check of the input
    IF (ABS(col(1) - row(1)) > eps14) THEN
      WRITE(0,*) 'Warning: First element of input column does not match first &
                 &element of input row. Column wins diagonal conflict.'
    END IF

    ! create the Toeplitz matrix
    DO icol = 1, num_col
      DO irow = 1, num_row
        !
        IF (irow > icol) THEN
          ! use row for upper triangle
          matrix(irow, icol) = row(irow - icol + 1)
        ELSE
          ! use col for lower triangle and diagonal
          matrix(irow, icol) = col(icol - irow + 1)
        END IF
        !
      END DO ! irow
    END DO ! icol

  END SUBROUTINE toeplitz_nonsym

  !> wrapper for LAPACK singular value decomposition routine
  SUBROUTINE svd(matrix, sigma, umat, vmat)

    USE kinds, ONLY: dp

    !> The matrix for which the SVD \f$A = U \Sigma V^{\text{H}}\f$ is evaluated.
    COMPLEX(dp), INTENT(IN) :: matrix(:,:)

    !> singular values of the matrix \f$\Sigma\f$ (ascending)
    REAL(dp),    ALLOCATABLE, INTENT(OUT) :: sigma(:)

    !> Unitary matrix U (left)
    COMPLEX(dp), ALLOCATABLE, INTENT(OUT), OPTIONAL :: umat(:,:)

    !> Unitary matrix V (right), note returns \f$V^{\text{H}}\f$.
    COMPLEX(dp), ALLOCATABLE, INTENT(OUT), OPTIONAL :: vmat(:,:)

    !> jobz parameter for LAPACK SVD
    CHARACTER(1) jobz

    !> number of rows M of the input matrix
    INTEGER num_row

    !> number of columns N of the input matrix
    INTEGER num_col

    !> miniumum of number of rows and number of columns
    INTEGER num_min

    !> number of elements in work array
    INTEGER num_work

    !> error flag returned by LAPACK
    INTEGER ierr

    !> optimal size of work
    COMPLEX(dp) opt_size

    !> integer work array for SVD
    INTEGER,     ALLOCATABLE :: iwork(:)

    !> real work array for SVD
    REAL(dp),    ALLOCATABLE :: rwork(:)

    !> copy of the input matrix, will be destroyed or overwritten by LAPACK call
    COMPLEX(dp), ALLOCATABLE :: amat(:,:)

    !> work array for SVD
    COMPLEX(dp), ALLOCATABLE :: work(:)

    !> LAPACK flag to determine work size
    INTEGER,     PARAMETER   :: determine = -1

    !> complex constant of 0
    COMPLEX(dp), PARAMETER   :: zero = CMPLX(0.0_dp, 0.0_dp, KIND=dp)

    ! set helper variables
    num_row = SIZE(matrix, 1)
    num_col = SIZE(matrix, 2)
    num_min = MIN(num_row, num_col)

    ! sanity check - either both or none of U and V present
    IF ((PRESENT(umat).AND..NOT.PRESENT(vmat)).OR. &
        (PRESENT(vmat).AND..NOT.PRESENT(umat))) THEN
      CALL errore(__FILE__, "either both or none of the optional arguments must be present", 1)
    END IF

    ! allocate arrays for output
    ! U is M x M matrix
    IF (PRESENT(umat)) ALLOCATE(umat(num_row, num_row))
    ! V is N x N matrix
    IF (PRESENT(vmat)) ALLOCATE(vmat(num_col, num_col))
    ! Sigma has MIN(N, M) diagonal entries
    ALLOCATE(sigma(num_min))
    ! integer work array
    ALLOCATE(iwork(8 * num_min))
    ! real work array
    IF (PRESENT(umat)) THEN
      ALLOCATE(rwork(5 * num_min**2 + 7 * num_min))
    ELSE
      ALLOCATE(rwork(5 * num_min))
    END IF

    ! create copy of input matrix, because LAPACK destroys input
    ALLOCATE(amat(num_row, num_col))
    CALL ZCOPY(SIZE(amat), matrix, 1, amat, 1)

    IF (.NOT.PRESENT(umat)) THEN
      ! we evaluate only the singular values
      jobz = 'N'
    ELSE IF (num_row > num_col) THEN
      ! if the number of rows is larger than the number of columns, 
      ! we only evaluate the first N columns of U
      jobz = 'O'
    ELSE
      ! we evaluate all elements.
      jobz = 'A'
    END IF

    ! determine optimum work array size
    CALL ZGESDD(jobz, num_row, num_col, amat, num_row, sigma, umat, num_row, &
                vmat, num_col, opt_size, determine, rwork, iwork, ierr)
    CALL errore(__FILE__, "error calculating work size for SVD", ierr)

    ! create work array
    num_work = NINT(ABS(opt_size))
    ALLOCATE(work(num_work))

    ! perform SVD
    CALL ZGESDD(jobz, num_row, num_col, amat, num_row, sigma, umat, num_row, &
                vmat, num_col, work, num_work, rwork, iwork, ierr)
    CALL errore(__FILE__, "error calculating SVD", ierr)

    ! if jobz is 'O' output was written to A instead of U
    IF (jobz == 'O') THEN
      umat(:, num_col + 1:) = zero
      CALL ZCOPY(SIZE(amat), amat, 1, umat, 1)
    END IF

  END SUBROUTINE svd
 
END MODULE pade_module
