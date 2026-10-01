# Metal 4 development branch

All build 136 changes are preserved on [`ios/native-nvst-128`](https://github.com/joemossjr16/OpenNOW/tree/ios/native-nvst-128). This `metal-4` branch adds the first direct 10-bit HDR Metal 4 renderer, with shared shader/color interpretation, bounded resources, GPU feedback, drawable synchronization and legacy fallback. MetalFX/video interpolation still use their existing pipeline during this first port stage. [Implementation, validation and remaining stages](METAL4.md).

# Joe's OpenNOW iOS build 136

This branch contains the source for **OpenNOW 1.1.136**, based on the upstream iOS branch at `95c0f58d42eeed176edd677f604b193c85169d9e`. It includes the earlier local iOS changes needed by the current native receiver, hardware AV1/HDR rendering, catalog and launch features.

[Unsigned IPA and build notes](https://github.com/joemossjr16/ios-apps/releases/tag/opennow-136) · [KravaSigner feed](https://raw.githubusercontent.com/joemossjr16/ios-apps/main/repo.json)

## Build 136: independent frame-generation quality

**Frame Generation Quality → Performance / Native** is available in Settings and the in-stream Picture panel, separate from the MetalFX Quality preset. Performance is the new FG quality default (the FG toggle still defaults off). It interpolates smaller 8-bit NV12 inputs, capped at 960 pixels per axis / 518400 pixels, then scales the generated image for display. For 1680×720, generated images are 960×410; for 1080p they are 960×540. With MetalFX enabled, generated frames use the spatial scaler when its scale limits allow. Real decoded frames retain full resolution. Native keeps full-input interpolation. Source HDR/codec/color/FPS/bitrate and host resolution are unchanged by this selector, and it can change during gameplay.

Other color formats retain native processing size; unsupported formats, original received sizes and devices remain rejected. This does not establish 10-bit/4:4:4 interpolation support. Separate MetalFX resources for different real/generated input sizes avoid repeated asynchronous setup. The HUD now reports actual processing geometry plus measured Generated/Displayed FPS. Motion artifacts and presentation delay remain possible. GPU/pool/history, power/thermal and budget safeguards remain.

A current iPhone 1680×720 PQ sample decoded around 4.2 ms but interpolation/rendering averaged about 18.2 ms against an 8.33 ms display budget, producing few generated presentations. This change reduces interpolation work. Synthetic Mac checks at 1680×720 PQ measured a generated-frame encode-to-completion median of ~3.3 ms Performance vs ~8.7 ms Native, excluding separate real-frame rendering and readback. They do not establish sustained iPhone performance.

Validation: unsigned iOS build passed; **184 tests passed, zero failed, one simulator skip** (185 successful executions with dynamic parameters). New geometry/migration/GPU resize/range/PQ tests passed with existing regressions. Real Mac GPU checks covered both quality modes, 1080p and 1680×720, SDR/PQ, and alternating real/generated presentation: **944 combined generated images** preserved motion midpoint, neutral color, orientation and HDR highlights. Processor limits and history-only cooldown checks passed. Physical-device testing is still needed.

## Build 135: interpolation limits and generated/displayed FPS

The HUD and Picture panel now show **Generated FPS** and **Displayed FPS** separately from decoded stream FPS. These count actual drawable presentation callbacks in one-second windows: generated only, and total real + generated, respectively. They do not infer rates from 120 Hz, requested FPS or submitted work. Duplicate/backwards callbacks are ignored; old measurements expire after a pause.

An oversized-interpolation reproduction on this Mac accepted a 2560×1080 configuration/session and completed GPU commands but left the output Y/UV planes unwritten. The runtime API reports **1920 per axis / 2073600 total pixels** on this Mac. That failure can produce invalid/green output; it does not independently establish the iPhone's exact limit or every possible cause of flashing. Build 135 queries the device's maximum dimension **and** total pixel count on OS 27+, and rejects out-of-bounds input before allocating/presenting an interpolated frame. Older OS versions use an explicit conservative 1920-axis/1080p pixel ceiling. Unsupported input keeps ordinary decoded playback and reports its limit.

With FG enabled, automatic MetalFX presets now filter sizes through these limits and show their exact choice. The Resolution picker marks **FG size eligible / unsupported**; other device/format/FPS restrictions still apply. Opening Settings recalculates an active automatic preset. Manual resolution stays selected; select an eligible size and start a **fresh session** to apply the host request. Codec, HDR, bit depth/chroma, FPS and bitrate are preserved. For an illustrative 2868×1320 fill target at 21:9, the Mac's 1920/1080p limit makes Quality select the catalog's 1680×720 rather than 2560×1080 when FG is enabled. Actual device limits determine your choice.

The budget now also requires average completion cost above the display interval before suspending a sustained over-budget window, so the pause message cannot claim an average below budget exceeds it. Warm-up, bounded work, history-only cooldown and power/thermal/error guards remain.

Validation: unsigned iOS build passed; **182 tests passed, zero failed, one MetalFX simulator skip** (183 total). Presentation-meter, size/overflow/preset and average-budget tests passed with existing regressions. Real Mac GPU tests reject oversized interpolation, compare MetalFX orientation with ordinary playback, preserve HDR highlights, generate motion midpoints, resume after history-only cooldown, and process **118 SDR + 118 PQ frames** with interpolation and MetalFX in the same command buffer without unwritten/green neutral samples. Physical iPhone/iPad retest is still needed; these checks do not establish every corruption case, sustainable throughput or 10-bit/4:4:4 interpolation support. Build with the iOS 27 SDK; the Mac GPU harness requires the macOS 27 SDK.

## Build 134: orientation and interpolation startup/cooldown fixes

MetalFX no longer adds an extra vertical mirror after importing its output texture. The previous synthetic test assumed bitmap row order matched displayed orientation. Comparing the complete MetalFX path against ordinary playback reproduced the upside-down image. New GPU checks compare both output textures, covering asymmetric float HDR and NV12 SDR/PQ input. HDR highlights and fit/fill remain preserved.

The interpolation budget no longer pauses after only three startup frames or reloads the ML processor after every budget cooldown. It allows eight generated warm-up submissions, then requires nine over-budget completions in a rolling twelve-frame window before a two-second pause. Acquiring the drawable/converting the received frame is excluded from effect cost; encode/queue/completion wall time remains measured because GPU timestamps can omit ML work. The limit is still one native display interval (8.33ms at 120 Hz). History-only cooldown retains the initialized processor; GPU errors still reset it and pause five seconds. Stale completions cannot alter the current budget. Pools/admission/pending-frame limits and thermal/power/error safeguards remain. The HUD reports actual average processing time versus budget; diagnostics distinguish encode/GPU/completion cost. Discontinuous or slow source frames report **Waiting for steady 60 FPS input**.

A build-133 iPhone sample showed 1680×1050 8-bit SDR → 2112×1320 MetalFX output, three generated frames before the old pause, and startup GPU peak ~22.7ms. Later source arrival was ~40 FPS, with decode ~4ms and ordinary rendering ~3.5ms. These changing samples do not establish sustained interpolation cost. Frame generation still requires steady source frames; this change does not promise sustainable interpolation at every resolution.

Validation: unsigned iOS build passed; **180 tests passed, zero failed, one MetalFX simulator skip** (181 total). Real Mac GPU comparisons now match ordinary playback orientation for float HDR and NV12 SDR/PQ, with a 4.0 HDR highlight preserved at ~3.96. SDR/PQ native interpolation midpoint and HDR highlight checks passed, including resumption after history-only cooldown without ML session reload. Physical iPhone/iPad performance remains to be tested. Reproduce with `python3 ios/OpenNOWiOS/BuildScripts/validate-video-effects-macos.py`.

## Build 133: MetalFX quality presets, resolution labels and video interpolation

Both effects default **off**. Enable **Settings → Stream → Video → MetalFX Upscaling**, or toggle it in the in-stream **Picture** panel. This is Apple's **MTLFXSpatialScaler**, applied to a lower-resolution received image and the actual visible drawable size. It skips equal-resolution/downscale cases. HDR uses RGBA half-float extended linear BT.2020, MetalFX HDR processing and the original PQ/HLG 10-bit EDR display output. Initialization stays off the display thread; bounded reusable textures share the renderer's serial GPU queue. A real Mac MetalFX readback test verified HDR values above SDR white and correct horizontal/vertical orientation.

Enable MetalFX to show **MetalFX Quality: Manual / Quality / Balanced / Performance**. Each preset displays the exact input resolution it selects; automatic presets choose the nearest eligible, plan-allowed size at approximately 85% / 67% / 50% of the fitted landscape output dimensions. They preserve codec, HDR, color, FPS and bitrate. Start a **fresh session** to apply a changed host resolution; resuming an existing session may retain its old size. Manual keeps your choice. Selecting a resolution or the general stream preset resets MetalFX Quality to Manual. Aspect ratio, fit/fill and membership changes recalculate an active preset; choices with no eligible size are disabled. Catalog limits may make presets select the same size.

The **Resolution** picker labels choices **MetalFX eligible** or **No upscale** when MetalFX is enabled. The summary shows input → estimated landscape output; the live HUD reports actual drawable dimensions when bypassed. Eligibility is based on fit/fill geometry, with output greater than 1.02x and at most 4x on both axes. It does not establish physical-device MetalFX support. A 2560×1600 input can already exceed a fitted phone viewport: selecting a lower input and starting a fresh session is required to reduce decoder work. On an illustrative 2796×1290 screen at 16:10 fit, the output is 2064×1290 and Quality / Balanced / Performance select 1680×1050 / 1440×900 / 1280×800. The UI uses your device's dimensions rather than hard-coded phone resolutions. Presets select input size; MetalFX spatial has no quality-property setting.

**Frame Generation (Experimental)** uses Apple's video-oriented `VTLowLatencyFrameInterpolationConfiguration`, generating one midpoint between consecutive 60 FPS decoded frames on a 120 Hz display. It then presents the corresponding real frame on the next display tick. Host quality/FPS requests remain unchanged. It adds display delay and can show artifacts; existing FPS/decode stats continue reporting decoded stream frames. The effects HUD reports actual preparation, active or unavailable state; local diagnostics count generated presentations separately.

Frame interpolation requires iOS 26+ and runtime support for the received size and color format. It uses exact-format buffers, or full-resolution half-float RGB only if advertised as supported. Build 133 additionally bridges decoded `420f` to advertised `420v` with GPU-only luma/chroma range mapping, retaining resolution, 8-bit precision, 4:2:0 geometry, matrix, primaries and transfer metadata. This supports both SDR and already-8-bit PQ HDR without converting their transfer function. It **never converts 10-bit/4:4:4 input into 8-bit/4:2:0** to enable interpolation. On this Mac the processor advertises only `420v`; 10-bit/4:4:4 interpolation is unavailable here. iPhone/iPad support must be queried on-device; physical-device interpolation support/performance remains unverified. Low Power Mode, serious heat, processing errors and sustained missed 120 Hz deadlines suspend frame generation. ML initialization stays off the UI thread. One pending real frame, bounded pools and two GPU submissions limit backlog; stale/out-of-order frames discard history.

Validation: unsigned arm64 iOS build passed; **180 targeted simulator tests passed**, zero failed, with one explicit MetalFX skip (181 total) because Apple does not ship it in the simulator SDK. Tests cover preset geometry/plan limits, persistence, GPU full/video range mapping/PQ metadata and retained protocol/decode/render/input/PiP regressions. Separate macOS harnesses ran the same effects on real Apple GPU/API paths. MetalFX preserved a 4.0 linear HDR highlight at approximately 3.96 with correct orientation. Native interpolation through the GPU range bridge produced a moving-bar midpoint at x=755.51 for SDR and x=755.50 for 8-bit PQ HDR, expected x=755.5, and completed GPU commands. PQ highlight remained approximately 13.67 versus source 13.63 (SDR white is 1.0). These synthetic checks do not establish iPhone/iPad real-time performance, format support or visual quality. Reproduce on an Apple Silicon Mac with `python3 ios/OpenNOWiOS/BuildScripts/validate-video-effects-macos.py`.

### 4:4:4 decode audit

The decoder already requires and verifies hardware, preserves full-resolution 10-bit IOSurfaces, permits compatible full/video ranges, uses single-pass compressed-frame preparation and avoids temporal/B-frame reorder buffering. No documented property found in this review promises additional 4K/120 4:4:4 throughput. Apple's `1xRealTimePlayback` decode flag is a power-saving hint, and output-pool minimum count controls memory retention rather than decoder concurrency. Previous measured iPhone 4K/120 throughput and queue recovery remain documented below. The user now reports about **7ms at a smaller iPhone-oriented resolution and 120 FPS**; those exact dimensions/current throughput were not independently captured. Lower received resolution plus local MetalFX upscaling is the practical next comparison, without lowering chroma depth or HDR.

### Later Metal 4 / MetalFX integration

A Metal 4 render backend can reuse decoded IOSurfaces and migrate command/resource management in stages, with device capability checks, explicit barriers and a tested Metal 3 fallback. Benchmark GPU time, completion latency, power/thermal state and presentation pacing before enabling it by default. VideoToolbox hardware decoding remains separate; changing the graphics API does not itself make the media decoder faster.

MetalFX temporal upscaling and game-frame interpolation need game depth/motion textures. MetalFX denoised upscaling additionally needs normals, diffuse/specular albedo and roughness. The present GFN video protocol supplies finished encoded images, not those renderer buffers. An estimated-motion/depth experiment would require additional inference and validation and is not equivalent to native game-renderer integration. True game-data integration would need a host/game path that exports those buffers alongside the stream. Image-domain video interpolation is the supported client-side alternative implemented above; a video noise filter would be a separate feature rather than MetalFX ray-tracing denoising.

Apple references: [MetalFX overview](https://developer.apple.com/documentation/MetalFX), [Metal 4 overview](https://developer.apple.com/videos/play/wwdc2025/205/), [game interpolation and denoising requirements](https://developer.apple.com/videos/play/wwdc2025/211/), [video interpolation](https://developer.apple.com/documentation/videotoolbox/vtlowlatencyframeinterpolationconfiguration).

## Experimental 10-bit 4:4:4 HDR

Enable **Settings → Stream → Connection → Native NVST Receiver (Experimental)**, then under **Stream → Video** select **Color: 10-bit 4:4:4 (Experimental)**, **Codec: H265**, and **HDR: on**. Selecting 4:4:4 chooses H265 automatically; HDR is a separate setting. Start a fresh session after changing the format.

The receiver checks the incoming HEVC bitstream for exactly 10-bit 4:4:4, requires hardware decoding, requests only matching full/video-range 4:4:4 surfaces, and checks actual output chroma-plane dimensions. Unsupported hardware or a downgraded host stream stops with a clear error rather than silently converting to 4:2:0 or 8-bit. The HDR Metal path handles full-resolution chroma without an intermediate copy.

The **Color** status reports actual decoded output and transfer metadata. Look for **10-bit 4:4:4 HDR PQ** for a PQ HDR stream. Host SDR output remains labeled SDR. Build 129 live logs confirmed hardware-decoded 10-bit 4:4:4 HDR PQ on both an iPhone 18 Pro Max and M5 iPad Pro. The iPhone could not sustain the tested 4K/120 workload; successful format support does not establish real-time throughput. Choose **10-bit 4:2:0** if the host or device cannot support it. AV1 remains available for 4:2:0.

## Build 131 recovery fix

Build 130's iPhone sample confirmed hardware-decoded 4K 10-bit 4:4:4 HDR PQ with normal thermal state and Low Power Mode off. Moving segments showed roughly 19–31ms median completion time and about 78–88 decoded FPS as arrival rate varied. The queue-age peak stayed around 249ms, but recovery could then wait for a fresh keyframe until decoding stopped. Those changing conditions do not prove the range-selection change made the hardware faster.

The iOS wrapper sent only RTCP PLI, whose writer did not propagate an unavailable feedback channel, and never used the existing native IDR command. Build 131 requests a fresh keyframe using **0x0302 on reliable SCTP control**, falls back to the encrypted Mjolnir UDP PLI path if control cannot send, and sends feedback-channel PLI only when that channel is open. Request/retry throttling remains. Local counters distinguish requests, accepted control sends, UDP fallback attempts, received keyframes and feedback-channel state.

The recovery command is tested through a real local encrypted DTLS/SCTP association. A build 131 live iPhone sample confirmed 31 accepted control sends, 32 received keyframes including the initial keyframe, and continued decoding across 30 queue recoveries. The host now supplies recovery keyframes, but 4K/120 remained around 88 decoded FPS and 44ms completion time, with queue recovery about once per second. Thermal state was normal, Low Power Mode was off and display GPU time was around 2ms. This verifies recovery in the sampled session and does not establish sustainable 4K/120 throughput. Resolution, frame rate, HDR and color settings are preserved.

### iPhone 4K/60 comparison

A follow-up build 131 iPhone test changed only FPS to 60 while retaining 3840×2160, H265, 10-bit 4:4:4 and HDR. The last 30-second sample averaged **60.13 received FPS and 60.13 decoded FPS**, with decoded output still reporting **hardware=true / 10-bit 4:4:4 HDR PQ**. Median completion time stayed at **13.2ms** (sample medians 13.2–13.3ms), queue depth was zero at the last sample with a lifetime peak of two frames, and queue recoveries, skipped frames and decode errors all remained zero. Display samples presented around 60 FPS. Thermal state remained normal and Low Power Mode was off. This supports an overload diagnosis for the tested 4K/120 decoder path; it does not establish a permanent device limit or guarantee stutter-free playback outside the measured interval.

## Build 130 iPhone decode test

With the same requested 4K/120 H265 10-bit 4:4:4 HDR settings, build 129 samples showed roughly 120 received FPS but only 88–90 decoded FPS and about 50ms completion latency on iPhone. Queued work grew past 20 seconds of delay. An iPad working segment showed roughly 120 decoded FPS and 7.7ms completion latency. iPhone display GPU time was about 2.5ms.

Build 130 offers VideoToolbox both compatible full/video-range 10-bit 4:4:4 surfaces, allowing it to choose an output rather than requiring full range. Single-format fallback follows the source range. Actual decoded chroma/depth are still checked and the renderer handles either range. This tests whether forced range conversion contributed to the iPhone cost; that cause remains unconfirmed.

A single drain worker now consumes a compressed-frame inbox capped at 32 frames with a 250ms queued-age budget. Overflow/expiration discards stale queued work and waits for a fresh keyframe, retrying requests while waiting. It preserves healthy bursts and prevents indefinite queued-frame accumulation without decoding dependent frames from a deliberately broken chain. It cannot make overloaded hardware sustain 120 FPS or guarantee the host's keyframe response time.

Local numeric logs now distinguish preparation/build/submission time, completion latency, actual output format/resolution, decoder rebuilds/failures, queue recovery/drop counts, thermal state and low-power status. Build 131 host recovery is confirmed in the sampled iPhone session; sustained iPhone 4K/120 throughput remains unresolved. Resolution, FPS, HDR and color settings are not automatically downgraded.

## Retained fixes

- Gameplay uses a fullscreen UIKit hosting controller to request iPadOS pointer lock. Capture releases for controls, editing, guidance/alerts, inactive scenes and PiP, then resumes with gameplay.
- PiP uses an independent SDR preview capped at 1280×720 and 30 FPS. It has bounded frame admission and surface allocation, a host-clock playback timeline, and CPU conversion for background operation. The main stream retains its selected resolution, 10-bit HDR and hardware decoding.
- Native VideoToolbox submissions are recorded before calling the decoder and matched to their completion by frame ID. Early callbacks, rejected submissions and empty samples cannot shift a FIFO and misattribute timing or acknowledgements.

Native decode timing measures submission-to-output completion latency. It includes asynchronous decoder queueing and is different from the earlier decoder-call CPU timing; these changes do not promise a particular decode time.

## Build on an Apple Silicon Mac

Install full Xcode providing the iOS 27 SDK and its iOS platform. Run these commands from the repository root:

```sh
python3 ios/OpenNOWiOS/BuildScripts/prepare-native-libraries.py
xcodebuild build \
  -project ios/OpenNOWiOS/OpenNOWiOS.xcodeproj \
  -scheme OpenNOWiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

The preparation script downloads the matching static OpenSSL/usrsctp XCFrameworks, verifies the pinned SHA-256, and installs only their framework directories. The native C libraries are unchanged from build 128, so the preparation script reuses that checksum-pinned archive. Generated libraries and build outputs are ignored by Git. WebRTC remains the vendored framework already in the upstream repository. For a source build of the native dependencies, install CMake and run:

```sh
python3 ios/OpenNOWiOS/BuildScripts/build-native-protocol-libs.py --cmake /path/to/cmake
```

The unsigned device app is in `DerivedData/Build/Products/Debug-iphoneos/OpenNOWiOS.app`. To run directly from Xcode, open `ios/OpenNOWiOS/OpenNOWiOS.xcodeproj` and select your signing team. The native dependency archives contain arm64 device and arm64 simulator slices.

## Receiver setting and validation

Enable **Settings → Stream → Connection → Native NVST Receiver (Experimental)** and start or resume a session. The standard WebRTC receiver remains the default. Native NVST requires iOS 17 or later, an advertised RTSPS endpoint, and hardware decoding. A 10-bit stream cannot silently use an 8-bit output surface. Existing quality settings and device identity are preserved.

Build 131 passed an unsigned arm64 device build and **173 targeted simulator tests**. New checks cover exact IDR control-command framing, UDP fallback, and command delivery through a local encrypted DTLS/SCTP association. Tests additionally verify healthy queue bursts/FIFO order, bounded overflow and keyframe retry over thousands of arrivals, stale-work expiration, and that compatible range requests never allow chroma/depth downgrade. Existing tests verify strict 10-bit/4:4:4 bitstream validation, full/video-range surfaces, actual-output HDR labels, settings persistence, separate CloudMatch and RTSP chroma enums, and GPU readback of alternating one-pixel chroma detail through the HDR Metal renderer. Existing tests cover pointer preference and teardown, capture release policy, independent PiP conversion from 10-bit HDR, PiP clock/size bounds, early/reordered/rejected completion bookkeeping, encrypted DTLS/SCTP control and input, SRTP/FEC, RTSP, AV1/HDR metadata and settings migration. Simulator rendering tests do not establish physical hardware support for HEVC 10-bit 4:4:4.

Physical iPad mouse capture, PiP/background behavior and the updated decode timing still need testing after installation. Simulator results do not establish physical-device performance. Build 127 live samples showed roughly 120 received/decoded FPS on iPhone and on iPad after a restart; the earlier recurring iPad arrival gaps were absent in the post-restart sample, with their cause still unconfirmed.

Protocol provenance, pinned dependencies and MIT/Apache/BSD licenses are in [NVST](OpenNOWiOS/NVST/README.md). Native microphone carriage requires a host bundle that offers it and the microphone option enabled; legacy standalone microphone carriage is not implemented.
