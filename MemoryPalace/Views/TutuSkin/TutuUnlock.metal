#if PERSONAL_APPS
#include <TargetConditionals.h>
#if TARGET_OS_IOS || TUTU_NATIVE_FRAME
#include <metal_stdlib>
using namespace metal;

namespace tutuUnlock {
struct Uniforms {
    float4 rect;
    float4 view;
    float4 flags;
    float4 fx;
    float4 pet;
    float4 misc;
    float2 shake;
    float2 mask;
    float2 c;
    float2 padding;
    float3 a;
    float3 s0;
    float3 s1;
    float3 knot;
    float3 bp;
    float3 spark;
    float3x3 bri;
    float3x3 hr;
};
struct Varyings { float4 position [[position]]; float2 q; };
constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
float2 quad(uint id) { return float2((id & 1) ? 1.0 : -1.0, (id & 2) ? 1.0 : -1.0); }
float4 position(float2 q) { return float4(q.x / 420.0 * 2.0 - 1.0, 1.0 - q.y / 912.0 * 2.0, 0.0, 1.0); }
float2 uvOf(float2 p){ return clamp(p / float2(420.0, 912.0), float2(0.0005), float2(0.9995)); }
float lum(float3 c){ return dot(c, float3(0.2126, 0.7152, 0.0722)); }
// light through porcelain: how much gets through, and blue held back most
float3 throughChina(float L){
  float T = mix(0.035, 1.0, smoothstep(0.02, 0.88, L));
  return float3(1.0, 0.90, 0.74) * float3(pow(T, 0.72), T, pow(T, 1.55)) * 1.06;
}
float4 background(float2 vQ, constant Uniforms &u, texture2d<float> tBefore, texture2d<float> tAfter){
  float2 p = vQ;
  float tw = u.fx.y;
  if (tw < 0.0) { return float4(tBefore.sample(linearSampler, uvOf(p)).rgb, 1.0); }
  float2 dv = p - u.c; float r = length(dv); float2 dir = dv / max(r, 1e-3);
  // the sound: three rings from the bell running down the page, bending what is seen through it a little
  float bend = 0.0, glint = 0.0;
  for (int k = 0; k < 3; k++) {
    float tk = tw + 0.28 - 0.32 * float(k);   // the first one is already at the top of the screen when the bell strikes
    if (tk > 0.0) {
      float x = r - 650.0 * tk;
      float env = exp(-x * x / 5200.0) * exp(-tk * 0.5) / (1.0 + 0.6 * float(k));
      bend += sin(x * 0.16) * env; glint += cos(x * 0.16) * env;
    }
  }
  float quiet = 1.0 - smoothstep(2.0, 2.9, tw);
  float lit = 1.0 + 0.06 * glint * quiet;
  float2 q = p + dir * bend * 5.5 * quiet + u.shake;
  float3 A = tAfter.sample(linearSampler, uvOf(q)).rgb;
  float s = tw - 0.22 * clamp((r - 200.0) / 900.0, 0.0, 1.0);
  if (s > 1.45) { return float4(A * lit, 1.0); }
  float3 B = tBefore.sample(linearSampler, uvOf(q)).rgb;
  // the china spreads the light a little: a soft copy of the cathedral, and a wider glow round its bright parts
  float3 soft = float3(0.0), wide = float3(0.0);
  for (int i = 0; i < 8; i++) {
    float a = float(i) * 0.785398;
    float2 o = float2(cos(a), sin(a));
    soft += tAfter.sample(linearSampler, uvOf(q + o * 2.6)).rgb;
    wide += tAfter.sample(linearSampler, uvOf(q + float2(o.x * 0.924 - o.y * 0.383, o.x * 0.383 + o.y * 0.924) * 10.0)).rgb;
  }
  soft = soft / 8.0 * 0.6 + A * 0.4;
  wide /= 8.0;
  float L = lum(soft);
  float3 lith = throughChina(L) + float3(1.0, 0.72, 0.42) * 0.20 * smoothstep(0.25, 0.85, lum(wide));
  // her page, the moment the bell strikes: the light behind it comes on and the white goes warm
  float3 Bw = B * mix(float3(1.0), float3(1.03, 0.985, 0.92), smoothstep(0.0, 0.14, tw));
  float lt = smoothstep(0.03, 0.85, L);
  float a1 = 0.06 + 0.32 * lt;
  float k1 = smoothstep(a1, a1 + 0.32, s);
  float k2 = smoothstep(0.62, 1.45, s);
  // through more and more china: mixed the way thickness adds up (multiplying), so on the way down it goes amber, not grey
  float3 thru = exp(mix(log(max(Bw, float3(0.004))), log(max(lith, float3(0.004))), k1));
  float3 c = mix(thru, A, k2) * lit;
  return float4(c, 1.0);
}

float4 spark(float2 vQ, constant Uniforms &u){
  float2 d = (vQ - u.spark.xy) / 9.0;
  float star = exp(-abs(d.x) * 9.0) * exp(-abs(d.y) * 1.6) + exp(-abs(d.y) * 9.0) * exp(-abs(d.x) * 1.6);
  float glow = exp(-dot(d, d) * 5.0);
  float a = clamp((star * 0.8 + glow * 0.6) * u.spark.z, 0.0, 1.0);
  if (a < 0.003) discard_fragment();
  return float4(float3(1.0, 0.94, 0.80), a);
}
float4 petal(float2 vL, constant Uniforms &u){
  float v = vL.y * 0.5 + 0.5, pu = vL.x;
  float w = pow(sin(3.14159 * pow(clamp(v, 0.0, 1.0), 0.72)), 0.75) * mix(0.32, 1.0, smoothstep(0.0, 0.45, v));
  float edge = w - abs(pu);
  float a = smoothstep(0.0, 0.06, edge) * smoothstep(0.0, 0.04, v) * u.fx.w;
  if (a < 0.003) discard_fragment();
  float back = step(u.fx.z, 0.0);
  float blush = pow(clamp(1.0 - edge / max(w, 0.05), 0.0, 1.0), 2.2) * 0.75 + v * 0.2;
  float3 c = mix(float3(0.99, 0.965, 0.965), float3(0.96, 0.74, 0.80), clamp(blush + back * 0.35, 0.0, 1.0));
  float vein = abs(sin(atan2(pu, v + 0.15) * 14.0));
  c *= 1.0 - 0.035 * (1.0 - vein) * (1.0 - v);
  c *= 0.86 + 0.14 * abs(u.fx.z) + u.misc.x;
  return float4(c, a);
}
} // namespace tutuUnlock
vertex tutuUnlock::Varyings tutuUnlockVertex(uint id [[vertex_id]], constant tutuUnlock::Uniforms &u [[buffer(0)]]) {
    tutuUnlock::Varyings out;
    out.q = mix(u.rect.xy, u.rect.zw, tutuUnlock::quad(id) * 0.5 + 0.5);
    out.position = tutuUnlock::position(out.q);
    return out;
}
fragment float4 tutuUnlockBackground(tutuUnlock::Varyings in [[stage_in]], constant tutuUnlock::Uniforms &u [[buffer(0)]], texture2d<float> before [[texture(0)]], texture2d<float> after [[texture(1)]]) {
    return tutuUnlock::background(in.q, u, before, after);
}
fragment float4 tutuUnlockSpark(tutuUnlock::Varyings in [[stage_in]], constant tutuUnlock::Uniforms &u [[buffer(0)]]) {
    return tutuUnlock::spark(in.q, u);
}
fragment float4 tutuUnlockPetal(tutuUnlock::Varyings in [[stage_in]], constant tutuUnlock::Uniforms &u [[buffer(0)]]) {
    return tutuUnlock::petal(in.q, u);
}
vertex tutuUnlock::Varyings tutuUnlockPetalVertex(uint id [[vertex_id]], constant tutuUnlock::Uniforms &u [[buffer(0)]]){
  tutuUnlock::Varyings out; float2 aP = tutuUnlock::quad(id); out.q = aP;
  float2 q = aP * float2(u.pet.z * 0.62 * max(abs(u.fx.z), 0.08), u.pet.z);
  float c = cos(u.pet.w), s = sin(u.pet.w);
  float2 p = u.pet.xy + float2(c * q.x - s * q.y, s * q.x + c * q.y);
  out.position = tutuUnlock::position(p); return out;
}

struct TutuUnlockSprite {
    float4 affine;
    float4 geometry;
    float4 color;
};
vertex tutuUnlock::Varyings tutuUnlockSpriteVertex(uint id [[vertex_id]], constant TutuUnlockSprite &u [[buffer(0)]]) {
    tutuUnlock::Varyings out;
    float2 q = tutuUnlock::quad(id);
    out.q = q * 0.5 + 0.5;
    q *= u.geometry.zw * 0.5;
    float2 p = u.geometry.xy + float2(u.affine.x * q.x + u.affine.z * q.y, u.affine.y * q.x + u.affine.w * q.y);
    out.position = tutuUnlock::position(p);
    return out;
}
fragment float4 tutuUnlockSpriteFragment(tutuUnlock::Varyings in [[stage_in]], constant TutuUnlockSprite &u [[buffer(0)]], texture2d<float> image [[texture(0)]]) {
    float4 c = image.sample(tutuUnlock::linearSampler, in.q);
    // Canvas: opaque multiply fill, then destination-in with the original sprite.
    float3 tinted = u.color.rgb * (c.rgb + 1.0 - c.a) * c.a;
    return float4(tinted * u.color.a, c.a * u.color.a);
}
#endif
#endif
