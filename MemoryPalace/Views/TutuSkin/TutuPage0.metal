#if PERSONAL_APPS
#include <TargetConditionals.h>
#if TARGET_OS_IOS || TUTU_NATIVE_FRAME
#include <metal_stdlib>
using namespace metal;
// page0-gl.js SKY/CLOTH/SPR, unmodified algorithm constants. All functions are
// namespaced so the production default library can contain the other scenes.
struct TutuPage0Uniforms {
    float2 uTilt; float uT; float uDay;
    float uDusk; float uDawn; float uNight; float uYs;
    float4 uMoon;
    float uF; float uG; float uFold; float uRoom;
    float4 uSeam; float4 uSkyLight;
};
struct TutuPage0SkyVaryings { float4 position [[position]]; float2 vQ; };
struct TutuPage0ClothVaryings {
    float4 position [[position]]; float2 vUV; float3 vN;
    float vD; float vV; float vOpen;
};
// GLSL calls smoothstep with descending edges in CLOTH_FS. Write out its cubic
// explicitly: Metal's built-in smoothstep does not define descending edges.
float tutuPage0Smoothstep(float a, float b, float x) {
    float t = clamp((x - a) / (b - a), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}
constexpr sampler tutuPage0Sampler(coord::normalized, address::clamp_to_edge, filter::linear);
vertex TutuPage0SkyVaryings tutuPage0SkyVertex(uint id [[vertex_id]]) {
    const float2 q[4] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};
    float2 aP = q[id];
    return {float4(aP, 0.5, 1.0), float2(aP.x * 0.5 + 0.5, 0.5 - aP.y * 0.5) * float2(402.0,874.0)};
}
float tutuPage0Hash(float2 p){ return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
float tutuPage0Noise(float2 p){ float2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
  return mix(mix(tutuPage0Hash(i), tutuPage0Hash(i + float2(1.0, 0.0)), f.x), mix(tutuPage0Hash(i + float2(0.0, 1.0)), tutuPage0Hash(i + float2(1.0, 1.0)), f.x), f.y); }
float tutuPage0Fbm(float2 p){ float a = 0.5, s = 0.0; for (int i = 0; i < 5; i++) { s += a * tutuPage0Noise(p); p = p * 2.02 + 17.3; a *= 0.5; } return s; }
float tutuPage0Hash13(float3 p){ p = fract(p * 0.1031); p += dot(p, p.zyx + 31.32); return fract((p.x + p.y) * p.z); }
float3 tutuPage0Hash33(float3 p){ p = fract(p * float3(0.1031, 0.1030, 0.0973)); p += dot(p, p.yxz + 33.33); return fract((p.xxy + p.yxx) * p.zyx); }
float3 tutuPage0ViewDir(float2 a){
  float pitch = 0.80;
  float3 f = float3(0.0, sin(pitch), cos(pitch)), r = float3(1.0, 0.0, 0.0), u = float3(0.0, cos(pitch), -sin(pitch));
  float rr = length(a);
  return rr > 1e-5 ? f * cos(rr) + (r * a.x + u * a.y) / rr * sin(rr) : f;
}
float3 tutuPage0DirOf(float2 p, constant TutuPage0Uniforms& u){
  float2 a = float2(p.x - 201.0, 437.0 - p.y) * (1.25 / 874.0) + float2(u.uTilt.x, -u.uTilt.y) * 0.30;
  return tutuPage0ViewDir(a);
}
fragment float4 tutuPage0SkyFragment(TutuPage0SkyVaryings in [[stage_in]], constant TutuPage0Uniforms& u [[buffer(0)]]){
  float3 d = tutuPage0DirOf(in.vQ, u);
  float h = max(d.y, 0.0);
  float3 zen = float3(0.21, 0.35, 0.58) * u.uDay + float3(0.13, 0.16, 0.32) * (u.uDusk + u.uDawn) + float3(0.010, 0.016, 0.040) * u.uNight;
  float3 hor = float3(0.72, 0.80, 0.88) * u.uDay + float3(0.92, 0.62, 0.46) * u.uDusk + float3(0.86, 0.66, 0.62) * u.uDawn + float3(0.050, 0.060, 0.100) * u.uNight;
  float3 c = mix(hor, zen, pow(h, 0.42));
  float side = clamp(d.x * 1.4, -1.0, 1.0);
  c += float3(0.30, 0.13, 0.04) * u.uDusk * max(side, 0.0) * exp(-h * 3.0) + float3(0.26, 0.12, 0.10) * u.uDawn * max(-side, 0.0) * exp(-h * 3.0);
  if (u.uNight > 0.01) {
    float3 g3 = d * 330.0; float3 c3 = floor(g3);
    float r = tutuPage0Hash13(c3 + 0.5); float3 h3 = tutuPage0Hash33(c3 + 1.5);
    float3 sp3 = c3 + float3(0.5) + (h3 - 0.5) * 0.6;
    float tw = 0.7 + 0.3 * sin(u.uT * (1.3 + 2.0 * h3.x) + r * 40.0);
    float big = step(0.995, r);
    float3 dd = g3 - sp3; dd -= d * dot(dd, d);
    float2 sc = float2(0.0); float2 sp = float2(length(dd), 0.0);
    float st = (1.0 - tutuPage0Smoothstep(0.0, 0.42 + 0.30 * big, length(dd))) * step(0.972, r) * (0.12 + 0.88 * pow(h3.y, 2.5) + big * 1.2);
    float3 mw = normalize(float3(0.75, -0.45, 0.48));
    float band = exp(-pow(dot(d, mw) / 0.20, 2.0));
    float dust = tutuPage0Smoothstep(0.45, 0.75, tutuPage0Fbm(d.xy * 7.0 + d.z * 3.0));
    float glow = band * (0.45 + 0.55 * tutuPage0Fbm(d.xz * 5.0 + 2.0)) * (1.0 - 0.6 * dust * exp(-pow(dot(d, mw) / 0.07, 2.0)));
    float3 nightAdd = float3(0.86, 0.89, 0.98) * st * tw + float3(0.36, 0.38, 0.48) * glow * 0.34;
    float dense = band * h3.z * step(0.88, tutuPage0Hash13(c3 + 9.5)) * (1.0 - tutuPage0Smoothstep(0.0, 0.34, length(dd)));
    nightAdd += float3(0.7, 0.74, 0.85) * dense * 0.5;
    c += nightAdd * u.uNight * tutuPage0Smoothstep(0.0, 0.12, h);
  }
  float3 sd3 = normalize(float3(-0.62, 0.70, 0.36));
  float sd = max(dot(d, sd3), 0.0);
  c += float3(1.0, 0.95, 0.84) * (pow(sd, 6.0) * 0.16 + pow(sd, 48.0) * 0.30) * u.uDay;
  if (d.y > 0.015) {
    float haze = tutuPage0Smoothstep(0.015, 0.20, d.y);
    float3 cLit = float3(1.0, 0.99, 0.97) * u.uDay + float3(1.0, 0.74, 0.58) * u.uDusk + float3(0.98, 0.80, 0.76) * u.uDawn + float3(0.11, 0.12, 0.16) * u.uNight;
    float3 cSh = float3(0.58, 0.64, 0.73) * u.uDay + float3(0.36, 0.30, 0.40) * u.uDusk + float3(0.42, 0.36, 0.46) * u.uDawn + float3(0.03, 0.035, 0.05) * u.uNight;
    float2 hp = d.xz / (d.y + 0.25) * 1.4 + float2(u.uT * 0.0016, 0.0);
    float hd = tutuPage0Fbm(float2(hp.x * 0.8, hp.y * 2.6) * 1.6 + 9.0);
    float hc = tutuPage0Smoothstep(0.46, 0.80, hd);
    c = mix(c, cLit * 0.97, hc * 0.36 * (1.0 - u.uNight) * haze);
    float2 cp = d.xz / d.y * 0.9 + float2(u.uT * 0.003, u.uT * 0.0012);
    float den = tutuPage0Fbm(cp * 1.25 + 4.0);
    float cov = 0.44 + 0.12 * u.uNight;
    float cl = tutuPage0Smoothstep(cov, cov + 0.20, den);
    float den2 = tutuPage0Fbm(cp * 1.25 + 4.0 + float2(-0.09, 0.05));
    float lit = clamp(0.58 + (den - den2) * 4.5, 0.0, 1.0);
    float3 cc = mix(cSh, cLit, lit);
    cc = mix(cc, c, 0.25 * (1.0 - haze));
    c = mix(c, cc, cl * haze * (0.94 - 0.45 * u.uNight));
  }
  float3 md = normalize(u.uMoon.xyz);
  float ang = acos(clamp(dot(d, md), -1.0, 1.0));
  float disk = 1.0 - tutuPage0Smoothstep(0.034, 0.037, ang);
  float3 mu = normalize(cross(md, float3(0.0, 1.0, 0.0)) + float3(1e-4)); float3 mv = cross(mu, md);
  float2 mq = float2(dot(d - md, mu), dot(d - md, mv)) / 0.036;
  float mare = tutuPage0Smoothstep(0.45, 0.75, tutuPage0Fbm(mq * 2.2 + 3.7)) * 0.22 + tutuPage0Smoothstep(0.5, 0.8, tutuPage0Noise(mq * 5.0 + 1.1)) * 0.08;
  float limb = 1.0 - 0.18 * dot(mq, mq);
  float halo = exp(-ang / 0.08) * 0.35 + exp(-ang / 0.35) * 0.18;
  c = mix(c, float3(0.93, 0.91, 0.85) * limb * (1.0 - mare), disk * u.uMoon.w) + float3(0.42, 0.48, 0.62) * halo * u.uMoon.w * (1.0 - disk);
  c += (tutuPage0Hash(in.vQ * 1.37 + 0.5) - 0.5) / 255.0;
  return float4(c, 1.0);
}
float tutuPage0H1(float n){ return fract(sin(n) * 43758.5453); }
float tutuPage0N1(float x){ float i = floor(x), f = fract(x); f = f * f * (3.0 - 2.0 * f); return mix(tutuPage0H1(i), tutuPage0H1(i + 1.0), f); }
float tutuPage0SeamX(float v, constant TutuPage0Uniforms& u){ return mix(u.uSeam.x, u.uSeam.y, v / 874.0) + (tutuPage0N1(v * 0.02 + 3.0) - 0.5) * u.uSeam.z; }
float tutuPage0GapAt(float v, constant TutuPage0Uniforms& u){ float t = clamp((u.uYs - v) / max(u.uYs, 1.0), 0.0, 1.0); return u.uG * pow(t, 1.15) * (0.92 + 0.16 * tutuPage0N1(v * 0.011 + 7.0)); }
float3 tutuPage0Place(float d, float v, float s, constant TutuPage0Uniforms& u){
  float g = tutuPage0GapAt(v, u);
  float op = clamp(g / 60.0, 0.0, 1.0);
  float Lc = 13.0 + 11.0 * op;
  float th0 = tutuPage0Smoothstep(0.0, 0.25, op) * (0.5 + op * 1.75);
  float dx = 0.0, dz = 0.0, hs = 6.0 * Lc / 12.0;
  for (int k = 0; k < 12; k++) {
    float t = d + (float(k) + 0.5) * hs;
    float th = th0 * exp(-t / Lc);
    dx += (1.0 - cos(th)) * hs;
    dz += sin(th) * hs;
  }
  float sx = tutuPage0SeamX(v, u);
  float body = g * exp(-d / (150.0 + 1.2 * g));
  float bow = g * 0.55 * exp(-d / 70.0);
  float folds = u.uFold * op * (0.5 + 0.5 * sin(d / 11.0 + v * 0.006 + s * 1.7)) * exp(-d / 110.0);
  float far = s > 0.0 ? (402.0 - sx + 200.0) : (sx + 200.0);
  float e = u.uF * u.uF * (3.0 - 2.0 * u.uF);
  float slide = e * far;
  float sag = e * (1.0 - e) * 50.0 * sin(3.14159 * clamp(v / 874.0, 0.0, 1.0));
  return float3(sx + s * (d + dx + body + slide), v + sag * 0.3, -dz - bow - folds - e * 60.0);
}
vertex TutuPage0ClothVaryings tutuPage0ClothVertex(uint id [[vertex_id]], const device packed_float3* vertices [[buffer(0)]], constant TutuPage0Uniforms& u [[buffer(1)]]){
  float3 aM = float3(vertices[id]);
  TutuPage0ClothVaryings out;
  float s = aM.z, v = aM.y;
  float sx = tutuPage0SeamX(v, u);
  float dmax = s > 0.0 ? (402.0 + 170.0 - sx) : (sx + 170.0);
  float d = (1.0 - aM.x) * dmax;
  float3 P = tutuPage0Place(d, v, s, u);
  float3 Pd = tutuPage0Place(d + 0.6, v, s, u);
  float3 Pv = tutuPage0Place(d, v + 0.6, s, u);
  out.vN = s * normalize(cross(Pd - P, Pv - P));
  float photoU = sx + s * d;
  out.vUV = float2((121.5 + photoU * 1.4645) / 832.0, (v * 1.4645) / 1280.0);
  out.vD = d; out.vV = v; out.vOpen = clamp(tutuPage0GapAt(v, u) / 60.0, 0.0, 1.0);
  float k = 1300.0 / (1300.0 - P.z);
  float2 sp = float2(201.0, 437.0) + (P.xy - float2(201.0, 437.0)) * k;
  out.position = float4(sp.x / 402.0 * 2.0 - 1.0, 1.0 - sp.y / 874.0 * 2.0, clamp(-P.z / 1500.0, 0.0, 1.0), 1.0);
  return out;
}

fragment float4 tutuPage0ClothFragment(TutuPage0ClothVaryings in [[stage_in]], constant TutuPage0Uniforms& u [[buffer(0)]], texture2d<float> tVel [[texture(0)]]){
  float3 alb = tVel.sample(tutuPage0Sampler, in.vUV).rgb;
  float3 n = normalize(in.vN);
  float3 Lf = normalize(float3(-0.35, -0.45, 0.82));
  float flatF = 0.35 + 0.65 * Lf.z;
  float shade = (0.35 + 0.65 * max(dot(n, Lf), 0.0)) / flatF;
  float nv = clamp(n.z, 0.0, 1.0);
  float sheen = pow(1.0 - nv, 2.0);
  float3 col = alb * shade * u.uRoom + (alb * 3.2 + float3(0.05)) * sheen * u.uRoom;
  float back = clamp(-n.z, 0.0, 1.0) * 0.8 + pow(1.0 - nv, 2.0) * 0.5;
  col += (alb * 4.0 + float3(0.03)) * u.uSkyLight.xyz * back;
  col += u.uSkyLight.xyz * 0.55 * tutuPage0Smoothstep(0.30, 0.0, nv) * in.vOpen;
  float line = exp(-in.vD * in.vD / 0.35) * step(u.uYs, in.vV) * (1.0 - tutuPage0Smoothstep(780.0, 870.0, in.vV));
  col *= 1.0 - 0.45 * line;
  return float4(col, 1.0);
}
struct TutuPage0SpriteUniforms {
    float4 q0; float4 q1; float4 q2; float4 q3;
    float4 uColor; float4 modeDepth; // mode, WebGL clip z, unused, unused
};
struct TutuPage0SpriteVaryings { float4 position [[position]]; float2 vT; };
vertex TutuPage0SpriteVaryings tutuPage0SpriteVertex(uint id [[vertex_id]], constant TutuPage0SpriteUniforms& u [[buffer(0)]]) {
    float4 aQ = id == 0 ? u.q0 : id == 1 ? u.q1 : id == 2 ? u.q2 : u.q3;
    // WebGL clip z -1..1 -> Metal 0..1; shadow .98 therefore becomes .99.
    return {float4(aQ.x / 402.0 * 2.0 - 1.0, 1.0 - aQ.y / 874.0 * 2.0, u.modeDepth.y * 0.5 + 0.5, 1.0), aQ.zw};
}
fragment float4 tutuPage0SpriteFragment(TutuPage0SpriteVaryings in [[stage_in]], constant TutuPage0SpriteUniforms& u [[buffer(0)]], texture2d<float> tPom [[texture(0)]]) {
    if (u.modeDepth.x < 0.5) { float4 c = tPom.sample(tutuPage0Sampler, in.vT); return float4(c.rgb * u.uColor.rgb, c.a * u.uColor.a); }
    else if (u.modeDepth.x < 1.5) { return u.uColor; }
    else { float r = length(in.vT * 2.0 - 1.0); return float4(0.0, 0.0, 0.0, u.uColor.a * (1.0 - tutuPage0Smoothstep(0.15, 1.0, r))); }
}
#endif
#endif
