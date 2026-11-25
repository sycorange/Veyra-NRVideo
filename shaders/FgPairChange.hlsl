// FgPairChange: experimental per-region change test for one frame-generation input pair
// (VEYRA_TEST_FG_PAIR_CHECK=1), after RifeShotChange.hlsl but local instead of one
// decision per pair. Each of 16x8 blocks of a 128x72 luma picture of the previous real
// frame is matched in the current one within +-24 x +-10 luma pixels (about +-360 x +-150
// at 1080p). A pan or turn still finds its match; content that is gone (a cut, a body
// sweeping past the camera) does not. FgStaticRepair.hlsl shows the current real frame
// where the best-match error is high, instead of a blend of two unrelated pictures.
//
// Two dispatches per real frame: mode 0 (36 groups) writes this frame's luma, mode 1
// (128 groups, one block each) writes the block's best-match error. No readback.
Texture2D<float4> frameTex : register(t0);     // current real frame, work extent
RWTexture2D<float> lumaTex : register(u0);     // 128 x 144: slot * 72 + y
RWTexture2D<float> errorTex : register(u1);    // 16 x 8 best-match errors (0..1)

cbuffer FgPairChangeConstants : register(b0)
{
    uint width;
    uint height;
    uint mode;
    uint current;   // luma slot of this frame (0/1); the other holds the previous frame
    uint compare;   // 0: no usable previous frame, write zero errors
    uint unused0;
    uint unused1;
    uint unused2;
};

static const uint kW = 128;
static const uint kH = 72;
static const uint kBlockW = 8;
static const uint kBlockH = 9;
static const uint kGridW = 16;
static const uint kGridH = 8;
static const int kRangeX = 24;
static const int kRangeY = 10;
static const uint kStepsX = 25;   // -24..24 in steps of 2
static const uint kStepsY = 11;   // -10..10 in steps of 2
static const uint kCandidates = kStepsX * kStepsY;   // 275: two per thread
static const uint kWindowW = kBlockW + 2 * kRangeX;  // 56
static const uint kWindowH = kBlockH + 2 * kRangeY;  // 29

groupshared float blockA[kBlockW * kBlockH];
groupshared float windowB[kWindowW * kWindowH];
groupshared float candidate[256];

float lumaLoad(uint slot, uint x, uint y) { return lumaTex[uint2(x, slot * kH + y)]; }

float candidateError(uint c, uint bx, uint by)
{
    if (c >= kCandidates) return 1e9;
    const int dx = -kRangeX + 2 * int(c % kStepsX);
    const int dy = -kRangeY + 2 * int(c / kStepsX);
    if (int(bx) + dx < 0 || int(by) + dy < 0 || int(bx) + dx + int(kBlockW) > int(kW) || int(by) + dy + int(kBlockH) > int(kH)) return 1e9;
    float sad = 0;
    for (uint n = 0; n < kBlockW * kBlockH; ++n) {
        const uint nx = n % kBlockW;
        const uint ny = n / kBlockW;
        sad += abs(blockA[n] - windowB[(uint(dy + kRangeY) + ny) * kWindowW + uint(dx + kRangeX) + nx]);
    }
    return sad / float(kBlockW * kBlockH);
}

[numthreads(256, 1, 1)]
void main(uint3 group : SV_GroupID, uint index : SV_GroupIndex)
{
    if (mode == 0) {
        const uint i = group.x * 256 + index;
        if (i >= kW * kH) return;
        const uint x = i % kW;
        const uint y = i / kW;
        float sum = 0;
        for (uint s = 0; s < 16; ++s) {
            const float2 uv = (float2(x, y) + (float2(s % 4, s / 4) + 0.5) / 4.0) / float2(kW, kH);
            const uint2 q = min(uint2(uv * float2(width, height)), uint2(width - 1, height - 1));
            sum += dot(frameTex[q].rgb, float3(0.299, 0.587, 0.114));
        }
        lumaTex[uint2(x, current * kH + y)] = sum / 16.0;
        return;
    }
    if (group.x >= kGridW * kGridH) return;
    const uint previous = 1 - current;
    const uint bx = (group.x % kGridW) * kBlockW;
    const uint by = (group.x / kGridW) * kBlockH;
    for (uint a = index; a < kBlockW * kBlockH; a += 256)
        blockA[a] = lumaLoad(previous, bx + a % kBlockW, by + a / kBlockW);
    for (uint b = index; b < kWindowW * kWindowH; b += 256) {
        const int wx = int(bx) - kRangeX + int(b % kWindowW);
        const int wy = int(by) - kRangeY + int(b / kWindowW);
        windowB[b] = (wx >= 0 && wy >= 0 && wx < int(kW) && wy < int(kH)) ? lumaLoad(current, uint(wx), uint(wy)) : 0;
    }
    GroupMemoryBarrierWithGroupSync();
    candidate[index] = min(candidateError(index, bx, by), candidateError(index + 256, bx, by));
    GroupMemoryBarrierWithGroupSync();
    if (index != 0) return;
    float best = 1e9;
    for (uint c = 0; c < 256; ++c) best = min(best, candidate[c]);
    errorTex[uint2(group.x % kGridW, group.x / kGridW)] = (compare != 0 && best < 1e8) ? best : 0.0;
}
