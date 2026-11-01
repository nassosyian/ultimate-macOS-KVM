; Synthetic AIR kernel exercising atomics and SIMD-group intrinsics (no captured workload uses
; them). Assemble with llvm-as and check with a2s-check.
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

define void @syn(ptr addrspace(1) %buf, ptr addrspace(3) %tg, i32 %gid) {
  %a = call i32 @air.atomic.global.add.u.i32(ptr addrspace(1) %buf, i32 1, i32 0, i32 2, i1 true)
  %b = call i32 @air.atomic.global.max.s.i32(ptr addrspace(1) %buf, i32 %a, i32 0, i32 2, i1 true)
  %c = call i32 @air.atomic.local.add.u.i32(ptr addrspace(3) %tg, i32 %b, i32 0, i32 1, i1 true)
  %l = call i32 @air.atomic.global.load.i32(ptr addrspace(1) %buf, i32 0, i32 2, i1 true)
  %x = call i32 @air.atomic.global.xchg.i32(ptr addrspace(1) %buf, i32 %l, i32 0, i32 2, i1 true)
  call void @air.atomic.global.store.i32(ptr addrspace(1) %buf, i32 %x, i32 0, i32 2, i1 true)
  %s = call i32 @air.simd_sum.u.i32(i32 %c)
  %p = call i32 @air.simd_prefix_exclusive_sum.u.i32(i32 %s)
  %m = call float @air.simd_max.f32(float 1.0)
  %f = call float @air.simd_shuffle_xor.f32(float %m, i16 1)
  %d = call i32 @air.simd_shuffle_down.u.i32(i32 %p, i16 2)
  %q = call i32 @air.quad_sum.u.i32(i32 %d)
  %qb = call i32 @air.quad_broadcast.u.i32(i32 %q, i16 0)
  %bal = call i64 @air.simd_ballot.i64(i1 true)
  %all = call i1 @air.simd_all(i1 true)
  %first = call i1 @air.simd_is_first()
  %bf = call i32 @air.simd_broadcast_first.u.i32(i32 %qb)
  %fi = fptoui float %f to i32
  %t1 = add i32 %bf, %fi
  %bl = trunc i64 %bal to i32
  %t2 = add i32 %t1, %bl
  %sel = select i1 %all, i32 %t2, i32 0
  %sel2 = select i1 %first, i32 %sel, i32 1
  %slot = getelementptr inbounds i32, ptr addrspace(1) %buf, i32 %gid
  store i32 %sel2, ptr addrspace(1) %slot, align 4
  ret void
}

declare i32 @air.atomic.global.add.u.i32(ptr addrspace(1), i32, i32, i32, i1)
declare i32 @air.atomic.global.max.s.i32(ptr addrspace(1), i32, i32, i32, i1)
declare i32 @air.atomic.local.add.u.i32(ptr addrspace(3), i32, i32, i32, i1)
declare i32 @air.atomic.global.load.i32(ptr addrspace(1), i32, i32, i1)
declare i32 @air.atomic.global.xchg.i32(ptr addrspace(1), i32, i32, i32, i1)
declare void @air.atomic.global.store.i32(ptr addrspace(1), i32, i32, i32, i1)
declare i32 @air.simd_sum.u.i32(i32)
declare i32 @air.simd_prefix_exclusive_sum.u.i32(i32)
declare float @air.simd_max.f32(float)
declare float @air.simd_shuffle_xor.f32(float, i16)
declare i32 @air.simd_shuffle_down.u.i32(i32, i16)
declare i32 @air.quad_sum.u.i32(i32)
declare i32 @air.quad_broadcast.u.i32(i32, i16)
declare i64 @air.simd_ballot.i64(i1)
declare i1 @air.simd_all(i1)
declare i1 @air.simd_is_first()
declare i32 @air.simd_broadcast_first.u.i32(i32)

!air.kernel = !{!0}
!0 = !{ptr @syn, !1, !2}
!1 = !{}
!2 = !{!3, !4, !5}
!3 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"buf"}
!4 = !{i32 1, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 3, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"tg"}
!5 = !{i32 2, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"gid"}
