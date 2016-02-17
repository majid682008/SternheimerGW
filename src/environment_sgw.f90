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
MODULE environment
  !==-----------------------------------------------------------------------==!

  USE kinds, ONLY: DP
  USE io_files, ONLY: crash_file, nd_nmbr
  USE io_global, ONLY: stdout, meta_ionode
  USE mp_world,  ONLY: nproc
  USE mp_images, ONLY: me_image, my_image_id, root_image, nimage, &
      nproc_image
  USE mp_pools,  ONLY: npool
  USE mp_bands,  ONLY: ntask_groups, nproc_bgrp, nbgrp
  USE global_version, ONLY: version_number, svn_revision

  IMPLICIT NONE

  ! ...  title of the simulation
  CHARACTER(LEN=75) :: title

  SAVE

  PRIVATE

  PUBLIC :: environment_start
  PUBLIC :: environment_end

  !==-----------------------------------------------------------------------==!
CONTAINS
  !==-----------------------------------------------------------------------==!

  SUBROUTINE environment_start( code )

    CHARACTER(LEN=*), INTENT(IN) :: code

    LOGICAL           :: exst, debug = .false.
    CHARACTER(LEN=80) :: code_version, uname
    CHARACTER(LEN=6), EXTERNAL :: int_to_char
    INTEGER :: ios, crashunit
    INTEGER, EXTERNAL :: find_free_unit

    ! ... The Intel compiler allocates a lot of stack space
    ! ... Stack limit is often small, thus causing SIGSEGV and crash
    ! ... One may use "ulimit -s unlimited" but it doesn't always work
    ! ... The following call does the same and always works
    !
#ifdef __INTEL_COMPILER
    CALL remove_stack_limit ( )
#endif
    ! ... use ".FALSE." to disable all clocks except the total cpu time clock
    ! ... use ".TRUE."  to enable clocks

    CALL init_clocks( .TRUE. )
    CALL start_clock( TRIM(code) )

    code_version = TRIM (code) // " v." // TRIM (version_number)
    IF ( TRIM (svn_revision) /= "unknown" ) code_version = &
         TRIM (code_version) // " (svn rev. " // TRIM (svn_revision) // ")"

    ! ... for compatibility with PWSCF

#ifdef __MPI
    nd_nmbr = TRIM ( int_to_char( me_image+1 ))
#else
    nd_nmbr = ' '
#endif

    IF( meta_ionode ) THEN

       ! ...  search for file CRASH and delete it

       INQUIRE( FILE=TRIM(crash_file), EXIST=exst )
       IF( exst ) THEN
          crashunit = find_free_unit()
          OPEN( UNIT=crashunit, FILE=TRIM(crash_file), STATUS='OLD',IOSTAT=ios )
          IF (ios==0) THEN
             CLOSE( UNIT=crashunit, STATUS='DELETE', IOSTAT=ios )
          ELSE
             WRITE(stdout,'(5x,"Remark: CRASH file could not be deleted")')
          END IF
       END IF

    ELSE
       ! ... one processor per image (other than meta_ionode)
       ! ... or, for debugging purposes, all processors,
       ! ... open their own standard output file
#if defined(DEBUG)
       debug = .true.
#endif
       IF (me_image == root_image .OR. debug ) THEN
          uname = 'out.' // trim(int_to_char( my_image_id )) // '_' // &
               trim(int_to_char( me_image))
          OPEN ( unit = stdout, file = TRIM(uname),status='unknown')
       ELSE
#if defined(_WIN32)
          OPEN ( unit = stdout, file='NUL:', status='unknown' )
#else
          OPEN ( unit = stdout, file='/dev/null', status='unknown' )
#endif
       END IF

    END IF
    !
    CALL opening_message( code_version )
#ifdef __MPI
    CALL parallel_info ( )
#else
    CALL serial_info()
#endif
  END SUBROUTINE environment_start

  !==-----------------------------------------------------------------------==!

  SUBROUTINE environment_end( code )

    CHARACTER(LEN=*), INTENT(IN) :: code

    IF ( meta_ionode ) WRITE( stdout, * )

    CALL stop_clock(  TRIM(code) )
    CALL print_clock( TRIM(code) )

    CALL closing_message( )

    IF( meta_ionode ) THEN
       WRITE( stdout,'(A)')      '   JOB DONE.'
       WRITE( stdout,3335)
    END IF
