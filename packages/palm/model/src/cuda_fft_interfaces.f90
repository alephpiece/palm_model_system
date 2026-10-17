!> @file cuda_fft_interfaces.f90
!--------------------------------------------------------------------------------------------------!
! This file is part of the PALM model system.
!
! PALM is free software: you can redistribute it and/or modify it under the terms of the GNU General
! Public License as published by the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! PALM is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the
! implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
! Public License for more details.
!
! You should have received a copy of the GNU General Public License along with PALM. If not, see
! <http://www.gnu.org/licenses/>.
!
! Copyright 1997-2021 Leibniz Universitaet Hannover
!--------------------------------------------------------------------------------------------------!
!
! Description:
! ------------
!> Fortran interfaces for the CUDA and HIP FFT libraries.
!> The HIP backend retains the CUFFT procedure names used by the existing FFT callers.
!--------------------------------------------------------------------------------------------------!
#if defined( __cuda_fft ) && defined( __hip_fft )
#error "Select only one GPU FFT backend: __cuda_fft or __hip_fft"
#endif
#if ( defined( __cuda_fft ) || defined( __hip_fft ) ) && defined( __fftw )
#error "GPU FFT backends cannot be combined with __fftw"
#endif
#if ( defined( __cuda_fft ) || defined( __hip_fft ) ) && ! defined( _OPENACC )
#error "GPU FFT backends require OpenACC compilation"
#endif

 MODULE cuda_fft_interfaces

#if defined( __hip_fft )

    USE, INTRINSIC ::  ISO_C_BINDING,                                                               &
        ONLY:  C_DOUBLE,                                                                          &
               C_DOUBLE_COMPLEX,                                                                  &
               C_FLOAT,                                                                           &
               C_FLOAT_COMPLEX,                                                                   &
               C_INT,                                                                             &
               C_PTR

    IMPLICIT NONE

    INTEGER(C_INT), PARAMETER :: CUFFT_R2C = 42, CUFFT_C2R = 44
    INTEGER(C_INT), PARAMETER :: CUFFT_D2Z = 106, CUFFT_Z2D = 108

    INTERFACE
       FUNCTION hip_plan( plan, nx, fft_type, batch ) BIND(C, NAME='hipfftPlan1d') RESULT(status)
          IMPORT C_INT, C_PTR
          TYPE(C_PTR) :: plan
          INTEGER(C_INT), VALUE :: nx, fft_type, batch
          INTEGER(C_INT) :: status
       END FUNCTION hip_plan
       FUNCTION hip_destroy( plan ) BIND(C, NAME='hipfftDestroy') RESULT(status)
          IMPORT C_INT, C_PTR
          TYPE(C_PTR), VALUE :: plan
          INTEGER(C_INT) :: status
       END FUNCTION hip_destroy
       FUNCTION hip_sync() BIND(C, NAME='hipDeviceSynchronize') RESULT(status)
          IMPORT C_INT
          INTEGER(C_INT) :: status
       END FUNCTION hip_sync
       FUNCTION hip_R2C( plan, idata, odata ) BIND(C, NAME='hipfftExecR2C') RESULT(status)
          IMPORT C_INT, C_PTR, C_FLOAT, C_FLOAT_COMPLEX
          TYPE(C_PTR), VALUE :: plan
          REAL(C_FLOAT) :: idata(*)
          COMPLEX(C_FLOAT_COMPLEX) :: odata(*)
          INTEGER(C_INT) :: status
       END FUNCTION hip_R2C
       FUNCTION hip_C2R( plan, idata, odata ) BIND(C, NAME='hipfftExecC2R') RESULT(status)
          IMPORT C_INT, C_PTR, C_FLOAT, C_FLOAT_COMPLEX
          TYPE(C_PTR), VALUE :: plan
          COMPLEX(C_FLOAT_COMPLEX) :: idata(*)
          REAL(C_FLOAT) :: odata(*)
          INTEGER(C_INT) :: status
       END FUNCTION hip_C2R
       FUNCTION hip_D2Z( plan, idata, odata ) BIND(C, NAME='hipfftExecD2Z') RESULT(status)
          IMPORT C_INT, C_PTR, C_DOUBLE, C_DOUBLE_COMPLEX
          TYPE(C_PTR), VALUE :: plan
          REAL(C_DOUBLE) :: idata(*)
          COMPLEX(C_DOUBLE_COMPLEX) :: odata(*)
          INTEGER(C_INT) :: status
       END FUNCTION hip_D2Z
       FUNCTION hip_Z2D( plan, idata, odata ) BIND(C, NAME='hipfftExecZ2D') RESULT(status)
          IMPORT C_INT, C_PTR, C_DOUBLE, C_DOUBLE_COMPLEX
          TYPE(C_PTR), VALUE :: plan
          COMPLEX(C_DOUBLE_COMPLEX) :: idata(*)
          REAL(C_DOUBLE) :: odata(*)
          INTEGER(C_INT) :: status
       END FUNCTION hip_Z2D
    END INTERFACE

 CONTAINS

    SUBROUTINE check_hipfft( status, operation )
       INTEGER(C_INT), INTENT(IN) :: status
       CHARACTER(LEN=*), INTENT(IN) :: operation
       IF ( status /= 0 )  THEN
          WRITE(*,*) 'hipFFT failure: ', operation, status
          STOP 1
       ENDIF
    END SUBROUTINE check_hipfft

    SUBROUTINE CUFFTPLAN1D( plan, nx, fft_type, batch )
       TYPE(C_PTR), INTENT(OUT) :: plan
       INTEGER(C_INT), INTENT(IN) :: nx, fft_type, batch
       CALL check_hipfft( hip_plan(plan, nx, fft_type, batch), 'plan' )
    END SUBROUTINE CUFFTPLAN1D

    SUBROUTINE CUFFTDESTROY( plan )
       TYPE(C_PTR), INTENT(IN) :: plan
       CALL check_hipfft( hip_destroy(plan), 'destroy' )
    END SUBROUTINE CUFFTDESTROY

    SUBROUTINE CUFFTEXECR2C( plan, idata, odata )
       TYPE(C_PTR), INTENT(IN) :: plan
       REAL(C_FLOAT) :: idata(*)
       COMPLEX(C_FLOAT_COMPLEX) :: odata(*)
       CALL check_hipfft( hip_R2C(plan, idata, odata), 'R2C' )
