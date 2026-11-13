#include <metal_stdlib>
using namespace metal;
#if PERSONAL_APPS

struct TutuChatCardUniforms {
    uint4 size;                 // card px width/height, cut px width/height
    uint4 region;               // dispatched origin, extent
    float4 geometry;            // card pt width/height, pixels/pt, margin=1.5pt
    float4 motif;               // x0,y0,x1,y1 in pt
    uint4 control;              // per-pass radius/axis/threshold/motif-present
    float4 paper;               // mean, standard deviation, source ox,oy
    uint4 tiles;                // tile columns, noise grid columns, unused
};
struct TutuChatCardPillow { float4 ellipse; float4 relief; int4 bounds; };
struct TutuChatCardCut { float4 radii, cornerX, cornerY, rough; uint4 counts; };

inline uint2 tutuChatCardPosition(uint2 id, constant TutuChatCardUniforms &u) { return id + u.region.xy; }
inline bool tutuChatCardOutside(uint2 id, constant TutuChatCardUniforms &u) { return any(id >= u.region.zw); }
inline float tutuChatCardSample(device const float *a, uint2 size, float2 position) {
    float2 p = clamp(position, float2(0), float2(size) - 1.001f);
    uint2 q = uint2(p); float2 f = p - float2(q); uint i = q.y * size.x + q.x;
    return (a[i] * (1 - f.x) + a[i + 1] * f.x) * (1 - f.y)
         + (a[i + size.x] * (1 - f.x) + a[i + size.x + 1] * f.x) * f.y;
}
inline float tutuChatCardNoise1(device const float *g, uint offset, uint count, float t) {
    float period = float(count - 1), f = fmod(fmod(t, period) + period, period);
    uint i = uint(f); float u = f - float(i); u = u * u * (3 - 2 * u);
    return g[offset + i] * (1 - u) + g[offset + i + 1] * u;
}
inline float4 tutuChatCardBytes(float4 value) {
    // ImageData's Uint8ClampedArray uses round-to-nearest, ties-to-even.
    return rint(clamp(value, 0.0f, 255.0f)) / 255.0f;
}

kernel void tutuChatCardBorder(constant TutuChatCardUniforms &u [[buffer(0)]],
    device const TutuChatCardPillow *pillows [[buffer(1)]], device const uint *offsets [[buffer(2)]],
    device const uint *indices [[buffer(3)]], device float *height [[buffer(4)]], uint2 id [[thread_position_in_grid]]) {
    if (tutuChatCardOutside(id, u)) return;
    uint2 p = tutuChatCardPosition(id, u); uint tile = (p.y / 16) * u.tiles.x + p.x / 16;
    float2 point = (float2(p) + 0.5f) / u.geometry.z; float h = 0;
    for (uint i = offsets[tile]; i < offsets[tile + 1]; ++i) {
        TutuChatCardPillow a = pillows[indices[i]];
        if (any(int2(p) < a.bounds.xy) || any(int2(p) >= a.bounds.zw)) continue;
        float2 d = point - a.ellipse.xy;
        float x = (d.x * a.relief.x + d.y * a.relief.y) / a.ellipse.z;
        float y = (-d.x * a.relief.y + d.y * a.relief.x) / a.ellipse.w;
        float q = 1 - x * x - y * y;
        if (q > 0) h = max(h, a.relief.z * pow(min(q, 1.0f), a.relief.w));
    }
    height[p.y * u.size.x + p.x] = h;
}

kernel void tutuChatCardNoise(constant TutuChatCardUniforms &u [[buffer(0)]],
    device const float *grid [[buffer(1)]], device float *output [[buffer(2)]], uint2 id [[thread_position_in_grid]]) {
    if (tutuChatCardOutside(id, u)) return;
    uint2 p = tutuChatCardPosition(id, u); float2 f = float2(p) / u.paper.x;
    uint2 q = uint2(f); float2 t = f - float2(q); t = t * t * (3 - 2 * t);
    uint i = q.y * u.tiles.y + q.x; float a = grid[i], b = grid[i + 1], c = grid[i + u.tiles.y], d = grid[i + u.tiles.y + 1];
    output[p.y * u.size.x + p.x] = (a + (b - a) * t.x) * (1 - t.y) + (c + (d - c) * t.x) * t.y;
}

