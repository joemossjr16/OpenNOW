# Metal 4 streaming renderer development

Branch: `metal-4`. Baseline: build 136 at `ffc69ff0f13f69c60de8a22abcfe1b7a78b9ea29`. All existing changes are also pushed to [`ios/native-nvst-128`](https://github.com/joemossjr16/OpenNOW/tree/ios/native-nvst-128); subsequent Metal 4 development belongs here.

## Implemented: direct 10-bit HDR rendering

`NativeStreamMetal4HDRRenderer` submits real `MTL4CommandBuffer` work to an `MTL4CommandQueue`. It uses a Metal 4 compiler/pipeline descriptor, explicit command allocators, argument tables with GPU addresses/resource IDs, and residency sets. Two reusable slots bound in-flight work. Allocators, uniform memory and argument tables are reused only after commit feedback confirms completion. Source pixel buffers, IOSurface texture wrappers, output textures and drawables stay alive through completion.

The legacy and Metal 4 renderers share `NativeStreamHDRMetalProgram` for input validation, shader source, full/video-range math, BT.2020 coefficients and decoded-buffer orientation. Native 10-bit 4:2:0, 4:2:2 and 4:4:4 planes retain their original sizes; the renderer never reduces chroma detail or bit depth to match the API. PQ/HLG remain encoded, and the existing 10-bit EDR display layer owns color conversion.

On a physical iOS 26+ device that reports Metal 4 support, the stream view initializes this renderer asynchronously and selects it for eligible direct HDR playback when MetalFX, FG and sharpening are off. Unsupported input, unsupported hardware, setup failure or slot exhaustion uses the existing path. A GPU error disables Metal 4 for that view and selects legacy playback. The status identifies the active renderer; source codec and decode timing remain separate.

Metal 4 drawable submission follows `waitForDrawable` → commit → `signalDrawable` → present. Actual presented callbacks feed the existing display statistics. Commit feedback supplies GPU timing. A lock-protected telemetry owner handles GPU/presentation callbacks independently of UIView actor isolation; concurrent rate/counter updates and reset are covered by regression tests. A shared event timeline orders submissions across the two queues when live settings switch render paths. Tickets advance only after submission succeeds; completed GPU failures recover skipped event signals. Display code never blocks on GPU completion or compilation. CoreSimulator has an explicit unavailable implementation because its SDK omits the Metal 4 command API.

## Validation

The unsigned iOS build succeeds. 186 targeted protocol/rendering/input/PiP/HDR/FG simulator tests pass, zero fail, and one MetalFX test is explicitly skipped. This includes shared HDR input rejection and simulator fallback. Hardware-only MetalFX remains an explicit simulator skip.

Run on an Apple Silicon Mac with macOS 26+ and current Xcode:

```sh
python3 ios/OpenNOWiOS/BuildScripts/validate-metal4-hdr-macos.py
python3 ios/OpenNOWiOS/BuildScripts/validate-video-effects-macos.py
```

The new harness enables Metal API/GPU validation. It compares actual output pixels against the legacy renderer across all twelve combinations of 10-bit chroma layout, full/video range and PQ/HLG. It checks orientation, fit borders, adjacent 4:4:4 chroma detail, rejection of unsupported transfer functions, two-slot admission using a deliberately blocked GPU event, slot reuse and forty legacy/Metal 4 transitions. The existing harness checks HDR MetalFX, interpolation, limits, cooldown and alternating real/generated frames. These tests do not establish sustained iPhone/iPad performance, actual display EDR brightness or physical-device presentation timing.

## Next port stages

1. Port spatial upscaling to `MTL4FXSpatialScaler`. Define explicit producer/consumer events and bounded intermediate surfaces for the existing Core Image input/final conversion. Measure the synchronization and submission cost before selecting the new scaler in live playback.
2. Move eligible image conversion/sharpening into Metal 4 encoders so the display path can reduce queue handoffs. Compare HDR transfer/range and fit/fill output against existing playback before changing defaults.
3. Integrate video interpolation through explicit interoperability. The current SDK's `VTFrameProcessor.process` accepts `MTLCommandBuffer`; its processing remains on the legacy queue until a tested cross-queue bridge exists. Keep original/generated timestamps, presentation counters, history and budget ownership in the current module.

Metal 4 game-oriented temporal upscaling/frame interpolation requires inputs such as engine motion vectors and depth that the compressed GFN video stream does not currently supply. This branch does not fabricate these inputs or replace the working video interpolation with an unsupported game-renderer algorithm. Native MetalFX frame generation and denoising need a separately validated input strategy; changing command APIs alone does not supply it.

## Apple references

- [Understanding the Metal 4 core API](https://developer.apple.com/documentation/metal/understanding-the-metal-4-core-api)
- [Metal 4 spatial scaler](https://developer.apple.com/documentation/metalfx/mtl4fxspatialscaler)
- [Metal 4 command queue and drawable synchronization](https://developer.apple.com/documentation/metal/mtl4commandqueue)
- [MetalFX frame interpolator inputs](https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolatorbase)
- [VideoToolbox frame processor](https://developer.apple.com/documentation/videotoolbox/vtframeprocessor)

SDK signatures are checked against the installed iOS/macOS 27 headers. Runtime deployment remains compatible with older iOS through availability/capability fallback.
