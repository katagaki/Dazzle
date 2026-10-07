#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Blurs a layer more the closer each point is to either end of a visible
/// span, so content passing under the ends of a strip softens smoothly.
/// `leading` and `trailing` are the span's ends in the layer's coordinates;
/// within `fade` of either, the blur grows to `radius`.
[[ stitchable ]] half4 edgeBlur(float2 position, SwiftUI::Layer layer, float leading, float trailing, float fade, float radius) {
    float depth = max(leading + fade - position.x, position.x - (trailing - fade));
    float r = radius * saturate(depth / fade);
    if (r < 0.5) {
        return layer.sample(position);
    }
    // A centre tap and two rings of six, weighted toward the centre.
    half4 sum = layer.sample(position) * 0.2h;
    sum += (layer.sample(position + float2( 0.5,    0.0)   * r)
          + layer.sample(position + float2( 0.25,   0.433) * r)
          + layer.sample(position + float2(-0.25,   0.433) * r)
          + layer.sample(position + float2(-0.5,    0.0)   * r)
          + layer.sample(position + float2(-0.25,  -0.433) * r)
          + layer.sample(position + float2( 0.25,  -0.433) * r)) * 0.08h;
    sum += (layer.sample(position + float2( 0.866,  0.5)   * r)
          + layer.sample(position + float2( 0.0,    1.0)   * r)
          + layer.sample(position + float2(-0.866,  0.5)   * r)
          + layer.sample(position + float2(-0.866, -0.5)   * r)
          + layer.sample(position + float2( 0.0,   -1.0)   * r)
          + layer.sample(position + float2( 0.866, -0.5)   * r)) * (0.32h / 6.0h);
    return sum;
}
