# Full-port goal checkpoints

Legend: `[x]` verified or explicitly documented; `[ ]` incomplete or blocked (the reason is on the line). Implementation alone is not end-to-end validation. The maintained gap list is `docs/validation-gaps.md`; the original's menu-by-menu state is `docs/menu-inventory.md`.

## Baseline
- CI run #111 (commit `54c1c7f3`, build 14): 347 tests, 0 failures; signed app, extracted-package check and GUI check passed. Not run on a Mac (the verification Macs were unreachable; the last Mac-verified build is 13 / run #82).

## Inventory / Deep evidence
- [x] Goal contract, Notion TODO, Craft Anything `--deep` resources/backup/settings/lens/sensor analysis (`docs/deep-full-port.md`).
- [x] All 37 application dialogs mapped (`docs/dialog-port-map.md`); all 150 menu items classified (`docs/menu-inventory.md`: implemented 36, partial 81, unimplemented 13, blocked 3, refused by policy 1, no handler 13, framework 1, label 2).
- [x] 37-model table, model code location (control sector offset 0x1DC) and six dialog classes (`docs/settings-format.md`).
- [ ] Trace the remaining routines. Done: password storage, delete and initialise writes (generation byte and counters), the reader rule at card generation 1. Open: the reader rule at generation 2 and above, the model-specific initialisation (format flow), firmware update, the other five dialog classes' settings, 180° VR projection, 16-split content, multi-camera synchronisation.

## Implementation
- [x] Continuous recordings, fast lazy catalog, H.264/PCM playback, nine views, NIGHT, manual calibration.
- [x] Motion JPEG / OpenDML AVI + PCM, MP4, selectable subtitles, frame/second sampling, paged PDF, native print.
- [x] Event / continuous / history lists, report window/page/CSV, notes, trigger list, history report (`docs/report-format.md`, `docs/history-report.md`).
- [x] ログデータ変換: journal KML export compared with the original (`docs/kml-export.md`).
- [x] Windows BAK reader and writer (13/13 genuine parts byte-identical, `docs/validation-bak.md`).
- [x] Q-01-class settings editor writing only to new image copies, with WriteGuard; password set/clear/ask, 録画データ削除 and 記録設定データ初期化 are executed only on new copies (`docs/settings-format.md`, `docs/recording-data-operations.md`); format and firmware update are never executed (`docs/destructive-operations.md`).
- [ ] 360° views: pixel match to the original and factory calibration; 180° VR panorama; 16-split content; flip-front/rear rule (original: only one display type and model type).
- [ ] Multi-camera split windows and synchronisation (blocked: no multi-camera sample).
- [ ] G/gyro: G conversion done (raw ÷ 1000, truncated); gyro units/axes and external-input meaning unknown (blocked: no calibrating device); 車速パルス storage byte unknown.
- [ ] Settings of the five other dialog classes, week timetable, person detection, Wi-Fi (not analysed or blocked on sample cards of those models); the password is done for the Q-01 class only.
- [ ] Reader rule of 録画データ削除 at card generation 2 and above (the original listed nothing in the same experiments; unexplained), model-specific initialisation (format flow) and firmware update: original algorithms not recovered; execution against original media is refused by policy, and delete/initialise were never tried on a physical card.
- [ ] Original-application comparison of printed layouts of the history report and frame printing.
- [ ] Event/continuous-tab KML conversion compared with the original; Google Earth's display of KML.
- [ ] AVI beyond 4 GiB with real media and destination-full behaviour.

## Validation / delivery
- [x] All earlier tests preserved; 347 passing tests in GitHub Actions (run #111) with adverse inputs.
- [x] Exact build-13 artifact verified on a Mac with real data (run #82).
- [ ] Exact latest artifact verified on a Mac with real data (pending: no Mac reachable).
- [x] Intel x86_64 unit tests and packaged-CLI smoke in the manual compatibility workflow (build 10, 126 tests; rerun on the final commit pending).
- [x] Validation gaps recorded separately (`docs/validation-gaps.md`): physical SD/device, Windows interoperability beyond BAK, printer, Intel GUI, macOS 14 runtime.
