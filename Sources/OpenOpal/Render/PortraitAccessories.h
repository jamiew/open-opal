#ifndef OPEN_OPAL_PORTRAIT_ACCESSORIES_H
#define OPEN_OPAL_PORTRAIT_ACCESSORIES_H

// Original illustrated accessories in the eye-aligned, face-width coordinate
// frame. Geometry follows landmarks, not inferred gender or hair segmentation.
inline float3 effectPortraitBeard(float3 color, float2 p, float2 nose, float2 mouth,
                                 float height, float mouthWidth, float aa, float strength) {
    if (abs(p.x) > 0.65 || p.y < -0.10 || p.y > mouth.y + 0.48 * height) return color;
    float2 q = p - float2(mouth.x * 0.45, mouth.y);
    float2 side = float2(abs(q.x), q.y);
    float chin = effectEllipse(q - float2(0.0, 0.06 * height), float2(0.455, 0.33 * height));
    // A rising cheek line joins the sideburns while leaving central cheeks bare.
    float cheekLine = -0.035 * height - 0.47 * side.x;
    float body = max(chin, cheekLine - q.y);
    float sideburn = effectSegment(float2(abs(p.x), p.y), float2(0.43, 0.035),
                                  float2(0.40, mouth.y + 0.06 * height)) - 0.052;
    body = min(body, sideburn);

    // Two sloping moustache wings follow the nose-to-mouth gap. The opening
    // below is subtracted from every layer, including these wings and strands.
    float moustacheY = mix(nose.y, mouth.y, 0.65);
    float moustacheX = mix(nose.x, mouth.x, 0.65);
    float2 m = float2(abs(p.x - moustacheX), p.y - moustacheY);
    m.y -= 0.30 * m.x;
    float wingWidth = clamp(mouthWidth * 0.48, 0.10, 0.20);
    float moustache = effectEllipse(m - float2(wingWidth * 0.70, 0.0),
                                   float2(wingWidth, 0.049 * height));
    float silhouette = min(body, moustache);
    float mouthOpening = effectEllipse(p - mouth,
        float2(max(mouthWidth * 0.64 + 0.022, 0.13), max(0.075, 0.073 * height)));
    float outsideMouth = 1.0 - effectCoverage(mouthOpening - aa, aa);
    float mask = effectCoverage(silhouette, aa) * outsideMouth;
    float fill = effectCoverage(silhouette + 0.012, aa) * outsideMouth;
    float3 dark = float3(0.105, 0.047, 0.026);
    effectPaint(color, dark, mask, strength);
    float warmth = saturate(0.72 - side.x * 1.0 - q.y * 0.34 / height);
    float3 brown = mix(float3(0.20, 0.082, 0.038), float3(0.43, 0.225, 0.102), warmth);
    effectPaint(color, brown, fill, strength);

    // Sparse curved fibers give the shaped beard volume without noisy stubble.
    float strands = 1.0;
    float gleam = 1.0;
    for (int i = 0; i < 6; ++i) {
        float x = 0.047 + float(i) * 0.066;
        float t = saturate((q.y + 0.18 * height) / (0.58 * height));
        float curve = x * (1.0 - 0.24 * t) + 0.011 * sin(t * 7.0 + float(i));
        float distance = abs(side.x - curve) / 1.08;
        strands = min(strands, distance - 0.0035);
        gleam = min(gleam, abs(side.x - curve - 0.013) / 1.08 - 0.003);
    }
    float beardFill = effectCoverage(body + 0.016, aa) * outsideMouth;
    effectPaint(color, dark, effectCoverage(strands, aa) * beardFill * 0.55, strength);
    effectPaint(color, float3(0.58, 0.33, 0.16),
                effectCoverage(gleam, aa) * beardFill * 0.40, strength);
    float moustacheFill = effectCoverage(moustache + 0.010, aa) * outsideMouth;
    float sweep = abs(m.y + 0.010 * height) - 0.0035;
    effectPaint(color, float3(0.57, 0.31, 0.135),
                effectCoverage(sweep, aa) * moustacheFill * 0.60, strength);
    return color;
}

