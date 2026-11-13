#include <metal_stdlib>
using namespace metal;
#if PERSONAL_APPS

// CPU resolves the forward scatter in source order, including transparent last-writer overwrites.
kernel void tutuChatLaceScatter(device const int *sourceIndices [[buffer(0)]],
    texture2d<float, access::read> ribbon [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    int source = sourceIndices[p.y * output.get_width() + p.x];
    if (source < 0) { output.write(float4(0), p); return; }
    uint width = ribbon.get_width();
    output.write(ribbon.read(uint2(uint(source) % width, uint(source) / width)), p);
}
#endif
