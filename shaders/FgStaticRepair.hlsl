// FgStaticRepair: experimental repair of a generated frame where both real frames agree
// (VEYRA_TEST_FG_STATIC_REPAIR=1; 2 also tints the result for inspection: pink = repaired,
// cyan = static evidence but left alone as a thin object over a plain area).
//
// On 30 fps capture a camera turn moves the background far between two real frames while
// a third-person character stays almost still on screen. Interpolators (FSR, RIFE, AMD
// FRC were all observed doing it) then draw background over parts of the character's
// outline. Here a pixel whose neighbourhood is nearly identical in the previous and the
// current real frame, but clearly different in the generated frame, takes the average of
// the two real frames instead.
//
// The same test also fires on a thin scene detail crossing a self-similar surface (a lane
// line on asphalt, a pole or wire against the sky, a shadow edge): both real frames show
// the plain surface where the generated frame correctly draws the detail. The first two
// versions removed such details from generated frames on real capture. Two further tests
// with the frame-generation motion (current->previous pixels) of the pixel and of eight
// neighbours now gate the repair:
//  - the content at the pixel must not be explainable as moving background: with that
//    motion, the previous frame there must differ from the current one (asphalt and sky
//    look the same along the motion and never pass; a character's outline does);
//  - the generated content must not be explained by both real frames along a motion
//    (a correctly interpolated detail is: it is in the previous frame half a motion one
//    way and in the current frame half a motion the other way).
//
// With VEYRA_TEST_FG_PAIR_CHECK=1 the pass also reads FgPairChange.hlsl's block errors:
// where the previous frame's content has no match in the current one (a cut, a body
// sweeping past the camera), the generated frame shows the current real frame instead of
// a blend of two unrelated pictures (tinted yellow in the inspection view).
//
// Known limits: nothing is repaired where no nearby motion is known, or where the static
// part is narrower than the motion (the background really passes behind it in both frames).
Texture2D<float4> generatedTex : register(t0);
Texture2D<float4> currentTex : register(t1);    // newer real frame
Texture2D<float4> previousTex : register(t2);   // older real frame
Texture2D<float> pairErrorTex : register(t3);   // 16 x 8 best-match errors (FgPairChange)
Texture2D<float2> motionTex : register(t4);     // work extent, current->previous pixels
RWTexture2D<float4> outputTex : register(u0);

cbuffer FgStaticRepairConstants : register(b0)
{
    uint width;
    uint height;
    uint spacing;      // tap spacing in pixels (3x3 taps); motion candidates 15 spacings away
    uint debugView;    // 1: tint the result
    float repairOn;    // 1: static repair (thresholds live below while being tuned)
    float pairOn;      // 1: show the current real frame where the pair has no match
    float unused2;
    float unused3;
};

// SDR code values.
static const float kStaticLow = 0.03;    // real-frame difference up to this is fully static
static const float kStaticHigh = 0.08;   // from this on the pixel is moving: untouched
static const float kDifferLow = 0.025;   // generated-frame deviation where the repair starts
static const float kDifferHigh = 0.07;   // and where it is complete
static const float kMinMotion = 3.0;     // candidate motions shorter than this many spacings are ignored
static const float kMoveLow = 0.05;      // "is moving background" mismatch where the repair starts
static const float kMoveHigh = 0.10;     // and where the pixel is surely not moving background
static const float kLegitLow = 0.04;     // generated content matches both real frames up to here: keep it
static const float kLegitHigh = 0.08;    // from here on it is explained by neither

static const float kPairLow = 0.09;      // block best-match error where the real frame starts to show
static const float kPairHigh = 0.15;     // and where it fully replaces the generated frame

static const int2 kRing[8] = { int2(10, 0), int2(7, 7), int2(0, 10), int2(-7, 7), int2(-10, 0), int2(-7, -7), int2(0, -10), int2(7, -7) };

float maxComponent(float3 v) { return max(v.x, max(v.y, v.z)); }