inline float3 effectPortraitHair(float3 color, float2 p, float height, float aa, float strength) {
    // Long locks extend beyond the chin, but the remainder of the frame is exact
    // passthrough. Scaling y alone keeps the eye-axis alignment and face width.
    float2 q = float2(p.x, p.y / height);
    if (abs(q.x) > 0.79 || q.y < -0.88 || q.y > 1.26) return color;
    float hairAA = aa / max(height, 1.0);
    float sideSign = q.x < 0.0 ? -1.0 : 1.0;
    float side = abs(q.x);
    float wave = 0.040 * sin(q.y * 7.0 + sideSign * 0.4)
               + 0.019 * sin(q.y * 13.0 - sideSign * 0.7);
    float lockCenter = 0.545 + wave;
    float taper = saturate((q.y + 0.15) / 1.36);
    float lockWidth = mix(0.148, 0.077, taper);
    float lock = effectEllipse(float2(side - lockCenter, q.y - 0.32),
                               float2(lockWidth, 0.88));
    float crown = effectEllipse(q - float2(-0.015, -0.34), float2(0.615, 0.48));
    float silhouette = min(crown, lock);

    // An asymmetrical swept hairline and a continuous face opening, rather
    // than an opaque cap across the face. Central eyes, nose and lips stay clear.
    float2 openingPoint = q - float2(0.0, 0.13);
    openingPoint.y -= 0.055 * sin(q.x * 8.0);
    float opening = effectEllipse(openingPoint, float2(0.438, 0.595));
    float lowerOpening = max(0.725 - q.y, side - 0.365);
    opening = min(opening, lowerOpening);
    float outsideFace = 1.0 - effectCoverage(opening - hairAA, hairAA);
    float mask = effectCoverage(silhouette, hairAA) * outsideFace;
    float fill = effectCoverage(silhouette + 0.014, hairAA) * outsideFace;
    float3 dark = float3(0.115, 0.050, 0.030);
    effectPaint(color, dark, mask, strength);
    float lighting = saturate(0.65 - q.x * 0.35 - q.y * 0.13
                              + 0.12 * cos((side - lockCenter) * 20.0));
    float3 chestnut = mix(float3(0.245, 0.100, 0.050), float3(0.56, 0.30, 0.135), lighting);
    effectPaint(color, chestnut, fill, strength);

    // Broad caramel ribbons ride the same waves as the silhouette. A handful
    // of finer contours separate overlapping locks and preserve a drawn look.
    float sideRegion = smoothstep(-0.42, -0.10, q.y);
    float ribbon = abs(side - lockCenter + 0.035) / 1.12 - 0.022;
    effectPaint(color, float3(0.72, 0.435, 0.215),
                effectCoverage(ribbon, hairAA) * fill * sideRegion * 0.72, strength);
    float contours = 1.0;
    float fineLight = 1.0;
    for (int i = 0; i < 4; ++i) {
        float offset = (float(i) - 1.5) * 0.046 * (1.0 - 0.35 * taper);
        contours = min(contours, abs(side - lockCenter - offset) / 1.12 - 0.0035);
        fineLight = min(fineLight, abs(side - lockCenter - offset - 0.012) / 1.12 - 0.0025);
    }
    effectPaint(color, dark, effectCoverage(contours, hairAA) * fill * sideRegion * 0.62, strength);
    effectPaint(color, float3(0.82, 0.55, 0.285),
                effectCoverage(fineLight, hairAA) * fill * sideRegion * 0.46, strength);

    // Off-center part with swept crown arcs. These are clipped to hair so the
    // fringe can frame the forehead without painting into the face opening.
    float2 crownPoint = q - float2(-0.095, -0.24);
    float arcs = 1.0;
    float crownShine = 1.0;
    for (int i = 0; i < 4; ++i) {
        float radius = 0.25 + float(i) * 0.080;
        float arc = effectEllipse(crownPoint, float2(radius * 1.18, radius));
        arcs = min(arcs, abs(arc) - 0.0035);
        crownShine = min(crownShine, abs(arc + 0.018) - 0.008);
    }
    float crownRegion = 1.0 - smoothstep(-0.32, -0.10, q.y);
    effectPaint(color, dark, effectCoverage(arcs, hairAA) * fill * crownRegion * 0.55, strength);
    effectPaint(color, float3(0.73, 0.44, 0.215),
                effectCoverage(crownShine, hairAA) * fill * crownRegion * 0.60, strength);
    float part = effectSegment(q, float2(-0.105, -0.790), float2(-0.072, -0.480));
    effectPaint(color, dark, effectCoverage(part - 0.011, hairAA) * fill, strength);
    effectPaint(color, float3(0.78, 0.53, 0.33),
                effectCoverage(part - 0.003, hairAA) * fill * 0.75, strength);
    return color;
}

