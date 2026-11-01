; Synthetic AIR kernel: phi / select / icmp over pointers into one private array (a loop walking
; it by pointer, a select between two elements, a phi joining two branches). Apple's compiler
; emits these for naga's MSL (RFinder's vs_backdrop and mesh vertex shader). Assemble with llvm-as
; and check with a2s-check.
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

define void @syn(ptr addrspace(1) %buf, i32 %gid) {
entry:
  %arr = alloca [8 x float], align 4
  %end = getelementptr inbounds [8 x float], ptr %arr, i64 0, i64 8
  br label %fill

fill:
  %p = phi ptr [ %arr, %entry ], [ %pn, %fill ]
  %i = phi i32 [ 0, %entry ], [ %in, %fill ]
  %f = uitofp i32 %i to float
  store float %f, ptr %p, align 4
  %pn = getelementptr inbounds float, ptr %p, i64 1
  %in = add i32 %i, 1
  %done = icmp eq ptr %pn, %end
  br i1 %done, label %pick, label %fill

pick:
  %c = icmp ult i32 %gid, 4
  %a0 = getelementptr inbounds [8 x float], ptr %arr, i64 0, i64 1
  %a1 = getelementptr inbounds [8 x float], ptr %arr, i64 0, i64 6
  %sel = select i1 %c, ptr %a0, ptr %a1
  %v = load float, ptr %sel, align 4
  br i1 %c, label %left, label %right

left:
  %pl = getelementptr inbounds [8 x float], ptr %arr, i64 0, i64 2
  br label %join

right:
  %pr = getelementptr inbounds [8 x float], ptr %arr, i64 0, i64 5
  br label %join

join:
  %pj = phi ptr [ %pl, %left ], [ %pr, %right ]
  %w = load float, ptr %pj, align 4
  %sum = fadd float %v, %w
  %slot = getelementptr inbounds float, ptr addrspace(1) %buf, i32 %gid
  store float %sum, ptr addrspace(1) %slot, align 4
  ret void
}

!air.kernel = !{!0}
!0 = !{ptr @syn, !1, !2}
!1 = !{}
!2 = !{!3, !4}
!3 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"buf"}
!4 = !{i32 1, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"gid"}
