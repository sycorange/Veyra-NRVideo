# FSR frame generation: depth from FG motion (experiment)

Status: experimental, off by default. Enable with the environment variable
`VEYRA_TEST_FSR_FLOW_DEPTH=1` for same-EXE A/B runs. Applies only to FSR 3.1 / FSR 4 ML
graph frame generation with flow motion. DLSS FG, ANR, VFG, RIFE, AMF FRC and XeSS are unchanged.

## Problem

Video and capture sources have no engine depth, so `FsrFgPresenter::generate` receives
`depthTex_`, a constant 0.9. FSR uses depth to prefer the nearer vector where motion
vectors meet (silhouette dilation) and to detect disocclusion. With a flat depth it has
no notion of foreground. That is a plausible contributor to halos and smearing around
characters, weapons and vehicles that move against a panning background in 30→60 capture.

## Change

`shaders/FsrFlowDepth.hlsl`, four small dispatches after the FG motion is final and before
HUD protection's motion fix:

1. Clear a 64×64 histogram of 2-pixel motion bins (count plus fixed-point vector sums).
2. Every 4×4th pixel of the FG motion (`fgBaseFlow_`, or `baseFlow_` without refinement)
   votes for its bin.
3. One 256-thread group picks the bin whose 3×3 neighbourhood holds the most votes and
   averages its vectors as the dominant (camera) motion. If it holds under 30% of the
   votes (zoom, rotation, split motion), the frame is marked invalid.
4. Per pixel: distance to the dominant motion, with a threshold of 1.5 px + 10% of the
   dominant speed and a 4 px ramp, after a radius-3 cross erosion to drop isolated
   flow errors. Depth is lerp(0.9 far, 0.5 near). An invalid frame writes 0.9 everywhere,
   so it matches the existing constant.

Resets and frames without flow keep `depthTex_`. Allocation or shader failure logs
`fsr-flow-depth` and falls back to the constant depth. FG itself never fails because of it.
Cost: four dispatches at the working extent (the histogram at 1/16 of the pixels). No
readback and no CPU wait.

## Known limits

- It's a heuristic: "differs from the dominant motion" isn't always "nearer". When a foreground
  object fills most of the frame, the labels invert. Expect neutral or worse output there.
- No temporal smoothing of the dominant motion or depth. Depth can change abruptly
  between frames.
- Validated only by compilation in CI at the time of writing. Image-quality results need
  side-by-side captures (on/off) on real 30→60 content.

## Related experiment: double-resolution FidelityFX flow

`VEYRA_TEST_AMD_FLOW_DOUBLE=1` (off by default) runs FidelityFX optical flow on a 2×
bilinear enlargement of the source, so its 8×8 blocks cover 4×4 source pixels. It targets
blocky frame-generation tears at silhouettes during camera turns (a head edge taking the
background's vector and showing the background through it). This was reproduced on 2.2.1
with FSR 4 FG on 1080p capture whether depth or Edge Aegis was on or off. It costs about 4× the flow
work. It doesn't apply with AMD half-resolution flow or still images, or past a 4096×2304
flow extent.
