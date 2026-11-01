# air2spv: Apple AIR → Vulkan SPIR-V

Translator for the guest's Metal shaders (AIR = LLVM bitcode inside a single-function `metallib`, target
`air64-apple-macosx15.0.0`) into SPIR-V 1.6 for Vulkan 1.3 on the host GPU. Written in C on top of the
LLVM-C API of the system LLVM 19 (`libLLVM-19.so`); no SPIR-V headers or tools are installed, so the SPIR-V
constants live in `pvgmetal/spv.h` and correctness is checked by the Khronos validation layer (it runs
spirv-val on `vkCreateShaderModule`).

## Corpus (WindowServer, Tahoe 26.7.1, run 9): 58 functions = 8 vertex + 50 fragment
19 are single-block; max 29 blocks; 2 use alloca, 4 loops, 3 switch, 4 half. Intrinsics (shaders using):
sample_texture_2d 37, fast_fmax 37, any 30, fast_saturate 23, convert 18, read_texture_2d 15, fwidth 13,
dot 13, fast_clamp 12, fast_sqrt 10, fast_fabs 10, mix 7, fma 6, fast_powr 6, sign 5, fast_fmin 5,
discard_fragment 4, saturate 3, fast_rsqrt 3, fast_pow 3, fast_log2 3, sample_texture_3d 2, fast_log 2,
fast_fract 2, fast_fmax3 2, fast_floor 2, fast_exp 2, fast_ceil 2, fast_atan2 2, dfdx/dfdy 2, unpack 1,
sample_texture_1d_array 1.

## Mapping decisions
- **Pointers** (`ptr addrspace(1)` device, `addrspace(2)` constant) are plain `u64` values in SPIR-V
  (buffer device addresses). GEPs become integer arithmetic using the module's data layout; loads/stores do
  `OpConvertUToPtr` to a `PhysicalStorageBuffer` pointer of the accessed type with an `Aligned` operand.
  Buffer arguments (`air.buffer`, `air.location_index N`) arrive in a push-constant block of 31 `u64`.
- **Textures** (`air.texture`, location N) → `UniformConstant` `OpTypeImage` at set 0, binding `16 + N`;
  **samplers** (`air.sampler`, location N) → `OpTypeSampler` at binding `48 + N`; constant samplers
  (`@__air_sampler_state*`, `!air.sampler_states`) → bindings `64 + k`, created by the host from metadata.
- **Fragment**: `air.position` → `FragCoord`; `air.fragment_input "user(name)"` → `Input` with a Location
  taken from a caller-provided varying map (vertex/fragment pairs are matched by name in Metal); return
  value → `Output` Location 0 (or per `air.render_target` for struct returns). `discard_fragment` →
  `OpDemoteToHelperInvocation`.
- **Vertex**: `air.vertex_id`/`air.instance_id` → `VertexIndex`/`InstanceIndex`; return struct member
  `air.position` → `Position` (y flipped, z remapped as needed by the host), `air.vertex_output "user(name)"` →
  Output Location from the varying map.
- **Sampling**: `sample(tex, smp, coord, i1, offset, i1 is_level, f32 lod_or_bias, f32 min_lod, i32)`:
  explicit LOD when `is_level`, otherwise implicit with Bias if non-zero; returns `{v4f32, i8}` (residency = 0).
  `read_texture_2d(tex, int2, i32 lod, i32)` → `OpImageFetch` with Lod.
- **Control flow**: LLVM passes `lower-switch, fix-irreducible, unify-loop-exits, structurizecfg` first;
  selection merges = immediate post-dominator; loops (header = back-edge target) get `OpLoopMerge` with the
  unique exit and the latch. v0 rejects loops, alloca and half.

## Files
- `pvgmetal/spv.h`, `spv.c`: SPIR-V constants and a small module builder.
- `pvgmetal/air2spv.c/.h`: the translator (`air2spv_translate(bitcode, len, varyings, &spirv)`).
- `pvgmetal/air2spv-test.c`: CLI: translate `.bc` files, write `.spv`, validate via Vulkan + validation layer.
