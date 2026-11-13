# Full-port validation checkpoints

Full Windows PC Browser 1.9.60.0 parity is **not achieved**. A checked implementation below is not a claim of original-format compatibility or physical-device validation. Builds and unit tests run only in GitHub Actions; dc Macs run the exact resulting package, without rebuilding it.

## Build 6 — reproducible checkpoint

- Commit `607e314ab11b619d20cb81ca785ab4c9079f8a7e`, Actions run [43375913589](https://github.com/nmt3325/pc-browser-mac/actions/runs/43375913589), bundle build 6.
- 109 tests passed, zero failures, preserving the original 77. A prior new GPS test fixture omitted satellite/fix flags; the fixture and validity assertions were corrected, not the expected product behavior.
- Verified artifact SHA-256, every inner checksum, extracted executable signatures, architecture and bundle build on the new Apple Silicon dc Mac (macOS 15.8.2).
- Private fixture: 1,200 real-media packets, three internal blocks (450/450/300), one continuous recording, 40.0333333-second card-clock timeline. It is a **partial backup**, not a complete SD or physical-card test.
- GUI: audio clock, seek/reverse, continuous playback across packet 450 and 900, all nine projection modes, raw-query match/exclusion, explicit external-GPS opt-in/no extrapolation, local notes, report and settings sheets. First catalog 0.091706 s; selected detail 0.122293 s. These timings are not whole-card/physical-SD timings.
- Native CLI: all 1,200 H.264 frames decoded, MP4 plus audio, report CSV/JSON/multipage PDF, five reference frames, nine distinct 5-second samples, nine-page one-frame print PDF, short AVI, partial-to-full-copy refusal, and missing-timezone refusal. Input sizes and mtimes unchanged.
- External NMEA test coordinates are **synthetic** and synchronized using explicit Asia/Tokyo plus offset zero. They are not added to card GPS CSV/statistics.

## Independent decode / PDF checks

On korakuen, a separate FFmpeg build fully decoded build-6 MP4 video/audio (1,200 H.264 frames and AAC), and the 91-frame Motion JPEG/PCM AVI, with `-xerror` and no decode errors. SHA-256:

- MP4: `c723b09c6cc45d75e77f5422c4617ad886d2c3775b59a7a64b98cec8676bd353`
- Short AVI: `4606417644203ee0bfeb72f05253a19b7f2ed50724824d3bc97031c19fbef6f2`
- Recording PDF: `fb6a1d8fa7f265a69788947aefc2ce13eddb5a88df0488be4f33225877451335` (five pages, all long notes including end marker present).
- One-frame PDF: `ea303f0ecd51b942ce30f4e6caa641347de4632eedaf629e1ce8b9e16f846e7b` (nine pages).

Earlier build 5 additionally produced 44 forced OpenDML segments. All 1,201 AVI timeline frames decoded, indexed seeks matched linear frame MD5s, and 320,267 PCM samples exactly matched source WAV. The extra CFR frame preserves a recorded clock gap; 1,200 source packets are not the same thing as 1,200 constant-rate output frames. A three-page/four-frame PDF was visually inspected.

## Visual QA follow-up — build 7 pending

Actual settings-sheet images exposed intrinsic-width clipping of long Form labels/help. The report PDF also selected an overly thin Japanese font. Source changes replace unbounded forms with finite-width, wrapping settings panes and separate long labels from controls; PDF uses an explicit regular face, clear headings, reserved margins and one page sequence across portrait summaries and landscape references. GUI capture now includes all five settings tabs and their scroll endpoints when available.

These are source changes awaiting Actions and exact-artifact/native revalidation. Do not mark the visual issues resolved solely because the source changed.

## Explicit remaining gaps

- Full-card real H.264/audio playback and long-duration exports; physical SD insertion, helper privileges, destination-full and physical printers.
- Original Windows BAK reader/writer interoperability, restore, model/FW settings schema/encoding, password algorithms, erase/format and firmware update.
- Original factory optical calibration, VR-pn/NIGHT pixel equivalence, sensor physical-unit/axis calibration, event/input semantics and multi-camera synchronization.
- Weekly standby schedule, person-detection warnings/output, connection-ID/Wi-Fi features and original automatic event reports.
- Intel, macOS 14 actual run, Developer ID signing and Apple notarization.

Private image/media/GPS fixtures and original proprietary binaries remain outside Git and CI. Header-only sparse IMG catalog validation does not demonstrate complete video payload reception.
