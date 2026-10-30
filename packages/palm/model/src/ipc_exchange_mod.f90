!> @file ipc_exchange_mod.f90
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
!> Single-node pressure halo exchange through HIP IPC.
!>
!> The caller limits this path to a uniform 2x2, single-level sorted redblack solve.
!> Setup is collective once per solve; unsupported layouts or IPC export/import
!> capability consistently select the existing exchange path. Completed-color
!> barriers and the return barrier protect peer reads from later pressure writes.
!> Release must run before the pressure allocation is destroyed.
#if defined(PALM_RB_IPC) && defined(PALM_RB_HOST_STAGING) && defined(__parallel) && defined(_OPENACC)
MODULE ipc_exchange_mod
  USE iso_c_binding
  USE iso_fortran_env, ONLY: int64
  USE mpi
  USE kinds, ONLY: wp
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: ipc_setup,ipc_exchange,ipc_finish_redblack,ipc_release
  TYPE, BIND(C) :: ipc_handle
     INTEGER(c_int8_t) :: data(64)
  END TYPE
  LOGICAL :: ready=.FALSE.,decided=.FALSE.,plan_mapped=.FALSE.,plan_valid=.TRUE.
  LOGICAL :: opened(3)=.FALSE.,mapped(3)=.FALSE.
  INTEGER :: communicator=MPI_COMM_NULL,rank=-1,cells=0,capacity=0,counts(2)=0
  INTEGER :: bounds(6)
  INTEGER :: metadata(10,0:3),h_all(2,2,4,0:3),bot_all(2,2,4,0:3),top_all(2,2,4,0:3)
  INTEGER :: slots(0:3),peer_ids(3)
  INTEGER, ALLOCATABLE :: destination(:,:),source_index(:,:),source_slot(:,:)
  REAL(wp), ALLOCATABLE,TARGET :: aliases(:,:)
  TYPE(c_ptr) :: imported(3)=c_null_ptr,remote_view(3)=c_null_ptr
  INTERFACE
     FUNCTION acc_pointer(p) BIND(C,NAME='acc_deviceptr') RESULT(device)
       IMPORT c_ptr
       TYPE(c_ptr),VALUE :: p
       TYPE(c_ptr) :: device
     END FUNCTION
     SUBROUTINE map_pointer(host,device,bytes) BIND(C,NAME='acc_map_data')
       IMPORT c_ptr,c_size_t
       TYPE(c_ptr),VALUE :: host,device
       INTEGER(c_size_t),VALUE :: bytes
     END SUBROUTINE
     SUBROUTINE unmap_pointer(host) BIND(C,NAME='acc_unmap_data')
       IMPORT c_ptr
       TYPE(c_ptr),VALUE :: host
     END SUBROUTINE
     FUNCTION memory_range(base,bytes,p) BIND(C,NAME='hipMemGetAddressRange') RESULT(status)
       IMPORT c_ptr,c_size_t,c_int
       TYPE(c_ptr),INTENT(OUT) :: base
       INTEGER(c_size_t),INTENT(OUT) :: bytes
       TYPE(c_ptr),VALUE :: p
       INTEGER(c_int) :: status
     END FUNCTION
     FUNCTION export_memory(handle,p) BIND(C,NAME='hipIpcGetMemHandle') RESULT(status)
       IMPORT ipc_handle,c_ptr,c_int
       TYPE(ipc_handle),INTENT(OUT) :: handle
       TYPE(c_ptr),VALUE :: p
       INTEGER(c_int) :: status
     END FUNCTION
     FUNCTION import_memory(p,handle,flags) BIND(C,NAME='hipIpcOpenMemHandle') RESULT(status)
       IMPORT ipc_handle,c_ptr,c_int
       TYPE(c_ptr),INTENT(OUT) :: p
       TYPE(ipc_handle),VALUE :: handle
       INTEGER(c_int),VALUE :: flags
       INTEGER(c_int) :: status
     END FUNCTION
     FUNCTION close_memory(p) BIND(C,NAME='hipIpcCloseMemHandle') RESULT(status)
       IMPORT c_ptr,c_int
       TYPE(c_ptr),VALUE :: p
       INTEGER(c_int) :: status
     END FUNCTION
  END INTERFACE