kernel void tutuChatCardGaussian(constant TutuChatCardUniforms &u [[buffer(0)]],
    device const float *input [[buffer(1)]], device float *output [[buffer(2)]],
    device const float *weights [[buffer(3)]], device const float *threshold [[buffer(4)]], uint2 id [[thread_position_in_grid]]) {
    if (tutuChatCardOutside(id, u)) return;
    uint2 p = tutuChatCardPosition(id, u); int radius = int(u.control.x); float value = 0;
    for (int j = -radius; j <= radius; ++j) {
        int2 q = int2(p) + (u.control.y == 0 ? int2(j, 0) : int2(0, j));
        q = clamp(q, int2(0), int2(u.size.xy) - 1);
        value += weights[j + radius] * input[uint(q.y) * u.size.x + uint(q.x)];
    }
    uint k = p.y * u.size.x + p.x;
    if (u.control.z != 0) value = clamp((value - (0.5f + 0.09f * threshold[k])) / 0.3f + 0.5f, 0.0f, 1.0f);
    output[k] = value;
}

kernel void tutuChatCardMotif(constant TutuChatCardUniforms &u [[buffer(0)]],
    device const float *border [[buffer(1)]], device float *base [[buffer(2)]],
    texture2d<float, access::read> sanyu [[texture(0)]], uint2 id [[thread_position_in_grid]]) {
    if (tutuChatCardOutside(id, u)) return;
    uint2 p = tutuChatCardPosition(id, u); uint k = p.y * u.size.x + p.x; float h = border[k];
    if (u.control.w != 0) {
        float scale = min((u.motif.z - u.motif.x) / 112, (u.motif.w - u.motif.y) / 52);
        float2 center = (u.motif.xy + u.motif.zw) / 2;
        float2 extent = float2(sanyu.get_width(), sanyu.get_height());
        float2 halfSize = extent / 3 / 2 * scale;
        int2 lo = max(int2(0), int2(floor((center - halfSize) * u.geometry.z)));
        int2 hi = min(int2(u.size.xy), int2(ceil((center + halfSize) * u.geometry.z)));
        if (all(int2(p) >= lo) && all(int2(p) < hi)) {
            float2 source = (extent / 3 / 2 + ((float2(p) + 0.5f) / u.geometry.z - center) / scale) * 3 - 0.5f;
            if (all(source >= 0) && all(source < extent - 1)) {
                uint2 q = uint2(source); float2 f = source - float2(q);
                float a = sanyu.read(q).r * 255, b = sanyu.read(q + uint2(1, 0)).r * 255;
                float c = sanyu.read(q + uint2(0, 1)).r * 255, d = sanyu.read(q + uint2(1, 1)).r * 255;
                float relief = ((a * (1 - f.x) + b * f.x) * (1 - f.y) + (c * (1 - f.x) + d * f.x) * f.y) / 255 * 0.5f;
                h = max(h, relief);
            }
        }
    }
    base[k] = h;
}

kernel void tutuChatCardPaper(constant TutuChatCardUniforms &u [[buffer(0)]],
    device float4 *output [[buffer(1)]], texture2d<float, access::read> paper [[texture(0)]], uint2 id [[thread_position_in_grid]]) {
    if (tutuChatCardOutside(id, u)) return;
    uint2 p = tutuChatCardPosition(id, u);
    // The source sheet is 3px/pt regardless of the destination device scale.
    float2 source = (float2(p) + 0.5f) * (3 / u.geometry.z) - 0.5f + u.paper.zw;
    int2 q = int2(floor(source)), size = int2(paper.get_width(), paper.get_height()); float2 f = source - float2(q);
    int2 a = ((q % size) + size) % size, b = (a + 1) % size;
    float3 p00 = rint(paper.read(uint2(a)).rgb * 255), p10 = rint(paper.read(uint2(b.x, a.y)).rgb * 255);
    float3 p01 = rint(paper.read(uint2(a.x, b.y)).rgb * 255), p11 = rint(paper.read(uint2(b)).rgb * 255);
    float3 rgb = (p00 * (1 - f.x) + p10 * f.x) * (1 - f.y) + (p01 * (1 - f.x) + p11 * f.x) * f.y;
    output[p.y * u.size.x + p.x] = float4(rgb, (rgb.x + rgb.y + rgb.z) / 3);
}

kernel void tutuChatCardWarp(constant TutuChatCardUniforms &u [[buffer(0)]],
    device const float *mask [[buffer(1)]], device const float *nx [[buffer(2)]], device const float *ny [[buffer(3)]],
    device float *output [[buffer(4)]], uint2 id [[thread_position_in_grid]]) {
    if (tutuChatCardOutside(id, u)) return;
    uint2 p = tutuChatCardPosition(id, u); uint k = p.y * u.size.x + p.x;
    output[k] = tutuChatCardSample(mask, u.size.xy, float2(p) + 0.1f * u.geometry.z * float2(nx[k], ny[k]));
}

