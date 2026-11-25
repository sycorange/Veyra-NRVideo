// FsrFlowDepth: a coarse foreground/background depth for FSR frame generation, estimated
// from the frame-generation motion (experimental, VEYRA_TEST_FSR_FLOW_DEPTH=1).
//
// Video and capture have no engine depth, so FSR otherwise receives one constant depth.
// FSR uses depth to choose the nearer motion vector where vectors meet (silhouette
// dilation) and to detect disocclusion; a flat depth gives it no foreground, which
// shows as halos and smearing around characters and weapons moving against the
// background. This pass marks pixels whose motion differs clearly from the dominant
// (camera) motion as nearer. It is a heuristic: when no motion dominates (zoom,
// rotation, a scene split between several motions), the whole frame keeps the
// existing constant far depth.
//
// Four dispatches per frame (all UAVs, R32_UINT unless noted):
//   mode 0 clear     - histogram counts and fixed-point vector sums
//   mode 1 histogram - every `sampleStep` pixel votes for its 2-pixel motion bin
//   mode 2 dominant  - one 256-thread group finds the strongest 3x3 bin neighbourhood
//   mode 3 depth     - per-pixel depth at the working extent (R32_FLOAT)
Texture2D<float2> motion : register(t0);          // work extent, current->previous pixels
RWTexture2D<uint> histogram : register(u0);       // kBins x (3 * kBins): count, sum x, sum y
RWTexture2D<uint> dominant : register(u1);        // 4 x 1: x bits, y bits, valid, votes
RWTexture2D<float> depth : register(u2);          // work extent, FSR depth (0 near, 1 far)

cbuffer FsrFlowDepthConstants : register(b0)
{
    uint workW;
    uint workH;
    uint mode;
    uint sampleStep;
    float farDepth;     // background (and fallback) depth: the existing constant 0.9
    float nearDepth;    // clear foreground
    float minShare;     // dominant neighbourhood must hold this share of all votes
    uint unused0;
};

static const int kBins = 64;          // 2-pixel bins over [-64, 64) pixels per axis
static const float kBinSize = 2.0;
static const float kFixed = 8.0;      // vector sums in 1/8 pixel

int2 binOf(float2 v)
{
    return clamp(int2(floor((v + kBinSize * kBins * 0.5) / kBinSize)), 0, kBins - 1);
}

// Cross-shaped erosion taps for mode 3.
static const int2 kTaps[5] = { int2(0, 0), int2(3, 0), int2(-3, 0), int2(0, 3), int2(0, -3) };

groupshared uint gsVotes[256];
groupshared uint gsBin[256];

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID, uint gi : SV_GroupIndex)
{
    if (mode == 0) {
        if (id.x < uint(kBins) && id.y < uint(3 * kBins)) histogram[id.xy] = 0;
        if (id.x < 4 && id.y == 0) dominant[id.xy] = 0;
        return;
    }
    if (mode == 1) {
        const uint2 p = id.xy * sampleStep;
        if (p.x >= workW || p.y >= workH) return;
        const float2 v = motion[p];
        if (!all(isfinite(v))) return;
        const int2 b = binOf(v);
        const int2 fixedV = int2(round(clamp(v, -256.0, 256.0) * kFixed));
        uint ignored;
        InterlockedAdd(histogram[uint2(b.x, b.y)], 1u, ignored);
        InterlockedAdd(histogram[uint2(b.x, b.y + kBins)], asuint(fixedV.x), ignored);
        InterlockedAdd(histogram[uint2(b.x, b.y + 2 * kBins)], asuint(fixedV.y), ignored);
        return;
    }
    if (mode == 2) {
        // Dispatched as a single group: thread gi scans 16 bins and scores each by its
        // 3x3 neighbourhood, so a motion split across a bin edge still counts once.
        uint bestVotes = 0, bestBin = 0;
        for (uint i = 0; i < 16; ++i) {
            const uint bin = gi * 16 + i;
            const int2 c = int2(bin % kBins, bin / kBins);
            uint votes = 0;
            [unroll] for (int dy = -1; dy <= 1; ++dy)
                [unroll] for (int dx = -1; dx <= 1; ++dx) {
                    const int2 q = c + int2(dx, dy);
                    if (all(q >= 0) && all(q < kBins)) votes += histogram[uint2(q)];
                }
            if (votes > bestVotes) { bestVotes = votes; bestBin = bin; }
        }
        gsVotes[gi] = bestVotes; gsBin[gi] = bestBin;
        GroupMemoryBarrierWithGroupSync();
        for (uint s = 128; s > 0; s >>= 1) {
            if (gi < s && gsVotes[gi + s] > gsVotes[gi]) { gsVotes[gi] = gsVotes[gi + s]; gsBin[gi] = gsBin[gi + s]; }
            GroupMemoryBarrierWithGroupSync();
        }
        if (gi != 0) return;
        uint total = 0;
        for (uint y = 0; y < uint(kBins); ++y)
            for (uint x = 0; x < uint(kBins); ++x) total += histogram[uint2(x, y)];
        const int2 c = int2(gsBin[0] % kBins, gsBin[0] / kBins);
        uint count = 0; int sx = 0, sy = 0;
        for (int dy = -1; dy <= 1; ++dy)
            for (int dx = -1; dx <= 1; ++dx) {
                const int2 q = c + int2(dx, dy);
                if (any(q < 0) || any(q >= kBins)) continue;
                count += histogram[uint2(q)];
                sx += asint(histogram[uint2(q.x, q.y + kBins)]);
                sy += asint(histogram[uint2(q.x, q.y + 2 * kBins)]);
            }
        const bool valid = count > 0 && total > 0 && float(count) >= minShare * float(total);
        const float2 g = count > 0 ? float2(sx, sy) / (kFixed * float(count)) : float2(0, 0);
        dominant[uint2(0, 0)] = asuint(g.x);
        dominant[uint2(1, 0)] = asuint(g.y);
        dominant[uint2(2, 0)] = valid ? 1u : 0u;
        dominant[uint2(3, 0)] = count;
        return;
    }
    // mode 3: depth from the distance to the dominant motion.
    if (id.x >= workW || id.y >= workH) return;
    if (dominant[uint2(2, 0)] == 0) { depth[id.xy] = farDepth; return; }
    const float2 g = float2(asfloat(dominant[uint2(0, 0)]), asfloat(dominant[uint2(1, 0)]));
    // Allow more slack for fast camera motion, where flow error grows with speed.
    const float t0 = 1.5 + 0.1 * length(g);
    const float t1 = t0 + 4.0;
    // Cross-shaped erosion (radius 3): isolated flow errors must not become
    // foreground specks; FSR's own nearest-depth dilation restores the silhouette.
    float nearness = 1.0;
    [unroll] for (int tap = 0; tap < 5; ++tap) {
        const int2 q = clamp(int2(id.xy) + kTaps[tap], int2(0, 0), int2(workW - 1, workH - 1));
        const float2 v = motion[q];
        const float d = all(isfinite(v)) ? length(v - g) : 0.0;
        nearness = min(nearness, saturate((d - t0) / (t1 - t0)));
    }
    depth[id.xy] = lerp(farDepth, nearDepth, nearness);
}
