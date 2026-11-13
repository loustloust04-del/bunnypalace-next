#if PERSONAL_APPS
#include <TargetConditionals.h>
#if TARGET_OS_IOS || TUTU_NATIVE_FRAME
#include <metal_stdlib>
using namespace metal;
// Direct GLSL translation. GL depth [-1,1] becomes Metal depth [0,1].
struct TutuCathedralUniforms {
    float uTime;
    float uRestoring;
    float uRestore;
    float uCrack;
    float uFracturePass;
    float uReleasedAt;
    float2 uTilt;
    float uShatter;
    float uPlants;
    float2 uRes;
    float uS;
    float uDay;
    float uNightSpec;
    float3 uK;
    float3 uKr;
    float3 uKu;
    float3 uS2;
    float3 uS2r;
    float3 uS2u;
    float3 uW3;
    float3 uW3r;
    float3 uW3u;
    float3 uMoon;
    float4 uFBox;
    float3 uBg;
};
struct TutuCathedralVaryings {
    float4 position [[position]];
    float2 vUv;
    float4 vFracture;
    float2 vFinish;
    float3 vAngles;
    float3 vSolidNormal;
    float3 vWorld;
    float vLoss;
};
constexpr sampler tutuNearest(coord::normalized,address::clamp_to_edge,filter::nearest);
constexpr sampler tutuLinear(coord::normalized,address::clamp_to_edge,filter::linear);
constexpr sampler tutuMip(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear);
float3 turnShard(float3 p, float3 a){
  float3 c = cos(a), s = sin(a);
  p = float3(p.x, c.x*p.y-s.x*p.z, s.x*p.y+c.x*p.z);
  p = float3(c.y*p.x+s.y*p.z, p.y, -s.y*p.x+c.y*p.z);
  return float3(c.z*p.x-s.z*p.y, s.z*p.x+c.z*p.y, p.z);
}
vertex TutuCathedralVaryings tutuCathedralVertex(uint vertexID [[vertex_id]],uint instanceID [[instance_id]],constant TutuCathedralUniforms &u [[buffer(0)]],const device float *vertices [[buffer(1)]]) {
 TutuCathedralVaryings o;
 uint stride=u.uFracturePass>1.5?24:8; uint at=(instanceID*3+vertexID)*stride;
 float2 p=float2(vertices[at],vertices[at+1]);
 float4 face=float4(vertices[at+2],vertices[at+3],vertices[at+4],vertices[at+5]);
 float2 finish=float2(vertices[at+6],vertices[at+7]);
 float4 shard=float4(0,0,-1,0);float3 solidNormal=float3(0),home=float3(0);float4 family=float4(0);float2 hierarchy=float2(0);
 if(u.uFracturePass>1.5){shard=float4(vertices[at+8],vertices[at+9],vertices[at+10],vertices[at+11]);solidNormal=float3(vertices[at+12],vertices[at+13],vertices[at+14]);family=float4(vertices[at+15],vertices[at+16],vertices[at+17],vertices[at+18]);hierarchy=float2(vertices[at+19],vertices[at+20]);home=float3(vertices[at+21],vertices[at+22],vertices[at+23]);}
 if(u.uFracturePass>1.5) shard.z=u.uReleasedAt;
o.vUv = float2(p.x*0.5+0.5, 0.5-p.y*0.5);
  o.vLoss=0.0; o.vAngles = float3(0.0); o.vSolidNormal = solidNormal; o.vWorld = float3(o.vUv * float2(390.0, 844.0), 0.0);
  if (u.uFracturePass > 1.5) {
    if (shard.z < 0.0 && u.uRestoring < 0.5) { o.position = float4(2.0, 2.0, 2.0, 1.0); o.vFracture = float4(0.0); o.vFinish = finish; o.position.z=(o.position.z+o.position.w)*0.5; return o; }
    float t = shard.z < 0.0 ? 0.0 : max(0.0, u.uTime - shard.z);
    float seed=family.z,spin=fract(seed*17.37),impact=abs(family.w);
    o.vLoss=max(step(impact,t),u.uRestore);
    bool innerWall=hierarchy.x>0.5 && dot(solidNormal,solidNormal)>0.5 && abs(solidNormal.z)<0.5;
    if ((hierarchy.x < 0.5 && (t >= impact || u.uRestoring > 0.5)) || (innerWall && t < impact && u.uRestoring < 0.5)) { o.position=float4(2.0,2.0,2.0,1.0); o.vFracture=float4(0.0); o.vFinish=finish; o.position.z=(o.position.z+o.position.w)*0.5; return o; }
    float parentT=family.w<0.0 ? 0.0 : min(t,impact);
    float3 parentAngles=float3(0.35+spin*0.35,(seed-0.5)*0.70,(spin-0.5)*0.40)*parentT;
    float3 parentOrigin=float3(family.x+(seed-0.5)*28.0*parentT, family.y+(-8.0-10.0*spin)*parentT+130.0*parentT*parentT, 12.0*(1.0-exp(-parentT*7.0)));
    float3 angles=parentAngles;
    if (t < impact) {
      o.vWorld=parentOrigin+turnShard(float3(o.vWorld.xy-family.xy,face.z),parentAngles);
    } else {
      float dt=max(0.0,t-impact),cs=shard.w,spin2=fract(cs*19.73);
      float3 origin=parentOrigin+turnShard(float3(shard.xy-family.xy,0.0),parentAngles);
      float g=260.0,vy=-42.0-24.0*spin2,vx=(seed-0.5)*28.0+(cs-0.5)*32.0;
      float floorY=819.0-min(hierarchy.y*0.28,28.0)-cs*7.0;
      float hit=(sqrt(vy*vy+2.0*g*max(floorY-origin.y,0.0))-vy)/g;
      float after=max(0.0,dt-hit),bounceV=-(vy+g*hit)*0.12;
      float y=dt<hit ? origin.y+vy*dt+0.5*g*dt*dt : floorY+min(0.0,bounceV*after+0.5*g*after*after);
      float x=origin.x+vx*min(dt,hit)+vx*0.20*(1.0-exp(-after*5.0));
      float spinTime=min(dt,hit)+0.12*(1.0-exp(-after*5.0));
      angles+=float3(0.7+spin2,(cs-0.5)*1.6,(spin2-0.5)*0.8)*spinTime;
      float settled=smoothstep(-2.0*bounceV/g,-2.0*bounceV/g+0.5,after)*step(hit,dt);
      angles=mix(angles,float3(1.2+cs*0.15,(spin2-0.5)*0.6,(cs-0.5)*0.3),settled);
      o.vWorld=float3(x,y,origin.z)+turnShard(float3(o.vWorld.xy-shard.xy,face.z),angles);
    }
    if (u.uRestoring > 0.5) {
      float3 local=float3(o.vUv*float2(390.0,844.0)-shard.xy,face.z);
      float3 centre=o.vWorld-turnShard(local,angles);
      angles=mix(angles,float3(0.0,0.0,home.z),u.uRestore);
      centre=mix(centre,float3(home.xy,0.0),u.uRestore);
      o.vWorld=centre+turnShard(local,angles);
    }
    o.vAngles=angles;
    float2 projected = (o.vWorld.xy-float2(195.0,422.0)) * (900.0/(900.0-o.vWorld.z)) + float2(195.0,422.0);
    o.position = float4(projected * float2(2.0/390.0,-2.0/844.0) + float2(-1.0,1.0), -0.4-o.vWorld.z/200.0, 1.0);
    o.vFracture = float4(face.xy,face.z,1.0); o.vFinish = finish; o.position.z=(o.position.z+o.position.w)*0.5; return o;
  }
  float opening = smoothstep(face.w, face.w + 0.035, u.uCrack) * u.uFracturePass;
  float z = face.z * opening;
  o.vFracture = float4(face.xy * opening, z, opening);
  o.vFinish = finish;
  float2 parallax = z * u.uTilt * float2(2.0/390.0, -2.0/844.0);
  o.position = float4(p + parallax, -z / 8.0, 1.0);

 o.position.z=(o.position.z+o.position.w)*0.5; return o;
}
constant float K_ABS = 2.9;
constant float TR_FLOOR = 0.08;
constant float EXPO = 2.3;
constant float B0_TOP = 1.25;
constant float B0_LOW = 1.0;
constant float CARVE = 0.42;
constant float T_MIN = 0.10;
float lightOf(float c){ return min(c, 1.0) * exp(-0.45 * max(c - 1.0, 0.0)); }
constant float HM = 0.8;
float dec(float3 c){ return (c.r*65280.0 + c.g*255.0)/65535.0; }

