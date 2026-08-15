#include <flutter/runtime_effect.glsl>

precision highp float;

// --- Standard uniforms ---
uniform vec2 uResolution;    // index 0-1
uniform float uTime;         // index 2

// --- Custom uniforms ---
uniform float uColorCount;   // index 3, number of palette colors (2..6)
uniform vec4 uColors[6];     // index 4-27, palette colors (rgb used, a=weight)
uniform float uParams[9];    // index 28-36:
//   [0]=speed [1]=noiseScale [2]=turbulence [3]=warping
//   [4]=deformSpeed [5]=presence [6]=uniformity [7]=smoothness [8]=darkness

out vec4 fragColor;

const float PI = 3.14159265359;

// --- Value noise (2D) ---
// Mediump-safe hash: small multipliers keep precision on mobile GPUs (Mali).
float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);

    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// FBM: layered noise for organic detail. 2 octaves: lighter on mobile GPUs,
// avoids the frame drops (BLASTBufferQueue) seen with 3 octaves.
float fbm(vec2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 2; i++) {
        value += amplitude * noise(p);
        p *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

// Sample the palette at normalized height h in [0,1] (piecewise-linear).
// Branch-per-segment: dynamic array indexing is unreliable on mobile GLES.
vec3 samplePalette(float h) {
    h = fract(h);
    float n = uColorCount;

    // 6 colors max: uColors[0..5]. Branch by count to keep indices constant.
    float w = h * 6.0;
    int seg = int(floor(w));
    float f = fract(w);

    if (n <= 2.0) {
        // 2 colors: segments 0,3 -> c0; 1,4 -> lerp; 2,5 -> c1
        if (seg == 0 || seg == 3) return uColors[0].rgb;
        if (seg == 2 || seg == 5) return uColors[1].rgb;
        return mix(uColors[0].rgb, uColors[1].rgb, f);
    } else if (n <= 3.0) {
        if (seg == 0 || seg == 2 || seg == 4) return uColors[0].rgb;
        if (seg == 3 || seg == 5) return uColors[2].rgb;
        if (seg == 1) return mix(uColors[0].rgb, uColors[1].rgb, f);
        return mix(uColors[1].rgb, uColors[2].rgb, f);
    } else if (n <= 4.0) {
        if (seg == 0 || seg == 4) return uColors[0].rgb;
        if (seg == 1) return mix(uColors[0].rgb, uColors[1].rgb, f);
        if (seg == 2) return mix(uColors[1].rgb, uColors[2].rgb, f);
        if (seg == 3) return mix(uColors[2].rgb, uColors[3].rgb, f);
        return mix(uColors[3].rgb, uColors[0].rgb, f);
    } else if (n <= 5.0) {
        if (seg == 0) return mix(uColors[0].rgb, uColors[1].rgb, f);
        if (seg == 1) return mix(uColors[1].rgb, uColors[2].rgb, f);
        if (seg == 2) return mix(uColors[2].rgb, uColors[3].rgb, f);
        if (seg == 3) return mix(uColors[3].rgb, uColors[4].rgb, f);
        if (seg == 4) return mix(uColors[4].rgb, uColors[0].rgb, f);
        return mix(uColors[0].rgb, uColors[1].rgb, f);
    } else {
        // 6 colors: each segment maps directly.
        if (seg == 0) return mix(uColors[0].rgb, uColors[1].rgb, f);
        if (seg == 1) return mix(uColors[1].rgb, uColors[2].rgb, f);
        if (seg == 2) return mix(uColors[2].rgb, uColors[3].rgb, f);
        if (seg == 3) return mix(uColors[3].rgb, uColors[4].rgb, f);
        if (seg == 4) return mix(uColors[4].rgb, uColors[5].rgb, f);
        return mix(uColors[5].rgb, uColors[0].rgb, f);
    }
}

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 uv = fragCoord / uResolution;

    float t = uTime * uParams[0];

    // Aspect-correct coordinates so blobs stay round.
    float aspect = uResolution.x / uResolution.y;
    vec2 p = vec2(uv.x * aspect, uv.y) * uParams[1];

    // Terrain deformation: noise field evolves over time.
    float deformT = t * uParams[4];
    vec2 pDeformed = p + vec2(
        noise(p + vec2(deformT, 0.0)),
        noise(p + vec2(0.0, deformT))
    ) * 0.3;

    // Global drift (visible motion).
    pDeformed += vec2(t * 0.18, t * 0.12);

    // Domain warping with turbulence (single pass: lighter on mobile GPUs).
    vec2 q = vec2(
        fbm(pDeformed + vec2(0.0, 0.0) + deformT * uParams[2]),
        fbm(pDeformed + vec2(5.2, 1.3) + deformT * uParams[2])
    );
    float h = fbm(pDeformed + uParams[3] * q);

    // Height mapping: cycle through palette for richer colors.
    h = fract(h * uParams[5] * 0.5 + 0.5);

    // Terrain reshaping: pull mid-values toward extremes for defined regions.
    float centered = 2.0 * h - 1.0;
    float sCurved = 0.5 + 0.5 * pow(abs(centered), uParams[6]) * sign(centered);
    float smoothed = smoothstep(-0.1, 1.1, sCurved);
    h = mix(sCurved, smoothed, uParams[7]);

    // Palette sampling.
    vec3 color = samplePalette(h);

    // Background blend: dark base always (player page convention).
    vec3 base = vec3(0.02, 0.02, 0.04);
    // Keep colors visible but not overpowering content.
    float amount = 0.85;
    // Aspect-independent edge vignette: corner distance is always 1.
    vec2 center = uv - vec2(0.5);
    float dist = length(center) / 0.7071;
    amount *= 1.0 - smoothstep(0.55, 1.1, dist) * 0.4;

    color = mix(base, color, clamp(amount, 0.0, 1.0));

    fragColor = vec4(color, 1.0);
}
