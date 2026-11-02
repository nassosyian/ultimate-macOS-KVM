; Synthetic AIR kernel using an argument buffer with a nested pointer:
;   struct Inner { device float *values; };
;   struct Args { texture2d<float, access::write> out; device Inner *inner; };
;   kernel void k(device Args &args [[buffer(0)]], uint2 gid [[thread_position_in_grid]])
;   { args.out.write(float4(args.inner->values[gid.x]), gid); }
; Two levels of device pointers loaded from memory (each translated) and a storage texture
; handle. Assemble with llvm-as and check with a2s-check.
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

declare void @air.write_texture_2d.v4f32(ptr addrspace(1), <2 x i32>, <4 x float>, i32, i32)

define void @syn(ptr addrspace(1) %args, <2 x i32> %gid) {
entry:
  %out = load ptr addrspace(1), ptr addrspace(1) %args, align 8
  %inner_p = getelementptr inbounds i8, ptr addrspace(1) %args, i64 8
  %inner = load ptr addrspace(1), ptr addrspace(1) %inner_p, align 8
  %values = load ptr addrspace(1), ptr addrspace(1) %inner, align 8
  %x = extractelement <2 x i32> %gid, i32 0
  %xi = zext i32 %x to i64
  %vp = getelementptr inbounds float, ptr addrspace(1) %values, i64 %xi
  %v = load float, ptr addrspace(1) %vp, align 4
  %vi = insertelement <4 x float> undef, float %v, i32 0
  %vv = shufflevector <4 x float> %vi, <4 x float> undef, <4 x i32> zeroinitializer
  tail call void @air.write_texture_2d.v4f32(ptr addrspace(1) %out, <2 x i32> %gid, <4 x float> %vv, i32 0, i32 0)
  ret void
}

!air.kernel = !{!0}
!0 = !{ptr @syn, !1, !2}
!1 = !{}
!2 = !{!3, !4}
!3 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"Args", !"air.arg_name", !"args"}
!4 = !{i32 1, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint2", !"air.arg_name", !"gid"}
