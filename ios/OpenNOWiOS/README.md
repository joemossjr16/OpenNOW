# Joe's OpenNOW iOS build 128

This branch contains the source for **OpenNOW 1.1.128**, based on the upstream iOS branch at `95c0f58d42eeed176edd677f604b193c85169d9e`. It includes the earlier local iOS changes needed by the current native receiver, hardware AV1/HDR rendering, catalog and launch features.

[Unsigned IPA and build notes](https://github.com/joemossjr16/ios-apps/releases/tag/opennow-128) · [KravaSigner feed](https://raw.githubusercontent.com/joemossjr16/ios-apps/main/repo.json)

## Current fixes

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

The preparation script downloads the matching static OpenSSL/usrsctp XCFrameworks, verifies the pinned SHA-256, and installs only their framework directories. Generated libraries and build outputs are ignored by Git. WebRTC remains the vendored framework already in the upstream repository. For a source build of the native dependencies, install CMake and run:

```sh
python3 ios/OpenNOWiOS/BuildScripts/build-native-protocol-libs.py --cmake /path/to/cmake
```

The unsigned device app is in `DerivedData/Build/Products/Debug-iphoneos/OpenNOWiOS.app`. To run directly from Xcode, open `ios/OpenNOWiOS/OpenNOWiOS.xcodeproj` and select your signing team. The native dependency archives contain arm64 device and arm64 simulator slices.

## Receiver setting and validation

Enable **Settings → Stream → Connection → Native NVST Receiver (Experimental)** and start or resume a session. The standard WebRTC receiver remains the default. Native NVST requires iOS 17 or later, an advertised RTSPS endpoint, and hardware decoding. A 10-bit stream cannot silently use an 8-bit output surface. Existing quality settings and device identity are preserved.

Build 128 passed an unsigned arm64 device build and **162 targeted simulator tests**. The new checks cover the presented pointer preference and teardown, capture release policy, independent visible PiP conversion from 10-bit HDR, PiP clock/size bounds, and early/reordered/rejected completion bookkeeping. Existing tests cover encrypted DTLS/SCTP control and input, SRTP/FEC, RTSP, AV1/HDR metadata and settings migration.

Physical iPad mouse capture, PiP/background behavior and the updated decode timing still need testing after installing build 128. Simulator results do not establish physical-device performance. Build 127 live samples showed roughly 120 received/decoded FPS on iPhone and on iPad after a restart; the earlier recurring iPad arrival gaps were absent in the post-restart sample, with their cause still unconfirmed.

Protocol provenance, pinned dependencies and MIT/Apache/BSD licenses are in [NVST](OpenNOWiOS/NVST/README.md). Native microphone carriage requires a host bundle that offers it and the microphone option enabled; legacy standalone microphone carriage is not implemented.
