# Optional client video features

`NativeStreamClientVideo.swift` owns FSR1 producer effects, adaptive HDR policy
and resource lifetime. StreamerView retains the existing Metal 4 input-copy/event
handoff and drawable presentation owner. Rendering uses the newest real frame.

## Controls

Settings → Stream and HUD → Picture expose:

- **Adaptive HDR:** Core Image's `CIToneMapHeadroom` with the active screen's
  `currentEDRHeadroom`. Unknown source headroom leaves the original HDR path
  intact and reports the metadata limitation. Off by default.
- **Upscaling method:** MetalFX, NIS or AMD FSR1. NIS/FSR1 accept near-native
  enlargement up to 2× per dimension, retain the requested stream resolution and
  use Stream Sharpening for integrated sharpening.

All persistent textures are retained until queued work finishes. FSR1 producer
outputs feed Core Image's copy into the existing Metal 4 slot. Compatible rendering
uses the same serial queue and three-frame admission bound. FSR1 kernels compile
on a background queue only when FSR1 upscaling is requested.

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
HDR tone-map output and NIS/FSR1 → Metal 4 event/lifetime handoff.
Simulator parity tests cover persistence, profile retention and migration from
removed options. These checks do not establish physical iPhone/iPad performance,
battery impact, sustained 120 FPS or artifact-free gameplay.
