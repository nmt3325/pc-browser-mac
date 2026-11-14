# Validation gaps — what has *not* been verified

This page separates what the Mac port has been shown to do (see `validation-history.md`, `validation-full-port.md`, `validation-bak.md`, `history-report.md`, `kml-export.md`) from what has **not** been verified. Nothing on this page may be read as "works"; each row names the missing evidence. A row leaves this page only when the evidence exists and is linked from the validation documents.

**CI status:** the 16分割表示 change (commit `7d0e57d0`) was first built and tested in run #132 (commit `b600745f`) after the owner re-enabled GitHub Actions: unit tests, the signed app build, the extracted-package check, the GUI self-check (including the 16分割 menu and sheet check on the generated test pattern) and packaging all passed. Before that, run #130 and a manual diagnostic workflow (`ubuntu-latest`, `macos-15`, `macos-14`, `macos-latest`) had failed within two seconds with no runner assigned (an availability problem of the account, not of the code), and run #131 failed to compile because of one Swift lexical error (`projection.mode=.perspective`, fixed in `b600745f`).

Earlier verified CI: run #126, 378 tests, 0 failures, signed app, extracted-package check, GUI check and settings smoke (including delete / initialise on copies) passed. Build 13 (run #82) and the build-14 artifact of run #128 were run on a real Mac with real data (build 14: lists, history report CSVs, KML, BAK writer and delete/initialise on clones of the sample card image; `validation-full-port.md`). The decode/export paths of build 14 (MP4, AVI, print, report PDF), AVI beyond 4 GiB and the packaged GUI check on real media have **not** been run on a Mac, and the newest build (build 15, with the 16分割 screen) has not been started there at all, so everything else the later builds added is verified by CI (synthetic data, differential tests against independent reference scripts) and by comparisons made on the Linux machine that runs the original application, not on a Mac.

## Hardware and media

| Area | Status | Missing evidence |
|---|---|---|
| Physical SD card in a reader | not tested | no card reader or physical card is available in the verification environment; all real-card results come from an image of a card |
| Physical camera / recorder | not tested | no device; recorded behaviour of a camera that reads a card written by the Mac port is unknown |
| Writing to an original card or image | **forbidden by design** | the Mac port writes only to copies; original media are never opened for writing |
| Other models than the sample card's model (Q-01) | partly analysed | the model table (37 models, 6 dialog classes) is known; settings storage and dialog controls were observed on the Q-01 class only; the other five classes expose more (or other) controls |
| Cards from other firmware versions, damaged cards, wrapped circular recordings | not tested | only the sample card and partial backups of it were available |
| Intel Mac GUI, macOS 14 execution | not tested | unit tests ran on an Intel CI runner (compatibility build, build 10, 126 tests); the GUI has not been exercised on Intel hardware or macOS 14 |
| Mac run of the latest builds | **partly done** | the run #128 artifact (build 14) was verified on a Mac: signature, lists, history report CSVs, KML, BAK writer, delete/initialise on clones. Not done: decoding and exports (MP4/AVI/print/report PDF), AVI beyond 4 GiB, destination-full behaviour, the packaged GUI check on real media, and any build newer than #128 (build 15 has not been started on a Mac) |

## Original-application equivalence

| Area | Status | Missing evidence |
|---|---|---|
| Event list | 5/5 rows identical on the sample card | other cards, other trigger bits (mask bits beyond 0x01/0x02/0x04/0x08/0x10 are not exercised) |
| History (履歴記録) list | start 517/517, duration 516/517 | one duration differs by a factor of two; three lone-marker rows and one row end differ in the summary file's clocks |
| History report files | summary ≈520 lines, 514 identical; data ≈604,500 lines, 17 differ | the 17 differing clock cells and the six summary differences are explained only in part (`history-report.md`) |
| Event / continuous report files | CSV byte-identical on the sample card | other cards; the print preview of the report is not compared |
| ログデータ変換 (KML) | one card: identical except the 12th decimal of ≈1.5 % of coordinates (the original's x87 arithmetic) and two points near a clock edge | conversion from the event or continuous tab, colour channel order of non-black colours, "start Google Earth" behaviour, overwrite behaviour and invalid-coordinate handling were not observed |
| 360° conversions, NIGHT, optical calibration | implemented independently | pixel-level comparison with the original output has not been done; the original's factory calibration is not reproduced; 180° VR panorama and the 16-split contents are unconfirmed |
| 前後反転 (flip front/rear) | differs | the original adds half a turn only for one display type and one model type; the Mac port always adds it |
| 録画データ削除／記録設定データ初期化: which recordings the original lists afterwards | rule proven at card generation 1 only | at generation 2 and above the original listed nothing in the same experiments; the rule that explains both is unknown, so the Mac port hides a region only when its head header is positively stale (`recording-data-operations.md`) |
| Delete / initialise / password on a physical card or recorder | not tested | executed only on new image copies (CI, synthetic data); no hardware; whether a recorder accepts a card written this way is unknown |
| Multi-camera synchronisation and split windows | not implemented | no multi-camera recording was available |
| G / gyro units, axes, external inputs, 車速パルス | raw values only | calibration and axis conventions are unknown without a device that produces known accelerations; the byte holding the 車速パルス setting is unknown |
| Original print layouts | report print dialog (172) reproduced from the original's preview; other PDF layouts are Mac-original | print previews of the history report and of frame printing were not captured; no physical printer |
| Google Earth rendering of generated KML | launch verified, display not verified | screen capture of the verification VM is black and the accessibility tree exposes no document nodes |
| AVI larger than 4 GiB, destination-full behaviour | not run with real video | needs a card image with enough video and a volume to fill |
| BAK interoperability | writer: 13 of 13 parts byte-identical on 6 runs | PC Viewer format, reading a Mac-written BAK with the original, restoring to a card |

## Settings, password and format operations

Tracked in `settings-format.md`, `recording-data-operations.md` and `destructive-operations.md`. In short: every setting field the Mac port writes was derived from the original's own writes on a scratch copy and is limited to the Q-01 class. The password (set, change, clear, ask on open), 録画データ削除 and 記録設定データ初期化 are implemented for that class on **new image copies only**; the reader rule behind 削除 is verified at card generation 1 only (see above). The settings of the other five dialog classes, week-timetable, person-detection and Wi-Fi settings, the model-specific initialisation (format flow), quick/full format and firmware update are analysed in part or guarded but never executed against an original medium. The original's format flow was observed only up to the partition table, the FAT16 boot sector and the first FAT sector (a Wine stub then stopped it).
