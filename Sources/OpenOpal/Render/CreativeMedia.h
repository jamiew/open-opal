#ifndef OPENOPAL_CREATIVE_MEDIA_H
#define OPENOPAL_CREATIVE_MEDIA_H

// Original single-frame artwork in display-encoded RGB. All spatial scales are
// based on image height, with a pixel minimum for tiny input textures.
inline float3 creativeSample(texture2d<float, access::sample> source, float2 uv) {
    constexpr sampler sampleImage(filter::linear, address::clamp_to_edge);
    float3 color = source.sample(sampleImage, clamp(uv, float2(0.0), float2(1.0))).rgb;
    return select(float3(0.0), saturate(color), isfinite(color));
}

inline float creativeLuma(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

inline float creativeHash(float2 p) {
    float3 q = fract(float3(p.x, p.y, p.x) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

inline float creativeNoise(float seed, float time) {
    float step = floor(time);
    float phase = fract(time);
    phase = phase * phase * (3.0 - 2.0 * phase);
    return mix(creativeHash(float2(seed, step)),
               creativeHash(float2(seed, step + 1.0)), phase);
}

inline float creativeDisk(float distance, float radius, float aa) {
    return 1.0 - smoothstep(radius - aa, radius + aa, distance);
}

inline float3 creativePointCloud(texture2d<float, access::sample> source,
                                 float2 uv, float2 size, float time) {
    // A sampled 2D point mosaic, not inferred depth or a reconstructed point cloud.
    float spacing = max(size.y / 150.0, 3.0);
    float2 cell = floor(uv * size / spacing);
    float2 jitter = float2(creativeHash(cell), creativeHash(cell + 19.0)) - 0.5;
    float2 center = (cell + 0.5 + jitter * 0.18) * spacing;
    float3 sampled = creativeSample(source, center / size);
    float light = creativeLuma(sampled);
    float radius = (0.08 + 0.34 * sqrt(light)) * spacing;
    float dotMask = creativeDisk(length(uv * size - center), radius, 0.65);
    float scanDistance = abs(fract(uv.y - time * 0.07 + 0.5) - 0.5);
    float scan = 1.0 - smoothstep(0.0, 0.055, scanDistance);
    float3 dotColor = saturate(sampled * 1.28 + float3(0.018, 0.032, 0.045));
    dotColor = mix(dotColor, float3(0.65, 0.94, 1.0), scan * 0.16);
    return mix(float3(0.009, 0.014, 0.024), dotColor, dotMask);
}

inline float3 creativeGlitch(texture2d<float, access::sample> source,
                             float2 uv, float2 size, float time) {
    float band = floor(uv.y * 72.0);
    // Smooth band-local envelopes prevent full-frame contrast flashes.
    float activity = smoothstep(0.63, 0.93, creativeNoise(band, time * 1.7));
    float direction = creativeNoise(band + 101.0, time * 1.1) * 2.0 - 1.0;
    float displacement = direction * activity * size.y * 0.038;
    float split = max(size.y / 720.0, 0.5) * (0.65 + activity * 3.4);
    float2 shifted = uv + float2(displacement / size.x, 0.0);
    float3 center = creativeSample(source, shifted);
    float red = creativeSample(source, shifted + float2(split / size.x, 0.0)).r;
    float blue = creativeSample(source, shifted - float2(split / size.x, 0.0)).b;
    float row = floor(uv.y * size.y / max(size.y / 540.0, 1.0));
    float sparse = smoothstep(0.97, 1.0, creativeHash(float2(row, floor(time * 5.0))));
    float noise = (creativeHash(floor(uv * size / 2.0)) - 0.5) * sparse * 0.10;
    float scanline = 0.985 + 0.015 * cos(uv.y * size.y * 3.14159265);
    return saturate(float3(red, center.g, blue) * scanline + noise);
}

inline float3 creativeAnime(texture2d<float, access::sample> source,
                            float2 uv, float2 size) {
    float3 center = creativeSample(source, uv);
    float spacing = max(size.y / 720.0, 1.0);
    float3 sum = center * 2.0;
    float weights = 2.0;
    float3 gradientX = float3(0.0);
    float3 gradientY = float3(0.0);
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            if (x == 0 && y == 0) continue;
            float3 sample = creativeSample(source, uv + float2(x, y) * spacing / size);
            float3 delta = sample - center;
            float spatial = (x == 0 || y == 0) ? 1.0 : 0.7071;
            float weight = spatial * exp(-dot(delta, delta) * 28.0);
            sum += sample * weight;
            weights += weight;
            gradientX += sample * float(x * (y == 0 ? 2 : 1));
            gradientY += sample * float(y * (x == 0 ? 2 : 1));
        }
    }
    float3 softened = sum / weights;
    float light = creativeLuma(softened);
    float celLight = floor(light * 6.0 + 0.5) / 6.0;
    float3 cel = saturate(softened * ((celLight + 0.035) / (light + 0.035)));
    cel = saturate(mix(float3(creativeLuma(cel)), cel, 1.08));
    float edge = sqrt(dot(gradientX, gradientX) + dot(gradientY, gradientY)) / 8.0;
    float ink = smoothstep(0.055, 0.20, edge) * 0.72;
    return mix(cel, float3(0.025, 0.030, 0.045), ink);
}

inline float creativeDotRank(float2 cellPoint) {
    // Area inside a centered circle intersected with a unit square. The rank is
    // uniform over the square, so thresholding it preserves average ink coverage
    // even when dark-tone dots grow beyond the sides and merge together.
    float radiusSquared = dot(cellPoint, cellPoint);
    float area = 3.14159265 * radiusSquared;
    if (radiusSquared > 0.25) {
        float radius = sqrt(radiusSquared);
        area -= 4.0 * (radiusSquared * acos(clamp(0.5 / radius, 0.0, 1.0))
                       - 0.5 * sqrt(radiusSquared - 0.25));
    }
    return saturate(area);
}

inline float3 creativeHalftone(texture2d<float, access::sample> source,
                               float2 uv, float2 size) {
    float spacing = max(size.y / 100.0, 3.0);
    float2 pixel = uv * size;
    // A 15-degree screen keeps the print distinct from the pixel-grid styles.
    float2 screen = float2(pixel.x * 0.9659258 + pixel.y * 0.2588190,
                          -pixel.x * 0.2588190 + pixel.y * 0.9659258) / spacing;
    float2 screenCenter = (floor(screen) + 0.5) * spacing;
    float2 center = float2(screenCenter.x * 0.9659258 - screenCenter.y * 0.2588190,
                          screenCenter.x * 0.2588190 + screenCenter.y * 0.9659258);
    float light = creativeLuma(creativeSample(source, center / size));
    float3 paper = float3(0.97, 0.946, 0.89);
    float3 ink = float3(0.045, 0.055, 0.072);
    float coverage = saturate((creativeLuma(paper) - light)
                             / (creativeLuma(paper) - creativeLuma(ink)));
    float rank = creativeDotRank(fract(screen) - 0.5);
    float aa = min(0.20, 0.7 / spacing);
    float dotMask = smoothstep(-aa, aa, coverage - rank);
    // Exact endpoint tones also avoid isolated dots on an all-white input.
    dotMask = coverage <= 0.0 ? 0.0 : (coverage >= 1.0 ? 1.0 : dotMask);
    return mix(paper, ink, dotMask);
}

inline float creativeEdges(texture2d<float, access::sample> source,
                           float2 uv, float2 size) {
    float spacing = max(size.y / 900.0, 1.0);
    float3 left = creativeSample(source, uv - float2(spacing / size.x, 0.0));
    float3 right = creativeSample(source, uv + float2(spacing / size.x, 0.0));
    float3 up = creativeSample(source, uv - float2(0.0, spacing / size.y));
    float3 down = creativeSample(source, uv + float2(0.0, spacing / size.y));
    float3 dx = right - left;
    float3 dy = down - up;
    return saturate(sqrt(dot(dx, dx) + dot(dy, dy)) * 0.75);
}

inline float3 creativeBlueprint(texture2d<float, access::sample> source,
                                float2 uv, float2 size) {
    float light = creativeLuma(creativeSample(source, uv));
    float edge = creativeEdges(source, uv, size);
    float spacing = max(size.y / 24.0, 5.0);
    float2 gridPoint = abs(fract(uv * size / spacing + 0.5) - 0.5) * spacing;
    float grid = 1.0 - smoothstep(0.35, 1.1, min(gridPoint.x, gridPoint.y));
    float3 navy = float3(0.013, 0.048, 0.12) + float3(0.013, 0.026, 0.05) * light;
    navy += float3(0.008, 0.034, 0.055) * grid;
    float drawing = smoothstep(0.025, 0.28, edge);
    float3 line = mix(float3(0.12, 0.70, 0.91), float3(0.85, 0.97, 1.0),
                      smoothstep(0.25, 0.7, edge));
    return mix(navy, line, drawing);
}

inline float3 creativeThermal(texture2d<float, access::sample> source, float2 uv) {
    // A luminance lookup only. No temperatures or hidden physical measurements.
    float light = creativeLuma(creativeSample(source, uv));
    float position = light * 5.0;
    if (position < 1.0) return mix(float3(0.012, 0.008, 0.08), float3(0.19, 0.045, 0.48), position);
    if (position < 2.0) return mix(float3(0.19, 0.045, 0.48), float3(0.66, 0.055, 0.36), position - 1.0);
    if (position < 3.0) return mix(float3(0.66, 0.055, 0.36), float3(0.97, 0.25, 0.055), position - 2.0);
    if (position < 4.0) return mix(float3(0.97, 0.25, 0.055), float3(1.0, 0.73, 0.08), position - 3.0);
    return mix(float3(1.0, 0.73, 0.08), float3(1.0, 0.98, 0.80), position - 4.0);
}

constant float3 creativeRetroPalette[16] = {
    float3(0.055, 0.065, 0.12), float3(0.20, 0.17, 0.29),
    float3(0.40, 0.22, 0.34), float3(0.66, 0.28, 0.36),
    float3(0.88, 0.46, 0.38), float3(0.98, 0.72, 0.51),
    float3(0.98, 0.90, 0.68), float3(0.94, 0.96, 0.91),
    float3(0.16, 0.32, 0.39), float3(0.22, 0.51, 0.51),
    float3(0.43, 0.72, 0.62), float3(0.68, 0.83, 0.61),
    float3(0.20, 0.29, 0.55), float3(0.35, 0.48, 0.72),
    float3(0.58, 0.67, 0.83), float3(0.60, 0.45, 0.63)
};

inline float3 creativePixelate(texture2d<float, access::sample> source,
                               float2 uv, float2 size) {
    float spacing = max(size.y / 90.0, 1.0);
    float2 center = (floor(uv * size / spacing) + 0.5) * spacing;
    float3 sampled = creativeSample(source, center / size);
    float bestDistance = 10.0;
    float3 bestColor = creativeRetroPalette[0];
    for (int index = 0; index < 16; ++index) {
        float3 delta = sampled - creativeRetroPalette[index];
        float lightDelta = creativeLuma(delta);
        float distance = dot(delta, delta) + lightDelta * lightDelta * 1.5;
        if (distance < bestDistance) {
            bestDistance = distance;
            bestColor = creativeRetroPalette[index];
        }
    }
    return bestColor;
}

inline float3 creativeHologram(texture2d<float, access::sample> source,
                               float2 uv, float2 size, float time) {
    float light = creativeLuma(creativeSample(source, uv));
    float edge = creativeEdges(source, uv, size);
    float scanSpacing = max(size.y / 220.0, 2.0);
    float scan = 0.84 + 0.16 * cos(uv.y * size.y / scanSpacing * 6.2831853);
    float distance = abs(fract(uv.y - time * 0.105 + 0.5) - 0.5);
    float sweep = 1.0 - smoothstep(0.0, 0.07, distance);
    float3 color = float3(0.006, 0.022, 0.047)
                 + float3(0.04, 0.61, 0.72) * light * scan;
    color += float3(0.12, 0.30, 0.31) * smoothstep(0.025, 0.32, edge);
    color += float3(0.11, 0.20, 0.21) * sweep * (0.2 + 0.8 * light);
    return saturate(color);
}

inline float3 creativeRisograph(texture2d<float, access::sample> source,
                                float2 uv, float2 size) {
    float registration = max(size.y / 850.0, 0.65);
    float3 coralSample = creativeSample(source, uv + float2(registration, 0.35 * registration) / size);
    float3 tealSample = creativeSample(source, uv + float2(-registration, 0.2 * registration) / size);
    float3 center = creativeSample(source, uv);
    float coral = saturate((coralSample.r - coralSample.g) * 0.95
                           + (1.0 - creativeLuma(coralSample)) * 0.42);
    float teal = saturate(((tealSample.b + tealSample.g) * 0.5 - tealSample.r) * 0.72
                          + (1.0 - creativeLuma(tealSample)) * 0.38);
    float dark = smoothstep(0.15, 0.92, 1.0 - creativeLuma(center)) * 0.88;
    float spacing = max(size.y / 220.0, 2.0);
    float2 pixel = uv * size;
    float coralScreen = creativeDotRank(fract((pixel + float2(registration, 0.0)) / spacing) - 0.5);
    float2 rotated = float2(pixel.x + pixel.y, pixel.y - pixel.x) * 0.7071068;
    float tealScreen = creativeDotRank(fract((rotated - float2(registration, 0.0)) / spacing) - 0.5);
    float aa = min(0.23, 0.65 / spacing);
    float coralInk = coral <= 0.0 ? 0.0 : smoothstep(-aa, aa, coral - coralScreen) * 0.78;
    float tealInk = teal <= 0.0 ? 0.0 : smoothstep(-aa, aa, teal - tealScreen) * 0.75;
    float grain = creativeHash(floor(pixel / max(size.y / 1080.0, 1.0))) - 0.5;
    float3 paper = float3(0.97, 0.925, 0.82) + grain * 0.035;
    // Multiplicative overprints mimic translucent inks, not additive neon light.
    paper *= mix(float3(1.0), float3(0.97, 0.32, 0.28), coralInk);
    paper *= mix(float3(1.0), float3(0.16, 0.63, 0.66), tealInk);
    paper *= mix(float3(1.0), float3(0.16, 0.19, 0.27), dark * (0.94 + grain * 0.12));
    return saturate(paper);
}

inline float3 creativeMedia(texture2d<float, access::sample> source,
                            float2 uv, float2 size, int kind, float time) {
    size = max(size, float2(1.0));
    // The Swift encoder supplies bounded, finite time. Static styles ignore it.
    float phase = time;
    switch (kind) {
        case 6: return creativePointCloud(source, uv, size, phase);
        case 7: return creativeGlitch(source, uv, size, phase);
        case 8: return creativeAnime(source, uv, size);
        case 10: return creativeHalftone(source, uv, size);
        case 11: return creativeBlueprint(source, uv, size);
        case 12: return creativeThermal(source, uv);
        case 13: return creativePixelate(source, uv, size);
        case 14: return creativeHologram(source, uv, size, phase);
        case 15: return creativeRisograph(source, uv, size);
        default: return creativeSample(source, uv);
    }
}

#endif
