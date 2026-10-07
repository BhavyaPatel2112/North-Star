// The opening star (a Metal shader: a tiny program the graphics chip runs once
// for every pixel, every frame).
//
// It paints a star the way a camera sees one in the night sky: a white-hot
// centre, a soft four-pointed glow, and thin rays of light (diffraction
// spikes). The light travels around the star, and the glow splits into colour
// at its edges (orange outside, blue inside, lavender on one side) like light
// through a prism. Faint background stars twinkle around it, and everything is
// seen through textured glass: tiny cells that bend the light and leave fine
// specks, as in Brett McMillin's "Spectral signal through the pane of glass".

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// A repeatable random number from 0 to 1 for each grid cell.
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// How bright the star is at point q, measured in star radii from its centre.
// spike: how far the rays reach; lit: how strongly the travelling light falls here.
static float starField(float2 q, float spike, float lit) {
    float2 a = abs(q);
    // Four-pointed body: (sqrt|x| + sqrt|y|)^2 is 1 on a concave four-point star,
    // so its glow fades in star-shaped rings, long along the axes, short on diagonals.
    float s = pow(sqrt(a.x) + sqrt(a.y), 2.0);
    float body = exp(-s * 1.7) * lit;
    float core = exp(-dot(q, q) * 30.0) * 1.5;           // white-hot centre
    float halo = exp(-length(q) * 1.25) * 0.45 * lit;     // round soft halo
    // Rays: thin lines along the axes, and fainter ones on the diagonals.
    float rays = exp(-a.y * 55.0) * exp(-a.x / spike) + exp(-a.x * 55.0) * exp(-a.y / spike);
    float2 d = abs(float2(q.x + q.y, q.x - q.y)) * 0.70710678;
    float diagonal = exp(-d.y * 70.0) * exp(-d.x / (spike * 0.4)) + exp(-d.x * 70.0) * exp(-d.y / (spike * 0.4));
    return body + core + halo + (rays * 0.7 + diagonal * 0.25) * (0.5 + 0.5 * lit);
}

// position: this pixel (points); size: the screen (points); time: seconds;
// bloom: 0 to 1 as the star appears; orbit: direction of the travelling light
// (radians); flare: 0 to 1 at the final sparkle; sky: 0 to 1 for background stars.
[[ stitchable ]] half4 skyStar(float2 position, half4 color, float2 size, float time,
                               float bloom, float orbit, float flare, float sky) {
    float2 centre = size * float2(0.5, 0.46);
    float radius = min(size.x, size.y) * 0.25 * (0.3 + 0.7 * bloom) * (1.0 + 0.3 * flare);

    // Glass: each 2.5-point cell bends the light behind it a little, its own way.
    float cell = 2.5;
    float2 id = floor(position / cell);
    float2 random = float2(hash21(id), hash21(id + 17.0));
    float2 q = (position + (random - 0.5) * 3.0 - centre) / radius;

    // The travelling light, and a gentle twinkle.
    float theta = atan2(q.y, q.x);
    float lit = 0.2 + 1.3 * pow(0.5 + 0.5 * cos(theta - orbit), 2.5);
    float twinkle = 1.0 + 0.1 * sin(time * 11.0) * sin(time * 6.7 + 1.3);
    float spike = (0.55 + 0.9 * flare) * twinkle;

    // Prism: red spreads a little wider than green, blue a little tighter.
    float3 light = float3(starField(q / 1.16, spike, lit),
                          starField(q, spike, lit),
                          starField(q / 0.86, spike, lit));

    // Lavender on the side the light is heading, warm behind it; the centre stays white.
    float side = sin(theta - orbit);
    float3 tint = mix(float3(1.0, 0.62, 0.38), float3(0.78, 0.62, 1.0), 0.5 + 0.5 * side);
    light *= mix(float3(1.0), tint, smoothstep(0.15, 0.9, length(q)));

    // Soft roll-off, so bright light turns creamy white instead of clipping.
    float brightness = bloom * twinkle * (1.0 + 1.5 * flare);
    float3 colour = 1.0 - exp(-light * brightness * 1.3);

    // Background stars: about one in four 36-point squares holds a faint twinkling star.
    float grid = 36.0;
    float2 square = floor(position / grid);
    float present = step(0.72, hash21(square + 5.0));
    float2 spot = (square + 0.15 + 0.7 * float2(hash21(square + 9.0), hash21(square + 23.0))) * grid;
    float blink = 0.55 + 0.45 * sin(time * (1.5 + 3.0 * hash21(square + 31.0)) + 6.28 * hash21(square + 41.0));
    float star = present * sky * blink * (0.25 + 0.5 * hash21(square + 3.0))
               * exp(-length_squared(position - spot) / 1.1);
    colour += float3(star * 0.9, star * 0.92, star);

    // Glass specks: one per cell, dark over bright light, faintly bright over black.
    float2 inCell = fract(position / cell) - (0.2 + random.yx * 0.6);
    float speck = smoothstep(0.32, 0.05, length(inCell));
    float luminance = dot(colour, float3(0.3, 0.59, 0.11));
    colour *= 1.0 - speck * 0.55 * smoothstep(0.04, 0.5, luminance);
    colour += speck * 0.03 * (1.0 - smoothstep(0.0, 0.2, luminance)) * sky;

    return half4(half3(colour), 1.0);
}
