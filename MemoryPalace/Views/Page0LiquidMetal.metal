// page0 底色：液态金属（铬）。小样 docs/design-liquid-metal.html 「铬」那款的 MSL 直译。
// 用法：ShaderLibrary.page0LiquidMetal(.boundingRect, .float(t))，当 ShapeStyle 填满背景。
// 做法：平滑噪声算一张缓慢流动的液面高度 → 求法线 → 反射一个程序生成的摄影棚
// （暗底 + 几条柔光箱亮带 + 地平线暗线）→ 三通道微色散 + 菲涅尔 → 色调映射 + 颗粒。
#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

namespace page0metal {

static float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float2 mod289v2(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float3 permute(float3 x) { return mod289((x * 34.0 + 1.0) * x); }

static float snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439,
                            -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289v2(i);
    float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m; m = m * m;
    float3 x_ = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x_) - 0.5;
    float3 ox = floor(x_ + 0.5);
    float3 a0 = x_ - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

static float hash(float2 p) {
    p = fract(p * float2(443.897, 441.423));
    p += dot(p, p.yx + 19.19);
    return fract((p.x + p.y) * p.x);
}

// 液面高度：一层大尺度扭曲 + 两层平滑起伏，低频为主 = 粘稠的水银感
static float height(float2 p, float t) {
    float2 q = p + 0.38 * float2(snoise(p * 0.42 + float2(0.0, t * 0.08)),
                                 snoise(p * 0.42 + float2(5.2, -t * 0.07)));
    return snoise(q * 0.62 + float2(t * 0.035, -t * 0.025)) * 0.70
         + snoise(q * 1.25 - float2(t * 0.05, t * 0.04)) * 0.20;
}

// 摄影棚：暗底 + 两条斜柔光箱（窄亮芯 + 一点外晕）+ 侧面竖条 + 反光板 + 地平线暗线
static float3 env(float3 r) {
    float a = r.y + 0.38 * r.x;
    float sky = mix(0.035, 0.42, smoothstep(-0.7, 0.95, r.y));
    float s1 = exp(-pow((a - 0.62) / 0.038, 2.0)) * 1.45 + exp(-pow((a - 0.62) / 0.12, 2.0)) * 0.25;
    float s2 = exp(-pow((a + 0.12) / 0.026, 2.0)) * 0.8;
    float s3 = exp(-pow((r.x - 0.55) / 0.06, 2.0)) * 0.5 * smoothstep(-0.1, 0.7, r.y);
    float s4 = exp(-pow((r.x + 0.7) / 0.16, 2.0)) * 0.18;
    float hz = -0.25 * exp(-pow(r.y * 7.0, 2.0));
    float v = max(sky + s1 + s2 + s3 + s4 + hz, 0.0);
    float3 cool = float3(0.86, 0.91, 1.0), warm = float3(1.0, 0.95, 0.88);
    return v * mix(warm, cool, smoothstep(-0.3, 0.8, r.y));
}

}  // namespace page0metal

[[ stitchable ]] half4 page0LiquidMetal(float2 position, float4 bounds, float time) {
    using namespace page0metal;
    float2 size = bounds.zw;
    // 按高归一，y 向上（和小样同一套坐标）
    float2 p = float2(position.x - 0.5 * size.x, 0.5 * size.y - position.y) / size.y * 1.5;
    float e = 1.5 / size.y;                        // ≈ 1pt 的步长求法线
    float h0 = height(p, time);
    float hx = height(p + float2(e, 0.0), time);
    float hy = height(p + float2(0.0, e), time);
    float2 grad = float2(hx - h0, hy - h0) / e;
    float3 n = normalize(float3(-grad * 0.30, 1.0));
    float3 v = float3(0.0, 0.0, -1.0);
    // 三通道各用略不同的法线反射：曲率大的地方泛一点彩边
    const float disp = 0.025;
    float3 col;
    col.r = env(reflect(v, normalize(n * float3(1.0 + disp, 1.0 + disp, 1.0)))).r;
    col.g = env(reflect(v, n)).g;
    col.b = env(reflect(v, normalize(n * float3(1.0 - disp, 1.0 - disp, 1.0)))).b;
    col += pow(1.0 - clamp(n.z, 0.0, 1.0), 2.2) * 0.35;          // 菲涅尔：坡陡处更亮
    col *= mix(0.78, 1.0, smoothstep(-0.6, 0.4, h0));             // 凹处轻微自遮蔽
    col = 1.0 - exp(-col * 1.25);                                 // 色调映射
    float2 uv = position / size;
    col *= mix(0.82, 1.0, smoothstep(1.2, 0.25, length(uv - 0.5)));
    col = pow(col, float3(1.0 / 1.1));
    float g = hash(position * 3.0 + fract(time * 0.37) * 91.0) + hash(position.yx * 3.9 + 7.0) - 1.0;
    col += g * (3.0 / 255.0);
    return half4(half3(col), 1.0h);
}
