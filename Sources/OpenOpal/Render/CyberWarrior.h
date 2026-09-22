#ifndef OPEN_OPAL_CYBER_WARRIOR_H
#define OPEN_OPAL_CYBER_WARRIOR_H

// Convex panels use counterclockwise vertices in face-local coordinates.
// Half-plane distances keep straight armor edges crisp without mesh data.
inline float cyberWarriorPanel(float2 p, float2 a, float2 b, float2 c, float2 d) {
    float ab = -effectCross(b - a, p - a) / max(length(b - a), 1e-5);
    float bc = -effectCross(c - b, p - b) / max(length(c - b), 1e-5);
    float cd = -effectCross(d - c, p - c) / max(length(d - c), 1e-5);
    float da = -effectCross(a - d, p - d) / max(length(a - d), 1e-5);
    return max(max(ab, bc), max(cd, da));
}

inline float3 effectCyberWarrior(float3 color, float2 p, float aa, float strength, float time) {
    if (strength <= 0.0 || abs(p.x) > 0.56 || p.y < -0.25 || p.y > 0.49) return color;
    aa = clamp(aa, 0.0005, 0.025);
    strength = saturate(strength);
    float2 q = float2(abs(p.x), p.y);
    float pulse = 0.92 + 0.08 * sin(time * 1.35);
    float3 cyan = float3(0.10, 0.88, 0.96);
    float3 magenta = float3(0.93, 0.22, 0.69);
    float3 circuitColor = p.x < 0.0 ? cyan : magenta;
    float3 metalDark = float3(0.035, 0.055, 0.085);
    float3 metalLight = float3(0.21, 0.29, 0.36);

    // Separate beveled plates hug the temples and cheekbones. The mouth,
    // central cheeks, lower nose and forehead remain visible between them.
    if (q.x > 0.24) {
        float temple = cyberWarriorPanel(q, float2(0.35, -0.19), float2(0.50, -0.13),
                                        float2(0.49, 0.18), float2(0.35, 0.10));
        float cheek = cyberWarriorPanel(q, float2(0.38, 0.13), float2(0.49, 0.18),
                                       float2(0.38, 0.43), float2(0.27, 0.30));
        float armor = min(temple, cheek);
        float armorMask = effectCoverage(armor, aa);
        effectPaint(color, float3(0.015, 0.025, 0.045), effectCoverage(armor - 0.006, aa), strength);
        float lighting = saturate(0.55 - q.y * 0.55 + (0.46 - q.x) * 1.8);
        effectPaint(color, mix(metalDark, metalLight, lighting), armorMask, strength);
        float bevel = armorMask * (1.0 - effectCoverage(armor + 0.012, aa));
        effectPaint(color, float3(0.34, 0.43, 0.48), bevel * 0.65, strength);

        float templeFacet = effectTriangle(q, float2(0.40, -0.16),
                                           float2(0.49, -0.11), float2(0.43, 0.12));
        effectPaint(color, float3(0.32, 0.39, 0.45),
                    effectCoverage(templeFacet, aa) * armorMask * 0.7, strength);
        float cheekFacet = effectTriangle(q, float2(0.475, 0.195),
                                          float2(0.375, 0.41), float2(0.34, 0.30));
        effectPaint(color, metalDark, effectCoverage(cheekFacet, aa) * armorMask * 0.85, strength);
        float seam = effectSegment(q, float2(0.365, 0.155), float2(0.435, 0.195));
        effectPaint(color, float3(0.012, 0.020, 0.030),
                    effectCoverage(seam - 0.005, aa) * armorMask, strength);

        float templeTrace = min(effectSegment(q, float2(0.455, -0.07), float2(0.43, 0.065)),
                                effectSegment(q, float2(0.43, 0.065), float2(0.39, 0.09)));
        float cheekTrace = min(effectSegment(q, float2(0.425, 0.215), float2(0.385, 0.31)),
                               effectSegment(q, float2(0.385, 0.31), float2(0.345, 0.325)));
        float trace = min(templeTrace, cheekTrace);
        effectPaint(color, circuitColor, effectCoverage(trace - 0.014, aa) * armorMask * 0.22, strength);
        effectPaint(color, circuitColor * pulse,
                    effectCoverage(trace - 0.0035, aa) * armorMask * 0.94, strength);
        float terminal = min(length(q - float2(0.455, -0.07)), length(q - float2(0.345, 0.325)));
        effectPaint(color, float3(0.035, 0.055, 0.07),
                    effectCoverage(terminal - 0.013, aa) * armorMask, strength);
        effectPaint(color, circuitColor * pulse,
                    effectCoverage(abs(terminal - 0.009) - 0.002, aa) * armorMask, strength);

        // Recessed mechanical vents remain matte rather than blinking.
        float vent = min(effectSegment(q, float2(0.464, -0.015), float2(0.478, -0.009)),
                         effectSegment(q, float2(0.461, 0.012), float2(0.475, 0.018)));
        effectPaint(color, metalDark, effectCoverage(vent - 0.0035, aa) * armorMask, strength);
    }

    // Two tapered glass lenses, not a rectangular mask. Each eye is centered
    // near x = +/- 1 / 4.6, so the transparent interiors preserve the gaze.
    if (q.x < 0.45 && p.y > -0.18 && p.y < 0.14) {
        float visor = cyberWarriorPanel(q, float2(0.065, -0.095), float2(0.36, -0.14),
                                       float2(0.42, 0.06), float2(0.10, 0.10));
        float glass = effectCoverage(visor, aa);
        effectPaint(color, float3(0.055, 0.33, 0.40), glass * 0.16, strength);
        effectPaint(color, metalDark, effectCoverage(abs(visor) - 0.006, aa) * 0.85, strength);
        effectPaint(color, mix(cyan, circuitColor, 0.3),
                    effectCoverage(abs(visor) - 0.002, aa) * 0.72, strength);

        float reflection = abs(p.y + 0.06 + q.x * 0.15);
        effectPaint(color, float3(0.66, 0.91, 0.96),
                    effectCoverage(reflection - 0.007, aa) * glass * 0.18, strength);
        float scanY = 0.005 + 0.075 * sin(time * 0.65);
        float scan = effectCoverage(abs(p.y - scanY) - 0.005, aa);
        effectPaint(color, cyan, scan * glass * 0.13, strength);

        // Small side reticles deliberately stay away from the pupil centers.
        float reticle = min(effectSegment(q, float2(0.32, -0.045), float2(0.34, -0.045)),
                            effectSegment(q, float2(0.34, -0.045), float2(0.34, -0.02)));
        effectPaint(color, cyan, effectCoverage(reticle - 0.002, aa) * glass * 0.72, strength);
    }

    // A split bridge and thin nose rails join the lenses without hiding the nose.
    if (q.x < 0.105 && p.y > -0.13 && p.y < 0.185) {
        float bridge = cyberWarriorPanel(q, float2(0.0, -0.105), float2(0.075, -0.07),
                                        float2(0.055, -0.028), float2(0.0, -0.048));
        effectPaint(color, metalDark, effectCoverage(bridge, aa), strength);
        float bridgeEdge = effectSegment(q, float2(0.006, -0.096), float2(0.066, -0.067));
        effectPaint(color, metalLight, effectCoverage(bridgeEdge - 0.004, aa), strength);
        float rail = min(effectSegment(q, float2(0.032, -0.025), float2(0.023, 0.105)),
                         effectSegment(q, float2(0.023, 0.105), float2(0.04, 0.145)));
        effectPaint(color, metalDark, effectCoverage(rail - 0.006, aa) * 0.75, strength);
        effectPaint(color, cyan * pulse, effectCoverage(rail - 0.0015, aa) * 0.65, strength);
        float bridgeLight = effectRoundBox(p - float2(0.0, -0.074), float2(0.014, 0.005), 0.002);
        effectPaint(color, cyan * pulse, effectCoverage(bridgeLight, aa), strength);
    }
    return saturate(color);
}

#endif