!      Complete the library stream before subsequent synchronous OpenACC regions consume its output.
       CALL check_hipfft( hip_sync(), 'synchronize' )
    END SUBROUTINE CUFFTEXECR2C

    SUBROUTINE CUFFTEXECC2R( plan, idata, odata )
       TYPE(C_PTR), INTENT(IN) :: plan
       COMPLEX(C_FLOAT_COMPLEX) :: idata(*)
       REAL(C_FLOAT) :: odata(*)
       CALL check_hipfft( hip_C2R(plan, idata, odata), 'C2R' )
!      Complete the library stream before subsequent synchronous OpenACC regions consume its output.
       CALL check_hipfft( hip_sync(), 'synchronize' )
    END SUBROUTINE CUFFTEXECC2R

    SUBROUTINE CUFFTEXECD2Z( plan, idata, odata )
       TYPE(C_PTR), INTENT(IN) :: plan
       REAL(C_DOUBLE) :: idata(*)
       COMPLEX(C_DOUBLE_COMPLEX) :: odata(*)
       CALL check_hipfft( hip_D2Z(plan, idata, odata), 'D2Z' )
!      Complete the library stream before subsequent synchronous OpenACC regions consume its output.
       CALL check_hipfft( hip_sync(), 'synchronize' )
    END SUBROUTINE CUFFTEXECD2Z

    SUBROUTINE CUFFTEXECZ2D( plan, idata, odata )
       TYPE(C_PTR), INTENT(IN) :: plan
       COMPLEX(C_DOUBLE_COMPLEX) :: idata(*)
       REAL(C_DOUBLE) :: odata(*)
       CALL check_hipfft( hip_Z2D(plan, idata, odata), 'Z2D' )
!      Complete the library stream before subsequent synchronous OpenACC regions consume its output.
       CALL check_hipfft( hip_sync(), 'synchronize' )
    END SUBROUTINE CUFFTEXECZ2D

#elif defined ( __cuda_fft )

    USE kinds

    INTEGER(iwp) ::  CUFFT_C2C = Z'29'    !< Complex to Complex, interleaved
    INTEGER(iwp) ::  CUFFT_C2R = Z'2c'    !< Complex (interleaved) to Real
    INTEGER(iwp) ::  CUFFT_D2Z = Z'6a'    !< Double to Double-Complex
    INTEGER(iwp) ::  CUFFT_FORWARD = -1   !<
    INTEGER(iwp) ::  CUFFT_INVERSE =  1   !<
    INTEGER(iwp) ::  CUFFT_R2C = Z'2a'    !< Real to Complex (interleaved)
    INTEGER(iwp) ::  CUFFT_Z2D = Z'6c'    !< Double-Complex to Double
    INTEGER(iwp) ::  CUFFT_Z2Z = Z'69'    !< Double-Complex to Double-Complex

    PUBLIC


!
!-- cufftPlan1d( cufftHandle *plan, int nx, cufftType type, int batch )
    INTERFACE CUFFTPLAN1D

