# Camera quality investigation — iPhone 17 Pro Max

## Result and scope

Tested on the connected iPhone 17 Pro Max (`iPhone18,2`), iOS 27.0.1, on 2026-10-25.
The user positioned the phone facing a fixed window/railing scene under unchanged indoor lighting.
The original camera policy and candidate were compared at 1× → 0.5× → 1× → 4× → 1×,
including a three-second background interval at every setting. Automatic lighting was tested separately.
Full-color delivered buffers, sample metadata, screenshots, configuration, drop reasons and timestamps
were inspected. Final runs included all app resources and used small-frame recording off, full every 120.
Normal-preview telemetry was sampled after stopping recording.

The fix improves secondary-camera exposure and detail visibility, fixes the exposure jump on foreground
return, and preserves the main camera's existing daylight format and rate. Residual low-light noise and
telephoto softness remain; these tests do not prove that all remaining softness is a hardware limit.
No new UI, filters, camera modes, virtual-camera fallback or feature work was added.

## Physical inputs verified on the device

| UI | Physical device type | Device ID suffix | Digital zoom | Format FOV | Delivered buffer |
| --- | --- | --- | --- | --- | --- |
| 0.5× | BuiltInUltraWideCamera | `video:5` | 1.000× | 106.20° | 1920×1080, unbinned |
| 1× | BuiltInWideAngleCamera | `video:0` | 1.000× | 74.60° | 1920×1080, unbinned |
| 4× | BuiltInTelephotoCamera | `video:2` | 1.000× | 19.86° | 1920×1080, unbinned |

All three inputs reported `virtualDevice=false`, preview-sized output off, stabilization off, measured
intrinsics enabled, and a digital-upscale threshold of 2.000×. **1× is the physical wide camera, not an
ultra-wide crop.** The labels are approximate native-lens labels, not exact measured focal-length ratios.
The actual per-frame intrinsics agree with the different fields of view after switching settles.
Device properties observed during the first callback after a switch can describe the new configuration
while an old queued sample still carries old intrinsics; analysis excludes the settling interval.

## Where quality first degraded

The delivered BGRA buffers already contain the secondary-camera noise, underexposure and softness.
The receiver wraps the same buffer in a Metal texture without resizing. Rendering rotates/aspect-fills
and samples that texture once with linear filtering, with optional gyro reprojection. There is no
secondary-camera blur pass or intermediate low-resolution camera render target. The native drawable
was 1320×2868, with 1.494 display pixels per sensor pixel for all three 1080p buffers.

The initial code hypothesis was a 720p/high-speed format outranking 1080p. That is a real possibility in
the old ranking, but **was not the target-device defect**: all tested lenses already delivered 1080p.
Instead, the original selection/exposure policy pushed every physical camera to about 120 fps. The
secondary cameras reached their ISO ceilings while their exposure time remained about 6.65 ms.

Final matched Day-mode recordings, excluding startup and settling samples:

| Input | Original → candidate capture rate | Device exposure | Median AE target offset |
| --- | --- | --- | --- |
| 0.5× | 119.96 → 59.97 fps | 6.65 → 16.32 ms | −2.21 → −0.04 EV |
| 1× | 119.96 → 119.96 fps | 6.65 → 6.65 ms | −0.60 → −0.72 EV |
| 4× | 119.96 → 59.97 fps | 6.65 → 16.32 ms | −4.52 → −0.39 EV |

The candidate's native secondary-camera images show more usable detail and brightness. It is not
accurate to call this a simple ISO reduction: observed ultra-wide ISO rose from about 1463 to 2708,
and telephoto from about 1170 to 7733 as metering recovered brightness. The photon budget and camera
operating constraints changed; high telephoto gain still leaves visible noise. These are automatic
exposure observations, not calibrated photometric measurements or scene-independent quality scores.

The bounded change gives secondary cameras a resolution-first, non-binned preference within the same
FOV bucket, then up to 60 fps. Formats that cannot run between 30 and 60 fps are excluded for them.
The main camera retains its exact original ranking and 120 fps cap. The 1920-width cap remains;
there is no unmeasured 4K bandwidth increase or extra processing pass. Intrinsics-support fallback can
still select a lower-ranked candidate on other hardware; tried-format diagnostics expose this.

## Foreground return: reproduced cause and fix

The original automatic-lighting run started in continuous auto exposure at roughly 1/150 s and sample
ISO 4000. After returning from background, it switched to fixed 1/8 s and maximum manual ISO (device
3456, sample 3200), reporting about **+2.54 EV** overexposure. The blown-out image is present in the
original buffer, before rendering.

Two related code defects explain the change:

1. `start()` applied exposure, then awaited focus while status was still idle. The lighting refresh could
   change the phase during that await, cache the new blend and mark it pushed, but skip applying it
   because capture was not yet marked running. The next resume finally applied that cached night phase.
2. Night defaulted to manual exposure at the format's maximum ISO, regardless of scene brightness.

