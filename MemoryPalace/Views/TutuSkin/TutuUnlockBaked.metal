#if PERSONAL_APPS
#include <TargetConditionals.h>
#if TARGET_OS_IOS || TUTU_NATIVE_FRAME
#include <metal_stdlib>
using namespace metal;
struct TutuUnlockBakedUniforms {
    float4 bounds;
    float4 transform; // origin.xy, cos(angle), sin(angle)
    float4 rects[6];
    float4 shifts[6];
    float4 weights[2];
    float4 options; // mask y, alpha, tile period, tile start
    float4 clip; // local tile start/end, is tile, unused
};
struct TutuUnlockBakedVaryings { float4 position [[position]]; float2 scene; };
vertex TutuUnlockBakedVaryings tutuUnlockBakedVertex(uint id [[vertex_id]], constant TutuUnlockBakedUniforms &u [[buffer(0)]]) {
    float2 uv = float2(id & 1, (id >> 1) & 1);
    float2 p = mix(u.bounds.xy, u.bounds.zw, uv);
    return { float4(p.x / 210.0 - 1.0, 1.0 - p.y / 456.0, 0.0, 1.0), p };
}
fragment float4 tutuUnlockBakedFragment(TutuUnlockBakedVaryings in [[stage_in]], constant TutuUnlockBakedUniforms &u [[buffer(0)]], array<texture2d<float>, 6> images [[texture(0)]]) {
    if (in.scene.y > u.options.x) discard_fragment();
    float2 d = in.scene - u.transform.xy;
    float2 local = float2(u.transform.z * d.x + u.transform.w * d.y, -u.transform.w * d.x + u.transform.z * d.y);
    constexpr sampler sampleImage(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 result = float4(0.0);
    for (uint i = 0; i < 6; ++i) {
        float weight = u.weights[i / 4][i % 4];
        if (weight <= 0.0) continue;
        float2 p = local - u.shifts[i].xy;
        float4 r = u.rects[i];
        if (u.clip.z > 0.5) {
            if (p.y < u.clip.x || p.y >= u.clip.y) continue;
            p.y = r.y + fract((p.y - u.options.w) / u.options.z) * u.options.z;
        }
        float2 uv = (p - r.xy) / r.zw;
        if (any(uv < 0.0) || any(uv > 1.0)) continue;
        result += images[i].sample(sampleImage, uv) * weight;
    }
    return result * u.options.y;
}
#endif
#endif
