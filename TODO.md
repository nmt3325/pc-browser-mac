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
- [ ] All sampling/printing GUI paths and physical printers; one-frame page native test.
- [ ] KML points/routes, color/alpha/width/density controls and explicit external Earth application launch.
- [ ] Timestamped external NMEA synchronization with explicit device timezone and log offset; no invented UTC timezone.
- [ ] Sensor/trigger search and recording-kind semantics, calibrated G/gyro and physical camera identity.
- [ ] Original optical calibration, VRpn/NIGHT pixel-equivalence and synchronized physical-camera playback.
- [ ] Windows PC Browser / PC Viewer backup compatibility; full-image clone/restore to new output files.
- [ ] Model/FW identity and recording configuration editor, proven settings encoding and safe copied-image application.
- [ ] Password, erase/format and FW updates: recover exact algorithms; require device-specific confirmation before original media operations.

## Validation / delivery
- [ ] Existing 77 tests plus new feature/adverse-input tests pass in GitHub Actions without weakening existing checks.
- [ ] Native CLI/GUI checks of the exact CI artifact, including old continuous audio/video boundaries and new exports.
- [ ] Separately record physical SD, whole-card media, device/model, Windows-original interoperability, printer, Intel and older-macOS validation gaps.

## Progress
- Baseline source copied before modification. No original card/image writes performed.
- Goal is in progress, not achieved. Automatic persistence service is not available in this host; this file and the Notion task page preserve checkpoints.

## Additional discovered features
- [ ] Recording report and notes: CSV/JSON/PDF, reference-frame contact pages, local notes. New implementation awaits build-6 native verification; not original event-report equivalence.
- [ ] Same-frame raw acceleration/gyro/event/input search, without guessing physical units or event names.
- [ ] Whole-input copy to a new regular IMG, free-space preflight, streaming SHA-256 and readback; no raw-device restore.
- [ ] Original PC Browser/PC Viewer BAK reader/writer interoperability.
- [ ] Weekly recording-standby timetable, person detection/warnings/external output, Wi-Fi/connection-ID dialogs.

## Latest validation checkpoint
- Build 5 / Actions 43373263989: 97 tests passed (all original 77 preserved); exact artifact GUI/audio/continuous boundaries and independent AVI tests passed.
- CFR output is 1,201 frames from 1,200 source packets: 40.0333333 seconds × 30 fps, with a card-clock gap retained. A manual 1,200-frame expectation was corrected, not the time-preserving scheduler.
- Build-6 attempt 43375508959 compiled and ran all 109 tests, but the new GPS-gap fixture omitted satellite/fix flags and correctly produced no valid GPS. Fixture flags and explicit validity assertions were fixed; expected gap coverage is unchanged. Re-run pending.