Capture is now marked running before awaiting focus, so lighting updates during the await take effect.
An awaited start also no longer sets running again after a concurrent stop. A stopped session retains
its real physical-lens identity; `setInitialLens` cannot relabel an already attached input as wide.
Night now defaults to the existing automatic-ISO strategy. This hardware reports shutter-priority
unsupported for the chosen format, so the controller uses continuous auto exposure with the existing
night shutter ceiling instead of falling back to maximum manual ISO. Explicit manual mode remains.

The candidate's Auto run reported AE target offsets around +0.014 EV before background and −0.014 EV
after return. Sample exposure/ISO changed from approximately 1/60 s / 3200 to 1/14 s / 640 while keeping
the image metered. This scene still invokes night settings because Auto is driven by solar altitude;
the change does not add ambient-light mode detection.

## Main-camera pacing and limitations

- Main-camera steady capture stayed at 119.96 fps with an 8.34 ms p95 frame period, before and after resume.
- Recording-off Day telemetry: original display/drawn-camera rates 106.4/91.7 fps; candidate 110.3/96.1 fps.
  Both reported delivered 120 fps. Capture-to-target-display snapshots were 46.3/54.3 ms respectively;
  callback latency snapshots 23.5/21.5 ms. These short readings show no sustained rate regression, not
  a guarantee of identical latency or actual panel presentation.
- Original final Day recording had zero reported drops; candidate had ten `FrameWasLate` callbacks in
  a short burst around 106 seconds during the last wide-camera segment. Its other settled segments
  delivered the expected rates, and the final wide segment returned to 119.96 fps. This small burst
  remains a measured limitation; zero-drop equivalence has not been established.
- Night frame rate is allowed to adapt to metering. The candidate night snapshot delivered 14.3 fps,
  versus the original's forced 8 fps; the normal daylight main-camera policy is unchanged.
- The measured apertures were f/2.2 ultra-wide, f/1.78 wide, and about f/2.80 telephoto. Telephoto reports
  a 1160 mm minimum focus distance (wide 200 mm, ultra-wide 20 mm). It cannot focus arbitrarily close.
  AF was settled in the comparison samples; a settled AF flag does not prove correct optical focus.
- The scene includes reflective glass, dark outdoor content and moving reflected people. Fixed structural
  detail was compared; this was not a calibrated chart, lux-controlled multi-light experiment, distance
  sweep or controlled camera pan. Remaining blur cannot be conclusively divided among focus distance,
  reflections and ISP/hardware without those additional measurements. Stabilization remains off to
  preserve intrinsic delivery. No claims about handheld telephoto stabilization were inferred from a
  stationary phone.
- Earliest app frames are after Apple's ISP, not sensor RAW. The evidence locates the observed degradation
  upstream of app rendering but cannot separate sensor and ISP processing internally.

## Evidence and repeatability

Evidence is local under `build/camera-evidence/` (ignored by Git):

- `baseline-day`, `candidate-day`, `baseline-auto`, `candidate-auto`: `meta.json`, `frames.jsonl`,
  `renders.jsonl`, `drops.jsonl`, selected original full-color PNGs and their metadata.
- `final-report.json`: settled timing summaries. Background timestamp discontinuities are segmented
  separately so a deliberate three-second pause is not misreported as low continuous capture FPS.
- `build/camera-baseline-final-attachments/` and `build/camera-candidate-final-attachments/`: screenshots
  and recording-off telemetry exported from the device test bundles.

The earliest isolated baseline build omitted sky resources; it was corrected and the final baseline
repeated with full resources before comparing rendering performance. Earlier exploratory sessions
are retained separately and are not used for the final performance conclusion.

The existing recorder now also stores lossless full-color BGRA copies before app rendering. PNG encoding
runs off the capture queue, and sampled buffers are copied rather than retained in the camera pool.
Per-frame diagnostics add no reads/copies/writes to normal preview unless recording is active. Frame
rows distinguish per-sample exposure/ISO/intrinsics from device properties observed at callback time.
Render timing is a CPU draw request plus display-link target, not GPU completion or panel measurement.
The probe includes the available format inventory; drop callbacks include Apple's reason.

Repeat with the existing Debug recorder (Small off; Full every 120), then run:

```sh
python3 tools/inspect_camera_quality.py <baseline-session> <candidate-session> > report.json
```

For a sharper focus/optics diagnosis, use a stationary, distant, finely textured target in stronger
constant light, away from reflective glass, and repeat at known distances. Do not compare unrelated
whole-frame sharpness scores across different fields of view.

Validation: signed device build; both final physical-camera UI tests passed; eight focused simulator
checks passed (format policy, night default, color round-trip, projection); three Python report tests
passed. The broader unit-suite attempts hit auto-alignment solver readiness/outcome timeouts; those
failures were not changed or represented as a clean full-suite pass. Existing user changes to the sky
engine/drawing files were preserved.

API behavior was checked against the installed Xcode 27 headers and Apple's documentation for
[output sizing](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/automaticallyconfiguresoutputbufferdimensions),
[digital zoom](https://developer.apple.com/documentation/avfoundation/avcapturedevice/videozoomfactor),
and [lens position](https://developer.apple.com/documentation/avfoundation/avcapturedevice/lensposition).