kernel void tutuChatCardHeight(constant TutuChatCardUniforms &u [[buffer(0)]],
    device const float *base [[buffer(1)]], device const float *impression [[buffer(2)]],
    device const float *pressure1 [[buffer(3)]], device const float *pressure2 [[buffer(4)]],
    device float *height [[buffer(5)]], uint2 id [[thread_position_in_grid]]) {
    if (tutuChatCardOutside(id, u)) return;
    uint2 p = tutuChatCardPosition(id, u); uint k = p.y * u.size.x + p.x;
    height[k] = base[k] - 0.22f * (0.8f + 0.3f * pressure1[k] + 0.1f * pressure2[k]) * min(1.0f, impression[k] * 1.3f);
}

kernel void tutuChatCardShade(constant TutuChatCardUniforms &u [[buffer(0)]],
    device const float *height [[buffer(1)]], device const float *alpha [[buffer(2)]],
    device const float *inkNoise [[buffer(3)]], device const float4 *paper [[buffer(4)]],
    device float4 *color [[buffer(5)]], uint2 id [[thread_position_in_grid]]) {
    if (tutuChatCardOutside(id, u)) return;
    uint2 p = tutuChatCardPosition(id, u); uint k = p.y * u.size.x + p.x;
    float eroded = 1e9f;
    for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {
        int2 q = clamp(int2(p) + int2(x, y), int2(0), int2(u.size.xy) - 1);
        eroded = min(eroded, alpha[uint(q.y) * u.size.x + uint(q.x)]);
    }
    float edge = clamp(alpha[k] - eroded, 0.0f, 1.0f), tooth = (paper[k].w - u.paper.x) / u.paper.y;
    float ink = alpha[k] * (0.9f + 0.07f * tooth + 0.06f * inkNoise[k]) + 0.06f * edge;
    if (tooth < -1.35f) ink *= 0.72f;
    ink = clamp(ink, 0.0f, 1.0f);
    uint left = p.x == 0 ? 0 : p.x - 1, right = min(p.x + 1, u.size.x - 1);
    uint top = p.y == 0 ? 0 : p.y - 1, bottom = min(p.y + 1, u.size.y - 1);
    float gx = (height[p.y * u.size.x + right] - height[p.y * u.size.x + left]) * (p.x == 0 || p.x == u.size.x - 1 ? 1.0f : 0.5f) * u.geometry.z;
    float gy = (height[bottom * u.size.x + p.x] - height[top * u.size.x + p.x]) * (p.y == 0 || p.y == u.size.y - 1 ? 1.0f : 0.5f) * u.geometry.z;
    const float3 light = normalize(float3(-0.48f, -0.62f, 0.62f));
    float s = max(0.0f, (-gx * light.x - gy * light.y + light.z) / sqrt(gx * gx + gy * gy + 1));
    float d = (s - light.z) / light.z, shade = 1 + 0.8f * (d > 0 ? 0.72f * d : 1.25f * d);
    // ACT_INK and INK are independently specified in JS, both [72,33,42].
    color[k] = float4((paper[k].rgb * (1 - ink) + float3(72, 33, 42) * (1 - 0.14f * edge) * ink) * shade, 1);
}

inline bool tutuChatCardNearer(uint2 a, uint2 b) {
    return a.x < b.x || (a.x == b.x && a.y < b.y);
}

