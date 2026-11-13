#include <metal_stdlib>
using namespace metal;
#if PERSONAL_APPS

struct TutuChatFeltUniforms {
    uint width, height, fibreSize, binsWide;
    float kf, scale;
    uint toy, tox;
};
struct TutuChatFeltBlurUniforms { uint width, height, radius, vertical; };

kernel void tutuChatFeltMaterial(
    device const float *sdf [[buffer(0)]], device const float *fibre [[buffer(1)]],
    device const float2 *points [[buffer(2)]], device const float *lengths [[buffer(3)]],
    device const int4 *bounds [[buffer(4)]], device const uint *offsets [[buffer(5)]],
    device const uint *references [[buffer(6)]], device float4 *material [[buffer(7)]],
    device float2 *coverage [[buffer(8)]], constant TutuChatFeltUniforms &u [[buffer(9)]],
    uint2 p [[thread_position_in_grid]]) {
    if (p.x >= u.width || p.y >= u.height) return;
    uint k = p.y * u.width + p.x;
    float s = sdf[k], tv = fibre[((p.y + u.toy) % u.fibreSize) * u.fibreSize + (p.x + u.tox) % u.fibreSize];
    float body = s < -0.5f / u.kf ? 1.0f : (s > 0.5f / u.kf ? 0.0f : 0.5f - s * u.kf);
    float height = 0.0f;
    float3 albedo = float3(0.0f);
    if (body > 0.0f) {
        height = (s < 0.0f ? 0.62f * (1.0f - exp(s / 1.6f)) : 0.0f) + 0.012f * tv * body;
        albedo = float3(241, 237, 231) * (1.0f + 0.018f * tv);
    }
    float threadCoverage = 0.0f;
    uint bin = (p.y / 16) * u.binsWide + p.x / 16;
    // Each pixel sees stitches in the serial source order, including overlapping needle holes.
    for (uint ref = offsets[bin]; ref < offsets[bin + 1]; ++ref) {
        uint stitch = references[ref];
        int4 b = bounds[stitch];
        if (int(p.x) < b.x || int(p.y) < b.y || int(p.x) >= b.z || int(p.y) >= b.w) continue;
        uint base = stitch * 16;
        float dmin = 1e9f, tmin = 0.0f;
        for (uint q = 0; q < 15; ++q) {
            float2 a = points[base + q], delta = points[base + q + 1] - a;
            float l2 = delta.x * delta.x + delta.y * delta.y + 1e-9f;
            float t = clamp(dot(float2(p) - a, delta) / l2, 0.0f, 1.0f);
            float d = length(float2(p) - (a + t * delta));
            if (d < dmin) { dmin = d; tmin = (float(q) + t) / 15.0f; }
        }
        float ends = min(tmin, 1.0f - tmin);
        float radius = 0.42f * u.kf * sqrt(clamp(ends / 0.1f, 0.45f, 1.0f));
        float first = length(float2(p) - points[base]) / (0.42f * u.kf);
        float last = length(float2(p) - points[base + 15]) / (0.42f * u.kf);
        float hole = 0.16f * (exp(-first * first) + exp(-last * last));
        if (dmin < radius + 0.5f) {
            float ratio = dmin / radius;
            float profile = sqrt(clamp(1.0f - ratio * ratio, 0.0f, 1.0f));
            float along = tmin * lengths[stitch];
            float twist = 0.5f + 0.5f * cos(2.0f * M_PI_F * (along + dmin / u.kf * 0.9f) / 0.5f);
            float lift = profile * 0.45f * pow(clamp(ends / 0.14f, 0.0f, 1.0f), 0.6f) * (0.84f + 0.16f * twist);
            float cov = clamp(radius - dmin + 0.5f, 0.0f, 1.0f);
            float tc = (0.97f + 0.03f * twist) * cov;
            height += lift;
            albedo = albedo * (1.0f - cov) + float3(252, 250, 245) * tc;
            threadCoverage = max(threadCoverage, cov);
        }
        height -= hole;
    }
    material[k] = float4(height, albedo);
    coverage[k] = float2(body, threadCoverage);
}

kernel void tutuChatFeltShadow(device const float2 *coverage [[buffer(0)]], device float *shadow [[buffer(1)]],
    constant TutuChatFeltUniforms &u [[buffer(2)]], uint2 p [[thread_position_in_grid]]) {
    uint w = u.width / 2, h = u.height / 2;
    if (p.x >= w || p.y >= h) return;
    int sy = int(floor(0.55f * u.kf + 0.5f)), sx = int(floor(0.42f * u.kf + 0.5f));
    int y0 = int(2 * p.y) - sy, x0 = int(2 * p.x) - sx;
    float sum = 0.0f;
    for (int dy = 0; dy < 2; ++dy) for (int dx = 0; dx < 2; ++dx) {
        int x = x0 + dx, y = y0 + dy;
        if (x >= 0 && y >= 0) sum += coverage[y * u.width + x].y;
    }
    shadow[p.y * w + p.x] = sum / 4.0f;
}

