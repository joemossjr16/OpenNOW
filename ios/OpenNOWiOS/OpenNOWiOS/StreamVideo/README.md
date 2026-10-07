# Optional client video features

`NativeStreamClientVideo.swift` owns client timing policy, optional compatible-Metal
producer effects and their resource lifetime. StreamerView retains the existing
Metal 4 input-copy/event handoff and drawable presentation owner. All features are
off by default except the existing lowest-latency policy.

## Controls

Settings → Stream and HUD → Picture expose:

- **Frame pacing:** Lowest latency (latest frame) or Balanced (two pending frames,
  nominal-frame cadence). Interpolation uses lowest-latency selection.
- **Client interpolation:** Experimental, at most one intermediate frame per real
  frame. Streams must be at most 60 FPS; display callbacks must
  run at least 1.5× the configured stream FPS. A 60 FPS stream on a 120 Hz display
  is the intended first device test. There is no resolution cap; streams above 60 FPS remain
  real-frame playback. This feature does not change the negotiated stream profile
  or claim VRR. It adds temporal delay and can introduce motion artifacts.
- **Adaptive HDR:** Core Image's `CIToneMapHeadroom` with the active screen's
  `currentEDRHeadroom`. Unknown source headroom leaves the original HDR path
  intact and reports the metadata limitation.
- **Upscaling method:** MetalFX, NIS or AMD FSR1. NIS/FSR1 accept near-native
  enlargement up to 2× per dimension, retain the requested stream resolution and
  use Stream Sharpening for integrated sharpening.

## Interpolation implementation

`Interpolation.metal` is an independent bounded block-matching/warp implementation.
It searches source displacement coarse-to-fine on an eighth-size motion field,
then warps adjacent encoded RGB frames. Residual and color disagreement reject
unreliable motion/scene cuts in favor of the current real frame. This is not the
recovered PXPlay shader implementation, a neural model or server frame generation.

Two adjacent real frames warm up history. Frame gaps, size/color changes and live
option changes reset it. Only one extra presentation is admitted between real
frames; missing frames never extrapolate indefinitely. GPU command failures suspend interpolation
until a settings change retries it. There is no GPU-time cutoff.
Producer/consumer GPU performance and physical thermals need device testing.

All persistent textures are retained until queued work finishes. Optional producer
outputs feed Core Image's copy into the existing Metal 4 slot; the Metal 4 queue
does not directly read recyclable interpolation/FSR surfaces. Compatible rendering
uses the same serial queue and three-frame admission bound. Kernels compile on a
background queue only when interpolation or FSR1 is requested.

## FSR provenance

The vendored `ffx_fsr1.h` is unmodified AMD MIT source from
https://github.com/GPUOpen-Effects/FidelityFX-FSR at commit
`a21ffb8f6c13233ba336352bdff293894c706575`. `FSR-LICENSE.txt` preserves the license.

Generate the MSL implementation with:

```sh
python3 ios/OpenNOWiOS/BuildScripts/generate-fsr-metal.py
```

The generator retains the FP32 EASU twelve-tap edge-adaptive filter and RCAS
sharpening math, translates parameter qualifiers/types and replaces gather/load
callbacks with signed, clamped texel reads. Full-precision guarded reciprocals
replace hardware approximation helpers. RCAS denoising is enabled; alpha is opaque.
SDR sRGB or HDR PQ encoded RGB enters the spatial filter; Core Image handles
source/output color interpretation. A zero sharpening slider skips RCAS.

## Verification

```sh
python3 ios/OpenNOWiOS/BuildScripts/validate-client-video-macos.py
python3 ios/OpenNOWiOS/BuildScripts/validate-metal4-effects-macos.py
```

The first script enables Metal API/shader validation and covers SDR/PQ constant
colors, near-native/2× geometry, 2560×1080→2868×1320, edge coverage, sharpening,
known translation/midpoint motion, cuts, history reset/GPU-error fallback, HDR
tone-map output and NIS/FSR1/interpolation → Metal 4 event/lifetime handoff.
Simulator parity tests cover persistence, profile retention, timing gates and the
bounded balanced mailbox. These checks do not establish physical iPhone/iPad
performance, battery impact, sustained 120 FPS or artifact-free gameplay.