CONTAINS
  SUBROUTINE die(operation,code)
    CHARACTER(*),INTENT(IN) :: operation
    INTEGER,INTENT(IN) :: code
    INTEGER :: error
    WRITE(*,*) 'IPC_EXCHANGE_ERROR rank=',rank,' operation=',operation,' code=',code
    CALL MPI_ABORT(MPI_COMM_WORLD,98,error)
    STOP 98
  END SUBROUTINE
  SUBROUTINE check_status(code,operation)
    INTEGER,INTENT(IN) :: code
    CHARACTER(*),INTENT(IN) :: operation
    IF(code/=0) CALL die(operation,code)
  END SUBROUTINE
  LOGICAL FUNCTION agree(local)
    LOGICAL,INTENT(IN) :: local
    INTEGER :: error
    CALL MPI_ALLREDUCE(local,agree,1,MPI_LOGICAL,MPI_LAND,communicator,error)
    CALL check_status(error,'setup agreement')
  END FUNCTION
  SUBROUTINE ipc_setup(p,comm,zb,zt,xl,xr,ys,yn,neighbors,hrecv,krecv_bot,krecv_top,eligible,enabled)
    INTEGER,INTENT(IN) :: comm,zb,zt,xl,xr,ys,yn,neighbors(4)
    INTEGER,INTENT(IN) :: hrecv(2,2,4),krecv_bot(2,2,4),krecv_top(2,2,4)
    LOGICAL,INTENT(IN) :: eligible
    LOGICAL,INTENT(OUT) :: enabled
    REAL(wp),TARGET,INTENT(INOUT) :: p(zb:zt+1,ys-1:yn+1,xl-1:xr+1)
    INTEGER :: error,nproc,node,node_size,peer,slot,c,side,g,k,h,dsti,dstj,srci,srcj,own,yp,ys_side
    INTEGER :: local_info(10),allocation_status
    INTEGER(int64) :: nx,ny,nz,limit,nc64,cap64,horizontal
    LOGICAL :: supported
    INTEGER(c_int) :: status
    INTEGER(c_size_t) :: bytes,allocation_bytes
    INTEGER(c_intptr_t) :: offset,offsets(0:3),address
    TYPE(c_ptr) :: base,host,device
    TYPE(ipc_handle) :: handle
    INTEGER(c_int8_t) :: handles(64,0:3)
    ! The single-level caller keeps this array and topology unchanged until release.
    enabled=ready
    IF(decided) RETURN
    decided=.TRUE.;communicator=comm
    CALL MPI_COMM_RANK(comm,rank,error);CALL check_status(error,'comm rank')
    IF(.NOT.agree(eligible)) RETURN
    CALL MPI_COMM_SIZE(comm,nproc,error);CALL check_status(error,'comm size')
    IF(nproc/=4) RETURN
    CALL MPI_COMM_SPLIT_TYPE(comm,MPI_COMM_TYPE_SHARED,0,MPI_INFO_NULL,node,error)
    CALL check_status(error,'shared node split')
    CALL MPI_COMM_SIZE(node,node_size,error);CALL check_status(error,'shared node size')
    CALL MPI_COMM_FREE(node,error);CALL check_status(error,'shared node free')
    IF(.NOT.agree(node_size==4)) RETURN
    nx=INT(xr,int64)-INT(xl,int64)+1;ny=INT(yn,int64)-INT(ys,int64)+1
    nz=INT(zt,int64)-INT(zb,int64);limit=INT(HUGE(cells),int64)
    supported=zb==0.AND.nz>=2.AND.MOD(nz,2_int64)==0.AND.nx>0.AND.ny>0
    supported=supported.AND.C_SIZEOF(handle)==64_c_size_t.AND.C_SIZEOF(0.0_wp)==8_c_size_t
    supported=supported.AND.C_SIZEOF(offset)==8_c_size_t
    ! The plan uses 32-bit offsets; test products before evaluating them.
    IF(supported) THEN
       supported=nx+2<=limit/(ny+2)
       IF(supported) THEN
          horizontal=(nx+2)*(ny+2)
          supported=horizontal<=limit/(nz+2)
       ENDIF
       IF(supported) supported=nz<=limit/2/(nx+ny+4)
    ENDIF
    IF(.NOT.agree(supported)) RETURN
    nc64=horizontal*(nz+2);cap64=2*nz*(nx+ny+4)
    cells=INT(nc64);capacity=INT(cap64);bounds=[zb,zt,xl,xr,ys,yn]
    local_info=[bounds,neighbors]
    CALL MPI_ALLGATHER(local_info,10,MPI_INTEGER,metadata,10,MPI_INTEGER,comm,error)
    CALL check_status(error,'geometry gather')
    CALL MPI_ALLGATHER(hrecv,16,MPI_INTEGER,h_all,16,MPI_INTEGER,comm,error)
    CALL check_status(error,'receive starts gather')
    CALL MPI_ALLGATHER(krecv_bot,16,MPI_INTEGER,bot_all,16,MPI_INTEGER,comm,error)
    CALL check_status(error,'receive bottoms gather')
    CALL MPI_ALLGATHER(krecv_top,16,MPI_INTEGER,top_all,16,MPI_INTEGER,comm,error)
    CALL check_status(error,'receive tops gather')
    supported=.TRUE.;slots=0;slot=0
    DO peer=0,3
       IF(INT(metadata(4,peer),int64)-INT(metadata(3,peer),int64)+1/=nx.OR. &
          INT(metadata(6,peer),int64)-INT(metadata(5,peer),int64)+1/=ny.OR. &
          metadata(2,peer)/=zt.OR.metadata(1,peer)/=zb) supported=.FALSE.
       IF(peer/=rank) THEN
          slot=slot+1;slots(peer)=slot;peer_ids(slot)=peer
       ENDIF
    ENDDO
    DO side=1,4
       peer=neighbors(side)
       IF(peer==MPI_PROC_NULL) CYCLE
       IF(peer<0.OR.peer>3.OR.peer==rank) THEN
          supported=.FALSE.
          CYCLE
       ENDIF
       IF(side<=2) THEN
          IF(ANY(metadata(3:4,peer)/=[xl,xr])) supported=.FALSE.
       ELSE
          IF(ANY(metadata(5:6,peer)/=[ys,yn])) supported=.FALSE.
       ENDIF
    ENDDO
    IF(.NOT.agree(supported)) RETURN
    ALLOCATE(destination(capacity,2),source_index(capacity,2),source_slot(capacity,2), &
             aliases(cells,3),STAT=allocation_status)
    IF(.NOT.agree(allocation_status==0)) THEN
       CALL release_resources()
       RETURN
    ENDIF
    destination=0;source_index=0;source_slot=0;counts=0;plan_valid=.TRUE.
    DO c=1,2
       DO side=1,4
          peer=neighbors(side)
          IF(peer==MPI_PROC_NULL) CYCLE
          IF(MAX(krecv_bot(1,c,side),krecv_bot(2,c,side))<=MIN(krecv_top(1,c,side),krecv_top(2,c,side))) &
              plan_valid=.FALSE.
          DO g=1,2
             IF(krecv_bot(g,c,side)<zb+1.OR.krecv_top(g,c,side)>zt) THEN
                plan_valid=.FALSE.
                CYCLE
             ENDIF
             h=0
             DO
                IF(side<=2) THEN
                   dsti=hrecv(g,c,side)+2*h
                   IF(dsti>xr) EXIT
                   IF(dsti<xl) THEN
                      plan_valid=.FALSE.
                      EXIT
                   ENDIF
                   dstj=MERGE(ys-1,yn+1,side==1)
                   srci=dsti
                   srcj=MERGE(metadata(6,peer),metadata(5,peer),side==1)
                ELSE
                   dstj=hrecv(g,c,side)+2*h
                   IF(dstj>yn+1) EXIT
                   IF(dstj<ys-1) THEN
                      plan_valid=.FALSE.
                      EXIT
                   ENDIF
                   dsti=MERGE(xl-1,xr+1,side==3)
                   srci=MERGE(metadata(4,peer),metadata(3,peer),side==3)
                   srcj=dstj
                ENDIF
                DO k=krecv_bot(g,c,side),krecv_top(g,c,side)
                   own=peer
                   IF(side>=3) THEN
                      ys_side=0
                      IF(srcj==metadata(5,peer)-1) ys_side=1
                      IF(srcj==metadata(6,peer)+1) ys_side=2
                      IF(ys_side/=0) THEN
                         yp=metadata(6+ys_side,peer)
                         ! Compose the original Y-unpack -> X-pack. A physical Y ghost
                         ! is not overwritten; X must read that ghost on its X neighbor.
                         IF(yp/=MPI_PROC_NULL) THEN
                            IF(received_y(peer,k,srci,ys_side,c)) own=yp
                         ENDIF
                      ENDIF
                   ENDIF
                   IF(own/=peer) THEN
                      CALL add_entry(c,k,dstj,dsti,own,k,MERGE(metadata(6,own),metadata(5,own),ys_side==1),srci)
                   ELSE
                      CALL add_entry(c,k,dstj,dsti,own,k,srcj,srci)
                   ENDIF
                ENDDO
                h=h+1
             ENDDO
          ENDDO
       ENDDO
    ENDDO
    IF(.NOT.agree(plan_valid)) THEN
       CALL release_resources()
       RETURN
    ENDIF
    host=C_LOC(p(zb,ys-1,xl-1));device=acc_pointer(host)
    supported=c_associated(device)
    bytes=INT(cells,c_size_t)*C_SIZEOF(0.0_wp)
    IF(supported) THEN
       status=memory_range(base,allocation_bytes,device)
       supported=status==0
    ENDIF
    IF(supported) THEN
       offset=TRANSFER(device,offset)-TRANSFER(base,offset)
       supported=offset>=0.AND.INT(offset,c_size_t)<=allocation_bytes
       IF(supported) supported=bytes<=allocation_bytes-INT(offset,c_size_t)
    ENDIF
    IF(supported) THEN
       status=export_memory(handle,base)
       supported=status==0
    ENDIF
    IF(.NOT.agree(supported)) THEN
       CALL release_resources()
       RETURN
    ENDIF
    CALL MPI_ALLGATHER(handle%data,64,MPI_BYTE,handles,64,MPI_BYTE,comm,error)
    CALL check_status(error,'handle gather')
    CALL MPI_ALLGATHER(offset,1,MPI_INTEGER8,offsets,1,MPI_INTEGER8,comm,error)
    CALL check_status(error,'offset gather')
    DO slot=1,3
       peer=peer_ids(slot);handle%data=handles(:,peer)
       ! hipIpcMemLazyEnablePeerAccess = 0x01.
       status=import_memory(imported(slot),handle,1_c_int)
       opened(slot)=status==0
    ENDDO
    ! No aliases are mapped and no peer reads start until every import succeeds.
    IF(.NOT.agree(ALL(opened))) THEN
       CALL release_resources()
       RETURN
    ENDIF
    DO slot=1,3
       peer=peer_ids(slot)
       address=TRANSFER(imported(slot),address)+offsets(peer)
       remote_view(slot)=TRANSFER(address,c_null_ptr)
       CALL map_pointer(C_LOC(aliases(1,slot)),remote_view(slot),bytes)
       mapped(slot)=.TRUE.
       IF(.NOT.c_associated(acc_pointer(C_LOC(aliases(1,slot))),remote_view(slot))) CALL die('alias mapping',1)
    ENDDO
    !$ACC ENTER DATA COPYIN(destination,source_index,source_slot)
    plan_mapped=.TRUE.;ready=.TRUE.;enabled=.TRUE.
  END SUBROUTINE ipc_setup


  LOGICAL FUNCTION received_y(peer,k,i,side,c)
    INTEGER,INTENT(IN) :: peer,k,i,side,c
    INTEGER :: g,d
    received_y=.FALSE.
    DO g=1,2
       d=i-h_all(g,c,side,peer)
       IF(k>=bot_all(g,c,side,peer).AND.k<=top_all(g,c,side,peer).AND.d>=0.AND.MOD(d,2)==0) &
           received_y=.TRUE.
    ENDDO
  END FUNCTION
  INTEGER FUNCTION flat_index(peer,k,j,i) RESULT(index)
    INTEGER,INTENT(IN) :: peer,k,j,i
    INTEGER :: nz,ny
    index=0
    IF(peer<0.OR.peer>3) RETURN
    IF(k<metadata(1,peer).OR.k>metadata(2,peer)+1.OR. &
       j<metadata(5,peer)-1.OR.j>metadata(6,peer)+1.OR. &
       i<metadata(3,peer)-1.OR.i>metadata(4,peer)+1) RETURN
    nz=metadata(2,peer)-metadata(1,peer)+2;ny=metadata(6,peer)-metadata(5,peer)+3
    index=1+(k-metadata(1,peer))+nz*((j-metadata(5,peer)+1)+ny*(i-metadata(3,peer)+1))
  END FUNCTION
  SUBROUTINE add_entry(c,dk,dj,di,peer,sk,sj,si)
    INTEGER,INTENT(IN) :: c,dk,dj,di,peer,sk,sj,si
    INTEGER :: n,dst,src
    IF(peer<0.OR.peer>3) THEN
       plan_valid=.FALSE.
       RETURN
    ENDIF
    dst=flat_index(rank,dk,dj,di);src=flat_index(peer,sk,sj,si)
    n=counts(c)+1
    IF(slots(peer)==0.OR.n>capacity.OR.dst==0.OR.src==0) THEN
       plan_valid=.FALSE.
       RETURN
    ENDIF
    counts(c)=n
    destination(n,c)=dst;source_index(n,c)=src;source_slot(n,c)=slots(peer)
  END SUBROUTINE
  SUBROUTINE ipc_exchange(p,color)
    INTEGER,INTENT(IN) :: color
    REAL(wp),INTENT(INOUT) :: p(bounds(1):bounds(2)+1,bounds(5)-1:bounds(6)+1,bounds(3)-1:bounds(4)+1)
    INTEGER :: error
    IF(.NOT.ready.OR.color<1.OR.color>2) CALL die('exchange without setup/color',1)
    ! Every rank has completed its synchronous current-color update here.
    CALL MPI_BARRIER(communicator,error);CALL check_status(error,'color barrier')
    CALL copy_plan(p,aliases(:,1),aliases(:,2),aliases(:,3),destination(:,color), &
                   source_index(:,color),source_slot(:,color),counts(color),cells)
  END SUBROUTINE
  SUBROUTINE copy_plan(p,a,b,c,dst,src,owner,n,ncells)
    INTEGER,INTENT(IN) :: n,ncells,dst(n),src(n),owner(n)
    REAL(wp),INTENT(INOUT) :: p(ncells)
    REAL(wp),INTENT(IN) :: a(ncells),b(ncells),c(ncells)
    INTEGER :: t
    !$ACC PARALLEL LOOP GANG VECTOR DEFAULT(PRESENT)
    DO t=1,n
       SELECT CASE(owner(t))
       CASE(1);p(dst(t))=a(src(t))
       CASE(2);p(dst(t))=b(src(t))
       CASE(3);p(dst(t))=c(src(t))
       END SELECT
    ENDDO
    !$ACC END PARALLEL LOOP
  END SUBROUTINE
  SUBROUTINE ipc_finish_redblack()
    INTEGER :: error
    IF(.NOT.ready) CALL die('finish without setup',1)
    ! Protect the last color before arbitrary caller writes/sort/deallocation.
    CALL MPI_BARRIER(communicator,error);CALL check_status(error,'return barrier')
  END SUBROUTINE
  SUBROUTINE release_resources()
    INTEGER :: slot
    INTEGER(c_int) :: status
    IF(plan_mapped) THEN
       !$ACC EXIT DATA DELETE(destination,source_index,source_slot)
       plan_mapped=.FALSE.
    ENDIF
    DO slot=1,3
       IF(mapped(slot)) CALL unmap_pointer(C_LOC(aliases(1,slot)))
       mapped(slot)=.FALSE.
       IF(opened(slot)) THEN
          status=close_memory(imported(slot));CALL check_status(status,'IPC close')
       ENDIF
       opened(slot)=.FALSE.;imported(slot)=c_null_ptr;remote_view(slot)=c_null_ptr
    ENDDO
    IF(ALLOCATED(aliases)) DEALLOCATE(aliases)
    IF(ALLOCATED(destination)) DEALLOCATE(destination)
    IF(ALLOCATED(source_index)) DEALLOCATE(source_index)
    IF(ALLOCATED(source_slot)) DEALLOCATE(source_slot)
  END SUBROUTINE
  SUBROUTINE ipc_release()
    INTEGER :: error
    IF(ready) THEN
       CALL MPI_BARRIER(communicator,error);CALL check_status(error,'release entry barrier')
    ENDIF
    CALL release_resources()
    IF(ready) THEN
       CALL MPI_BARRIER(communicator,error);CALL check_status(error,'release exit barrier')
    ENDIF
    ! A rejected setup must be reconsidered for the next pressure solve too.
    ready=.FALSE.;decided=.FALSE.;cells=0;capacity=0;counts=0
    communicator=MPI_COMM_NULL;rank=-1
  END SUBROUTINE
END MODULE ipc_exchange_mod
#else
MODULE ipc_exchange_mod
END MODULE ipc_exchange_mod
#endif
