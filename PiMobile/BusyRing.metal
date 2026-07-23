#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Comet-trail spinner ring, drawn crisply inside the host circle's bounds.
[[ stitchable ]] half4 busyRing(
    float2 position,
    half4 color,
    float4 bounds,
    float time,
    half4 tint
) {
    const float tau = 6.28318530718;

    float2 size = max(bounds.zw, float2(1.0));
    float2 uv = (position - bounds.xy) / size - 0.5;
    float r = length(uv);
    float px = 1.0 / min(size.x, size.y); // one pixel in normalized units

    float ringRadius = 0.44;
    float halfWidth = 0.035;
    float d = abs(r - ringRadius);

    // Crisp ring band, antialiased over ~1px, plus a soft energy aura.
    float band = 1.0 - smoothstep(halfWidth - px, halfWidth + px, d);
    float aura = exp(-pow(d / 0.06, 2.0));

    // Angle behind the comet head, always in [0, tau).
    float angle = atan2(uv.y, uv.x);
    float a = angle - time * 2.6;
    float delta = a - tau * floor(a / tau);

    float trail = pow(1.0 - delta / tau, 3.0);
    float head = exp(-delta * 5.0);

    // Gentle forcefield pulse on the base track.
    float pulse = 0.8 + 0.2 * sin(time * 4.0);

    float alpha = band * (0.16 * pulse + 0.84 * trail) + aura * head * 0.5;
    alpha = saturate(alpha);

    // Whiten toward the head so it reads as a hot spot.
    half3 rgb = mix(tint.rgb, half3(1.0h), half(head * 0.6));
    return half4(rgb * half(alpha), half(alpha));
}
