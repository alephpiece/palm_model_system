!> @file rb_buffer_cache_mod.f90
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
!--------------------------------------------------------------------------------------------------!
!
! Description:
! ------------
!> Reuse host-staging buffers during a pressure solve. GPU buffers are registered with HIP and
!> mapped on the device until release. The CPU fallback uses independent, unregistered storage.
!--------------------------------------------------------------------------------------------------!
MODULE rb_buffer_cache_mod
#if defined(PALM_RB_HOST_STAGING) && defined(__parallel)
  USE iso_c_binding, ONLY: c_ptr,c_null_ptr,c_associated,c_f_pointer,c_int,c_size_t,c_sizeof
  USE kinds, ONLY: wp
  USE mpi
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: rb_buffers_get,rb_buffers_release
  TYPE :: arena
     TYPE(c_ptr) :: address=c_null_ptr
     REAL(wp), POINTER, CONTIGUOUS :: words(:)=>NULL()
     INTEGER :: capacity=0,owner_device=-1
     INTEGER(c_size_t) :: bytes=0
     LOGICAL :: registered=.FALSE.
     LOGICAL :: mapped=.FALSE.
  END TYPE
  ! Independent Y/X storage for host fallback and registered, device-mapped buffers.
  TYPE(arena), TARGET, SAVE :: pools(2,2)
  INTERFACE
     FUNCTION allocate_aligned(ptr,alignment,bytes) BIND(C,NAME='posix_memalign') RESULT(status)
       IMPORT c_ptr,c_size_t,c_int
       TYPE(c_ptr), INTENT(OUT) :: ptr
       INTEGER(c_size_t), VALUE :: alignment,bytes
       INTEGER(c_int) :: status
     END FUNCTION
     SUBROUTINE free_host(ptr) BIND(C,NAME='free')
       IMPORT c_ptr
       TYPE(c_ptr), VALUE :: ptr
     END SUBROUTINE
#if defined(_OPENACC)
     FUNCTION create_device(ptr,bytes) BIND(C,NAME='acc_create') RESULT(device_ptr)
       IMPORT c_ptr,c_size_t
       TYPE(c_ptr), VALUE :: ptr
       INTEGER(c_size_t), VALUE :: bytes
       TYPE(c_ptr) :: device_ptr
     END FUNCTION
     SUBROUTINE delete_device(ptr,bytes) BIND(C,NAME='acc_delete')
       IMPORT c_ptr,c_size_t
       TYPE(c_ptr), VALUE :: ptr
       INTEGER(c_size_t), VALUE :: bytes
     END SUBROUTINE
     FUNCTION device_present(ptr,bytes) BIND(C,NAME='acc_is_present') RESULT(present)
       IMPORT c_ptr,c_size_t,c_int
       TYPE(c_ptr), VALUE :: ptr
       INTEGER(c_size_t), VALUE :: bytes
       INTEGER(c_int) :: present
     END FUNCTION
     FUNCTION register_host(ptr,bytes,flags) BIND(C,NAME='hipHostRegister') RESULT(status)
       IMPORT c_ptr,c_size_t,c_int
       TYPE(c_ptr), VALUE :: ptr
       INTEGER(c_size_t), VALUE :: bytes
       INTEGER(c_int), VALUE :: flags
       INTEGER(c_int) :: status
     END FUNCTION
     FUNCTION unregister_host(ptr) BIND(C,NAME='hipHostUnregister') RESULT(status)
       IMPORT c_ptr,c_int
       TYPE(c_ptr), VALUE :: ptr
       INTEGER(c_int) :: status
     END FUNCTION
     FUNCTION current_device(device) BIND(C,NAME='hipGetDevice') RESULT(status)
       IMPORT c_int
       INTEGER(c_int), INTENT(OUT) :: device
       INTEGER(c_int) :: status
     END FUNCTION
#endif
  END INTERFACE
CONTAINS
  SUBROUTINE rb_buffer_error(operation,status)
    CHARACTER(*), INTENT(IN) :: operation
    INTEGER, INTENT(IN) :: status
    INTEGER :: rank,ierr
    CALL MPI_COMM_RANK(MPI_COMM_WORLD,rank,ierr)
    WRITE(*,*) 'RB_BUFFER_ERROR rank=',rank,' operation=',TRIM(operation),' status=',status
    CALL MPI_ABORT(MPI_COMM_WORLD,97,ierr)
    STOP 97
  END SUBROUTINE

  SUBROUTINE rb_buffers_get(axis,klo,khi,hlo,hhi,lacc,recvbuf1,recvbuf2,sendbuf1,sendbuf2)
    INTEGER, INTENT(IN) :: axis,klo,khi,hlo,hhi
    LOGICAL, INTENT(IN) :: lacc
    REAL(wp), POINTER, CONTIGUOUS, INTENT(OUT) :: recvbuf1(:,:),recvbuf2(:,:), &
                                                       sendbuf1(:,:),sendbuf2(:,:)
    TYPE(arena), POINTER :: slot
    INTEGER :: kind,n,offset
    INTEGER(c_int) :: status,device
    INTEGER(c_size_t) :: count,requested_bytes
