// FgStaticRepair: experimental repair of a generated frame where both real frames agree
// (VEYRA_TEST_FG_STATIC_REPAIR=1; 2 also tints repaired pixels for inspection).
//
// On 30 fps capture a camera turn moves the background far between two real frames while
// a third-person character stays almost still on screen. Interpolators (FSR, RIFE, AMD
// FRC were all observed doing it) then draw background over parts of the character's
// outline. Here a pixel whose neighbourhood is nearly identical in the previous and the
// current real frame, but clearly different in the generated frame, takes the average of
// the two real frames instead.
//
// Known limit: an object smaller than its own per-frame displacement, crossing a plain
// area, is static evidence by this test as well and is removed from the generated frame.
Texture2D<float4> generatedTex : register(t0);
Texture2D<float4> currentTex : register(t1);    // newer real frame
Texture2D<float4> previousTex : register(t2);   // older real frame
RWTexture2D<float4> outputTex : register(u0);

cbuffer FgStaticRepairConstants : register(b0)
{
    uint width;
    uint height;
    uint spacing;      // tap spacing in pixels (3x3 taps)
    uint debugView;    // 1: tint repaired pixels
    float staticLow;   // real-frame difference up to this is fully static
    float staticHigh;  // from this on the pixel is moving: untouched
    float differLow;   // generated-frame deviation (beyond twice the real difference) where repair starts
    float differHigh;  // and where it is complete
};

float maxComponent(float3 v) { return max(v.x, max(v.y, v.z)); }

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    if (id.x >= width || id.y >= height) return;
    const int2 p = int2(id.xy);
    const int2 limit = int2(int(width) - 1, int(height) - 1);
    const float4 g = generatedTex[p];
    float still = 0;
    float differ = 0;
    [unroll] for (int j = 0; j < 9; ++j) {
        const int2 q = clamp(p + int2(j % 3 - 1, j / 3 - 1) * int(spacing), int2(0, 0), limit);
        const float3 a = previousTex[q].rgb;
        const float3 b = currentTex[q].rgb;
        still += maxComponent(abs(a - b));
        differ += maxComponent(abs(generatedTex[q].rgb - 0.5 * (a + b)));
    }
    still /= 9.0;
    differ /= 9.0;
    const float w = (1.0 - smoothstep(staticLow, staticHigh, still)) * smoothstep(differLow, differHigh, differ - 2.0 * still);
    const float3 real = 0.5 * (previousTex[p].rgb + currentTex[p].rgb);
    float3 result = lerp(g.rgb, real, w);
    if (debugView != 0) result = lerp(result, float3(1.0, 0.0, 1.0), 0.6 * w);
    outputTex[p] = float4(result, g.a);
}
