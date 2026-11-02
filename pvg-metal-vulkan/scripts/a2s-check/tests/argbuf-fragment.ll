; Synthetic AIR fragment function reading an argument buffer (Tier 2 layout: 8-byte handles):
;   struct Args { texture2d<float> tex; sampler smp; device const float *data; };
;   fragment float4 f(constant Args &args [[buffer(0)]], float2 uv [[user(locn0)]])
;   { return args.tex.sample(args.smp, uv) * args.data[1]; }
; The texture / sampler handles and the device pointer are loaded from memory: air2spv resolves
; them through the A2S_INDIRECT_SET lookup tables. Assemble with llvm-as and check with a2s-check.
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

declare { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1), ptr addrspace(2), <2 x float>, i1, <2 x i32>, i1, float, float, i32)

define <4 x float> @syn(ptr addrspace(2) %args, <2 x float> %uv) {
entry:
  %tex = load ptr addrspace(1), ptr addrspace(2) %args, align 8
  %smp_p = getelementptr inbounds i8, ptr addrspace(2) %args, i64 8
  %smp = load ptr addrspace(2), ptr addrspace(2) %smp_p, align 8
  %data_p = getelementptr inbounds i8, ptr addrspace(2) %args, i64 16
  %data = load ptr addrspace(1), ptr addrspace(2) %data_p, align 8
  %s = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(ptr addrspace(1) %tex, ptr addrspace(2) %smp, <2 x float> %uv, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0)
  %c = extractvalue { <4 x float>, i8 } %s, 0
  %e = getelementptr inbounds float, ptr addrspace(1) %data, i64 1
  %k = load float, ptr addrspace(1) %e, align 4
  %ki = insertelement <4 x float> undef, float %k, i32 0
  %kv = shufflevector <4 x float> %ki, <4 x float> undef, <4 x i32> zeroinitializer
  %r = fmul <4 x float> %c, %kv
  ret <4 x float> %r
}

!air.fragment = !{!0}
!0 = !{ptr @syn, !1, !2}
!1 = !{!3}
!2 = !{!4, !5}
!3 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4", !"air.arg_name", !"color"}
!4 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 24, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"Args", !"air.arg_name", !"args"}
!5 = !{i32 1, !"air.fragment_input", !"user(locn0)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"uv"}
