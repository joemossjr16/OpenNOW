# NVIDIA Image Scaling for OpenNOW iOS

NIS SDK 1.0.3 from https://github.com/NVIDIAGameWorks/NVIDIAImageScaling,
commit `35e13ba316c98eeecf16f37eae70ce88019911f6`.
`NIS_Config.h` and `NIS_Scaler.h` are unmodified upstream files. NVIDIA's MIT
license is retained in both files and in the generated Metal adapter.

Run `python3 ios/OpenNOWiOS/BuildScripts/generate-nis-metal.py` from the repository
root to reproduce `NIS.metal`. The adapter ports NVScaler's six-tap directional
scaling and integrated sharpening to MSL; it does not use proprietary extracted
macOS shaders. Coefficients come directly from the upstream tables.

MSL adaptations:

- Explicit thread/threadgroup/constant address spaces and texture bindings.
- A 32×16 output block with 128 threads to fit Apple's threadgroup memory limit,
  including GPU validation. The host dispatch uses the same block dimensions.
- Partial-block output checks use exclusive bounds, after group barriers.
- Signed support coordinates remain floating point to prevent unsigned wrapping
  at the top and left texture borders.
- Display-referred sRGB inputs use SDR NIS; BT.2020 PQ inputs use PQ NIS. HLG is
  converted through the existing ColorSync transform to PQ before scaling.
- Output clamps to the valid encoded [0,1] range; presentation does not apply the
  transfer function a second time.

Select NIS in Settings → Stream or the stream HUD's Picture panel. Scaling uses
the current decoded resolution and the actual fitted presentation area, without
changing the session's requested resolution. NIS supports enlargement up to 2×
in each dimension. Stream Sharpening controls NVScaler's integrated sharpening;
there is no separate sharpening pass while NIS scaling is active.

Metal 4 uses the existing leased frame slots, decoder coherence, resource
residency, GPU dependencies and presentation ring. Compatible Metal uses the
existing serial queue and three-frame admission limit. Setup occurs off the
display thread; failed setup retains compatible presentation and an unavailable
status. Existing settings continue to select MetalFX until the user chooses NIS.

Validation: `python3 ios/OpenNOWiOS/BuildScripts/validate-nis-macos.py` compares
the Swift constants to NVIDIA's C++ implementation and exercises real SDR/PQ
GPU scaling, partial blocks, signed borders, motion fixtures, and Metal 3/4
SDR/PQ/HLG output agreement. iPhone/iPad gameplay performance remains a device
test, separate from these Mac GPU checks.
