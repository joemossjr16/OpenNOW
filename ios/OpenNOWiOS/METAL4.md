# Metal 4 streaming renderer

Build **1.1.144 (144)** on [`metal-4`](https://github.com/joemossjr16/OpenNOW/tree/metal-4). [Unsigned experimental IPA](https://github.com/joemossjr16/ios-apps/releases/tag/opennow-metal4-144). The original cumulative changes remain on [`ios/native-nvst-128`](https://github.com/joemossjr16/OpenNOW/tree/ios/native-nvst-128), build 136.

## Rendering and effects

Direct HDR, color conversion, sharpening, spatial scaling and effects presentation use real `MTL4CommandBuffer` / `MTL4CommandQueue` submissions, Metal 4 compiler and pipeline descriptors, argument tables, residency sets, command allocators, commit feedback and drawable synchronization. VideoToolbox hardware decoding remains unchanged.

The effects renderer reads native 8-bit and 10-bit 4:2:0/4:2:2/4:4:4 IOSurface planes, full/video range, and known BT.709/BT.2020 metadata directly. Supported SDR sRGB/BT.709, HDR PQ/HLG, BGRA and explicitly tagged linear RGBAHalf interpolation surfaces enter the Metal 4 path without a per-frame Core Image color-conversion producer. Unknown transfer, ambiguous gamut, unsupported plane geometry or incompatible target format retains the compatible renderer.

PQ converts analytically to linear BT.2020 with 203-nit reference white. HLG uses a 65³ half-float ColorSync lookup prepared once off the display thread. SDR video transfer curves likewise use a small static ColorSync lookup generated from tagged neutral video ramps. These preserve Apple's source interpretation rather than substituting a display gamma for a video transfer function. SDR BT.2020 converts to linear sRGB before presentation. SDR scaler input clamps to [0,1]; HDR retains half-float highlight range. Both HDR transfers present as PQ BT.2020 in a 10-bit EDR drawable; the HUD still identifies the received transfer separately.

Sharpening runs in a Metal 4 compute pass in linear light before MetalFX. Its luminance unsharp filter preserves chroma and HDR highlights and bounds overshoot before the scaler. The existing strength control remains; the new filter is not pixel-identical to Core Image's sharpening filter. Unsupported input/device paths keep the previous Core Image filter. Conversion → sharpening → `MTL4FXSpatialScaler` → presentation share one Metal 4 command buffer with explicit render/compute dependencies. With no effects, the direct PQ renderer continues to avoid the intermediate linear surface.

Two slots bound each configuration; the view admits at most two GPU submissions overall. Separate cached real/generated configurations avoid repeatedly rebuilding scalers when performance interpolation uses smaller images. Setup runs off the display thread. Completion retains source IOSurfaces, color lookups, intermediates, argument tables, uniforms, scalers, producer commands and drawables. Shared GPU events order live renderer switches. Completed GPU failures recover skipped signals and select the compatible renderer. CoreSimulator uses explicit fallback because its SDK omits Metal 4.

## Color selection and persistence

Build 144 saves Color/HDR choices together immediately through the store. Explicitly selecting 8-bit disables HDR, so the requested output stays 8-bit SDR instead of silently promoting to 10-bit HDR. Enabling HDR promotes the selected color to its ten-bit counterpart; disabling HDR preserves the separately selected chroma/depth, allowing 10-bit SDR and 4:4:4 SDR. The picker and summary show effective request color even for older saved HDR-plus-eight-bit preferences. Codec rules remain unchanged; manual video choices select the Custom preset.

The active session keeps its allocation snapshot. Preferences apply to a fresh session; resuming retains the host's existing format. UI guidance distinguishes this from saved settings. Bounded logs record explicit Color/HDR choices without session/account data. Legacy HDR preference migration remains compatible. Three new regressions cover settings reload, launch resolution, CloudMatch/RTSP SDR requests, old-session color mismatch, HDR toggling and codec selection. Rendering remains unchanged from build 143 and retains its actual GPU validation.

## Frame generation and timing

The existing VideoToolbox low-latency video interpolator exposes its generated CVPixelBuffer directly to Metal 4, avoiding a second Core Image presentation conversion for supported output formats. Its processing API still requires a legacy `MTLCommandBuffer`; a GPU event connects that producer to the Metal 4 consumer without CPU waits. The RGB-half source bridge, when supported by the processor, also retains its compatible producer. This is not the game-oriented MetalFX frame interpolator: the video stream does not supply its required game depth and motion-vector textures.

CADisplayLink target timestamps schedule generated/paired-real presentation. When a midpoint cannot fit the remaining display interval, the client presents real video instead while advancing interpolation history. Held real frames expire after two display intervals rather than accumulating latency. Conversion-only producer work is still committed so the next interpolation pair has valid history. The existing warm-up, sustained-overload, heat/power and source-60/display-120 gates remain. Generated/displayed FPS count actual drawable presentation callbacks, not submitted work.

A processor accepting only 8-bit NV12 cannot generate frames for 10-bit/4:4:4 input without losing the requested color format. The app reports that limitation and keeps real decoded video; it never silently truncates HDR or subsamples 4:4:4. GPU fixtures validate output correctness and synchronization, not sustainable iPhone/iPad frame-generation rates or live display brightness.

## Features and native touch

HDR negotiation, strict 4:4:4 validation, MetalFX resolution/quality presets, FG quality/settings, fit/fill, generated/displayed FPS, native touch/finger mouse, pointer capture, PiP, catalog/imports and existing controls remain available. No host codec, color, resolution or FPS request changes in build 143.

Native 4:4:4 defaults to the Windows DESKTOP identity. **Settings → Input → Touch & Controller → Native Touch with 4:4:4 (Experimental)** retains that identity while requesting touchFriendly input provisioning. Touch Mode Always overrides attached physical input; Automatic retains its physical-input preference. Existing 4:2:0 native touch keeps its Android TABLET allocation. Claims preserve the original input envelope; request signatures avoid automatically reusing older incompatible allocations.

The build-142 iPhone test received hardware H.265 10-bit 4:4:4 HDR PQ at about 5 ms decode time, with active native input capture and 344 touch packets accepted by the control transport, zero send failures and zero decoder errors. The user reported touch working. Packet counters confirm client submission, not independent host digitizer acknowledgment or universal game support. Earlier Windows TABLET provisioning caused the host to downgrade video, so the working DESKTOP profile is retained unchanged. If experimental touch fails, disable it and launch a fresh desktop session; Finger Mouse remains available.

## Validation

Run on Apple Silicon macOS 26+ with Xcode's current SDK:

```sh
python3 ios/OpenNOWiOS/BuildScripts/validate-metal4-hdr-macos.py
python3 ios/OpenNOWiOS/BuildScripts/validate-metal4-effects-macos.py
python3 ios/OpenNOWiOS/BuildScripts/validate-metal4-interpolation-macos.py
```

Metal API and GPU validation are enabled. Direct rendering covers twelve chroma/range/transfer cases, fit/orientation, two-slot admission and forty cross-queue switches. Effects covers 24 CI HDR plus 24 native PQ/HLG cases, 96 native SDR chroma/range/transfer/gamut combinations, four BGRA cases, eight linear-RGB/sharpen combinations, four compatible SDR/sharpen cases and native/CI timeline switching. CPU luminance-filter references check sharpening independently, including highlights and upscale on/off. HDR color fixtures differ by at most four 10-bit codes; SDR by at most two codes without upscale/four with upscale. The HDR sharpen/upscale CPU reference allows six codes at half-float rounding boundaries, with mean error below one code (observed maximum five).

Interpolation tests eight size/quality/SDR/PQ combinations and 944 generated/scaled images alternating native/CI presentation and full-size real images, plus history-only cooldown, deadline skips and explicit rejection of unsupported HDR444 generation. No unwritten/green output occurred in the fixtures. The installed Mac processor advertises only NV12, so actual HDR444 interpolation through a half-float processor remains device-dependent; tagged half-float rendering is checked separately.

The unsigned iOS device build and 209 targeted simulator protocol/render/input/PiP/HDR/FG tests passed: zero failures, one hardware MetalFX skip. New regressions cover video-choice persistence/requests in addition to presentation deadlines and direct-effects color metadata. Native libraries and licenses remain unchanged.

## Apple references

- [Metal 4 core API](https://developer.apple.com/documentation/metal/understanding-the-metal-4-core-api)
- [Metal 4 spatial scaler](https://developer.apple.com/documentation/metalfx/mtl4fxspatialscaler)
- [VideoToolbox command-buffer processing](https://developer.apple.com/documentation/videotoolbox/vtframeprocessor/process(with:parameters:))
- [MetalFX frame interpolator inputs](https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolatorbase)
- [Extended linear BT.2020](https://developer.apple.com/documentation/coregraphics/cgcolorspace/extendedlinearitur_2020)
