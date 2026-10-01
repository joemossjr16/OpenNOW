# Joe's OpenNOW iOS build 131

This branch contains the source for **OpenNOW 1.1.131**, based on the upstream iOS branch at `95c0f58d42eeed176edd677f604b193c85169d9e`. It includes the earlier local iOS changes needed by the current native receiver, hardware AV1/HDR rendering, catalog and launch features.

[Unsigned IPA and build notes](https://github.com/joemossjr16/ios-apps/releases/tag/opennow-131) · [KravaSigner feed](https://raw.githubusercontent.com/joemossjr16/ios-apps/main/repo.json)

## Experimental 10-bit 4:4:4 HDR

Enable **Settings → Stream → Connection → Native NVST Receiver (Experimental)**, then under **Stream → Video** select **Color: 10-bit 4:4:4 (Experimental)**, **Codec: H265**, and **HDR: on**. Selecting 4:4:4 chooses H265 automatically; HDR is a separate setting. Start a fresh session after changing the format.

The receiver checks the incoming HEVC bitstream for exactly 10-bit 4:4:4, requires hardware decoding, requests only matching full/video-range 4:4:4 surfaces, and checks actual output chroma-plane dimensions. Unsupported hardware or a downgraded host stream stops with a clear error rather than silently converting to 4:2:0 or 8-bit. The HDR Metal path handles full-resolution chroma without an intermediate copy.

The **Color** status reports actual decoded output and transfer metadata. Look for **10-bit 4:4:4 HDR PQ** for a PQ HDR stream. Host SDR output remains labeled SDR. Build 129 live logs confirmed hardware-decoded 10-bit 4:4:4 HDR PQ on both an iPhone 18 Pro Max and M5 iPad Pro. The iPhone could not sustain the tested 4K/120 workload; successful format support does not establish real-time throughput. Choose **10-bit 4:2:0** if the host or device cannot support it. AV1 remains available for 4:2:0.

## Build 131 recovery fix

Build 130's iPhone sample confirmed hardware-decoded 4K 10-bit 4:4:4 HDR PQ with normal thermal state and Low Power Mode off. Moving segments showed roughly 19–31ms median completion time and about 78–88 decoded FPS as arrival rate varied. The queue-age peak stayed around 249ms, but recovery could then wait for a fresh keyframe until decoding stopped. Those changing conditions do not prove the range-selection change made the hardware faster.

The iOS wrapper sent only RTCP PLI, whose writer did not propagate an unavailable feedback channel, and never used the existing native IDR command. Build 131 requests a fresh keyframe using **0x0302 on reliable SCTP control**, falls back to the encrypted Mjolnir UDP PLI path if control cannot send, and sends feedback-channel PLI only when that channel is open. Request/retry throttling remains. Local counters distinguish requests, accepted control sends, UDP fallback attempts, received keyframes and feedback-channel state.

The recovery command is tested through a real local encrypted DTLS/SCTP association. A build 131 live iPhone sample confirmed 31 accepted control sends, 32 received keyframes including the initial keyframe, and continued decoding across 30 queue recoveries. The host now supplies recovery keyframes, but 4K/120 remained around 88 decoded FPS and 44ms completion time, with queue recovery about once per second. Thermal state was normal, Low Power Mode was off and display GPU time was around 2ms. This verifies recovery in the sampled session and does not establish sustainable 4K/120 throughput. Resolution, frame rate, HDR and color settings are preserved.

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

Install full Xcode with its iOS platform. Run these commands from the repository root:

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