float removed(float2 p, texture2d<float> tBreak, float uShatter){ if (uShatter < 0.001) return 0.0; float3 m=tBreak.sample(tutuNearest,p).rgb; return step(0.5,m.b)*step(dec(m),uShatter)*step(0.001,uShatter); }
float Hs(float2 p, texture2d<float> tA){ return dec(tA.sample(tutuNearest,p).rgb) * HM; }
float Hb(float2 p, texture2d<float> tA2){ return dec(tA2.sample(tutuNearest,p).rgb) * HM; }
float3 tintOf(float th){ return mix(float3(1.0, 0.962, 0.895), float3(1.0, 0.83, 0.62), th); }
float3 transmit(float T){ return (TR_FLOOR + (1.0 - TR_FLOOR) * exp(-K_ABS * T)) * tintOf(clamp(T / 0.72, 0.0, 1.0)); }
float boxL(float3 R, float3 c, float3 rr, float3 uu, float2 hs, float edge){
  float w = dot(R, c); if (w <= 0.02) return 0.0;
  float2 q = float2(dot(R, rr), dot(R, uu)) / w;
  float2 a = abs(q) / hs;
  float d = pow(pow(a.x, 6.0) + pow(a.y, 6.0), 1.0/6.0);
  return 1.0 - smoothstep(1.0 - edge, 1.0, d);
}
float boxW(float3 R, float3 c, float3 rr, float3 uu, float2 hs, float edge){
  float w = dot(R, c); if (w <= 0.02) return 0.0;
  float2 q = float2(dot(R, rr), dot(R, uu)) / w;
  float2 a = abs(q) / hs;
  float d = pow(pow(a.x, 6.0) + pow(a.y, 6.0), 1.0/6.0);
  float m = 1.0 - smoothstep(1.0 - edge, 1.0, d);
  float mull = smoothstep(0.035, 0.08, a.x);
  float tran = smoothstep(0.025, 0.05, abs(q.y / hs.y - 0.38));
  float grad = 0.50 + 0.50 * smoothstep(-1.0, 1.0, q.y / hs.y);
  return m * mull * tran * grad;
}
float hash(float2 p){ return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453); }
float carveBlur(float2 q, float r, float biasValue, texture2d<float> tF){
  float s = tF.sample(tutuMip,q,bias(biasValue)).r * 2.0;
  for (int k = 0; k < 8; k++) {
    float a = float(k) * 0.785398 + 0.39;
    s += tF.sample(tutuMip,q + r * float2(cos(a), sin(a)),bias(biasValue)).r;
  }
  return s / 10.0;
}
// Rendered with the same two base triangles, viewport and interpolated UVs as the
// base pass. Keep the original biased implicit-LOD sampling (not compute LODs).
float4 tutuCarveFields(float2 fq, constant TutuCathedralUniforms &u, texture2d<float> tF) {
  float e1 = 1.6 / u.uFBox.z;
  float fSharp = carveBlur(fq, 0.3 / u.uFBox.z, 0.4, tF) * 4.0;
  float fSoft = carveBlur(fq, e1, 2.4, tF) * 4.0;
  float fdx = (lightOf(tF.sample(tutuMip,fq + float2(e1, 0.0),bias(2.4)).r * 4.0) - lightOf(tF.sample(tutuMip,fq - float2(e1, 0.0),bias(2.4)).r * 4.0)) / (2.0 * 1.6);
  float fdy = (lightOf(tF.sample(tutuMip,fq + float2(0.0, e1),bias(2.4)).r * 4.0) - lightOf(tF.sample(tutuMip,fq - float2(0.0, e1),bias(2.4)).r * 4.0)) / (2.0 * 1.6);
  return float4(fSharp, fSoft, fdx, fdy);
}
fragment float4 tutuCathedralStaticFragment(TutuCathedralVaryings in [[stage_in]], constant TutuCathedralUniforms &u [[buffer(0)]], texture2d<float> tA2 [[texture(1)]], texture2d<float> tT2 [[texture(4)]], texture2d<float> tF [[texture(7)]]) {
  float2 pc = in.vUv * float2(390.0, 844.0);
  float2 fq = (pc - u.uFBox.xy) / u.uFBox.zw;
  float inF = step(0.0, fq.x) * step(fq.x, 1.0) * step(0.0, fq.y) * step(fq.y, 1.0);
  float carveMask = tT2.sample(tutuLinear,in.vUv).b * tA2.sample(tutuNearest,in.vUv).b * inF;
  return carveMask > 0.001 ? tutuCarveFields(fq, u, tF) : float4(0.0);
}
fragment float4 tutuCathedralFragment(TutuCathedralVaryings in [[stage_in]],constant TutuCathedralUniforms &u [[buffer(0)]],texture2d<float> tA [[texture(0)]],texture2d<float> tA2 [[texture(1)]],texture2d<float> tB [[texture(2)]],texture2d<float> tT [[texture(3)]],texture2d<float> tT2 [[texture(4)]],texture2d<float> tV [[texture(5)]],texture2d<float> tG [[texture(6)]],texture2d<float> tF [[texture(7)]],texture2d<float> tP [[texture(8)]],texture2d<float> tBreak [[texture(9)]],texture2d<float> tLoss [[texture(10)]],texture2d<float> tCarve [[texture(11)]]
  #if TUTU_NATIVE_FRAME && TUTU_OVERDRAW
  , device atomic_uint *counter [[buffer(2)]]
  #endif
){
  #if TUTU_NATIVE_FRAME && TUTU_OVERDRAW
  // Measurement-only invocation planes, before shader discards. Device atomics
  // may inhibit early-Z: do not label these as production hardware counters.
  uint width = uint(u.uRes.x), height = uint(u.uRes.y);
  uint2 pixel = uint2(in.position.xy);
  uint plane = uint(u.uFracturePass);
  if (plane < 3 && pixel.x < width && pixel.y < height) {
    atomic_fetch_add_explicit(counter + plane * width * height + pixel.y * width + pixel.x, 1u, memory_order_relaxed);
  }
  #endif
  float2 px = 1.0 / u.uRes;
  float2 uv = in.vUv;
  float2 pc = uv * float2(390.0, 844.0);
  float3 a2 = tA2.sample(tutuNearest,uv).rgb;
  float missing = u.uFracturePass < 1.5 ? removed(uv, tBreak, u.uShatter) : 0.0;
  float cov = a2.b * (1.0-missing);
  float3 tb = tB.sample(tutuLinear,uv).rgb;
  float rim = tb.b;
  if (u.uFracturePass > 1.5) { cov*=mix(1.0,tLoss.sample(tutuLinear,uv).r,in.vLoss); if (cov < 0.5) discard_fragment(); }
  else if (u.uFracturePass > 0.5 && (cov < 0.995 || rim > 0.1 || in.vFracture.w < 0.001)) discard_fragment();
  // A solid side's normal does not depend on the carved surface normal. Reject
  // the identical back-facing fragments before their texture/lighting work.
  if (u.uFracturePass > 1.5 && dot(in.vSolidNormal,in.vSolidNormal)>0.5) {
    float3 solidN = normalize(turnShard(in.vSolidNormal,in.vAngles));
    if (dot(solidN,normalize(float3(195.0,422.0,1700.0)-in.vWorld)) < 0.0) discard_fragment();
  }
  float cav = tA.sample(tutuNearest,uv).b;
  float2 fq = (pc - u.uFBox.xy) / u.uFBox.zw;
  float inF = step(0.0, fq.x) * step(fq.x, 1.0) * step(0.0, fq.y) * step(fq.y, 1.0);
  float3 tt2 = tT2.sample(tutuLinear,uv).rgb;
  float carveMask = tt2.b * cov * inF;
  float fSharp = 0.0, fSoft = 0.0, fdx = 0.0, fdy = 0.0;
  if (carveMask > 0.001) {
    float4 fields = u.uFracturePass < 0.5 ? tCarve.read(uint2(in.position.xy)) : tutuCarveFields(fq, u, tF);
    fSharp = fields.x; fSoft = fields.y; fdx = fields.z; fdy = fields.w;
  }
  float hl = Hs(uv - float2(px.x, 0.0), tA), hr = Hs(uv + float2(px.x, 0.0), tA), hu = Hs(uv - float2(0.0, px.y), tA), hd = Hs(uv + float2(0.0, px.y), tA);
  float3 N = normalize(float3(-(hr - hl) * 0.5 * u.uS + 0.05 * fdx * u.uS * carveMask, -(hd - hu) * 0.5 * u.uS + 0.05 * fdy * u.uS * carveMask, 1.0));
  float bl = Hb(uv - float2(2.0*px.x, 0.0), tA2), br = Hb(uv + float2(2.0*px.x, 0.0), tA2), bu = Hb(uv - float2(0.0, 2.0*px.y), tA2), bd = Hb(uv + float2(0.0, 2.0*px.y), tA2);
  float3 Nb = normalize(float3(-(br - bl) * 0.25 * u.uS, -(bd - bu) * 0.25 * u.uS, 1.0));
  float2 gc = float2(0.10 * (pc.x - 195.0) / 195.0, 0.035 * (pc.y - 430.0) / 430.0) * cov;
  N = normalize(N + float3(gc, 0.0) * N.z); Nb = normalize(Nb + float3(gc, 0.0) * Nb.z);
  float damage = in.vFracture.w * (1.0 - rim) * cov;
  float3 tangent = normalize(float3(1.0, 0.0, -N.x / max(N.z, 0.08)));
  float3 bitangent = normalize(cross(N, tangent));
  N = normalize(N + tangent * in.vFracture.x + bitangent * in.vFracture.y);
  Nb = normalize(mix(Nb, N, damage * 0.38));
  if (u.uFracturePass > 1.5) {
    N = turnShard(N, in.vAngles); Nb = turnShard(Nb, in.vAngles);
    if (dot(in.vSolidNormal,in.vSolidNormal)>0.5) { N=normalize(turnShard(in.vSolidNormal,in.vAngles)); Nb=N; }
    if (dot(N,normalize(float3(195.0,422.0,1700.0)-in.vWorld)) < 0.0) discard_fragment();
  }
  float3 Nm = normalize(N + Nb);
  float2 dl = normalize(u.uK.xy + float2(1e-5));
  float tanE = u.uK.z / max(length(u.uK.xy), 0.05);
  float h0 = Hb(uv, tA2) * u.uS, occ = 0.0;
  for (int k = 1; k <= 10; k++) { float t = float(k) * 1.6; float hq = Hb(uv + dl * t * px, tA2) * u.uS * (1.0-removed(uv+dl*t*px, tBreak, u.uShatter)); occ = max(occ, hq - h0 - t * tanE); }
  float sh = u.uFracturePass > 1.5 ? 1.0 : 1.0 - 0.34 * smoothstep(0.0, 2.4, occ);
  float3 wv = float3(0.80, 0.60, 0.50);
  float3 dif = float3(max(dot(Nb, u.uK) + wv.x, 0.0), max(dot(Nm, u.uK) + wv.y, 0.0), max(dot(N, u.uK) + wv.z, 0.0)) / (float3(0.66) + wv);
  float3 shc = mix(float3(1.0), float3(sh), float3(0.80, 1.0, 1.06));
  float3 alb = float3(0.952, 0.940, 0.912);
  float3 amb = float3(0.95, 0.96, 0.985) * 0.36 * (1.0 - 0.35 * cav);
  float3 key = float3(1.0, 0.980, 0.945) * 0.53;
  float3 col = alb * (amb + key * dif * shc);
  col *= float3(1.0) - float3(0.10, 0.095, 0.07) * cav;
  col *= 1.0 + 0.10 * dot(uv - 0.5, dl);
  float3 V = normalize(float3(195.0, 422.0, 1700.0) - (u.uFracturePass > 1.5 ? in.vWorld : float3(pc, 0.0)));
  float nv = max(dot(N, V), 0.0);
  float3 Rf = 2.0 * nv * N - V;
  float f0 = mix(0.045, 0.03746, damage);
  float F = f0 + (1.0 - f0) * pow(1.0 - nv, 5.0);
  float rough = mix(0.08, in.vFinish.x, damage);
  float b1 = boxL(Rf, u.uK, u.uKr, u.uKu, float2(0.17, 0.12) + damage * rough * 0.10, 0.08 + damage * rough);
  float b2 = boxL(Rf, u.uS2, u.uS2r, u.uS2u, float2(0.022, 0.40) + damage * rough * 0.07, 0.12 + damage * rough);
  float b3 = boxW(Rf, u.uW3, u.uW3r, u.uW3u, float2(0.036, 0.088) + damage * rough * 0.08, 0.07 + damage * rough);
  float envA = 0.30 + 0.50 * clamp(-Rf.y * 0.8 + 0.25, 0.0, 1.0);
  float spec = F * (16.0 * b1 + 8.0 * b2 + 5.0 * b3 + envA);
  float nl = max(dot(N, u.uK), 0.0);
  float kG = pow(rough + 1.0, 2.0) / 8.0;
  float smith = nv / max(nv * (1.0 - kG) + kG, 0.001);
  smith *= nl / max(nl * (1.0 - kG) + kG, 0.001);
  spec *= mix(1.0, smith / (1.0 + rough * rough * 4.0), damage);
  float menv = 0.16 + 1.5 * b1 + 0.9 * b2 + 0.6 * b3 + 0.25 * envA;
  float3 plat = float3(0.84, 0.85, 0.87) * menv * 0.85;
  float4 tt = tT.sample(tutuNearest,uv);
  float body = 1.0 + (tt.b - 0.5) / 4.0;
  float Tb = mix(tt2.r, tt2.g, clamp(tt2.r / 0.72, 0.0, 1.0) * 0.5);
  float sss = clamp(Tb / 0.6, 0.0, 1.0) * 0.7;
  float carve = lightOf(mix(fSharp, fSoft, sss)) * carveMask;
  float Tn = max(Tb - CARVE * carve, min(Tb, T_MIN));
  float Td = max(Tb - CARVE * 0.35 * lightOf(fSoft) * carveMask, min(Tb, T_MIN));
  float3 opaq = float3((1.0 - 0.92 * rim) * cov * body);
  float3 trN = transmit(Tn) * opaq;
  float3 trD = transmit(Td) * opaq;
  float3 day = col * 0.76 + trD * 0.40 + spec * float3(0.985, 0.99, 1.0);
  day = mix(day, plat, rim);
  float y = uv.y;
  float B0 = (B0_LOW + (B0_TOP - B0_LOW) * (1.0 - smoothstep(0.12, 0.62, y))) * (1.0 - 0.08 * smoothstep(0.78, 0.96, y));
  float dm = length(pc - u.uMoon.xy);
  float disc = clamp((17.0 - dm) / 1.4, 0.0, 1.0);
  float mf = (0.50 * exp(-pow(dm / 34.0, 2.0)) + 0.20 * exp(-pow(dm / 110.0, 2.0))) * u.uMoon.z;
  float3 night = 1.0 - exp(-EXPO * trN * B0);
  night += trN * 0.55 * mf * float3(0.93, 0.965, 1.0);
  night += col * 0.05 * float3(0.86, 0.92, 1.0) + spec * u.uNightSpec * float3(0.9, 0.95, 1.0);
  night = mix(night, plat * 0.25, rim);
  float recess = max(-in.vFracture.z, 0.0);
  float cavity = damage * in.vFinish.y;
  float ao = exp(-recess * (0.30 + 0.30 * (1.0 - nl)));
  float3 glaze = mix(float3(1.0), float3(0.87, 0.96, 0.97), damage * (0.24 + recess));
  day = day * glaze * mix(1.0, ao, damage) * (1.0 - cavity * 0.06);
  night *= mix(1.0, exp(-recess * 0.75), damage) * (1.0 - cavity * 0.12);
  float3 slab = mix(night, day, u.uDay);
  if (u.uFracturePass > 1.5) {
    if (dot(in.vSolidNormal,in.vSolidNormal)>0.5) {
      float light = 0.34+0.56*max(dot(N,u.uK),0.0);
      slab = float3(0.90,0.865,0.79)*light*mix(0.38,1.0,u.uDay) + spec*0.06;
    }
    return float4(clamp(slab,0.0,1.0),1.0);
  }
  float3 vel = tV.sample(tutuLinear,uv).rgb / 3.0;
  float sd = 7.0 + 8.0 * (1.0 - u.uK.z);
  float2 so = dl * sd / float2(390.0, 844.0);
  float cs = tB.sample(tutuLinear,uv + so).r * (1.0-removed(uv+so, tBreak, u.uShatter));
  float ts = tT2.sample(tutuLinear,uv + so).g;
  float3 velD = vel * (1.0 - 0.66 * cs + 0.30 * cs * (1.0 - ts) * float3(1.0, 0.9, 0.75));
  float3 velN = vel * 0.62;
  float3 bg = mix(velN, velD, u.uDay);
  float ef = smoothstep(0.0, 0.07, min(uv.x, 1.0 - uv.x)) * smoothstep(0.0, 0.06, min(uv.y, 1.0 - uv.y));
  float3 outc = mix(u.uBg, bg, ef);
  float hole = max(tb.g, missing*a2.b) * (1.0 - cov);
  outc += (1.0 - u.uDay) * hole * u.uMoon.z * (disc * float3(0.96, 0.95, 0.90) * 0.92 + 0.10 * exp(-pow(dm / 26.0, 2.0)) * float3(0.9, 0.93, 1.0));
  float3 tp = tP.sample(tutuLinear,uv).rgb * u.uPlants;
  float3 plD = float3(0.60, 0.60, 0.585) * (0.42 + 0.58 * tp.g) * (1.0 - 0.50 * cs);
  float rimN = 0.40 + 0.60 * exp(-pow(dm / 170.0, 2.0)) * u.uMoon.z;
  float3 plN = float3(0.22, 0.23, 0.25) * (0.45 + 0.55 * tp.g) * rimN + float3(0.02);
  outc = mix(outc, mix(plN, plD, u.uDay), tp.r * ef);
  outc = mix(outc, slab, cov);
  float ish = tP.sample(tutuLinear,uv + so * 0.45).b * u.uPlants;
  outc *= 1.0 - 0.36 * ish * u.uDay * cov;
  float eg = mix(ef, 1.0, cov);
  outc += (1.0 - u.uDay) * tG.sample(tutuLinear,uv).rgb * 0.5 * eg * (1.0-missing) * (1.0-step(0.999,u.uShatter));
  outc += (1.0 - u.uDay) * u.uMoon.z * 0.07 * pow(max(1.0 - dm / 170.0, 0.0), 2.0) * float3(1.0, 0.98, 0.94) * eg;
  float ia = tp.b;
  if (ia > 0.002) {
    float2 e2 = float2(1.0 / 780.0, 1.0 / 1688.0);
    float2 gi = float2(tP.sample(tutuLinear,uv + float2(e2.x, 0.0)).b - tP.sample(tutuLinear,uv - float2(e2.x, 0.0)).b, tP.sample(tutuLinear,uv + float2(0.0, e2.y)).b - tP.sample(tutuLinear,uv - float2(0.0, e2.y)).b);
    float lit = max(0.0, dot(-gi, dl)) * 0.9;
    float3 ivD = float3(0.072, 0.077, 0.070) + float3(0.20, 0.21, 0.20) * lit;
    float3 ivN = float3(0.016, 0.017, 0.019);
    outc = mix(outc, mix(ivN, ivD, u.uDay), ia * u.uPlants);
  }
  outc += (hash(pc * 1.37) - 0.5) / 255.0;
  return  float4(clamp(outc, 0.0, 1.0), 1.0);
}
vertex TutuCathedralVaryings tutuCathedralUpscaleVertex(uint id [[vertex_id]]) {
 TutuCathedralVaryings o; float2 p=float2((id==1)?3.0:-1.0,(id==2)?3.0:-1.0);o.position=float4(p,0,1);o.vUv=float2(p.x*.5+.5,.5-p.y*.5);return o;
}
fragment float4 tutuCathedralUpscaleFragment(TutuCathedralVaryings in [[stage_in]], texture2d<float> image [[texture(0)]]) {return image.sample(tutuLinear,in.vUv);}
#endif
#endif