inline float3 effectPortraitSunglasses(float3 color, float2 p, float eyeDistance,
                                      float aa, float strength) {
    if (abs(p.x) > 0.61 || p.y < -0.22 || p.y > 0.23) return color;
    float eyeX = eyeDistance * 0.5;
    float halfWidth = clamp(eyeDistance * 0.41, 0.13, 0.205);
    float halfHeight = halfWidth * 0.70;
    float2 q = float2(abs(p.x), p.y);
    float2 lensPoint = q - float2(eyeX, 0.008);
    lensPoint.y -= 0.09 * lensPoint.x;
    // The top is slightly wider than the bottom, with lifted outer corners.
    float width = halfWidth - 0.16 * max(lensPoint.y, 0.0);
    float lens = effectRoundBox(lensPoint, float2(width, halfHeight), 0.052);
    float3 frame = float3(0.028, 0.025, 0.025);
    float3 metal = float3(0.68, 0.48, 0.25);
    float temple = effectSegment(q, float2(eyeX + halfWidth - 0.025, -0.045),
                                float2(0.535, -0.064));
    effectPaint(color, frame, effectCoverage(temple - 0.025, aa), strength);
    effectPaint(color, metal, effectCoverage(temple - 0.006, aa) * 0.78, strength);
    float bridgeHalfWidth = max(eyeX - halfWidth + 0.038, 0.050);
    float bridgeY = -0.012 - 0.038 * (1.0 - pow(p.x / bridgeHalfWidth, 2.0));
    float bridge = max(abs(p.y - bridgeY) / 1.5 - 0.010, abs(p.x) - bridgeHalfWidth);
    effectPaint(color, frame, effectCoverage(bridge - 0.006, aa), strength);
    effectPaint(color, metal, effectCoverage(bridge, aa), strength);

    effectPaint(color, frame, effectCoverage(lens - 0.012, aa), strength);
    float rim = effectCoverage(lens, aa);
    effectPaint(color, metal, rim, strength);
    float glass = effectCoverage(lens + 0.012, aa);
    float lowerLight = saturate(lensPoint.y / (halfHeight * 2.0) + 0.5);
    float3 tint = mix(float3(0.023, 0.044, 0.062), float3(0.10, 0.16, 0.18), lowerLight);
    effectPaint(color, tint, glass, strength);
    float reflection = abs(lensPoint.x + 0.58 * lensPoint.y + 0.055) / 1.156 - 0.017;
    float reflectionFine = abs(lensPoint.x + 0.58 * lensPoint.y - 0.003) / 1.156 - 0.004;
    effectPaint(color, float3(0.62, 0.79, 0.81),
                effectCoverage(reflection, aa) * glass * 0.32, strength);
    effectPaint(color, float3(0.83, 0.92, 0.90),
                effectCoverage(reflectionFine, aa) * glass * 0.36, strength);
    float upperRim = effectCoverage(abs(lens + 0.004) - 0.003, aa)
                   * (1.0 - smoothstep(-0.02, 0.025, lensPoint.y));
    effectPaint(color, float3(0.92, 0.74, 0.46), upperRim * 0.78, strength);
    float rivet = length(q - float2(eyeX + halfWidth - 0.028, -0.063));
    effectPaint(color, float3(0.95, 0.84, 0.61), effectCoverage(rivet - 0.009, aa), strength);
    return color;
}

inline float3 effectPortraitAccessory(float3 color, float2 uv, constant CameraEffectUniforms& u,
                                     int kind, float strength) {
    if (strength <= 0.0) return color;
    float2 p = effectLocal(uv, u);
    float width = max(u.dimensions.x, 1.0);
    float height = clamp(u.dimensions.y / width, 0.90, 1.70);
    float aa = clamp(0.75 / width, 0.0005, 0.025);
    strength = saturate(strength);
    if (kind == 18) {
        float2 nose = effectLocal(u.features.xy, u);
        float2 mouth = effectLocal(u.features.zw, u);
        return effectPortraitBeard(color, p, nose, mouth, height,
                                   clamp(u.dimensions.w / width, 0.14, 0.48), aa, strength);
    }
    if (kind == 19) return effectPortraitHair(color, p, height, aa, strength);
    if (kind == 20) return effectPortraitSunglasses(color, p,
        clamp(u.dimensions.z / width, 0.34, 0.54), aa, strength);
    return color;
}

#endif
