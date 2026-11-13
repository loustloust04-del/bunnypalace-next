#include <metal_stdlib>
using namespace metal;
#if PERSONAL_APPS
struct TutuChatTextureVertex {
    float4 position [[position]];
    float2 uv;
};
vertex TutuChatTextureVertex tutuChatTextureVertex(uint id [[vertex_id]]) {
    const float2 positions[] = {float2(-1, 1), float2(1, 1), float2(-1, -1), float2(1, -1)};
    const float2 coordinates[] = {float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1)};
    return {float4(positions[id], 0, 1), coordinates[id]};
}
fragment float4 tutuChatTextureFragment(TutuChatTextureVertex in [[stage_in]], texture2d<float> image [[texture(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    return image.sample(linearSampler, in.uv);
}

struct TutuChatBackgroundUniforms {
    float4 geometry;
    float4 silver;
};
float tutuChatBackgroundHash(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.x + p3.y) * p3.z);
}
float tutuChatBackgroundNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    return mix(mix(tutuChatBackgroundHash(i), tutuChatBackgroundHash(i + float2(1, 0)), f.x),
               mix(tutuChatBackgroundHash(i + float2(0, 1)), tutuChatBackgroundHash(i + float2(1, 1)), f.x), f.y);
}
kernel void tutuChatBackground(texture2d<float, access::write> target [[texture(0)]],
                               texture2d<float> tone [[texture(1)]],
                               constant TutuChatBackgroundUniforms& u [[buffer(0)]],
                               uint2 id [[thread_position_in_grid]]) {
    if (id.x >= target.get_width() || id.y >= target.get_height()) return;
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    const float2 screen = u.geometry.zw;
    const float pitch = 2.4f, c45 = 0.70710678f, pi = 3.14159265f;
    float2 p = (float2(id) + 0.5f) / u.geometry.x;
    // chat11.FS at glDraw(ZEND, 1, 1): P4=P, s=k=1; all transition terms cancel exactly.
    float2 g = float2(p.x + p.y, p.y - p.x) * (c45 / pitch);
    float2 cell = floor(g) + 0.5f;
    float2 f = (g - cell) * 2.0f;
    float2 center = float2(cell.x - cell.y, cell.x + cell.y) * (c45 * pitch);
    float coverage = u.geometry.y * tone.sample(linearSampler, center / screen).r;
    float radius = pitch * sqrt(coverage / pi), distance = length(f) * 0.5f * pitch;
    float rough = (tutuChatBackgroundNoise(p / 0.5333f) - 0.5f) * 0.12f
                + (tutuChatBackgroundNoise(p / 1.6667f + 17.0f) - 0.5f) * 0.0733f;
    float ink = clamp((radius - distance + rough) / 0.6f + 0.5f, 0.0f, 1.0f) * step(0.0833f, radius);
    float2 q = p / screen;
    float grain = ((tutuChatBackgroundNoise(p / 0.4f + 41.0f) - 0.5f) * 2.2f
                 + (tutuChatBackgroundNoise(p / 2.3333f + 73.0f) - 0.5f) * 1.6f) / 255.0f;
    float3 paper = (float3(21, 17, 15) / 255.0f + grain) * (1.05f - 0.10f * clamp(q.x * 0.45f + q.y * 0.55f, 0.0f, 1.0f));
    float3 silver = u.silver.xyz * (0.92f + 0.12f * (1.0f - clamp(q.x * 0.5f + q.y * 0.5f, 0.0f, 1.0f)));
    target.write(float4(mix(paper, silver, ink), 1), id);
}
#endif
