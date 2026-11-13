#include <metal_stdlib>
using namespace metal;
#if defined(PERSONAL_APPS)
// Finished-page LIGHT, line-for-line arithmetic port; material is the original RGBA bake.
struct WuUniforms { float4 lamp; float4 candle; float4 pile; float4 ground; float4 sheen; float4 spec; float4 glint; float4 canvas; float4 viewport; };
float wuH1(float2 p) { return fract(sin(dot(p,float2(12.9898,78.233)))*43758.5453); }
float3 wuLitBody(float3 L,float att,float3 N,float4 t,constant WuUniforms& u) {
 float nl=dot(N,L);
 float dif=max(nl,0.0f);
 float side=max(1.0f-N.z*N.z,0.0f);
 float lside=max(1.0f-nl*nl,0.0f);
 float sheen=pow(side,0.8f)*(0.3f+0.7f*lside)*smoothstep(-0.15f,0.35f,nl);
 float3 pile=u.pile.xyz*(0.3f+0.7f*dif)+u.sheen.xyz*sheen;
 float a=t.a*6.2831853f;
 float3 d3=float3(cos(a),sin(a),0.0f);
 float3 Tn=normalize(d3-N*dot(N,d3)+float3(0.0f,0.0f,1e-4f));
 float3 Hh=normalize(L+float3(0.0f,0.0f,1.0f));
 float th=dot(Tn,Hh);
 float aniso=pow(sqrt(max(1.0f-th*th,0.0f)),u.glint.w);
 float iso=pow(max(dot(N,Hh),0.0f),u.glint.z);
 float3 sat=u.ground.xyz*(0.3f+0.7f*dif)+u.spec.xyz*(u.glint.x*aniso+u.glint.y*iso)*smoothstep(0.0f,0.25f,nl);
 return mix(pile,sat,t.b)*att;
}
float3 wuLit(float3 lamp,float fall,float2 p,float3 N,float4 t,constant WuUniforms& u) {
 float3 Lv=lamp-float3(p,0.0f);
 float dist=length(Lv);
 return wuLitBody(Lv/dist,1.0f/(1.0f+dist*dist/fall),N,t,u);
}
// Cache at the ORIGINAL whole-strip 1.5x grid, not a viewport-sized approximation.
kernel void tutuWuPrepare(texture2d<float,access::sample> source [[texture(0)]],texture2d<float,access::write> material [[texture(1)]],texture2d<float,access::write> normals [[texture(2)]],texture2d<float,access::write> candle [[texture(3)]],constant WuUniforms& u [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
 if(gid.x>=material.get_width()||gid.y>=material.get_height())return;
 float2 frag=float2(float(gid.x)+0.5f,float(material.get_height()-1-gid.y)+0.5f);
 float2 uv=frag/u.canvas.xy;
 float2 p=float2(uv.x*1560.0f,(1.0f-uv.y)*844.0f);
 constexpr sampler linearSampler(coord::normalized,address::clamp_to_edge,filter::linear);
 float4 t=source.sample(linearSampler,uv);
 float2 nxy=t.rg*2.0f-1.0f;
 float3 N=float3(nxy,sqrt(max(1.0f-dot(nxy,nxy),0.0f)));
 float a=t.a*6.2831853f;
 float3 d3=float3(cos(a),sin(a),0.0f);
 float3 Tn=normalize(d3-N*dot(N,d3)+float3(0.0f,0.0f,1e-4f));
 material.write(float4(Tn,t.b),gid);
 normals.write(float4(N,pow(max(1.0f-N.z*N.z,0.0f),0.8f)),gid);
 // Keep float32: the candle term must join the moving lamp BEFORE gamma.
 // Store this bounded candle/grain term as half; all light arithmetic remains float32.
 candle.write(float4(wuLit(u.candle.xyz,230000.0f,p,N,t,u)*1.25f*float3(1.0f,0.74f,0.47f),(wuH1(frag)-0.5f)/255.0f),gid);
}
struct WuVertex { float4 position [[position]]; float2 uv; };
vertex WuVertex tutuWuVertex(uint id [[vertex_id]]) {
 float2 uv=float2((id<<1)&2,id&2);
 return {float4(uv*float2(2.0f,-2.0f)+float2(-1.0f,1.0f),0.0f,1.0f),uv};
}
// This is wuLitBody with only offset-independent terms substituted from float caches.
float3 wuMovingLamp(float2 p,float4 normal,float4 material,constant WuUniforms& u) {
 float3 Lv=u.lamp.xyz-float3(p,0.0f);
 float dist=length(Lv); float3 L=Lv/dist; float3 N=normal.xyz;
 float nl=dot(N,L); float dif=max(nl,0.0f); float lside=max(1.0f-nl*nl,0.0f);
 float sheen=normal.w*(0.3f+0.7f*lside)*smoothstep(-0.15f,0.35f,nl);
 float3 pile=u.pile.xyz*(0.3f+0.7f*dif)+u.sheen.xyz*sheen;
 float3 Hh=normalize(L+float3(0.0f,0.0f,1.0f));
 float th=dot(material.xyz,Hh);
 float aniso=pow(sqrt(max(1.0f-th*th,0.0f)),u.glint.w);
 float iso=pow(max(dot(N,Hh),0.0f),u.glint.z);
 float3 sat=u.ground.xyz*(0.3f+0.7f*dif)+u.spec.xyz*(u.glint.x*aniso+u.glint.y*iso)*smoothstep(0.0f,0.25f,nl);
 return mix(pile,sat,material.w)*(1.0f/(1.0f+dist*dist/1210000.0f));
}
float3 wuWallPixel(int2 pixel,texture2d<float,access::read> material,texture2d<float,access::read> normals,texture2d<float,access::read> candle,constant WuUniforms& u) {
 uint2 gid=uint2(clamp(pixel,int2(0),int2(u.canvas.xy)-1));
 float2 frag=float2(float(gid.x)+0.5f,u.canvas.y-1.0f-float(gid.y)+0.5f);
 float2 uv=frag/u.canvas.xy;
 float2 p=float2(uv.x*1560.0f,(1.0f-uv.y)*844.0f);
 float4 fixedCandle=candle.read(gid);
 float3 col=wuMovingLamp(p,normals.read(gid),material.read(gid),u)*0.42f+fixedCandle.xyz;
 col=pow(col,float3(0.4545f));
 col+=fixedCandle.w;
 // The old rgba8 output was quantized BEFORE CALayer's fractional-offset filtering.
 return rint(clamp(col,0.0f,1.0f)*255.0f)/255.0f;
}
fragment float4 tutuWuViewport(WuVertex in [[stage_in]],texture2d<float,access::read> material [[texture(0)]],texture2d<float,access::read> normals [[texture(1)]],texture2d<float,access::read> candle [[texture(2)]],constant WuUniforms& u [[buffer(0)]]) {
 float scale=u.viewport.y/844.0f;
 float2 world=float2((in.uv.x*u.viewport.x+u.viewport.z)/(1560.0f*scale),in.uv.y);
 float2 grid=world*u.canvas.xy-0.5f;
 int2 p=int2(floor(grid)); float2 f=fract(grid);
 float3 a=wuWallPixel(p,material,normals,candle,u),b=wuWallPixel(p+int2(1,0),material,normals,candle,u);
 float3 c=wuWallPixel(p+int2(0,1),material,normals,candle,u),d=wuWallPixel(p+int2(1,1),material,normals,candle,u);
 return float4(mix(mix(a,b,f.x),mix(c,d,f.x),f.y),1.0f);
}
float4 wuLightByte(float4 col) {
 // The original CGContext stores premultiplied 8-bit channels after EVERY draw.
 return rint(clamp(col,0.0f,1.0f)*255.0f)/255.0f;
}
float4 wuLightSample(texture2d<float,access::sample> light,float2 world,float2 size,float4 region) {
 constexpr sampler worldSampler(coord::normalized,address::clamp_to_zero,filter::linear);
 return light.sample(worldSampler,(world*size-region.xy)/region.zw);
}
fragment float4 tutuWuLight(WuVertex in [[stage_in]],texture2d<float,access::sample> lamp [[texture(3)]],array<texture2d<float,access::sample>,8> lights [[texture(4)]],constant WuUniforms& u [[buffer(0)]],constant float4* regions [[buffer(1)]]) {
 constexpr sampler screenSampler(coord::normalized,address::clamp_to_edge,filter::linear);
 float scale=u.viewport.y/844.0f;
 float2 world=float2((in.uv.x*u.viewport.x+u.viewport.z)/(1560.0f*scale),in.uv.y);
 // Original drawLight order: shade, screen lamp destination-out, world candle
 // destination-out, additive pool/motes, then EACH additive halo + normal flame.
 float4 col=lamp.sample(screenSampler,in.uv);
 col=wuLightByte(col*(1.0f-wuLightSample(lights[0],world,u.canvas.zw,regions[0]).r));
 col=wuLightByte(col+wuLightSample(lights[1],world,u.canvas.zw,regions[1]));
 for(uint i=2;i<uint(u.viewport.w);i+=2) {
  col=wuLightByte(col+wuLightSample(lights[i],world,u.canvas.zw,regions[i]));
  float4 flame=wuLightSample(lights[i+1],world,u.canvas.zw,regions[i+1]);
  col=wuLightByte(flame+col*(1.0f-flame.a));
 }
 return col;
}
#endif
