// The "pane of glass" for the opening star (a Metal shader: a tiny program
// the graphics chip runs once for every pixel, every frame).
//
// The screen is split into small square cells, like a sheet of textured glass.
// Each cell bends the light behind it in its own random direction, and bends
// red light a little more than blue, which splits the glow into rainbow
// fringes. Each cell also holds one faint speck that lights up where the glow
// is bright, like dust caught in light.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// A repeatable random number from 0 to 1 for each cell.
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// position: this pixel; layer: the glowing star drawn underneath;
// cell: glass cell size in points; strength: how far each cell bends the light.
[[ stitchable ]] half4 glassPane(float2 position, SwiftUI::Layer layer, float cell, float strength) {
    float2 id = floor(position / cell);
    float r1 = hash21(id);
    float r2 = hash21(id + 17.0);

    // Bend: look at the glow a little to one side, different for every cell.
    float2 bend = (float2(r1, r2) - 0.5) * strength;
    half4 base = layer.sample(position + bend);

    // Rainbow fringe: red bends more than green, blue less.
    half red = layer.sample(position + bend * 1.4).r;
    half blue = layer.sample(position + bend * 0.6).b;
    half3 colour = half3(red, base.g, blue);

    // One speck per cell, at a random spot inside it.
    float2 inCell = fract(position / cell) - (0.2 + float2(r2, r1) * 0.6);
    float speck = smoothstep(0.16, 0.0, length(inCell)) * (0.3 + 0.7 * hash21(id + 3.0));
    float glow = dot(float3(base.rgb), float3(0.3, 0.59, 0.11));
    colour += half3(speck * (0.05 + glow * 0.8));

    return half4(colour, 1.0);
}