kernel void tutuChatCardCutGeometry(constant TutuChatCardUniforms &u [[buffer(0)]],
    device const TutuChatCardCut *topology [[buffer(1)]], device const float *noise [[buffer(2)]],
    device const float4 *fibers [[buffer(3)]], device const uint *offsets [[buffer(4)]],
    device const uint *indices [[buffer(5)]], device float4 *output [[buffer(6)]],
    device const uint4 *edgeOrder [[buffer(7)]], uint2 id [[thread_position_in_grid]]) {
    if (tutuChatCardOutside(id, u)) return;
    uint2 p = tutuChatCardPosition(id, u); TutuChatCardCut c = topology[0];
    float w = u.geometry.x, h = u.geometry.y, scale = u.geometry.z;
    float2 point = (float2(p) + 0.5f) / scale - u.geometry.w;
    float X = point.x, Y = point.y, sv; float2 normal;
    // Compare the source's Double edge distances exactly. Strict comparisons in
    // top/right/bottom/left order retain Math.min + === tie precedence.
    uint4 horizontal = edgeOrder[p.x], vertical = edgeOrder[u.size.z + p.y];
    uint side = 0; uint2 nearest = vertical.xy;
    if (tutuChatCardNearer(horizontal.zw, nearest)) { side = 1; nearest = horizontal.zw; }
    if (tutuChatCardNearer(vertical.zw, nearest)) { side = 2; nearest = vertical.zw; }
    if (tutuChatCardNearer(horizontal.xy, nearest)) side = 3;
    if (side == 0) { sv = clamp(X, 0.0f, w); normal = float2(0, -1); }
    else if (side == 1) { sv = w + clamp(Y, 0.0f, h); normal = float2(1, 0); }
    else if (side == 2) { sv = w + h + w - clamp(X, 0.0f, w); normal = float2(0, 1); }
    else { sv = 2 * w + h + h - clamp(Y, 0.0f, h); normal = float2(-1, 0); }
    float skew;
    if (sv < w) skew = -(c.cornerY[0] + (c.cornerY[1] - c.cornerY[0]) * sv / w);
    else if (sv < w + h) skew = c.cornerX[1] + (c.cornerX[2] - c.cornerX[1]) * (sv - w) / h;
    else if (sv < 2 * w + h) skew = c.cornerY[2] + (c.cornerY[3] - c.cornerY[2]) * (sv - w - h) / w;
    else skew = -(c.cornerX[3] + (c.cornerX[0] - c.cornerX[3]) * (sv - 2 * w - h) / h);
    float rough = 0;
    for (uint i = 0; i < c.counts.w; ++i) {
        float a = c.rough[i * 2], b = c.rough[i * 2 + 1];
        if (sv > a && sv < b) rough = max(rough, sin(M_PI_F * (sv - a) / (b - a)));
    }
    float wander = skew + 0.15f * tutuChatCardNoise1(noise, 0, c.counts.x, sv / 9)
        + 0.06f * tutuChatCardNoise1(noise, c.counts.x, c.counts.y, sv / 2.5f)
        + 0.18f * rough * tutuChatCardNoise1(noise, c.counts.x + c.counts.y, c.counts.z, sv / 0.7f);
    // Preserve JS's quadrant index, including its BR/BL correspondence.
    uint corner = (X > w / 2 ? 1 : 0) + (Y > h / 2 ? 2 : 0); float rc = c.radii[corner];
    float2 q = abs(point - float2(w, h) / 2) - (float2(w, h) / 2 - rc);
    float2 positive = max(q, float2(0));
    float dist = sqrt(dot(positive, positive)) + min(max(q.x, q.y), 0.0f) - rc - wander;
    float body = clamp(0.5f - dist * scale, 0.0f, 1.0f), fiber = 0;
    uint tile = (p.y / 16) * u.tiles.x + p.x / 16;
    // Tile indices retain source splat order; no unordered float atomics.
    for (uint i = offsets[tile]; i < offsets[tile + 1]; ++i) {
        float4 f = fibers[indices[i]]; int2 root = int2(floor(f.xy)); float2 frac = f.xy - float2(root);
        int2 delta = int2(p) - root;
        if (all(delta >= 0) && all(delta <= 1)) {
            float fx = delta.x == 0 ? 1 - frac.x : frac.x, fy = delta.y == 0 ? 1 - frac.y : frac.y;
            fiber += f.z * fx * fy;
        }
    }
    float fa = fiber > 0 ? 1 - exp(-fiber * 2.2f) : 0;
    const float2 light = normalize(float2(-0.48f, -0.62f)); float facing = dot(normal, light);
    float lit = facing > 0 ? 1 + 0.09f * facing : 1 + 0.16f * facing;
    float cut = dist > -1.2f / scale ? lit : 1;
    float weight = body >= fa ? 1 : body / max(fa, 1e-4f), alpha = max(body, fa);
    output[p.y * u.size.z + p.x] = float4(cut, weight, 0.94f + 0.06f * facing, alpha);
}

kernel void tutuChatCardCutColor(constant TutuChatCardUniforms &u [[buffer(0)]],
    device const float4 *color [[buffer(1)]], device const float4 *geometry [[buffer(2)]],
    texture2d<float, access::write> output [[texture(0)]], uint2 id [[thread_position_in_grid]]) {
    if (tutuChatCardOutside(id, u)) return;
    uint2 p = tutuChatCardPosition(id, u); float4 g = geometry[p.y * u.size.z + p.x];
    if (g.w <= 0) { output.write(float4(0), p); return; }
    int offset = int(floor(u.geometry.w * u.geometry.z + 0.5f));
    int2 q = clamp(int2(p) - offset, int2(0), int2(u.size.xy) - 1);
    float3 rgb = color[uint(q.y) * u.size.x + uint(q.x)].rgb * g.x * g.y + float3(222, 219, 212) * g.z * (1 - g.y);
    output.write(tutuChatCardBytes(float4(rgb, g.w * 255)), p);
}
#endif
