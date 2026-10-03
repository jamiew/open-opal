#ifndef OPENOPAL_PORTRAIT_WARP_H
#define OPENOPAL_PORTRAIT_WARP_H

// Original, single-frame cartoon geometry. These looks do not estimate age or
// gender. Coordinates and radii are in face widths, with y pointing down.
inline float portraitSupport(float2 delta, float2 radii) {
    float2 q = delta / radii;
    float t = saturate(1.0 - dot(q, q));
    // Compact C2 support: value and first two derivatives vanish at the rim.
    return t * t * t * (10.0 + t * (-15.0 + 6.0 * t));
}

inline float2 portraitSourceUV(float2 p, constant CameraEffectUniforms& u) {
    float2 right = u.pose.zw;
    float2 down = float2(-right.y, right.x);
    float2 pixels = (right * p.x + down * p.y) * max(u.dimensions.x, 1.0);
    return clamp(u.pose.xy + pixels / max(u.frame.xy, float2(1.0)),
                 float2(0.0), float2(1.0));
}

inline float3 effectPortraitWarp(texture2d<float, access::sample> source,
                                 float2 uv, constant CameraEffectUniforms& u,
                                 int kind, float strength) {
    // Use the unmodified sampling path for exact zero-strength/outside passthrough.
    constexpr sampler sampleImage(filter::linear, address::clamp_to_edge);
    strength = saturate(strength);
    if (strength <= 0.0 || (kind != 16 && kind != 17)) {
        return source.sample(sampleImage, uv).rgb;
    }
    float width = max(u.dimensions.x, 1.0);
    float height = clamp(u.dimensions.y / width, 0.95, 1.6);
    float2 p = effectLocal(uv, u);
    float faceRadius = length((p - float2(0.0, height * 0.16))
                             / float2(0.47, height * 0.43));
    if (faceRadius >= 1.0) return source.sample(sampleImage, uv).rgb;
    float face = 1.0 - smoothstep(0.78, 1.0, faceRadius);
    float amount = strength * face;
    float eyeHalf = clamp(u.dimensions.z / width * 0.5, 0.14, 0.29);
    float2 nose = effectLocal(u.features.xy, u);
    float2 mouth = effectLocal(u.features.zw, u);
    float mouthRadius = clamp(u.dimensions.w / width * 0.68, 0.12, 0.27);
    float mouthDetail = smoothstep(0.75, 1.25,
        length((p - mouth) / float2(mouthRadius, 0.10)));
    bool anime = kind == 17;
    float2 eyeRadii = anime ? float2(0.235, 0.20) : float2(0.215, 0.17);
    float2 eyeScale = anime ? float2(0.36, 0.44) : float2(0.27, 0.32);
    float2 displacement = float2(0.0);
    for (int side = -1; side <= 1; side += 2) {
        float2 eyeDelta = p - float2(float(side) * eyeHalf, 0.0);
        // Inverse mapping pulls samples inward, enlarging the real eye instead
        // of painting a replacement. Both eyes retain their original centers.
        displacement -= eyeDelta * eyeScale * portraitSupport(eyeDelta, eyeRadii);
    }

    float2 cheekRadii = float2(0.19, 0.20);
    float cheekY = mix(nose.y, mouth.y, 0.45);
    float cheekX = nose.x * 0.3;
    float blush = 0.0;
    for (int side = -1; side <= 1; side += 2) {
        float2 cheek = float2(cheekX + float(side) * 0.275, cheekY);
        float2 cheekDelta = p - cheek;
        float support = portraitSupport(cheekDelta, cheekRadii);
        blush += portraitSupport(cheekDelta, float2(0.135, 0.095));
        if (!anime) displacement -= cheekDelta * float2(0.16, 0.09) * support;
    }
    float2 noseDelta = p - nose;
    displacement += noseDelta * (anime ? 0.10 : 0.23)
                  * portraitSupport(noseDelta, float2(0.14, 0.18));

    // Strength changes only the inverse map, never a blend of displaced faces.
    // A protected mouth and feathered face rim also gate the geometry itself.
    float2 sourcePoint = p + displacement * (amount * mouthDetail);
    float2 sourceUV = portraitSourceUV(sourcePoint, u);
    float3 color = creativeSample(source, sourceUV);
    if (anime) {
        // Cel shading and ink use the SAME displaced position as the base color.
        // Unlike Anime Ink this leaves the rest of the image completely intact.
        float3 cel = creativeAnime(source, sourceUV, max(u.frame.xy, float2(1.0)));
        color = mix(color, cel, amount * 0.48);
    } else {
        // Conservative joint-bilateral softening. Work only in skin regions;
        // exclude the enlarged eyes, lips and nose in source coordinates so
        // displaced lashes and nostrils cannot acquire a second blurred image.
        float2 eyePoint = float2(abs(sourcePoint.x) - eyeHalf, sourcePoint.y + 0.02);
        float skin = smoothstep(0.85, 1.35, length(eyePoint / float2(0.14, 0.105)));
        skin *= smoothstep(0.8, 1.3,
            length((sourcePoint - mouth) / float2(mouthRadius, 0.105)));
        skin *= smoothstep(0.65, 1.2,
            length((sourcePoint - nose) / float2(0.12, 0.13)));
        skin *= amount;
        if (skin > 0.001) {
            float spacing = clamp(width * 0.005, 1.0, 2.5);
            float2 step = spacing / max(u.frame.xy, float2(1.0));
            float3 sum = color * 2.0;
            float weights = 2.0;
            for (int y = -1; y <= 1; ++y) {
                for (int x = -1; x <= 1; ++x) {
                    if (x == 0 && y == 0) continue;
                    float3 sample = creativeSample(source, sourceUV + float2(x, y) * step);
                    float3 delta = sample - color;
                    float spatial = (x == 0 || y == 0) ? 1.0 : 0.7071;
                    float weight = spatial * exp(-dot(delta, delta) * 90.0);
                    sum += sample * weight;
                    weights += weight;
                }
            }
            color = mix(color, sum / weights, skin * 0.24);
        }
    }
    // A small tint, not a skin-color replacement or global brightening pass.
    color += float3(0.055, -0.016, 0.012)
           * (saturate(blush) * amount * mouthDetail * (anime ? 0.65 : 1.0));
    return saturate(color);
}

#endif
