# Metal 4 streaming renderer

Build **1.1.139 (139)** on `metal-4`. [Unsigned experimental IPA](https://github.com/joemossjr16/ios-apps/releases/tag/opennow-metal4-139). The original cumulative changes remain on [`ios/native-nvst-128`](https://github.com/joemossjr16/OpenNOW/tree/ios/native-nvst-128), build 136.

## Rendering and effects

The direct 10-bit PQ renderer and the general SDR/HDR effects renderer submit real `MTL4CommandBuffer` work to `MTL4CommandQueue`. They use Metal 4 compiler/pipeline descriptors, allocators, argument tables, residency sets, commit feedback and drawable synchronization. Direct PQ preserves native 10-bit 4:2:0/4:2:2/4:4:4 planes. The effects renderer preserves color precision in linear RGBA16Float surfaces and uses **MTL4FXSpatialScaler**, including for generated images. Native PQ 10-bit BT.2020 surfaces now convert directly to linear RGBA16Float on the Metal 4 queue, preserving native 4:2:0/4:2:2/4:4:4 planes and full/video range before scaling. Conversion, MTL4FXSpatialScaler and PQ presentation share one Metal 4 command buffer with explicit dependencies, without a Core Image producer or cross-queue event on this path. The HUD identifies it as `Metal 4 · native PQ conversion`. This path is used for real PQ frames with sharpening off; unsupported metadata, HLG, SDR, generated images and existing sharpening keep their compatible Core Image producer. Core Image supplies the remaining color conversion and existing sharpening; VTFrameProcessor supplies existing video interpolation. These APIs still take legacy Metal command buffers in the installed SDK, so producer and Metal 4 consumer are connected by GPU events, without blocking CPU waits. This is interoperable video interpolation, not the game-oriented MetalFX frame interpolator, which needs game motion vectors and depth absent from the received stream.

Two slots bound each configuration's work; the view admits at most two frames overall. Separate cached real/generated configurations avoid recompilation when performance interpolation produces smaller images. Setup happens off the display thread. GPU completion retains source IOSurfaces, intermediate textures, scalers, argument tables, uniform memory and drawables. A barrier covers compute/render/blit stages between spatial scaling and fragment reads. Shared events order live switches between legacy, direct and effects queues; completed GPU failures recover skipped signals and select the legacy path. Unsupported devices/inputs or setup failure also retain the existing renderer. CoreSimulator uses explicit fallback because its SDK omits Metal 4.

PQ and HLG sources both use a PQ BT.2020 10-bit EDR display in the general path. Core Image performs source-to-linear conversion; the Metal 4 shader applies the PQ encoding corresponding to Core Image's 203-nit reference white. HLG source status remains HLG, describing decoded video, while presentation is normalized to PQ. SDR uses explicit sRGB output. Texture orientation is preserved. Spatial input is clamped in the scaler's linear RGB space: SDR [0,1], HDR linear BT.2020 half-float highlight range. Explicit color matching around the clamp avoids clipping saturated BT.2020 HDR through Core Image's default sRGB working gamut; this prevents NaN output from sharpen overshoot. Existing fit/fill, MetalFX resolution presets, FG quality/settings, generated/displayed FPS, heat/power/budget gates, PiP, pointer capture, touch input, catalog/imports and other UI features remain available. FG never silently truncates 10-bit or subsamples 4:4:4 to satisfy a processor that accepts only 8-bit NV12.

## HDR negotiation and status

Native ANNOUNCE now explicitly carries HDR dynamic-range/BT.2020 CSC fields, independently of bit depth and chroma. HDR upgrades an old saved 8-bit color preference to the corresponding 10-bit request. H.264 does not advertise HDR. CloudMatch and RTSP retain their separate chroma/depth enums. Known downgraded host profiles are excluded from automatic compatible-session reuse; the request signature changes so a launch requests a fresh profile. Color status distinguishes received video from the requested format. Private bounded logs record requested format/build and finalized host HDR/depth/chroma without tokens, endpoints or full SDP.

Live build-138 fresh-session logs confirmed H.265 hardware 10-bit 4:4:4 HDR PQ on both the M5 iPad and iPhone 18 Pro Max. The phone's earlier AV1 session had HDR off and 4:2:0 despite its request; switching the local decoder alone did not change that host profile. The newly launched H.265 session finalized HDR on and 4:4:4. Latest phone samples decoded about 120 FPS at 2560×1080, with 4.7–5 ms decode and roughly 103–107 presented FPS; recovered bad-data bursts occurred earlier. The new build-139 native conversion path still needs a physical-device comparison for sustained FPS/latency. A host refusal continues to show its actual output. Ten-bit 4:4:4 remains strict H.265 native decoding; incompatible hosts/hardware report failure rather than silently delivering 4:2:0.

## Validation

Run on Apple Silicon macOS 26+ with Xcode's current SDK:

```sh
python3 ios/OpenNOWiOS/BuildScripts/validate-metal4-hdr-macos.py
python3 ios/OpenNOWiOS/BuildScripts/validate-metal4-effects-macos.py
python3 ios/OpenNOWiOS/BuildScripts/validate-metal4-interpolation-macos.py
```

These enable Metal API and GPU validation. Direct rendering checks twelve chroma/range/transfer cases, fit/orientation, bounded slots and forty cross-queue switches. Effects checks twenty-four CI HDR cases plus twelve native PQ cases (all six 10-bit chroma/range formats, upscale on/off), comparing GPU readback against Core Image/legacy MetalFX within four 10-bit codes in these fixtures. Forty native/CI effects switches validate the GPU timeline and fresh pixel values; a gated event verifies two-slot admission and metadata rejection preserves fallback; SDR/sharpen checks include upscale on/off. Interpolation checks eight real size/quality/SDR/PQ combinations, generated motion midpoint/highlights and 944 generated/upscaled images alternating with full-size real frames, including no green/unwritten output and history-only cooldown recovery. Mac fixtures establish pixel correctness and resource ordering, not live iPhone/iPad HDR brightness or sustainable performance.

The unsigned iOS device build and 189 targeted simulator protocol/render/input/PiP/HDR/FG checks passed (zero failures, one hardware MetalFX skip). Hardware-only MetalFX is an explicit simulator skip. A new gamut-clamping regression retains saturated BT.2020 HDR highlights while bounding SDR sharpening overshoot. Native libraries and licenses remain unchanged.

## Apple references

- [Metal 4 core API](https://developer.apple.com/documentation/metal/understanding-the-metal-4-core-api)
- [Metal 4 spatial scaler](https://developer.apple.com/documentation/metalfx/mtl4fxspatialscaler)
- [VideoToolbox command-buffer processing](https://developer.apple.com/documentation/videotoolbox/vtframeprocessor/process(with:parameters:))
- [MetalFX game frame interpolator inputs](https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolatorbase)
