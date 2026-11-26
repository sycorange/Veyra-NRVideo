// FgStaticRepair: experimental repair of a generated frame where both real frames agree
// (VEYRA_TEST_FG_STATIC_REPAIR=1; 2 also tints the result for inspection: pink = repaired,
// orange = repaired because it touches intact static foreground, cyan = static evidence that was
// left alone, green = filled by the occlusion fill,
// yellow = real frame shown by the pair check).
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
// With VEYRA_TEST_FG_OCCLUSION_FILL=1 (2 = tint green) the pass also fills the strip beside
// a screen-static object that the background passes behind during a pan. Half a motion
// one way that background is still visible in one real frame; half a motion the other way
// the other real frame shows the static object instead, so an interpolator has only one
// valid sample and was seen drawing a dark, ragged smear there. Where a nearby motion puts
// one sample on confirmed static foreground (static between the real frames, its own
// motion different, and not explainable as moving background) and the other sample on
// background that follows the motion, the pixel takes the background sample. The pixel
// itself must be background moving by that motion, the generated frame must already show
// the foreground at the foreground sample, and motions beyond 120 spacings are left alone.
// Prototyped offline on recorded frames with a stand-in optical flow
// (docs/FSR_FLOW_DEPTH_EXPERIMENT.md): it cleaned the smear in one fast turn, changed
// little in three others and slightly hurt a second character behind the first in one.
// Unproven on live capture.
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
    float fillOn;      // 1: occlusion fill beside static foreground
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

static const float kAnchorsNeeded = 2.0;  // intact static neighbours (of 16) where the rescue starts; two more complete it

static const float kPairLow = 0.09;      // block best-match error where the real frame starts to show
static const float kPairHigh = 0.15;     // and where it fully replaces the generated frame

static const float kFillMinMotion = 10.0; // spacings; a shorter pan leaves no strip worth filling
static const float kFillFadeMotion = 90.0; // spacings; longer motions are trusted less
static const float kFillMaxMotion = 120.0; // and from here on nothing is filled
static const float kFillAgree = 0.06;     // a sample follows the motion within this share of its length
static const float kFillLow = 0.02;       // generated-frame deviation from the background sample where the fill starts
static const float kFillHigh = 0.06;      // and where it is complete

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

// Distance of the motion at q from m; unknown motion counts as far.
float motionError(int2 q, float2 m)
{
    const float2 f = motionTex[q];
    return all(isfinite(f)) ? length(f - m) : 1.0e6;
}

