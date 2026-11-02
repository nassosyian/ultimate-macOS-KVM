; Synthetic AIR fragment function: [[barycentric_coord]] as a perspective float3 and a
; no_perspective float2, and [[primitive_id]] (Blender's Metal backend uses both). Assemble with
; llvm-as and check with a2s-check.
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

define <4 x float> @syn(<3 x float> %bary, <2 x float> %bary_np, i32 %prim) {
entry:
  %b0 = extractelement <3 x float> %bary, i32 0
  %b1 = extractelement <3 x float> %bary, i32 1
  %b2 = extractelement <3 x float> %bary, i32 2
  %n1 = extractelement <2 x float> %bary_np, i32 1
  %pf = uitofp i32 %prim to float
  %a = fadd float %b2, %n1
  %c0 = insertelement <4 x float> undef, float %b0, i32 0
  %c1 = insertelement <4 x float> %c0, float %b1, i32 1
  %c2 = insertelement <4 x float> %c1, float %a, i32 2
  %c3 = insertelement <4 x float> %c2, float %pf, i32 3
  ret <4 x float> %c3
}

!air.fragment = !{!0}
!0 = !{ptr @syn, !1, !2}
!1 = !{!3}
!2 = !{!4, !5, !6}
!3 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4", !"air.arg_name", !"color"}
!4 = !{i32 0, !"air.barycentric_coord", !"air.center", !"air.perspective", !"air.arg_type_name", !"float3", !"air.arg_name", !"bary"}
!5 = !{i32 1, !"air.barycentric_coord", !"air.center", !"air.no_perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"bary_np"}
!6 = !{i32 2, !"air.primitive_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"prim"}
