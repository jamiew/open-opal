#include <metal_stdlib>
using namespace metal;

// Original procedural artwork. All distances are in units of face width, in
// a pixel-aspect-correct coordinate frame whose origin is between the eyes.
struct CameraEffectUniforms {
    float4 frame;
    float4 pose;
    float4 features;
    float4 dimensions;
    float4 visibility;
};

inline float effectCoverage(float distance, float aa) {
    return 1.0 - smoothstep(-aa, aa, distance);
}

inline float effectSegment(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    return length(p - a - ab * saturate(dot(p - a, ab) / max(dot(ab, ab), 1e-6)));
}

inline float effectCross(float2 a, float2 b) {
    return a.x * b.y - a.y * b.x;
}

inline float effectTriangle(float2 p, float2 a, float2 b, float2 c) {
    float d = min(effectSegment(p, a, b),
                  min(effectSegment(p, b, c), effectSegment(p, c, a)));
    float s0 = effectCross(b - a, p - a);
    float s1 = effectCross(c - b, p - b);
    float s2 = effectCross(a - c, p - c);
    bool inside = (s0 >= 0 && s1 >= 0 && s2 >= 0) ||
                  (s0 <= 0 && s1 <= 0 && s2 <= 0);
    return inside ? -d : d;
}

inline float effectEllipse(float2 p, float2 radii) {
    return (length(p / radii) - 1.0) * min(radii.x, radii.y);
}