!--------------------------------------------------------------------------------------------------!
! Description:
! ------------
!> @todo Missing subroutine description.
!--------------------------------------------------------------------------------------------------!
       SUBROUTINE CUFFTPLAN1D( plan, nx, type, batch ) BIND( C, name='cufftPlan1d' )

          USE ISO_C_BINDING

          INTEGER(C_INT)        ::  plan   !<
          INTEGER(C_INT), VALUE ::  batch  !<
          INTEGER(C_INT), VALUE ::  nx     !<
          INTEGER(C_INT), VALUE ::  type   !<
       END SUBROUTINE CUFFTPLAN1D

    END INTERFACE CUFFTPLAN1D

!
!-- cufftDestroy( cufftHandle plan )  !!! remove later if not really needed !!!
    INTERFACE CUFFTDESTROY

!--------------------------------------------------------------------------------------------------!
! Description:
! ------------
!> @todo Missing subroutine description.
!--------------------------------------------------------------------------------------------------!
       SUBROUTINE CUFFTDESTROY( plan ) BIND( C, name='cufftDestroy' )

          USE ISO_C_BINDING

          INTEGER(C_INT), VALUE ::  plan

       END SUBROUTINE CUFFTDESTROY

    END INTERFACE CUFFTDESTROY


    INTERFACE CUFFTEXECC2R

!--------------------------------------------------------------------------------------------------!
! Description:
! ------------
!> @todo Missing subroutine description.
!--------------------------------------------------------------------------------------------------!
       SUBROUTINE CUFFTEXECC2R( plan, idata, odata ) BIND( C, name='cufftExecC2R' )

          USE ISO_C_BINDING
          USE kinds

          COMPLEX(sp), DEVICE   ::  idata(:,:,:)  !<

          INTEGER(C_INT), VALUE ::  plan          !<

          REAL(sp), DEVICE      ::  odata(:,:,:)  !<

       END SUBROUTINE CUFFTEXECC2R

    END INTERFACE CUFFTEXECC2R


    INTERFACE CUFFTEXECZ2D

!--------------------------------------------------------------------------------------------------!
! Description:
! ------------
!> @todo Missing subroutine description.
!--------------------------------------------------------------------------------------------------!
       SUBROUTINE CUFFTEXECZ2D( plan, idata, odata ) BIND( C, name='cufftExecZ2D' )

          USE ISO_C_BINDING
          USE kinds

          COMPLEX(dp), DEVICE   ::  idata(:,:,:)  !<

          INTEGER(C_INT), VALUE ::  plan          !<

          REAL(dp), DEVICE      ::  odata(:,:,:)  !<

       END SUBROUTINE CUFFTEXECZ2D

    END INTERFACE CUFFTEXECZ2D


    INTERFACE CUFFTEXECR2C

!--------------------------------------------------------------------------------------------------!
! Description:
! ------------
!> @todo Missing subroutine description.
!--------------------------------------------------------------------------------------------------!
       SUBROUTINE CUFFTEXECR2C( plan, idata, odata ) bind( C, name='cufftExecR2C' )

          USE ISO_C_BINDING

          USE kinds

          COMPLEX(sp), DEVICE   ::  odata(:,:,:)  !<

          INTEGER(C_INT), VALUE ::  plan          !<

          REAL(sp), DEVICE      ::  idata(:,:,:)  !<

       END SUBROUTINE CUFFTEXECR2C

    END INTERFACE CUFFTEXECR2C


    INTERFACE CUFFTEXECD2Z

!--------------------------------------------------------------------------------------------------!
! Description:
! ------------
!> @todo Missing subroutine description.
!--------------------------------------------------------------------------------------------------!
       SUBROUTINE CUFFTEXECD2Z( plan, idata, odata ) bind( C, name='cufftExecD2Z' )

          USE ISO_C_BINDING

          USE kinds

          COMPLEX(dp), DEVICE   ::  odata(:,:,:)  !<

          INTEGER(C_INT), VALUE ::  plan          !<

          REAL(dp), DEVICE      ::  idata(:,:,:)  !<

       END SUBROUTINE CUFFTEXECD2Z

    END INTERFACE CUFFTEXECD2Z

#else

    INTERFACE CUFFTdummy

!--------------------------------------------------------------------------------------------------!
! Description:
! ------------
!> Dummy interface to avoid compiler warnings in case of no bublic objects declared.
!--------------------------------------------------------------------------------------------------!
       SUBROUTINE CUFFTdummy( dummy )

          USE kinds

          REAL(wp) ::  dummy  !<

       END SUBROUTINE CUFFTdummy

    END INTERFACE CUFFTdummy

#endif

 END MODULE cuda_fft_interfaces