3335 FORMAT('=',78('-'),'=')
    FLUSH(stdout)

    RETURN
  END SUBROUTINE environment_end

  !==-----------------------------------------------------------------------==!

  SUBROUTINE opening_message( code_version )

    CHARACTER(LEN=*), INTENT(IN) :: code_version
    CHARACTER(LEN=9)  :: cdate, ctime

    CALL date_and_tim( cdate, ctime )
    !
    WRITE( stdout, '(/5X,"Program ",A," starts on ",A9," at ",A9)' ) &
         TRIM(code_version), cdate, ctime
    !
    WRITE( stdout, '(/5X,"This program is part of the open-source Quantum ",&
         &    "ESPRESSO suite", &
         &/5X,"for quantum simulation of materials; please cite",   &
         &/9X,"""P. Giannozzi et al., J. Phys.:Condens. Matter 21 ",&
         &    "395502 (2009);", &
         &/9X," URL http://www.quantum-espresso.org"", ", &
         &/5X,"in publications or presentations arising from this work. More details at",&
         &/5x,"http://www.quantum-espresso.org/quote")' )

    RETURN
  END SUBROUTINE opening_message

  !==-----------------------------------------------------------------------==!

  SUBROUTINE closing_message( )

    CHARACTER(LEN=9)  :: cdate, ctime
    CHARACTER(LEN=80) :: time_str

    CALL date_and_tim( cdate, ctime )

    time_str = 'This run was terminated on:  ' // ctime // ' ' // cdate

    IF( meta_ionode ) THEN
       WRITE( stdout,*)
       WRITE( stdout,3334) time_str
       WRITE( stdout,3335)
    END IF

3334 FORMAT(3X,A60,/)
3335 FORMAT('=',78('-'),'=')

    RETURN
  END SUBROUTINE closing_message

  !==-----------------------------------------------------------------------==!
  SUBROUTINE parallel_info ( )
    !
#if defined(__OPENMP)
    INTEGER, EXTERNAL :: omp_get_max_threads
    !
    WRITE( stdout, '(/5X,"Parallel version (MPI & OpenMP), running on ",&
         &I7," processor cores")' ) nproc * omp_get_max_threads()
    !
    WRITE( stdout, '(5X,"Number of MPI processes:           ",I7)' ) nproc
    !
    WRITE( stdout, '(5X,"Threads/MPI process:               ",I7)' ) &
         omp_get_max_threads()
#else
    WRITE( stdout, '(/5X,"Parallel version (MPI), running on ",&
         &I5," processors")' ) nproc 
#endif
    !
    IF ( nimage > 1 ) WRITE( stdout, &
         '(5X,"path-images division:  nimage    = ",I7)' ) nimage
    IF ( npool > 1 ) WRITE( stdout, &
         '(5X,"K-points division:     npool     = ",I7)' ) npool
    IF ( nbgrp > 1 ) WRITE( stdout, &
         '(5X,"band groups division:  nbgrp     = ",I7)' ) nbgrp
    IF ( nproc_bgrp > 1 ) WRITE( stdout, &
         '(5X,"R & G space division:  proc/nbgrp/npool/nimage = ",I7)' ) nproc_bgrp
    IF ( ntask_groups > 1 ) WRITE( stdout, &
         '(5X,"wavefunctions fft division:  fft and procs/group = ",2I7)' ) &
         ntask_groups, nproc_bgrp / ntask_groups
    !
  END SUBROUTINE parallel_info

  !==-----------------------------------------------------------------------==!
  SUBROUTINE serial_info ( )
    !
#if defined(__OPENMP)
    INTEGER, EXTERNAL :: omp_get_max_threads
#endif
    !
#if defined(__OPENMP)
    WRITE( stdout, '(/5X,"Serial multi-threaded version, running on ",&
         &I4," processor cores")' ) omp_get_max_threads()
    !
#else
    WRITE( stdout, '(/5X,"Serial version")' )
#endif
    !
  END SUBROUTINE serial_info
  !==-----------------------------------------------------------------------==!
END MODULE environment
!==-----------------------------------------------------------------------==!