inline float effectRoundBox(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

inline float2 effectLocal(float2 uv, constant CameraEffectUniforms& u) {
    float2 pixels = (uv - u.pose.xy) * u.frame.xy;
    float2 right = u.pose.zw;
    float2 down = float2(-right.y, right.x);
    return float2(dot(pixels, right), dot(pixels, down)) / max(u.dimensions.x, 1.0);
}

inline void effectPaint(thread float3& color, float3 paint, float alpha, float strength) {
    color = mix(color, paint, saturate(alpha * strength));
}

inline float3 effectCowboy(float3 color, float2 p, float aa, float strength) {
    if (abs(p.x) > 0.94 || p.y < -1.1 || p.y > -0.20) return color;
    float3 outline = float3(0.14, 0.075, 0.045);
    // The brim curls upward at both ends, with a separate front lip.
    float2 brimPoint = p - float2(0.0, -0.40);
    brimPoint.y += 0.13 * pow(abs(brimPoint.x) / 0.88, 3.0);
    float brim = effectEllipse(brimPoint, float2(0.88, 0.12));
    effectPaint(color, outline, effectCoverage(brim, aa), strength);
    float brimFill = effectCoverage(brim + 0.016, aa);
    float3 felt = mix(float3(0.46, 0.25, 0.105), float3(0.78, 0.52, 0.24),
                      saturate(0.6 - brimPoint.y * 3.0));
    effectPaint(color, felt, brimFill, strength);

    // Tapered crown with a shallow center crease, rather than a flat rectangle.
    float top = saturate((-p.y - 0.45) / 0.57);
    float halfWidth = mix(0.48, 0.35, top);
    float2 crownPoint = float2(p.x, p.y + 0.72);
    crownPoint.y -= 0.045 * exp(-p.x * p.x / 0.018) * top;
    float crown = effectRoundBox(crownPoint, float2(halfWidth, 0.29), 0.085);
    effectPaint(color, outline, effectCoverage(crown, aa), strength);
    float fill = effectCoverage(crown + 0.016, aa);
    float light = saturate(0.7 - p.x * 0.38 + p.y * 0.08);
    float3 crownColor = mix(float3(0.51, 0.29, 0.12), float3(0.83, 0.59, 0.30), light);
    float crease = exp(-pow((abs(p.x) - 0.24) / 0.032, 2.0)) * top * 0.15;
    effectPaint(color, crownColor * (1.0 - crease), fill, strength);
    float band = effectCoverage(abs(p.y + 0.49) - 0.048, aa) * fill;
    effectPaint(color, float3(0.22, 0.105, 0.058), band, strength);
    float buckle = effectRoundBox(p - float2(0, -0.49), float2(0.067, 0.048), 0.011);
    effectPaint(color, float3(0.92, 0.70, 0.30), effectCoverage(buckle, aa) * fill, strength);
    effectPaint(color, float3(0.27, 0.135, 0.065),
                effectCoverage(buckle + 0.014, aa) * fill, strength);
    return color;
}

inline float3 effectCat(float3 color, float2 p, float2 nose, float aa, float strength) {
    float3 fur = float3(0.32, 0.22, 0.19);
    float3 edge = float3(0.095, 0.065, 0.075);
    if (p.y < -0.20 && p.y > -0.92 && abs(p.x) < 0.66) {
        float2 earPoint = float2(abs(p.x), p.y);
        float ear = effectTriangle(earPoint, float2(0.17, -0.29),
                                   float2(0.32, -0.88), float2(0.63, -0.36));
        effectPaint(color, edge, effectCoverage(ear, aa), strength);
        float3 coat = mix(fur, float3(0.59, 0.43, 0.33), saturate(-p.y - 0.15));
        effectPaint(color, coat, effectCoverage(ear + 0.022, aa), strength);
        float inner = effectTriangle(earPoint, float2(0.27, -0.36),
                                     float2(0.33, -0.73), float2(0.52, -0.40));
        effectPaint(color, float3(0.90, 0.57, 0.61), effectCoverage(inner, aa), strength);
        float innerShade = effectSegment(earPoint, float2(0.33, -0.67), float2(0.37, -0.40));
        effectPaint(color, float3(0.66, 0.34, 0.40),
                    effectCoverage(innerShade - 0.015, aa) * effectCoverage(inner, aa), strength * 0.45);
    }

    float2 muzzle = p - nose;
    if (abs(muzzle.x) < 0.56 && abs(muzzle.y) < 0.20) {
        float2 side = float2(abs(muzzle.x), muzzle.y);
        float whisker = 1.0;
        for (int row = -1; row <= 1; ++row) {
            float r = float(row);
            float2 a = float2(0.115, 0.014 + r * 0.028);
            float2 b = float2(0.30, 0.01 + r * 0.075);
            float2 c = float2(0.51, 0.015 + r * 0.13);
            whisker = min(whisker, min(effectSegment(side, a, b), effectSegment(side, b, c)));
        }
        // Light rim + dark core keep fine whiskers legible on any skin tone.
        effectPaint(color, float3(0.91, 0.84, 0.75), effectCoverage(whisker - 0.012, aa), strength * 0.8);
        effectPaint(color, edge, effectCoverage(whisker - 0.0055, aa), strength);
        float noseShape = effectTriangle(muzzle, float2(-0.085, -0.028),
                                         float2(0.085, -0.028), float2(0, 0.075));
        effectPaint(color, edge, effectCoverage(noseShape - 0.007, aa), strength);
        effectPaint(color, float3(0.91, 0.48, 0.56), effectCoverage(noseShape + 0.006, aa), strength);
        float shine = effectEllipse(muzzle - float2(-0.025, -0.012), float2(0.025, 0.009));
        effectPaint(color, float3(1.0, 0.78, 0.81), effectCoverage(shine, aa), strength * 0.8);
        float mouth = min(effectSegment(muzzle, float2(0, 0.070), float2(0, 0.12)),
                          effectSegment(side, float2(0, 0.12), float2(0.075, 0.10)));
        effectPaint(color, edge, effectCoverage(mouth - 0.005, aa), strength * 0.85);
    }
    return color;
}

#include "CreativeMedia.h"
#include "CyberWarrior.h"
#include "PortraitWarp.h"
#include "PortraitAccessories.h"

kernel void camera_effect(texture2d<float, access::sample> source [[texture(0)]],
                          texture2d<float, access::write> destination [[texture(1)]],
                          constant CameraEffectUniforms& u [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) return;
    constexpr sampler sampleImage(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / u.frame.xy;
    float3 original = source.sample(sampleImage, uv).rgb;
    float3 color = original;
    float strength = saturate(u.frame.z);
    int kind = int(u.frame.w);
    if (kind == 4) {
        float gray = dot(original, float3(0.2126, 0.7152, 0.0722));
        color = mix(original, float3(gray), strength);
    } else if (kind == 5) {
        float3 warm = saturate(original * float3(1.035, 1.008, 0.96) + float3(0.018, 0.007, -0.006));
        color = mix(original, warm, strength);
    } else if (((kind >= 1 && kind <= 3) || kind == 9) && u.visibility.x > 0.0) {
        float2 p = effectLocal(uv, u);
        float2 nose = effectLocal(u.features.xy, u);
        float aa = max(0.75 / max(u.dimensions.x, 1.0), 0.0005);
        strength *= u.visibility.x;
        if (kind == 1) {
            color = effectCowboy(original, p, aa, strength);
        } else if (kind == 2) {
            color = effectCat(original, p, nose, aa, strength);
        } else if (kind == 9) {
            color = effectCyberWarrior(original, p, aa, strength, u.visibility.y);
        } else {
            // Small joint-bilateral skin softening, confined to a feathered face
            // oval. Eye/brow, mouth and nose detail are explicitly protected;
            // range weights additionally reject strong edges and facial hair.
            float height = clamp(u.dimensions.y / max(u.dimensions.x, 1.0), 0.95, 1.6);
            float mask = 1.0 - smoothstep(0.78, 1.0,
                length((p - float2(0, height * 0.16)) / float2(0.45, height * 0.46)));
            float eyeX = u.dimensions.z / max(u.dimensions.x, 1.0) * 0.5;
            float2 eyePoint = float2(abs(p.x) - eyeX, p.y + 0.025);
            mask *= smoothstep(0.8, 1.3, length(eyePoint / float2(0.135, 0.10)));
            float2 mouth = effectLocal(u.features.zw, u);
            float mouthRadius = max(u.dimensions.w / max(u.dimensions.x, 1.0) * 0.65, 0.12);
            mask *= smoothstep(0.85, 1.35, length((p - mouth) / float2(mouthRadius, 0.10)));
            mask *= smoothstep(0.65, 1.15, length((p - nose) / float2(0.12, 0.12)));
            if (mask > 0.001) {
                float spacing = clamp(u.dimensions.x * 0.004, 1.0, 3.0);
                float3 sum = original;
                float weights = 1.0;
                for (int y = -2; y <= 2; ++y) {
                    for (int x = -2; x <= 2; ++x) {
                        if (x == 0 && y == 0) continue;
                        float2 offset = float2(x, y) * spacing / u.frame.xy;
                        float3 sample = source.sample(sampleImage, uv + offset).rgb;
                        float3 delta = sample - original;
                        float weight = exp(-float(x * x + y * y) / 5.0 - dot(delta, delta) * 95.0);
                        sum += sample * weight;
                        weights += weight;
                    }
                }
                float3 softened = sum / weights;
                color = mix(original, softened, mask * strength * 0.38);
                color += (1.0 - color) * (0.012 * mask * strength);
            }
        }
    }
    if (kind >= 6 && kind <= 15 && kind != 9) {
        color = mix(original, creativeMedia(source, uv, u.frame.xy, kind, u.visibility.y), strength);
    }
    if (kind >= 16 && kind <= 21 && u.visibility.x > 0.0) {
        float portraitStrength = strength * u.visibility.x;
        if (kind == 16 || kind == 17) {
            color = effectPortraitWarp(source, uv, u, kind, portraitStrength);
        } else {
            color = effectPortraitAccessory(original, uv, u, kind == 21 ? 18 : kind, portraitStrength);
            if (kind == 21) {
                float aa = max(0.75 / max(u.dimensions.x, 1.0), 0.0005);
                color = effectCowboy(color, effectLocal(uv, u), aa, portraitStrength);
            }
        }
    }
    // Texture format performs BGRA storage swizzling; shader values remain RGB.
    destination.write(float4(saturate(color), 1.0), gid);
}
