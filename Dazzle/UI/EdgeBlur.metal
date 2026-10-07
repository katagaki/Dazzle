#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Blurs a layer more the closer each point is to either end of a visible
/// span, so content passing under the ends of a strip softens smoothly.
/// `leading` and `trailing` are the span's ends in the layer's coordinates;
/// within `fade` of either, the blur grows to `radius`.
[[ stitchable ]] half4 edgeBlur(float2 position, SwiftUI::Layer layer, float leading, float trailing, float fade, float radius) {
    float depth = max(leading + fade - position.x, position.x - (trailing - fade));
    float r = radius * smoothstep(0.0, 1.0, saturate(depth / fade));
    if (r < 0.5) {
        return layer.sample(position);
    }
    // Taps on a golden-angle spiral fill the disc evenly, so the blur has no
    // ghost copies of edges however wide it grows; nearer taps weigh more.
    // Turning the spiral a little from point to point keeps the taps from
    // drawing streaks as the radius grows toward the ends.
    const int taps = 32;
    const float goldenAngle = 2.39996323;
    float turn = 6.28318531 * fract(52.9829189 * fract(dot(position, float2(0.06711056, 0.00583715))));
    half4 sum = 0;
    float total = 0;
    for (int i = 0; i < taps; i++) {
        float d = sqrt((float(i) + 0.5) / float(taps));
        float a = float(i) * goldenAngle + turn;
        float w = exp(-2.0 * d * d);
        sum += layer.sample(position + float2(cos(a), sin(a)) * d * r) * half(w);
        total += w;
    }
    return sum / half(total);
}