kernel void tutuChatFeltBlur(device const float *source [[buffer(0)]], device float *target [[buffer(1)]],
    device const float *weights [[buffer(2)]], constant TutuChatFeltBlurUniforms &u [[buffer(3)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= u.width || p.y >= u.height) return;
    float sum = 0.0f;
    for (int j = -int(u.radius); j <= int(u.radius); ++j) {
        int x = u.vertical ? int(p.x) : clamp(int(p.x) + j, 0, int(u.width) - 1);
        int y = u.vertical ? clamp(int(p.y) + j, 0, int(u.height) - 1) : int(p.y);
        sum += weights[j + int(u.radius)] * source[y * u.width + x];
    }
    target[p.y * u.width + p.x] = sum;
}

static float2 tutuChatFeltGradient(device const float *a, uint2 p, uint w, uint h) {
    uint xa = p.x > 0 ? p.x - 1 : p.x, xb = min(p.x + 1, w - 1);
    uint ya = p.y > 0 ? p.y - 1 : p.y, yb = min(p.y + 1, h - 1);
    return float2((a[p.y * w + xb] - a[p.y * w + xa]) / float(xb - xa),
                  (a[yb * w + p.x] - a[ya * w + p.x]) / float(yb - ya));
}
static float2 tutuChatFeltHeightGradient(device const float4 *a, uint2 p, uint w, uint h) {
    uint xa = p.x > 0 ? p.x - 1 : p.x, xb = min(p.x + 1, w - 1);
    uint ya = p.y > 0 ? p.y - 1 : p.y, yb = min(p.y + 1, h - 1);
    return float2((a[p.y * w + xb].x - a[p.y * w + xa].x) / float(xb - xa),
                  (a[yb * w + p.x].x - a[ya * w + p.x].x) / float(yb - ya));
}
static float tutuChatFeltShadowAt(device const float *a, uint2 p, uint w, uint h) {
    float2 q = clamp(float2(p) / 2.0f - 0.25f, float2(0), float2(w, h) - 1.001f);
    uint2 i = uint2(q); float2 f = q - float2(i); uint k = i.y * w + i.x;
    return (a[k] * (1.0f - f.x) + a[k + 1] * f.x) * (1.0f - f.y)
         + (a[k + w] * (1.0f - f.x) + a[k + w + 1] * f.x) * f.y;
}

kernel void tutuChatFeltFinish(device const float *sdf [[buffer(0)]], device const float *fuzz [[buffer(1)]],
    device const float4 *material [[buffer(2)]], device const float2 *coverage [[buffer(3)]],
    device const float *shadow [[buffer(4)]], constant TutuChatFeltUniforms &u [[buffer(5)]],
    texture2d<float, access::write> output [[texture(0)]], uint2 p [[thread_position_in_grid]]) {
    uint w = u.width / 2, h = u.height / 2;
    if (p.x >= w || p.y >= h) return;
    const float3 lamp = normalize(float3(-0.48f, -0.62f, 0.62f));
    float4 accumulated = float4(0.0f);
    // Row-major 2x2 reduction of premultiplied colour, followed by one unpremultiply.
    for (uint dy = 0; dy < 2; ++dy) for (uint dx = 0; dx < 2; ++dx) {
        uint2 q = p * 2 + uint2(dx, dy); uint k = q.y * u.width + q.x;
        float body = coverage[k].x, fur = fuzz[k];
        if (body <= 0.0f && fur <= 0.0f) continue;
        float fa = fur > 0.0f ? 1.0f - exp(-fur * 1.25f) : 0.0f, alpha = max(body, fa);
        float shade = 1.0f, hair = 1.0f;
        if (body > 0.0f) {
            // Intentionally scale, NOT kf: this is gradient(hgt) * S in the source.
            float2 g = tutuChatFeltHeightGradient(material, q, u.width, u.height) * u.scale;
            float normalDot = max(0.0f, (-g.x * lamp.x - g.y * lamp.y + lamp.z) / sqrt(g.x * g.x + g.y * g.y + 1.0f));
            shade = clamp(1.0f + 0.42f * (normalDot - lamp.z) / lamp.z, 0.78f, 1.12f)
                  * (1.0f - 0.2f * tutuChatFeltShadowAt(shadow, q, w, h) * (1.0f - coverage[k].y));
        }
        if (body < 1.0f) {
            float2 g = tutuChatFeltGradient(sdf, q, u.width, u.height);
            float gl = length(g) + 1e-9f;
            hair = 0.95f + 0.08f * clamp(dot(-g / gl, lamp.xy) / length(lamp.xy), -1.0f, 1.0f);
        }
        accumulated.rgb += (material[k].yzw * shade * body + float3(241, 237, 231) * hair * (1.0f - body)) * alpha;
        accumulated.a += alpha;
    }
    if (accumulated.a <= 0.0f) { output.write(float4(0), p); return; }
    float4 straight = float4(accumulated.rgb / accumulated.a, accumulated.a / 4.0f * 255.0f);
    // ImageData's Uint8ClampedArray uses round-to-nearest-even before normalized storage.
    output.write(rint(clamp(straight, 0.0f, 255.0f)) / 255.0f, p);
}
#endif