// 1 where the content at q is static between the real frames and is not background moving by fullMove.
float staticForeground(int2 q, int2 fullMove, int step, int2 limit)
{
    const float still = 1.0 - smoothstep(kStaticLow, kStaticHigh, patchDiff(previousTex, q, currentTex, q, step, limit));
    if (still <= 0.0) return 0.0;
    const float notBackground = max(patchDiff(currentTex, q, previousTex, q + fullMove, step, limit),
                                    patchDiff(previousTex, q, currentTex, q - fullMove, step, limit));
    return still * smoothstep(kMoveLow, kMoveHigh, notBackground);
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
    float rescued = 0;
    if (evidence > 0) {
        float notBackground = 0;   // largest mismatch of "the content here moves with a nearby motion"
        float explained = 1.0;     // smallest two-sided error of the generated content along a motion
        float2 longest = float2(0, 0);
        [loop] for (int k = 0; k < 9; ++k) {
            const int2 q = k == 0 ? p : clamp(p + kRing[max(k - 1, 0)] * step * 3 / 2, int2(0, 0), limit);
            const float2 m = motionTex[q];
            if (!all(isfinite(m)) || length(m) < kMinMotion * float(step)) continue;
            if (dot(m, m) > dot(longest, longest)) longest = m;
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
        const float base = evidence * smoothstep(kMoveLow, kMoveHigh, notBackground);
        w = base * smoothstep(kLegitLow, kLegitHigh, explained);
        // A pixel the motion test would leave alone is still repaired when it touches intact
        // static foreground: nearby pixels that are static in the real frames, are drawn the
        // same in the generated frame, have (almost) no motion of their own and cannot be
        // background moving by the longest nearby motion. A torn head keeps such pixels just
        // inside the tear; a lane line on the road has none.
        if (base > w) {
            const float reach = length(longest);
            const int2 longMove = int2(round(longest));
            float anchors = 0;
            [loop] for (int a = 0; a < 16; ++a) {
                const int2 q = p + kRing[a & 7] * step * (a < 8 ? 3 : 9) / 4;
                if (any(q < int2(0, 0)) || any(q > limit)) continue;
                const float2 f = motionTex[q];
                if (!all(isfinite(f)) || length(f) > 0.25 * reach) continue;
                const float intact = 1.0 - smoothstep(kStaticLow, kStaticHigh, patchDiff(generatedTex, q, previousTex, q, step, limit));
                if (intact <= 0.0) continue;
                anchors += intact * staticForeground(q, longMove, step, limit);
            }
            rescued = (base - w) * saturate((anchors - kAnchorsNeeded + 1.0) * 0.5);
            w += rescued;
        }
    }
    float fill = 0;
    float3 fillColor = g.rgb;
    const float moving = fillOn < 0.5 ? 0.0 : smoothstep(kStaticLow, kStaticHigh, still);
    if (moving > 0) {
        // Candidate motions: the pixel's own, a ring at 15 spacings and a ring at 45. The far
        // ring is for the strip where background comes out from behind the object: that
        // background has no match in the previous frame, so the motion inside the strip is
        // unreliable and has to come from beyond it.
        [loop] for (int n = 0; n < 17; ++n) {
            const int2 q = n == 0 ? p : clamp(p + kRing[max(n - 1, 0) & 7] * step * (n < 9 ? 3 : 9) / 2, int2(0, 0), limit);
            const float2 m = motionTex[q];
            if (!all(isfinite(m))) continue;
            const float len = length(m);
            if (len < kFillMinMotion * float(step)) continue;
            const float range = 1.0 - smoothstep(kFillFadeMotion * float(step), kFillMaxMotion * float(step), len);
            if (range <= 0.0) continue;
            const int2 fullMove = int2(round(m));
            const int2 halfMove = int2(round(0.5 * m));
            const int2 qa = p + halfMove;   // where this content is in the previous frame
            const int2 qb = p - halfMove;   // and in the current frame
            if (any(qa < int2(0, 0)) || any(qa > limit) || any(qb < int2(0, 0)) || any(qb > limit)) continue;
            const float ea = motionError(qa, m);
            const float eb = motionError(qb, m);
            const float tolerance = kFillAgree * len + 0.5 * float(step);
            const float fromPrevious = moving * range * (1.0 - smoothstep(tolerance, 2.0 * tolerance, ea)) * smoothstep(0.25, 0.5, eb / len);
            const float fromCurrent = moving * range * (1.0 - smoothstep(tolerance, 2.0 * tolerance, eb)) * smoothstep(0.25, 0.5, ea / len);
            if (max(fromPrevious, fromCurrent) <= fill) continue;
            const float fa = staticForeground(qa, fullMove, step, limit);
            const float fb = staticForeground(qb, fullMove, step, limit);
            // Each side in turn: the generated frame shows that foreground too; this pixel is
            // background that moved by m between the real frames; the generated frame differs
            // from the background sample.
            float wa = fromPrevious * fb * (1.0 - fa);
            if (wa > fill) wa *= 1.0 - smoothstep(kStaticLow, kStaticHigh, patchDiff(generatedTex, qb, previousTex, qb, step, limit));
            if (wa > fill) wa *= 1.0 - smoothstep(kStaticLow, kStaticHigh, patchDiff(currentTex, p, previousTex, p + fullMove, step, limit));
            if (wa > fill) wa *= smoothstep(kFillLow, kFillHigh, patchDiff(generatedTex, p, previousTex, qa, step, limit));
            if (wa > fill) { fill = wa; fillColor = previousTex[qa].rgb; }
            float wb = fromCurrent * fa * (1.0 - fb);
            if (wb > fill) wb *= 1.0 - smoothstep(kStaticLow, kStaticHigh, patchDiff(generatedTex, qa, currentTex, qa, step, limit));
            if (wb > fill) wb *= 1.0 - smoothstep(kStaticLow, kStaticHigh, patchDiff(previousTex, p, currentTex, p - fullMove, step, limit));
            if (wb > fill) wb *= smoothstep(kFillLow, kFillHigh, patchDiff(generatedTex, p, currentTex, qb, step, limit));
            if (wb > fill) { fill = wb; fillColor = currentTex[qb].rgb; }
        }
    }
    const float3 real = 0.5 * (previousTex[p].rgb + currentTex[p].rgb);
    float3 result = lerp(g.rgb, real, w);
    result = lerp(result, fillColor, fill);
    const float replaced = pairOn < 0.5 ? 0.0 : smoothstep(kPairLow, kPairHigh, pairError(p));
    result = lerp(result, currentTex[p].rgb, replaced);
    if (debugView != 0) {
        result = lerp(result, float3(1.0, 0.0, 1.0), 0.6 * (w - rescued));
        result = lerp(result, float3(0.0, 1.0, 1.0), 0.6 * (evidence - w));
        result = lerp(result, float3(1.0, 0.5, 0.0), 0.6 * rescued);
        result = lerp(result, float3(0.0, 1.0, 0.0), 0.6 * fill);
        result = lerp(result, float3(1.0, 1.0, 0.0), 0.4 * replaced);
    }
    outputTex[p] = float4(result, g.a);
}
