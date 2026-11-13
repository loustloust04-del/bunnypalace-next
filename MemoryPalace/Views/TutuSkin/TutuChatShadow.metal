#include <metal_stdlib>
using namespace metal;
#if PERSONAL_APPS

struct TutuChatShadowBlurUniforms {
    int4 geometry;
    int4 direction;
    float4 sampling;
};

struct TutuChatShadowUniforms {
    float4 geometry;
    float4 opacity;
    float4 sampling;
};

static float4 tutuChatShadowRead(texture2d<float, access::read> image, int2 position) {
    if (any(position < int2(0)) || position.x >= int(image.get_width()) || position.y >= int(image.get_height())) {
        return float4(0.0f);
    }
    return image.read(uint2(position));
}

static float4 tutuChatShadowReadLinear(texture2d<float, access::read> image, float2 position) {
    int2 base = int2(floor(position));
    float2 fraction = position - float2(base);
    if (all(fraction == float2(0))) return tutuChatShadowRead(image, base);
    float4 top = mix(tutuChatShadowRead(image, base), tutuChatShadowRead(image, base + int2(1, 0)), fraction.x);
    float4 bottom = mix(tutuChatShadowRead(image, base + int2(0, 1)), tutuChatShadowRead(image, base + int2(1, 1)), fraction.x);
    return mix(top, bottom, fraction.y);
}

// Integer coordinates denote texel centers. Outside the finite image is always
// transparent, including each of the four taps of a fractional translated sample.
static float tutuChatShadowBilinear(texture2d<float, access::read> image, float2 position) {
    int2 base = int2(floor(position));
    float2 fraction = position - float2(base);
    float top = mix(tutuChatShadowRead(image, base).r,
                    tutuChatShadowRead(image, base + int2(1, 0)).r, fraction.x);
    float bottom = mix(tutuChatShadowRead(image, base + int2(0, 1)).r,
                       tutuChatShadowRead(image, base + int2(1, 1)).r, fraction.x);
    return mix(top, bottom, fraction.y);
}

kernel void tutuChatShadowBlur(texture2d<float, access::read> input [[texture(0)]],
                               texture2d<float, access::write> output [[texture(1)]],
                               constant TutuChatShadowBlurUniforms &uniforms [[buffer(0)]],
                               const device float *weights [[buffer(1)]],
                               uint2 position [[thread_position_in_grid]]) {
    if (position.x >= output.get_width() || position.y >= output.get_height()) return;
    if (uniforms.direction.z > 0 && (position.x >= uint(uniforms.direction.z) || position.y >= uint(uniforms.direction.w))) {
        output.write(float4(0.0f), position);
        return;
    }
    int2 source = int2(position) - uniforms.geometry.xy;
    int radius = uniforms.geometry.z;
    int channel = uniforms.geometry.w;
    float alpha = 0.0f;
    for (int delta = -radius; delta <= radius; ++delta) {
        float2 sampled = (float2(source + uniforms.direction.xy * delta) + 0.5f) * uniforms.sampling.xy - 0.5f;
        float4 value = tutuChatShadowReadLinear(input, sampled);
        alpha += value[channel] * weights[delta + radius];
    }
    output.write(float4(alpha, 0.0f, 0.0f, 0.0f), position);
}

kernel void tutuChatShadowFirstFilter(texture2d<float, access::read> source [[texture(0)]],
                                      texture2d<float, access::read> blurred [[texture(1)]],
                                      texture2d<float, access::write> output [[texture(2)]],
                                      constant TutuChatShadowUniforms &uniforms [[buffer(0)]],
                                      uint2 position [[thread_position_in_grid]]) {
    if (position.x >= output.get_width() || position.y >= output.get_height()) return;
    if (uniforms.opacity.y > 0.0f && (position.x >= uint(uniforms.opacity.y) || position.y >= uint(uniforms.opacity.z))) {
        output.write(float4(0.0f), position);
        return;
    }
    float2 sampled = (float2(int2(position) - int2(uniforms.geometry.xy)) + 0.5f) * uniforms.sampling.xy - 0.5f;
    float original = tutuChatShadowReadLinear(source, sampled).a;
    float far = uniforms.opacity.x * tutuChatShadowBilinear(blurred, float2(position) - uniforms.geometry.zw);
    float firstAlpha = original + far * (1.0f - original);
    output.write(float4(far, firstAlpha, 0.0f, 0.0f), position);
}

kernel void tutuChatShadowBehind(texture2d<float, access::read> firstFilter [[texture(0)]],
                                 texture2d<float, access::read> blurredFirstFilter [[texture(1)]],
                                 texture2d<float, access::write> output [[texture(2)]],
                                 constant TutuChatShadowUniforms &uniforms [[buffer(0)]],
                                 uint2 position [[thread_position_in_grid]]) {
    if (position.x >= output.get_width() || position.y >= output.get_height()) return;
    if (uniforms.opacity.y > 0.0f && (position.x >= uint(uniforms.opacity.y) || position.y >= uint(uniforms.opacity.z))) {
        output.write(float4(0.0f), position);
        return;
    }
    float far = firstFilter.read(position).r;
    float near = uniforms.opacity.x * tutuChatShadowBilinear(blurredFirstFilter,
                                                           float2(position) - uniforms.geometry.zw);
    // The original foreground is deliberately absent. Placing it over this black
    // straight-alpha raster reconstructs A-over-F-over-N, the two CSS filter chain.
    float behind = far + near * (1.0f - far);
    output.write(float4(0.0f, 0.0f, 0.0f, clamp(behind, 0.0f, 1.0f)), position);
}
#endif
