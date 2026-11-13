# Full-port goal checkpoints

Legend: `[x]` verified or explicitly documented; `[ ]` incomplete. Implementation alone is not end-to-end validation.

## Inventory / Deep evidence
- [x] Read goal Skill; create durable goal contract and Notion TODO.
- [x] Re-run Craft Anything 0.6.1 `--deep`: resources (1,084 entries), backup/export, settings/password, lens/NIGHT and sensors/trigger strings. Evidence references: `docs/deep-full-port.md`.
- [x] Map all 37 application dialogs (plus 22 framework dialogs), including unresolved dialogs, to implementation and validation (`docs/dialog-port-map.md`).
- [ ] Trace `.bak` `BDRBACKUP___`, settings writers, password and projection routines; distinguish unsupported sample formats.

## Implementation checkpoints
- [x] Motion JPEG / OpenDML AVI plus PCM: core cleanup tests, native 40.0333-second export, 44 forced segments, independent full decode/PCM equality and indexed seeks (build 5).
- [ ] Long-duration AVI beyond 4 GiB with real media, additional audio formats and destination-full behavior.
- [ ] Selectable subtitle fields, including honest raw sensor/input overlays where semantics are not yet established.
- [x] Frame/seconds sampling core tests; native CLI exports 12 distinct frames and a 3-page four-frame PDF, visually inspected (build 5).
- [x] One-frame-per-page native PDF (9 pages from real-media input) and four-frame-per-page PDF (3 pages) generated.
- [ ] All sampling/printing GUI paths and physical printers.
- [ ] KML points/routes, color/alpha/width/density controls and explicit external Earth application launch.
- [ ] Timestamped external NMEA synchronization with explicit device timezone and log offset; no invented UTC timezone.
- [ ] Sensor/trigger search and recording-kind semantics, calibrated G/gyro and physical camera identity.
- [ ] Original optical calibration, VRpn/NIGHT pixel-equivalence and synchronized physical-camera playback.
- [ ] Windows PC Browser / PC Viewer backup compatibility; full-image clone/restore to new output files.
- [ ] Model/FW identity and recording configuration editor, proven settings encoding and safe copied-image application.
- [ ] Password, erase/format and FW updates: recover exact algorithms; require device-specific confirmation before original media operations.

## Validation / delivery
- [x] All original 77 tests preserved; build 6 has 109 passing tests in GitHub Actions, including adverse inputs.
- [x] Exact build-6 CI artifact: CLI/GUI checks passed, including old continuous boundaries and new exports. Validation scope remains the private 1,200-frame partial backup plus synthetic inputs, not the full card.
- [ ] Separately record physical SD, whole-card media, device/model, Windows-original interoperability, printer, Intel and older-macOS validation gaps.

## Progress
- Baseline source copied before modification. No original card/image writes performed.
- Goal is in progress, not achieved. Automatic persistence service is not available in this host; this file and the Notion task page preserve checkpoints.

## Additional discovered features
- [x] Recording report/notes: CSV/JSON/PDF, reference frames and local notes pass build-6 native tests.
- [ ] Original event-report semantics and automatic event selection are not established.
- [x] Same-frame raw acceleration/gyro/event/input search passes core, CLI and GUI-model checks. Physical units and event names remain unresolved.
- [x] New regular IMG copy, free-space preflight, SHA-256/readback and cancellation cleanup pass core/synthetic packaged-CLI tests; partial-copy refusal tested on real backup.
- [ ] Full-card real-image copy and physical restore are unverified; raw-device restore is not implemented.
- [ ] Original PC Browser/PC Viewer BAK reader/writer interoperability.
- [ ] Weekly recording-standby timetable, person detection/warnings/external output, Wi-Fi/connection-ID dialogs.

## Latest validation checkpoint
- Build 5 / Actions 43373263989: 97 tests passed (all original 77 preserved); exact artifact GUI/audio/continuous boundaries and independent AVI tests passed.
- CFR output is 1,201 frames from 1,200 source packets: 40.0333333 seconds × 30 fps, with a card-clock gap retained. A manual 1,200-frame expectation was corrected, not the time-preserving scheduler.
- Build-6 attempt 43375508959 compiled and ran all 109 tests, but the new GPS-gap fixture omitted satellite/fix flags and correctly produced no valid GPS. Fixture flags and explicit validity assertions were fixed; expected gap coverage is unchanged. Re-run 43375913589 passed all 109 tests; no expected value was relaxed.
- Build 6 exact artifact on new dc Mac: 1,200 real-media frames decode/export; explicit external-GPS synchronization; report CSV/JSON/multipage PDF; 5-second samples and 9-page print PDF; raw-query and notes; continuous 450/900 boundaries and all nine projections passed. First catalog 0.092 s; selected detail 0.122 s on the partial backup. Independent MP4/AVI full decode and PDF structure/text passed. Visual inspection found settings clipping and overly thin PDF text; build-7 fixes and exact-artifact revalidation are in progress.

- Build 7 source: bound/wrap all settings tabs; explicit regular Japanese report typography and unified page numbers. Actions/visual revalidation pending, not yet a verified fix.
