// Liquid metal（metal.jakubantalik.com / Jakubantalik/metal-fx，MIT）fragment 的 MSL 直译。
// 用法：当 ShapeStyle 填描边——ShaderLibrary.liquidMetal(.boundingRect, .float(t), .floatArray(params))
// params 顺序（LiquidMetalRing.swift 里对齐）：
//   [0] intensity [1] scale [2] direction(rad) [3] distortion [4] complexity
//   [5] vignette [6] vigOpacity [7] blur [8] shaderOpacity
//   [9..23] color1..5 的 rgb（原版 7 色只用前 5 个，alpha 全 1 省掉）
//   [24] baseW [25] baseH [26] shaderScale [27] dpr
// 原版几何：shader 画在一张 baseW×baseH（button 134×40）的共享画布上，元素只取画布**中心裁一块**
// （宽高各占 (elem/base)/shaderScale，超过 1 就整张），所以 uv 不按元素 bounds 算，按基准画布算。
#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

namespace liquidmetal {

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

static float fbm(float2 p, float oct) {
    float val = 0.0, amp = 0.5;
    int n = int(oct);
    for (int i = 0; i < 7; i++) {
        if (i >= n) break;
        val += amp * snoise(p);
        p *= 2.0;
        amp *= 0.5;
    }
    return val;
}

struct Params {
    float intensity, scale, direction, distortion, complexity;
    float vignette, vigOpacity, blur, shaderOpacity;
    float3 c1, c2, c3, c4, c5;
};

static Params load(device const float *p) {
    Params q;
    q.intensity = p[0]; q.scale = p[1]; q.direction = p[2]; q.distortion = p[3]; q.complexity = p[4];
    q.vignette = p[5]; q.vigOpacity = p[6]; q.blur = p[7]; q.shaderOpacity = p[8];
    q.c1 = float3(p[9], p[10], p[11]);
    q.c2 = float3(p[12], p[13], p[14]);
    q.c3 = float3(p[15], p[16], p[17]);
    q.c4 = float3(p[18], p[19], p[20]);
    q.c5 = float3(p[21], p[22], p[23]);
    return q;
}

static float nfbm(float2 p, float cpx) { return fbm(p, 3.0 + cpx * 4.0); }

static float3 palette(float t, thread const Params &q) {
    t = clamp(t, 0.0, 1.0);
    t = t * t * (3.0 - 2.0 * t);
    float k = 64.0;
    float w1 = exp(-k * t * t);
    float w2 = exp(-k * (t - 0.25) * (t - 0.25));
    float w3 = exp(-k * (t - 0.5)  * (t - 0.5));
    float w4 = exp(-k * (t - 0.75) * (t - 0.75));
    float w5 = exp(-k * (t - 1.0)  * (t - 1.0));
    float total = w1 + w2 + w3 + w4 + w5 + 0.0001;
    return (q.c1 * w1 + q.c2 * w2 + q.c3 * w3 + q.c4 * w4 + q.c5 * w5) / total;
}

static float2 warp(float2 p, float t, thread const Params &q) {
    float str = q.distortion * 2.0;
    return float2(
        nfbm(p + float2(t * 0.1, 0.0), q.complexity),
        nfbm(p + float2(0.0, t * 0.12) + 5.0, q.complexity)
    ) * str;
}

static float3 computeEffect(float2 uv, float aspect, float t, thread const Params &q) {
    float2 p = (uv - 0.5) * q.scale;
    p.x *= aspect;
    p += float2(cos(q.direction), sin(q.direction)) * t * 0.15;

    float freq = 3.0 + q.complexity * 8.0;
    float val = 0.0;
    val += sin(p.x * freq + t);
    val += sin(p.y * freq + t * 1.3);
    val += sin((p.x + p.y) * freq * 0.7 + t * 0.7);
    val += sin(length(p) * freq * 0.8 - t * 1.5);
    float2 w = warp(p, t, q);
    val += (w.x + w.y) * q.distortion;
    val = val * 0.2 * q.intensity + 0.5;
    return palette(clamp(val, 0.0, 1.0), q);
}

} // namespace

[[ stitchable ]] half4 liquidMetal(float2 position, float4 bounds, float time,
                                   device const float *params, int count) {
    using namespace liquidmetal;
    if (count < 28) return half4(0);
    Params q = load(params);
    float2 base = float2(params[24], params[25]);
    float shaderScale = params[26];
    float dpr = params[27];
    float2 elem = bounds.zw;
    float2 euv = (position - bounds.xy) / elem;
    // 元素在基准画布上的取样窗（居中），窗比例 = (elem/base)/scale，封顶 1
    float2 win = min(float2(1.0), (elem / base) / shaderScale);
    float2 uv = 0.5 + (euv - 0.5) * win;
    float2 res = base * dpr;
    float aspect = res.x / res.y;
    float t = time;

    float3 col;
    if (q.blur < 0.01) {
        col = computeEffect(uv, aspect, t, q);
    } else {
        float r = q.blur * 0.02;
        col  = computeEffect(uv,                    aspect, t, q) * 0.4;
        col += computeEffect(uv + float2( r, 0.0),  aspect, t, q) * 0.15;
        col += computeEffect(uv + float2(-r, 0.0),  aspect, t, q) * 0.15;
        col += computeEffect(uv + float2(0.0,  r),  aspect, t, q) * 0.15;
        col += computeEffect(uv + float2(0.0, -r),  aspect, t, q) * 0.15;
    }
    col = pow(max(col, 0.0), float3(1.3));

    float edgeDist = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
    float vigPx = 40.0 / min(res.x, res.y);
    float vigRange = vigPx * (1.0 + q.vignette * 3.0);
    float vig = edgeDist * edgeDist / (vigRange * vigRange);
    vig = smoothstep(0.0, 1.0, vig);
    col *= mix(1.0, vig, q.vignette * q.vigOpacity);

    return half4(half3(col), half(q.shaderOpacity));
}
