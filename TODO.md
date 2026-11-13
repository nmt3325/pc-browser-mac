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
- [x] Selectable subtitle fields: core checks and native MP4/AVI raw sensor/input/event overlays verified; physical semantics remain explicitly unknown.
- [x] Frame/seconds sampling core tests; native CLI exports 12 distinct frames and a 3-page four-frame PDF, visually inspected (build 5).
- [x] One-frame-per-page native PDF (9 pages from real-media input) and four-frame-per-page PDF (3 pages) generated.
- [ ] All sampling/printing GUI paths and physical printers.
- [ ] KML points/routes, color/alpha/width/density controls and explicit external Earth application launch.
  - [x] Colors, alpha, width, density and XML structure (independent parse).
  - [x] Actual installed bundle-ID launch through LaunchServices with completion/error propagation (build 9).
  - [ ] Earth's own display of the generated document, route and points (accessibility and screen capture cannot show it).
- [x] Timestamped external NMEA synchronization: explicit timezone/offset, GUI-model opt-in and no extrapolation verified with synthetic logs; no host-timezone assumption.
- [ ] Sensor/trigger search and recording-kind semantics, calibrated G/gyro and physical camera identity.
- [ ] Original optical calibration, VRpn/NIGHT pixel-equivalence and synchronized physical-camera playback.
- [ ] Windows PC Browser / PC Viewer backup compatibility; full-image clone/restore to new output files.
  - [x] Deep, independent Ghidra and read-only original-process analysis of the fixed XOR table and extent table.
  - [x] Single-file read-only adapter, 14 tests and native 1,200-frame plain/XOR checks on manually built fixtures (build 10; not original interoperability).
  - [ ] The genuine Windows application lists no recordings from the manual partial files; find the cause or obtain a real Windows-generated backup.
  - [ ] Splits, writer, PC Viewer, full copy and restore.
- [ ] Model/FW identity and recording configuration editor, proven settings encoding and safe copied-image application.
  - [x] Static Deep recovery of the card layout strings and the 50 `set.ini` key names recognized by the original parser (names only; see `docs/deep-full-port.md`).
  - [ ] Key semantics, value domains/units, required-key rule, dialog-control and model mapping, verified on a copied card image (the full-card CONFIG has only `VERSION.INI`; no `SET.INI` sample is available).
- [ ] Password, erase/format and FW updates: recover exact algorithms; require device-specific confirmation before original media operations.

## Validation / delivery
- [x] All original 77 tests preserved; build 10 has 126 passing tests in GitHub Actions (112 earlier plus 14 BAK), including adverse inputs.
- [x] Exact build-6 CI artifact: CLI/GUI checks passed, including old continuous boundaries and new exports. Validation scope remains the private 1,200-frame partial backup plus synthetic inputs, not the full card.
- [x] Intel x86_64 (`macos-15-intel`) unit tests (126, 0 failures) and packaged-CLI synthetic smoke pass in the manual compatibility workflow (run 1). Intel GUI/real media and the macOS 14 runtime remain unverified (the hosted `macos-14` job was cancelled before any step).
- [ ] Separately record physical SD, whole-card media, device/model, Windows-original interoperability, printer, Intel GUI/real-media and macOS 14 runtime validation gaps.

## Progress
- Baseline source copied before modification. No original card/image writes performed.
- Goal is in progress, not achieved. Native goal service is unavailable; the durable contract and an active bounded keep-awake (through 2026-11-13 19:25 JST) preserve execution. Never use its completion token before the original-feature checklist is verified.

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
- Build 6 exact artifact on new dc Mac: 1,200 real-media frames decode/export; explicit external-GPS synchronization; report CSV/JSON/multipage PDF; 5-second samples and 9-page print PDF; raw-query and notes; continuous 450/900 boundaries and all nine projections passed. First catalog 0.092 s; selected detail 0.122 s on the partial backup. Independent MP4/AVI full decode and PDF structure/text passed. Visual inspection found settings clipping and overly thin PDF text; both were fixed and exact build-7 revalidation is recorded below.

- Build 7 / Actions 43378656035, commit e40b30b9ed9c5ba0dcf0f3f150fb8be2ec91b655: 109 tests passed. Exact signed/ad-hoc arm64 artifact was checksum-verified on the new dc Mac; CLI and GUI regression passed. All nine own-view captures and all five recording-PDF pages were individually inspected: settings wrapping, regular Japanese typography, margins, image captions and unified page numbers passed.
- Whole-card header-only baseline on that Mac: 34 recordings, 993 blocks, 439,666 estimated frames; first row 0.007590 s, complete catalog 21.319446 s, 152,400 512-byte reads. No video/PCM loaded. This is not full-card real-media validation.
- Build 8 / Actions 43381381704, commit e5d424d2e7993a55628016b463b51dccc08930d4: 112 tests, zero failures. Retains every forward pair check while expanding telemetry only at published/final boundaries. Exact artifact checksum/commit/build/signature, 1,200-frame media, exports, GUI continuous boundaries and all nine projections passed on the new dc Mac; main own-view capture inspected.
- Interleaved header-only comparison, three runs each: build-7 catalog 19.182/15.504/11.987 s; build-8 17.609/13.102/12.348 s. Catalog IDs, all block LBAs/counts/ordinals, 152,400 reads and input size/mtime match. Medians 15.504 vs 13.102 s, but strong cache/time variance and the final pair reversing prevent an isolated speedup claim. First-row median 0.002123 s.
- Native sample of build 8 shows the active scanner mostly waiting in pread. Next checkpoint: recover/verify original control/block references rather than relaxing pair validation or adding a stale persistent cache. Whole-card media and physical SD remain unverified.

## Build 9 / 10 checkpoints
- Build 9 (Actions 43388655103, 112 tests): explicit Google Earth launch uses the real `com.Google.GoogleEarthPro` bundle ID with LaunchServices completion; generated KML independently parsed. Earth document display remains unverified.
- Build 10 (Actions 43390457538, 126 tests): read-only Windows BAK adapter (fixed XOR, UInt64 extents, partial/no integrity claim). Exact artifact passed native plain/XOR 1,200-frame checks and the broad regression; manual fixtures only, no original interoperability. Details: `docs/validation-full-port.md`.
- Static settings anchors (`config\set.ini`, `[SDINFO]`, `[YPFMT]`, model names) are recorded in `docs/deep-full-port.md`; no settings writer is implemented.
- The Mac and Windows reference environments went offline at about 08:50 UTC on 2026-11-13. New exact-artifact, GUI and original-application checks need a restarted environment.
