#include <metal_stdlib>
using namespace metal;
#if PERSONAL_APPS

struct TutuChatIntroUniforms {
    float4 geometry; // target pixel width/height, uZ, uSb
    float4 printing; // uSt, uMaxc, source-point screen width/height
    float4 silver;
};

struct TutuChatIntroVertex {
    float4 position [[position]];
};

vertex TutuChatIntroVertex tutuChatIntroVertex(uint id [[vertex_id]]) {
    const float2 positions[] = {float2(-1, 1), float2(1, 1), float2(-1, -1), float2(1, -1)};
    return {float4(positions[id], 0, 1)};
}

namespace tutu_chat_intro {
constant float2 FOC = float2(195.0f, -170.6f);
constant float ZEND = 1.4286f;
constant float PITCH = 2.4f, C45 = 0.70710678f, PI = 3.14159265f, SPREAD = 0.6f;
constant float3 PAPER = float3(21.0f, 17.0f, 15.0f) / 255.0f;

float lum(float3 c) { return dot(c, float3(0.299f, 0.587f, 0.114f)); }
float3 cath(float2 p4, texture2d<float> uCath, float2 SCR) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    return uCath.sample(linearSampler, (FOC + (p4 - FOC) / ZEND) / SCR).rgb;
}
float hash(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.x + p3.y) * p3.z);
}
float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    return mix(mix(hash(i), hash(i + float2(1.0f, 0.0f)), f.x),
               mix(hash(i + float2(0.0f, 1.0f)), hash(i + float2(1.0f, 1.0f)), f.x), f.y);
}
}

// Full chat11.FS.glsl, not the older intro.FS: PostScript focus, rough dots and paper grain.
fragment float4 tutuChatIntroFragment(TutuChatIntroVertex in [[stage_in]],
                                      texture2d<float> uCath [[texture(0)]],
                                      texture2d<float> uTone [[texture(1)]],
                                      constant TutuChatIntroUniforms& u [[buffer(0)]]) {
    using namespace tutu_chat_intro;
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    // Canonical references use SCR=(390,844). Production passes the unchanged M3a background
    // point size: only viewport-to-point mapping changes, never FOC, PITCH or the print algorithm.
    const float2 SCR = u.printing.zw;
    const float uZ = u.geometry.z, uSb = u.geometry.w, uSt = u.printing.x, uMaxc = u.printing.y;
    const float3 uSilver = u.silver.xyz;
    // Metal fragment position already has top-left origin; do not apply GLSL's Y inversion twice.
    float2 P = in.position.xy / u.geometry.xy * SCR;
    float2 P4 = FOC + (P - FOC) * (ZEND / uZ);
    float3 A = cath(P4, uCath, SCR);
    float2 g = float2(P4.x + P4.y, P4.y - P4.x) * (C45 / PITCH);
    float2 cell = floor(g) + 0.5f;
    float2 f = (g - cell) * 2.0f;
    float2 cc = float2(cell.x - cell.y, cell.x + cell.y) * (C45 * PITCH);
    float3 Ac = cath(cc, uCath, SCR);
    float c0 = clamp((lum(Ac) - 0.07f) / 0.86f, 0.0f, 1.0f);
    float c1 = uMaxc * uTone.sample(linearSampler, cc / SCR).r;
    float y = clamp(P.y / SCR.y, 0.0f, 1.0f);
    float sm = mix(uSt, uSb, y);
    float s = sm + 0.09f * (vnoise(P * float2(0.022f, 0.03f)) - 0.5f) * (1.0f - abs(2.0f * sm - 1.0f));
    s = clamp(s, 0.0f, 1.0f); s = s * s * (3.0f - 2.0f * s);
    float c = mix(c0, c1, s);
    float k = smoothstep(0.3f, 0.85f, s);
    float c1p = uMaxc * uTone.sample(linearSampler, P4 / SCR).r;
    // PostScript's round spot while the print is coming into focus; halftone.py's dot once it is there: a round dot with
    // a soft, ragged edge (the ink runs a little into the paper)
    float2 a = abs(f);
    float spot = a.x + a.y <= 1.0f ? 1.0f - dot(f, f) : dot(a - 1.0f, a - 1.0f) - 1.0f;
    float tau = c < 0.3927f ? 1.0f - 4.0f * c / PI : (c > 0.6073f ? -1.0f + 4.0f * (1.0f - c) / PI : mix(0.5f, -0.5f, (c - 0.3927f) / 0.2146f));
    float w = fwidth(spot) * (0.8f + 5.0f * (1.0f - k));
    float ink = smoothstep(tau - w, tau + w, spot) * step(0.004f, c);
    ink = mix(c, ink, k);
    float rad = PITCH * sqrt(c / PI), dist = length(f) * 0.5f * PITCH;
    float rough = (vnoise(P4 / 0.5333f) - 0.5f) * 0.12f + (vnoise(P4 / 1.6667f + 17.0f) - 0.5f) * 0.0733f;
    float inkP = clamp((rad - dist + rough) / SPREAD + 0.5f, 0.0f, 1.0f) * step(0.0833f, rad);
    ink = mix(ink, inkP, smoothstep(0.6f, 1.0f, k));
    float2 q = P / SCR;
    float grain = ((vnoise(P4 / 0.4f + 41.0f) - 0.5f) * 2.2f + (vnoise(P4 / 2.3333f + 73.0f) - 0.5f) * 1.6f) / 255.0f;
    float3 paper = (PAPER + grain * k) * (1.05f - 0.10f * clamp(q.x * 0.45f + q.y * 0.55f, 0.0f, 1.0f));
    float3 silver = uSilver * (0.92f + 0.12f * (1.0f - clamp(q.x * 0.5f + q.y * 0.5f, 0.0f, 1.0f)));
    float3 ink0 = min(Ac * (0.93f / max(lum(Ac), 0.06f)), float3(1.0f));
    float3 scr = mix(paper, mix(ink0, silver, s), ink);
    float3 dim = mix(A, paper + c1p * (silver - paper), s);
    return float4(mix(dim, scr, k), 1.0f);
}
#endif