// Mean difference of the 3x3 tap patches of x around px and y around py.
float patchDiff(Texture2D<float4> x, int2 px, Texture2D<float4> y, int2 py, int step, int2 limit)
{
    float sum = 0;
    [unroll] for (int j = 0; j < 9; ++j) {
        const int2 o = int2(j % 3 - 1, j / 3 - 1) * step;
        sum += maxComponent(abs(x[clamp(px + o, int2(0, 0), limit)].rgb - y[clamp(py + o, int2(0, 0), limit)].rgb));
    }
    return sum / 9.0;
}

float pairError(int2 p)
{
    const float2 f = (float2(p) + 0.5) / float2(width, height) * float2(16.0, 8.0) - 0.5;
    const int2 i0 = int2(floor(f));
    const float2 t = f - float2(i0);
    const int2 lo = clamp(i0, int2(0, 0), int2(15, 7));
    const int2 hi = clamp(i0 + 1, int2(0, 0), int2(15, 7));
    const float top = lerp(pairErrorTex[int2(lo.x, lo.y)], pairErrorTex[int2(hi.x, lo.y)], t.x);
    const float bottom = lerp(pairErrorTex[int2(lo.x, hi.y)], pairErrorTex[int2(hi.x, hi.y)], t.x);
    return lerp(top, bottom, t.y);
}

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    if (id.x >= width || id.y >= height) return;
    const int2 p = int2(id.xy);
    const int2 limit = int2(int(width) - 1, int(height) - 1);
    const int step = int(spacing);
    const float4 g = generatedTex[p];
    float still = 0;
    float differ = 0;
    [unroll] for (int j = 0; j < 9; ++j) {
        const int2 q = clamp(p + int2(j % 3 - 1, j / 3 - 1) * step, int2(0, 0), limit);
        const float3 a = previousTex[q].rgb;
        const float3 b = currentTex[q].rgb;
        still += maxComponent(abs(a - b));
        differ += maxComponent(abs(generatedTex[q].rgb - 0.5 * (a + b)));
    }
    still /= 9.0;
    differ /= 9.0;
    const float evidence = repairOn < 0.5 ? 0.0 : (1.0 - smoothstep(kStaticLow, kStaticHigh, still)) * smoothstep(kDifferLow, kDifferHigh, differ - 1.5 * still);
    float w = 0;
    if (evidence > 0) {
        float notBackground = 0;   // largest mismatch of "the content here moves with a nearby motion"
        float explained = 1.0;     // smallest two-sided error of the generated content along a motion
        [loop] for (int k = 0; k < 9; ++k) {
            const int2 q = k == 0 ? p : clamp(p + kRing[max(k - 1, 0)] * step * 3 / 2, int2(0, 0), limit);
            const float2 m = motionTex[q];
            if (!all(isfinite(m)) || length(m) < kMinMotion * float(step)) continue;
            const int2 fullMove = int2(round(m));
            const int2 halfMove = int2(round(0.5 * m));
            notBackground = max(notBackground, max(patchDiff(currentTex, p, previousTex, p + fullMove, step, limit),
                                                   patchDiff(previousTex, p, currentTex, p - fullMove, step, limit)));
            const float forward = max(patchDiff(generatedTex, p, previousTex, p + halfMove, step, limit),
                                      patchDiff(generatedTex, p, currentTex, p - halfMove, step, limit));
            const float backward = max(patchDiff(generatedTex, p, previousTex, p - halfMove, step, limit),
                                       patchDiff(generatedTex, p, currentTex, p + halfMove, step, limit));
            explained = min(explained, min(forward, backward));
        }
        w = evidence * smoothstep(kMoveLow, kMoveHigh, notBackground) * smoothstep(kLegitLow, kLegitHigh, explained);
    }
    const float3 real = 0.5 * (previousTex[p].rgb + currentTex[p].rgb);
    float3 result = lerp(g.rgb, real, w);
    const float replaced = pairOn < 0.5 ? 0.0 : smoothstep(kPairLow, kPairHigh, pairError(p));
    result = lerp(result, currentTex[p].rgb, replaced);
    if (debugView != 0) {
        result = lerp(result, float3(1.0, 0.0, 1.0), 0.6 * w);
        result = lerp(result, float3(0.0, 1.0, 1.0), 0.6 * (evidence - w));
        result = lerp(result, float3(1.0, 1.0, 0.0), 0.4 * replaced);
    }
    outputTex[p] = float4(result, g.a);
}
