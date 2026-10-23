// 按 docs/spec-dust-cleanroom.md 净室实现（#007）
// 删除消息散成灰：无状态粒子。每颗的位置 / 透明度都是 (粒子序号, 种子, 时间) 的闭式函数，
// 在顶点着色器里直接算，不需要计算 kernel 和粒子缓冲。
#include <metal_stdlib>
using namespace metal;

// 与 DustEffectRenderer.swift 的 AshDustUniforms 逐字段对齐（48 字节）
struct AshDustUniforms {
    float2 viewport;   // 覆盖层大小（点）
    float2 origin;     // 截图左上角（点）
    float2 size;       // 截图大小（点）
    float2 cell;       // 一颗占的格子（点）
    uint cols;
    uint rows;
    uint seed;
    float time;        // 这一条已经走了多少秒
};

struct AshDustVarying {
    float4 position [[position]];
    float2 uv;         // 采样点（静止时跟着像素走，飞起来收成格子中心）
    float2 local;      // 在小方块里的位置，[-1, 1]²
    float roundness;   // 0 = 方块（原图），1 = 圆点
    float alpha;
    float sparkle;     // 偶尔亮一下的那几颗，0…1
};

// 整数哈希（PCG 风格的一轮置换），够散、无表
static inline uint ashHash(uint x) {
    x = x * 747796405u + 2891336453u;
    uint w = ((x >> ((x >> 28u) + 4u)) ^ x) * 277803737u;
    return (w >> 22u) ^ w;
}

static inline float ashRand(uint index, uint seed, uint channel) {
    uint h = ashHash(index ^ ashHash(seed + channel * 0x9E3779B9u));
    return float(h >> 8) * (1.0 / 16777216.0);
}

// 节奏常数：起飞时刻 = 0.45 s × 横向位置 + 0–0.08 s 抖动（最晚 0.53 s 起飞，再加 0.12–0.2 s 渐变到全速）；
// 寿命 0.35–0.75 s，末尾 0.15 s 淡出 → 1.28 s 时全部透明。
// 改这几个数要同步 DustEffectRenderer.swift 的 duration（约束：duration ≥ kSweep + kSweepJitter + 最长寿命）
constant float kSweep = 0.45;
constant float kSweepJitter = 0.08;
constant float kFade = 0.15;
constant float kDrag = 0.6;           // 横向 / 初速的空气阻力：先四散，很快被热气接管
constant float kTwoPi = 6.2831853;

vertex AshDustVarying ashDustVertex(uint vid [[vertex_id]],
                                    uint iid [[instance_id]],
                                    constant AshDustUniforms &u [[buffer(0)]]) {
    const float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
    const uint col = iid % u.cols;
    const uint row = iid / u.cols;
    const float2 cellUV = float2((float(col) + 0.5) / float(u.cols), (float(row) + 0.5) / float(u.rows));
    const float2 home = u.origin + cellUV * u.size;

    // 起飞时刻：主要看横向位置（左先右后），加一点抖动让前沿是软的、带点颗粒感
    const float delay = kSweep * cellUV.x + kSweepJitter * ashRand(iid, u.seed, 1u);
    const float ramp = 0.12 + 0.08 * ashRand(iid, u.seed, 2u);
    const float s = u.time - delay;
    // 「有效时间」e：速度在 ramp 内线性从 0 涨到全速，积分出来的位移连续、不跳
    float e = 0.0;
    if (s > 0.0) e = s < ramp ? s * s / (2.0 * ramp) : s - 0.5 * ramp;
    const float progress = clamp(s / ramp, 0.0, 1.0);

    const float life = 0.35 + 0.40 * ashRand(iid, u.seed, 3u);
    float alpha = 1.0;
    if (s > 0.0) alpha = clamp((life - s) / kFade, 0.0, 1.0);

    AshDustVarying out;
    if (alpha <= 0.0) {
        // 死了的颗粒整块挤成一个点，光栅化直接跳过
        out.position = float4(-2.0, -2.0, 0.0, 1.0);
        out.uv = float2(0.0);
        out.local = float2(0.0);
        out.roundness = 0.0;
        out.alpha = 0.0;
        out.sparkle = 0.0;
        return out;
    }

    // 一整圈随机方向弹出，初速 80–170 pt/s，被阻力慢慢吃掉；向上的加速度一直在（y 向下所以减）
    const float angle = kTwoPi * ashRand(iid, u.seed, 4u);
    const float speed = 80.0 + 90.0 * ashRand(iid, u.seed, 5u);
    const float lift = 300.0 + 180.0 * ashRand(iid, u.seed, 6u);
    const float spread = (1.0 - exp(-kDrag * e)) / kDrag;
    float2 offset = float2(cos(angle), sin(angle)) * speed * spread;
    offset.y -= 0.5 * lift * e * e;
    // 像烟灰一样左右轻摆：幅度随起飞渐入
    const float swayAmp = 1.5 + 2.5 * ashRand(iid, u.seed, 7u);
    const float swayFreq = 7.0 + 6.0 * ashRand(iid, u.seed, 8u);
    offset.x += swayAmp * sin(swayFreq * e + kTwoPi * ashRand(iid, u.seed, 9u)) * min(e * 5.0, 1.0);

    // 静止时是正好一格的方块（拼回原图）；飞起来变成稍大的圆点，淡出时一起缩小
    const float dotScale = 1.1 + 0.45 * ashRand(iid, u.seed, 10u);
    const float grow = mix(1.0, dotScale, progress) * mix(0.55, 1.0, alpha);
    const float2 halfSize = 0.5 * u.cell * grow;
    const float2 p = home + offset + corner * halfSize;

    out.position = float4(p.x / u.viewport.x * 2.0 - 1.0, 1.0 - p.y / u.viewport.y * 2.0, 0.0, 1.0);
    out.local = corner;
    // 方块时每个片元按自己位置采样（与原图逐像素一致）；圆点时整颗取格子中心那一点的颜色（线性采样）
    const float2 cellHalfUV = 0.5 / float2(float(u.cols), float(u.rows));
    out.uv = cellUV + corner * cellHalfUV * (1.0 - progress);
    out.roundness = progress;
    out.alpha = alpha;
    // 约 3% 的颗粒在空中轻轻亮一下（只往自身颜色的亮处走，不加别的颜色）
    const float lucky = step(ashRand(iid, u.seed, 11u), 0.03);
    out.sparkle = lucky * sin(3.14159265 * clamp(s / life, 0.0, 1.0));
    return out;
}

fragment float4 ashDustFragment(AshDustVarying in [[stage_in]],
                                texture2d<float> image [[texture(0)]],
                                sampler smp [[sampler(0)]]) {
    float4 c = image.sample(smp, in.uv);                 // 预乘 alpha
    const float r = length(in.local);
    const float edge = max(fwidth(r), 1e-3);               // 约一个设备像素宽的软边
    const float disc = clamp((1.0 - r) / edge + 0.5, 0.0, 1.0);
    const float coverage = mix(1.0, disc, in.roundness);
    c.rgb = mix(c.rgb, float3(c.a), 0.35 * in.sparkle);  // 预乘下往白提亮 = 向 a 靠
    return c * (coverage * in.alpha);
}
