#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Safari's switcher lens over a copy of the labels: the text keeps its place in the middle and is only
/// shifted near the rim, as through the curved edge of a glass bead. One sample, so nothing doubles.
[[ stitchable ]] half4 glassLens(float2 position, SwiftUI::Layer layer, float2 origin, float2 size, float magnify, float bend) {
    float2 centre = origin + size * 0.5;
    float h = size.y * 0.5;
    // Distance to the capsule's centre line, 0 there and 1 at the rim.
    float2 spine = float2(clamp(position.x, origin.x + h, origin.x + size.x - h), centre.y);
    float2 out = position - spine;
    float rim = clamp(length(out) / h, 0.0, 1.0);
    float2 base = centre + (position - centre) / magnify;
    return layer.sample(base + out * pow(rim, 4.0) * bend);
}