#if defined(_OPENACC)
    TYPE(c_ptr) :: device_address
#endif
    INTEGER(c_size_t), PARAMETER :: alignment=4096_c_size_t
    IF (axis < 1 .OR. axis > 2) CALL rb_buffer_error('axis',-1)
    IF (khi < klo .OR. hhi < hlo) CALL rb_buffer_error('invalid shape',-1)
    count=INT(khi-klo+1,c_size_t)*INT(hhi-hlo+1,c_size_t)
    IF (count > INT(HUGE(n),c_size_t)/4 - alignment/C_SIZEOF(0.0_wp)) &
           CALL rb_buffer_error('capacity overflow',-1)
    n=INT(count)
    kind=1
    IF (lacc) kind=2
    slot=>pools(axis,kind)
    device=-1
    IF (lacc) THEN
#if defined(_OPENACC)
       status=current_device(device)
       IF (status /= 0) CALL rb_buffer_error('hipGetDevice',status)
       IF (slot%owner_device >= 0 .AND. slot%owner_device /= device) &
           CALL rb_buffer_error('device change requires release before switching device',-1)
#else
       CALL rb_buffer_error('GPU cache requested in CPU build',-1)
#endif
    ENDIF
    IF (slot%capacity < n) THEN
       CALL release_arena(slot)
       ! Give each buffer its own page-aligned start; no two views share a cache line.
       requested_bytes=((count*C_SIZEOF(0.0_wp)+alignment-1)/alignment)*alignment
       slot%capacity=INT(requested_bytes/C_SIZEOF(0.0_wp))
       slot%bytes=4_c_size_t*requested_bytes
       status=allocate_aligned(slot%address,alignment,slot%bytes)
       IF (status /= 0) CALL rb_buffer_error('posix_memalign',status)
       slot%owner_device=device
       CALL C_F_POINTER(slot%address,slot%words,[4*slot%capacity])
       IF (kind == 2) THEN
#if defined(_OPENACC)
          status=register_host(slot%address,slot%bytes,0_c_int)
          IF (status /= 0) CALL rb_buffer_error('hipHostRegister',status)
          slot%registered=.TRUE.
          IF (device_present(slot%address,slot%bytes) /= 0) &
           CALL rb_buffer_error('unexpected preexisting arena mapping',-1)
          device_address=create_device(slot%address,slot%bytes)
          IF (.NOT.c_associated(device_address)) CALL rb_buffer_error('acc_create returned null',-1)
          IF (device_present(slot%address,slot%bytes) == 0) &
           CALL rb_buffer_error('acc_create did not establish mapping',-1)
          slot%mapped=.TRUE.
#else
          CALL rb_buffer_error('device mapping requested in CPU build',-1)
#endif
       ENDIF
    ENDIF
    ! Separate contiguous views retain original bounds; unused capacity is between buffers.
    recvbuf1(klo:khi,hlo:hhi)=>slot%words(1:n)
    offset=slot%capacity
    recvbuf2(klo:khi,hlo:hhi)=>slot%words(offset+1:offset+n)
    offset=2*slot%capacity
    sendbuf1(klo:khi,hlo:hhi)=>slot%words(offset+1:offset+n)
    offset=3*slot%capacity
    sendbuf2(klo:khi,hlo:hhi)=>slot%words(offset+1:offset+n)
  END SUBROUTINE

  SUBROUTINE release_arena(slot)
    TYPE(arena), INTENT(INOUT) :: slot
#if defined(_OPENACC)
    INTEGER(c_int) :: status,device
#endif
    IF (.NOT.c_associated(slot%address)) RETURN
    ! Call only after MPI_WAITALL and completion of the direction's synchronous ACC region.
    IF (slot%registered) THEN
#if defined(_OPENACC)
       status=current_device(device)
       IF (status /= 0) CALL rb_buffer_error('hipGetDevice during release',status)
       IF (device /= slot%owner_device) CALL rb_buffer_error('release on different device',-1)
       IF (slot%mapped) THEN
          IF (device_present(slot%address,slot%bytes) == 0) &
           CALL rb_buffer_error('mapping missing before release',-1)
          CALL delete_device(slot%address,slot%bytes)
          IF (device_present(slot%address,slot%bytes) /= 0) &
           CALL rb_buffer_error('mapping remains after acc_delete',-1)
          slot%mapped=.FALSE.
       ENDIF
       status=unregister_host(slot%address)
       IF (status /= 0) CALL rb_buffer_error('hipHostUnregister',status)
#else
       CALL rb_buffer_error('registered storage in CPU build',-1)
#endif
    ENDIF
    CALL free_host(slot%address)
    slot%address=c_null_ptr
    NULLIFY(slot%words)
    slot%capacity=0
    slot%bytes=0
    slot%registered=.FALSE.
    slot%mapped=.FALSE.
    slot%owner_device=-1
  END SUBROUTINE

  SUBROUTINE rb_buffers_release()
    INTEGER :: axis,kind
    DO kind=1,2
       DO axis=1,2
          CALL release_arena(pools(axis,kind))
       ENDDO
    ENDDO
  END SUBROUTINE

#endif
END MODULE rb_buffer_cache_mod
