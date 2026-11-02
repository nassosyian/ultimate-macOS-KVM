// Runs INSIDE the macOS guest: osascript -l JavaScript metal-probe.js
// Compiles small Metal shaders at runtime and draws once with each, so the host receives the
// guest compiler's AIR (pvg-linux-pci dump-dir=... saves every translated function as a
// metallib). Prints the device's capability answers and what each pipeline did.
ObjC.import('Metal');
ObjC.import('Foundation');

function say(s) { console.log(s); }

const dev = $.MTLCreateSystemDefaultDevice();
say('device: ' + dev.name.js);
say('argumentBuffersSupport (1 = tier 2): ' + dev.argumentBuffersSupport);
say('supportsShaderBarycentricCoordinates: ' + dev.supportsShaderBarycentricCoordinates);
say('supportsFamily Mac2 (2002): ' + dev.supportsFamily(2002));

const header = `
#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; };
vertex V vs(uint vid [[vertex_id]]) {
    V o;
    float2 p = float2((vid << 1) & 2, vid & 2);
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}
`;
const fragments = {
    bary: 'fragment float4 fs_bary(float3 b [[barycentric_coord]]) { return float4(b, 1.0); }',
    bary_np: 'fragment float4 fs_bary_np(float2 b [[barycentric_coord, center_no_perspective]]) ' +
             '{ return float4(b, 0.0, 1.0); }',
    prim: 'fragment float4 fs_prim(uint p [[primitive_id]]) { return float4(float(p), 0, 0, 1); }',
};

const td = $.MTLTextureDescriptor.texture2DDescriptorWithPixelFormatWidthHeightMipmapped(
    70 /* RGBA8Unorm */, 64, 64, false);
td.usage = 4 /* RenderTarget */ | 1 /* ShaderRead */;
const tex = dev.newTextureWithDescriptor(td);
const queue = dev.newCommandQueue;

for (const name in fragments) {
    const err = Ref();
    const lib = dev.newLibraryWithSourceOptionsError($(header + fragments[name]),
                                                     $.MTLCompileOptions.alloc.init, err);

    if (!lib || lib.isNil()) {
        say(name + ': compile failed: ' + (err[0] ? err[0].localizedDescription.js : '?'));
        continue;
    }
    const desc = $.MTLRenderPipelineDescriptor.alloc.init;
    desc.vertexFunction = lib.newFunctionWithName($('vs'));
    desc.fragmentFunction = lib.newFunctionWithName($('fs_' + name));
    desc.colorAttachments.objectAtIndexedSubscript(0).pixelFormat = 70;
    const perr = Ref();
    const ps = dev.newRenderPipelineStateWithDescriptorError(desc, perr);

    if (!ps || ps.isNil()) {
        say(name + ': pipeline failed: ' + (perr[0] ? perr[0].localizedDescription.js : '?'));
        continue;
    }
    const rp = $.MTLRenderPassDescriptor.renderPassDescriptor;
    const att = rp.colorAttachments.objectAtIndexedSubscript(0);
    att.texture = tex;
    att.loadAction = 2;     /* Clear */
    att.storeAction = 1;    /* Store */
    const cb = queue.commandBuffer;
    const enc = cb.renderCommandEncoderWithDescriptor(rp);
    enc.setRenderPipelineState(ps);
    enc.drawPrimitivesVertexStartVertexCount(3 /* Triangle */, 0, 3);
    enc.endEncoding;
    cb.commit;
    cb.waitUntilCompleted;
    say(name + ': drawn, command buffer status ' + cb.status + ' (4 = completed)' +
        (cb.error && !cb.error.isNil() ? ', error ' + cb.error.localizedDescription.js : ''));
}
