#if PERSONAL_APPS
#include <TargetConditionals.h>
#if TARGET_OS_IOS || TUTU_NATIVE_FRAME
#include <metal_stdlib>
using namespace metal;
// Line-faithful v4 GLASS_FS; texture v is top-down in Metal, unlike WebGL.
struct TutuPage0GlassUniforms { float4 panel; float4 lightAndPixel; };
struct TutuPage0GlassVertexOut { float4 position [[position]]; float2 uv; };
constexpr sampler tutuPage0GlassSampler(coord::normalized, address::clamp_to_edge, filter::linear);
vertex TutuPage0GlassVertexOut tutuPage0GlassVertex(uint id [[vertex_id]]) {
    float2 p = float2(float(id & 1u), float(id >> 1u));
    return {float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0), p};
}
fragment float4 tutuPage0GlassDown(TutuPage0GlassVertexOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant float2 &texel [[buffer(0)]]) {
    return 0.25 * (src.sample(tutuPage0GlassSampler, in.uv + texel * float2(-1,-1)) + src.sample(tutuPage0GlassSampler, in.uv + texel * float2(1,-1)) + src.sample(tutuPage0GlassSampler, in.uv + texel * float2(-1,1)) + src.sample(tutuPage0GlassSampler, in.uv + texel * float2(1,1)));
}
fragment float4 tutuPage0GlassBlur(TutuPage0GlassVertexOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant float2 &dir [[buffer(0)]]) {
    float4 c = src.sample(tutuPage0GlassSampler, in.uv) * 0.2270270;
    c += (src.sample(tutuPage0GlassSampler, in.uv + dir * 1.3846154) + src.sample(tutuPage0GlassSampler, in.uv - dir * 1.3846154)) * 0.3162162;
    c += (src.sample(tutuPage0GlassSampler, in.uv + dir * 3.2307692) + src.sample(tutuPage0GlassSampler, in.uv - dir * 3.2307692)) * 0.0702703;
    return c;
}
namespace tutuPage0GlassDetail {
constant float RP = 18.0, RT = 12.0, RF = 12.0;
void seg(float2 p, float2 a, float2 b, thread float &best, thread float2 &bq){
  float2 pa = p - a, ba = b - a; float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
  float2 q = a + ba * h; float d = length(p - q);
  if (d < best) { best = d; bq = q; }
}
void arcQ(float2 p, float2 c, float r, float2 sg, thread float &best, thread float2 &bq){
  float2 v = p - c;
  if (v.x * sg.x >= 0.0 && v.y * sg.y >= 0.0) {
    float l = length(v); float d = abs(l - r);
    if (d < best) { best = d; bq = c + (l > 1e-4 ? v / l : sg * 0.7071) * r; }
  }
}
bool inFolder(float2 p, constant TutuPage0GlassUniforms &u){
  float4 P = u.panel; float3 T = float3(20.0, 135.0, 78.0);
  bool a = p.x >= P.x && p.x <= P.z && p.y >= P.y && p.y <= P.w;
  if (a && p.x > P.z - RP && p.y < P.y + RP && length(p - float2(P.z - RP, P.y + RP)) > RP) a = false;
  if (a && p.x > P.z - RP && p.y > P.w - RP && length(p - float2(P.z - RP, P.w - RP)) > RP) a = false;
  if (a && p.x < P.x + RP && p.y > P.w - RP && length(p - float2(P.x + RP, P.w - RP)) > RP) a = false;
  bool b = p.x >= T.x && p.x <= T.z && p.y >= T.y && p.y <= P.y + 0.5;
  if (b && p.x < T.x + RT && p.y < T.y + RT && length(p - float2(T.x + RT, T.y + RT)) > RT) b = false;
  if (b && p.x > T.z - RT && p.y < T.y + RT && length(p - float2(T.z - RT, T.y + RT)) > RT) b = false;
  bool f = p.x >= T.z && p.x <= T.z + RF && p.y >= P.y - RF && p.y <= P.y && length(p - float2(T.z + RF, P.y - RF)) >= RF;
  return a || b || f;
}
float folder(float2 p, thread float2 &bq, constant TutuPage0GlassUniforms &u){
  float4 P = u.panel; float3 T = float3(20.0, 135.0, 78.0); float best = 1e5; bq = p;
  seg(p, float2(P.x, T.y + RT), float2(P.x, P.w - RP), best, bq);
  arcQ(p, float2(T.x + RT, T.y + RT), RT, float2(-1.0, -1.0), best, bq);
  seg(p, float2(T.x + RT, T.y), float2(T.z - RT, T.y), best, bq);
  arcQ(p, float2(T.z - RT, T.y + RT), RT, float2(1.0, -1.0), best, bq);
  seg(p, float2(T.z, T.y + RT), float2(T.z, P.y - RF), best, bq);
  arcQ(p, float2(T.z + RF, P.y - RF), RF, float2(-1.0, 1.0), best, bq);
  seg(p, float2(T.z + RF, P.y), float2(P.z - RP, P.y), best, bq);
  arcQ(p, float2(P.z - RP, P.y + RP), RP, float2(1.0, -1.0), best, bq);
  seg(p, float2(P.z, P.y + RP), float2(P.z, P.w - RP), best, bq);
  arcQ(p, float2(P.z - RP, P.w - RP), RP, float2(1.0, 1.0), best, bq);
  seg(p, float2(P.z - RP, P.w), float2(P.x + RP, P.w), best, bq);
  arcQ(p, float2(P.x + RP, P.w - RP), RP, float2(-1.0, 1.0), best, bq);
  return inFolder(p, u) ? -best : best;
}
float2 uvOf(float2 p){ return float2(p.x / 402.0, p.y / 874.0); }
float hash(float2 p){ return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
}
fragment float4 tutuPage0GlassFragment(TutuPage0GlassVertexOut in [[stage_in]], texture2d<float> tScene [[texture(0)]], texture2d<float> tBlur [[texture(1)]], constant TutuPage0GlassUniforms &u [[buffer(0)]]){
  using namespace tutuPage0GlassDetail;
  float2 vQ = in.uv * float2(402.0, 874.0);
  float2 p = vQ, q = vQ, v, m;
  float s = 1e5, bevel = 22.0, refr = 18.0, dimHi = 0.60, l, sc;
  if (u.panel.z > u.panel.x) s = folder(p, q, u);
  if (float3(360.0, 92.0, 22.0).z > 0.0) { v = p - float3(360.0, 92.0, 22.0).xy; l = length(v); sc = l - float3(360.0, 92.0, 22.0).z;
    if (sc < s) { s = sc; q = float3(360.0, 92.0, 22.0).xy + (l > 1e-4 ? v / l : float2(0.0, -1.0)) * float3(360.0, 92.0, 22.0).z; bevel = 12.0; refr = 9.0; dimHi = 0.42; } }
  if (float3(360.0, 810.0, 22.0).z > 0.0) { v = p - float3(360.0, 810.0, 22.0).xy; l = length(v); sc = l - float3(360.0, 810.0, 22.0).z;
    if (sc < s) { s = sc; q = float3(360.0, 810.0, 22.0).xy + (l > 1e-4 ? v / l : float2(0.0, -1.0)) * float3(360.0, 810.0, 22.0).z; bevel = 12.0; refr = 9.0; dimHi = 0.42; } }
  if (float4(20.0, 788.0, 328.0, 832.0).z > float4(20.0, 788.0, 328.0, 832.0).x) { float hh = (float4(20.0, 788.0, 328.0, 832.0).w - float4(20.0, 788.0, 328.0, 832.0).y) * 0.5;
    m = float2(clamp(p.x, float4(20.0, 788.0, 328.0, 832.0).x + hh, float4(20.0, 788.0, 328.0, 832.0).z - hh), float4(20.0, 788.0, 328.0, 832.0).y + hh); v = p - m; l = length(v); sc = l - hh;
    if (sc < s) { s = sc; q = m + (l > 1e-4 ? v / l : float2(0.0, -1.0)) * hh; bevel = 13.0; refr = 10.0; dimHi = 0.42; } }
  if (s > 30.0) return tScene.sample(tutuPage0GlassSampler, uvOf(p));
  float2 dv = p - q; float2 n = (s > 0.0 ? dv : -dv) / max(length(dv), 1e-4);
  float3 base = tScene.sample(tutuPage0GlassSampler, uvOf(p)).rgb;
  float shd = 0.22 * exp(-max(s, 0.0) / 9.0) * (0.55 + 0.45 * clamp(n.y, 0.0, 1.0));
  float3 outside = base * (1.0 - shd);
  float cover = clamp(0.5 - s * u.lightAndPixel.z, 0.0, 1.0);
  if (cover <= 0.0) { return float4(outside, 1.0); }
  float depth = max(-s, 0.0);
  float t = clamp(depth / bevel, 0.0, 1.0);
  float2 off = -n * refr * pow(1.0 - t, 1.8);
  float2 pg = p + off;
  float3 cs = 0.25 * (tScene.sample(tutuPage0GlassSampler, uvOf(pg + float2(-1.0, -1.0))).rgb + tScene.sample(tutuPage0GlassSampler, uvOf(pg + float2(1.0, -1.0))).rgb
                  + tScene.sample(tutuPage0GlassSampler, uvOf(pg + float2(-1.0, 1.0))).rgb + tScene.sample(tutuPage0GlassSampler, uvOf(pg + float2(1.0, 1.0))).rgb);
  float3 cb = float3(tBlur.sample(tutuPage0GlassSampler, uvOf(p + off * 1.025)).r, tBlur.sample(tutuPage0GlassSampler, uvOf(pg)).g, tBlur.sample(tutuPage0GlassSampler, uvOf(p + off * 0.975)).b);
  float3 c = mix(cs, cb, mix(0.55, 1.0, smoothstep(0.0, 0.8, t)));
  float lum = dot(cb, float3(0.299, 0.587, 0.114));
  c *= mix(0.92, dimHi, smoothstep(0.08, 0.75, lum));
  float cl = dot(c, float3(0.299, 0.587, 0.114)); c = mix(float3(cl), c, 1.12);
  c += float3(0.030, 0.030, 0.035);
  float fa = dot(n, u.lightAndPixel.xy);
  float sp = 0.18 + 0.85 * pow(max(fa, 0.0), 1.3) + 0.38 * pow(max(-fa, 0.0), 1.6);
  c += float3(1.0, 0.99, 0.97) * (exp(-depth / 1.1) * sp * 0.75 + pow(1.0 - t, 2.0) * sp * 0.10);
  c += (hash(p * 1.37 + 0.5) - 0.5) / 255.0;
  return float4(mix(outside, c, cover), 1.0);
}

// Paper CSS controls deliberately do not share the v4 glass approximation.
struct TutuPage0PaperUniforms { float4 shape; float4 pixels; };
namespace tutuPage0PaperDetail {
float capsule(float2 p, float4 shape) {
    float2 q = p - shape.xy;
    q.x -= clamp(q.x, -shape.z, shape.z);
    return length(q) - shape.w;
}
float coverage(float distance, constant TutuPage0PaperUniforms &u) {
    return clamp(0.5 - distance * min(u.pixels.x / 402.0, u.pixels.y / 874.0), 0.0, 1.0);
}
float3 saturation(float3 color) {
    // CSS filter-effects saturate(1.2), applied in sRGB, before the RGBA fill.
    float luminance = dot(color, float3(0.213, 0.715, 0.072));
    return clamp(luminance + 1.2 * (color - luminance), 0.0, 1.0);
}
float3 control(float3 below, float3 blurred, float shadow, float distance,
               float3 fill, float fillAlpha, float borderAlpha,
               constant TutuPage0PaperUniforms &u) {
    float outer = coverage(distance, u);
    float inner = coverage(distance + 1.0, u); // inset 0 0 0 1px
    float3 background = mix(saturation(blurred), fill / 255.0, fillAlpha);
    float3 result = mix(below * (1.0 - 0.35 * shadow), background, outer);
    return result + (1.0 - background) * borderAlpha * (outer - inner);
}
}
fragment float4 tutuPage0PaperShadowMask(TutuPage0GlassVertexOut in [[stage_in]],
                                       constant TutuPage0PaperUniforms &u [[buffer(0)]]) {
    using namespace tutuPage0PaperDetail;
    float alpha = coverage(capsule(in.uv * float2(402.0, 874.0), u.shape), u);
    return float4(alpha);
}
fragment float4 tutuPage0PaperBackdropFragment(TutuPage0GlassVertexOut in [[stage_in]],
                                              texture2d<float> scene [[texture(0)]],
                                              constant TutuPage0PaperUniforms &u [[buffer(0)]]) {
    using namespace tutuPage0PaperDetail;
    float2 p = in.uv * float2(402.0, 874.0);
    float bottom = 166.0 + u.shape.x;
    float radius = min(18.0, u.shape.x * 0.5);
    float distance = max(max(20.0 - p.x, p.x - 382.0), max(166.0 - p.y, p.y - bottom));
    // .card: border-radius 0 18px 18px 18px; #fbf8f2.
    if (p.x > 382.0 - radius && p.y < 166.0 + radius)
        distance = max(distance, length(p - float2(382.0 - radius, 166.0 + radius)) - radius);
    if (p.x > 382.0 - radius && p.y > bottom - radius)
        distance = max(distance, length(p - float2(382.0 - radius, bottom - radius)) - radius);
    if (p.x < 20.0 + radius && p.y > bottom - radius)
        distance = max(distance, length(p - float2(20.0 + radius, bottom - radius)) - radius);
    return float4(mix(scene.sample(tutuPage0GlassSampler, in.uv).rgb,
                      float3(251.0, 248.0, 242.0) / 255.0, coverage(distance, u)), 1.0);
}
fragment float4 tutuPage0PaperControlsFragment(TutuPage0GlassVertexOut in [[stage_in]],
                                              texture2d<float> scene [[texture(0)]],
                                              texture2d<float> blur14 [[texture(1)]],
                                              texture2d<float> blur16 [[texture(2)]],
                                              texture2d<float> plusShadow [[texture(3)]],
                                              texture2d<float> searchShadow [[texture(4)]],
                                              texture2d<float> gearShadow [[texture(5)]],
                                              constant TutuPage0PaperUniforms &u [[buffer(0)]]) {
    using namespace tutuPage0PaperDetail;
    float2 p = in.uv * float2(402.0, 874.0);
    float3 color = scene.sample(tutuPage0GlassSampler, in.uv).rgb;
    float plusDistance = capsule(p, float4(360.0, 92.0, 0.0, 22.0));
    float searchDistance = capsule(p, float4(174.0, 810.0, 132.0, 22.0));
    float gearDistance = capsule(p, float4(360.0, 810.0, 0.0, 22.0));
    // Gaussian destinations are clipped to these controls. Never sample the
    // unwritten remainder, including when the eventual mix weight is zero.
    float3 upper = color, lower = color;
    if (coverage(plusDistance, u) > 0.0)
        upper = blur14.sample(tutuPage0GlassSampler, in.uv).rgb;
    if (coverage(min(searchDistance, gearDistance), u) > 0.0)
        lower = blur16.sample(tutuPage0GlassSampler, in.uv).rgb;
    // .plus: (338,70,44,44), r22, blur14, rgba(40,38,40,.42),
    // white .16 inset border, 0 6 18 black .35 shadow.
    color = control(color, upper,
        plusShadow.sample(tutuPage0GlassSampler, in.uv).r,
        plusDistance, float3(40.0, 38.0, 40.0), 0.42, 0.16, u);
    // .search: (20,788,308,44), r22; .gear: (338,788,44,44), r22.
    // Both blur16, rgba(28,26,28,.45), 0 8 20 black .35 shadows;
    // their white inset border alphas are .12 and .14 respectively.
    color = control(color, lower, searchShadow.sample(tutuPage0GlassSampler, in.uv).r,
        searchDistance, float3(28.0, 26.0, 28.0), 0.45, 0.12, u);
    color = control(color, lower, gearShadow.sample(tutuPage0GlassSampler, in.uv).r,
        gearDistance, float3(28.0, 26.0, 28.0), 0.45, 0.14, u);
    return float4(color, 1.0);
}
#endif
#endif
