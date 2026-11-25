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

## Related experiment: static repair of generated frames

`VEYRA_TEST_FG_STATIC_REPAIR=1` (off by default; `2` also tints repaired pixels) runs
`shaders/FgStaticRepair.hlsl` on each FSR-generated frame: where the two real frames agree
with each other in a 3×3 tap neighbourhood but the generated frame differs, the pixel takes
the real frames' average. It targets a screen-still third-person character losing parts of
its outline to the background during 30 fps camera turns, which FSR 4 ML, RIFE 4.26 and AMD
FRC all showed on the same capture. SDR output and FSR graph FG only. Known limit: objects
smaller than their per-frame displacement over plain areas were removed by the first two versions; two tests against the FG motion now gate the repair (see the shader header).

## Related experiment: per-region pair check

`VEYRA_TEST_FG_PAIR_CHECK=1` (off by default) runs `shaders/FgPairChange.hlsl` per real
frame: 16×8 blocks of a 128×72 luma picture of the previous real frame are matched in the
current one within ±24 × ±10 luma pixels. Where a block has no match, the compose pass shows
the current real frame instead of the generated one. Observed case: a character sweeping
past the camera during a spin, where FSR 4 ML produced a see-through blend of two unrelated
pictures. Thresholds are untuned; fast motion beyond the search range also falls back to
the real frame.

## Related experiment: occlusion fill beside static foreground

`VEYRA_TEST_FG_OCCLUSION_FILL=1` (off by default; `2` also tints filled pixels green) adds
a second rule to the same compose pass. During a pan the background passes behind a
screen-still character; in the strip beside the character one real frame still shows that
background and the other already shows the character, and FSR 4 ML drew a dark ragged smear
there on 30 fps capture. For the pixel's own FG motion and eight neighbours' (at least ten
tap spacings long), the pixel takes the previous frame's sample half a motion back when
that sample's surroundings follow the motion and the current frame's sample half a motion
forward lies on static foreground (static between the real frames, own motion different,
not explainable as background moving by that motion), and the mirrored case from the
current frame. The pixel itself must be background that moved by that motion, the generated
frame must already show the foreground at the foreground sample, and motions beyond 120
spacings are left alone. Static pixels are never touched. SDR output, FSR graph FG with
flow only. Prototyped offline on five recorded fast-turn frames with a different optical
flow (OpenCV DIS degraded to 8-pixel blocks): the smear was removed in one, three changed
little, and in one a second character behind the first was slightly degraded. Not yet
confirmed on live capture.
