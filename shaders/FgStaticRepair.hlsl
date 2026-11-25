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
// A thin object crossing a plain area (a pole or wire against the sky, a road marking)
// passes the same test: both real frames show the plain area where the generated frame
// correctly draws the object. Such a pixel has static surroundings on every side, while a
// character's outline borders the moving background. The repair therefore only acts near
// the edge of a static region: some of the pixels on two rings around it must be moving.
//
// Known limits: a thin object close to moving, textured content is still removed from the
// generated frame; a character against a plain sky is not repaired.
Texture2D<float4> generatedTex : register(t0);
Texture2D<float4> currentTex : register(t1);    // newer real frame
Texture2D<float4> previousTex : register(t2);   // older real frame
RWTexture2D<float4> outputTex : register(u0);

cbuffer FgStaticRepairConstants : register(b0)
{
    uint width;
    uint height;
    uint spacing;      // tap spacing in pixels (3x3 taps); rings at 10 and 20 spacings
    uint debugView;    // 1: tint the result
    float unused0;     // thresholds live below while the experiment is being tuned
    float unused1;
    float unused2;
    float unused3;
};

// SDR code values.
static const float kStaticLow = 0.03;    // real-frame difference up to this is fully static
static const float kStaticHigh = 0.08;   // from this on the pixel is moving: untouched
static const float kDifferLow = 0.025;   // generated-frame deviation where the repair starts
static const float kDifferHigh = 0.07;   // and where it is complete
static const float kMovingLow = 0.12;    // share of moving ring pixels where the repair starts
static const float kMovingHigh = 0.30;   // and where it is complete

static const int2 kRing[8] = { int2(10, 0), int2(7, 7), int2(0, 10), int2(-7, 7), int2(-10, 0), int2(-7, -7), int2(0, -10), int2(7, -7) };

float maxComponent(float3 v) { return max(v.x, max(v.y, v.z)); }

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
    const float evidence = (1.0 - smoothstep(kStaticLow, kStaticHigh, still)) * smoothstep(kDifferLow, kDifferHigh, differ - 1.5 * still);
    float w = 0;
    if (evidence > 0) {
        float nearRing = 0;
        float farRing = 0;
        [unroll] for (int k = 0; k < 8; ++k) {
            const int2 q1 = clamp(p + kRing[k] * step, int2(0, 0), limit);
            const int2 q2 = clamp(p + kRing[k] * step * 2, int2(0, 0), limit);
            nearRing += smoothstep(kStaticLow, kStaticHigh, maxComponent(abs(previousTex[q1].rgb - currentTex[q1].rgb)));
            farRing += smoothstep(kStaticLow, kStaticHigh, maxComponent(abs(previousTex[q2].rgb - currentTex[q2].rgb)));
        }
        const float moving = max(nearRing, farRing) / 8.0;
        w = evidence * smoothstep(kMovingLow, kMovingHigh, moving);
    }
    const float3 real = 0.5 * (previousTex[p].rgb + currentTex[p].rgb);
    float3 result = lerp(g.rgb, real, w);
    if (debugView != 0) {
        result = lerp(result, float3(1.0, 0.0, 1.0), 0.6 * w);
        result = lerp(result, float3(0.0, 1.0, 1.0), 0.6 * (evidence - w));
    }
    outputTex[p] = float4(result, g.a);
}
