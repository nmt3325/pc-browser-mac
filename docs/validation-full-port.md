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

## Visual QA follow-up — build 7 verified

Actual settings-sheet images exposed intrinsic-width clipping of long Form labels/help. The report PDF also selected an overly thin Japanese font. Source changes replace unbounded forms with finite-width, wrapping settings panes and separate long labels from controls; PDF uses an explicit regular face, clear headings, reserved margins and one page sequence across portrait summaries and landscape references. GUI capture now includes all five settings tabs and their scroll endpoints when available.

- Commit `e40b30b9ed9c5ba0dcf0f3f150fb8be2ec91b655`, [Actions 43378656035](https://github.com/nmt3325/pc-browser-mac/actions/runs/43378656035): 109 tests, zero failures.
- Exact app ZIP SHA-256 `c1445f857240768aaa51a9f98d76122f75f86757b829662e27b95f760ea9ee62`; source ZIP `67270872f83cccfd19bc8ad1ee3a2b891b956925eeb090d349884e0c14f11f4e`. Inner checksums, metadata commit, bundle build 7 and strict code-sign verification passed.
- The new dc Mac reran all 1,200 real-media-frame decode/export, short AVI, external NMEA and missing-timezone refusal, raw query, notes/report, sampled images/print, partial-copy refusal, continuous 450/900 boundaries and all nine projections. No rebuild on dc; original input size/mtime unchanged.
- Individually inspected all nine own-NSView captures: main, report, five settings tabs and two scroll endpoints. Labels/help wrap; controls fit the finite sheet; bottom controls remain reachable. Captures do not bypass screen-recording permission.
- Individually inspected all five report-PDF pages: regular Japanese body face, readable headings, no clipped notes/end marker, correct portrait/landscape image captions and global page footers 1/5 through 5/5. PDF text extraction confirms every note and end marker. No physical-printer validation is implied.

## Whole-card header catalog optimization — build 8 verified within scope

Build 7 on a sparse, header-only fixture from the complete card found 34 recordings, 993 blocks and an estimated 439,666 frames. First row: 0.007590 seconds; complete catalog: 21.319446 seconds; reads: 152,400 × 512 bytes (78,028,800 bytes). There were no loaded recordings or decoded media frames; this fixture contains no H.264 or PCM payload. File size and mtime remained unchanged.

Build 8 retains every forward pair/identity/span/length check while expanding telemetry only for first and published/final boundaries, retaining at most one pending 512-byte header per block. The new `catalog_boundary_parses` diagnostic and three appended regression tests check non-linear telemetry work, corrupt intermediate pairs and accurate boundaries at an explicit scan limit. [Actions 43381381704](https://github.com/nmt3325/pc-browser-mac/actions/runs/43381381704), commit `e5d424d2e7993a55628016b463b51dccc08930d4`: all 112 tests passed, including the original 109 and the three new cases. App ZIP SHA-256 `ff4ef329cffa2ef8b383a3d3a51e1bfeb80dc15d3d78f792b740b0f8e6d4afab`; exact source ZIP `d94d934de6530dfa1cd9635fe6b53fb07a1c3d84bbef82eef59660afd9c1d57f`. Outer artifact digest, every inner checksum, recorded source commit, bundle build 8 and strict code-sign verification passed on the new dc Mac.

Interleaved old/new runs, three per build, retained identical complete catalog IDs, block LBAs, counts and cumulative ordinals. All 152,400 header reads, zero loaded/validated media frames and unchanged input size/mtime were retained. Times in seconds:

| Run | Build 7 | Build 8 |
| --- | ---: | ---: |
| 1 | 19.181999 | 17.609111 |
| 2 | 15.503514 | 13.102254 |
| 3 | 11.987190 | 12.347951 |

Medians: 15.503514 vs 13.102254 seconds. New first-row median: 0.002123 seconds. Cache/time variance is material: both builds get faster over the sequence and the final pair reverses. These are not cache-isolated physical-SD measurements and are not evidence of a large or guaranteed speedup. Boundary telemetry expansions are 2,097 / 2,068 / 2,065 (publication timing-dependent), rather than every intermediate frame. A native `sample` run shows the active scanner predominantly in `pread`, so the next optimization investigation targets verified structural IO references, not unchecked skipping.

Exact build-8 native CLI and GUI regression also passed on the same 1,200-frame private partial backup: all source video frames, MP4/AAC, short 91-frame AVI/PCM, explicit external NMEA plus timezone refusal, raw query, notes/CSV/JSON/five-page report, nine interval samples and nine-page print PDF. GUI playback crosses 450/900 without changing recordings; all nine projections, audio clock, raw query/notes and external-GPS opt-in passed. Main own-view capture was individually inspected (no new clipping). Partial-copy refusal and original size/mtime checks passed. Partial-fixture GUI catalog 0.048353 s, selected detail 0.100311 s; these are not whole-card timings. Build-7's all-nine-view/five-PDF-page visual inspection above remains a separate checkpoint; not every build-8 PDF page was manually re-inspected.

## Build 9 — explicit Google Earth launch identity (launch verified; document display not verified)

- Commit `f2d2a9875b6bd2f2eb175f7b222c22d1265b40d8`, [Actions 43388655103](https://github.com/nmt3325/pc-browser-mac/actions/runs/43388655103) (run 17): 112 tests, zero failures.
- Explicit Earth launch now tries the signed official app's real bundle ID `com.Google.GoogleEarthPro` first, propagates the LaunchServices completion error/application, and has a separate opt-in native integration check (`--ui-check-earth`).
- On the new Apple Silicon dc Mac, the exact artifact launched the official Google Earth Pro 7.3.7.1327 (x86_64 under Rosetta, Google signature verified) through LaunchServices. The generated KML was independently XML-parsed: 75 names, 72 Points, 1 LineString, explicit color/alpha styles (alpha 173), width 7 and density 17.
- **Not verified:** that Earth itself imported or displayed the document. After the normal trust-warning Open action the sidebar accessibility tree exposes only the My Places / Temporary Places groups and no document names or points, and screen capture of the VM is black except the menu bar. No Screen Recording or TCC bypass was attempted. Launch completion must not be read as proof of display.

## Build 10 — Windows BAK read-only adapter (manual fixtures only)

- Commit `e2be1b9fbf4722ffcd0088965915f13b02f8d541`, [Actions 43390457538](https://github.com/nmt3325/pc-browser-mac/actions/runs/43390457538) (run 21): 126 tests, zero failures (the 112 earlier tests plus 14 BAK tests). The first attempt (43390039497) failed to compile only because of an untyped `UInt64` test array; the type was made explicit and no assertion was relaxed.
- Exact artifact `PC-Browser-Mac-arm64-21` (1,120,200 bytes), SHA-256 `d840702296bfec2f109f55ba5f943f80748e4ac90085cd24abf231494b95f981`; inner checksums, recorded commit, bundle build 10 and strict signature were verified on the new dc Mac.
- Format facts implemented (Deep decompile, independent Ghidra export and a read-only scan of the original process table): single-part `BDRBACKUP___` file, 48-byte plaintext header, extent table at offset 0x30, a fixed 256-byte XOR table, extent entries of four little-endian UInt64 values (virtual start, inclusive end, stored offset, length). Header offset 32 is a stored-file cursor, **not** a disk capacity. High-byte part selectors (splits) are rejected until verified. The reader is read-only and always reports a partial source without an integrity claim.
- Native results use a private, manually constructed plaintext BAK and an XOR-encrypted copy (not Windows-generated): each decodes 1,200 VideoToolbox frames and 320,267 PCM bytes (40.0333 s); GUI audio clock, continuous 450/900 boundaries and all nine projections pass; whole-image copy from the partial BAK refuses without output; source size and mtime are unchanged.
- The same exact artifact also passed the broader regression: 1,200-frame decode/export, short AVI plus PCM, explicit-timezone external NMEA (missing timezone refuses), raw query, notes, CSV/JSON/paginated report PDF, interval samples, nine-page print PDF, GUI continuous playback and all nine projections.
- Original-application interoperability experiment: the genuine Windows PC Browser opened a folder with the manually built partial BAK, and a variant that also contains the real primary and backup control sectors, but listed zero recordings and left every action disabled without showing an error. The cause is unproven; interoperability remains open and the manual fixtures must not be read as Windows-generated backups.
- Visual QA: the build-10 main-window capture from the broad regression was inspected after decoding and shows the video, map, labels, sensor/info panel and sidebar rendering correctly. An isolated rerun with no concurrent UI activity passed all automated assertions (first list 0.0697 s), but the macOS runner went offline before its image could be downloaded, and the other build-10 captures (settings, report, BAK window) were not re-inspected.

## Compatibility matrix (manual) — run 1

- Workflow `compat.yml` ([run 43404811414](https://github.com/nmt3325/pc-browser-mac/actions/runs/43404811414), commit `b5e2b899f1beba68d7656cc9cacab4328924d2d4`, docs-only change over the build-10 code).
- `macos-14` (arm64): the job was cancelled about one second after creation with no steps and no log; the reason was not retrievable (the runner label may no longer be offered). **macOS 14 runtime remains unverified**; only the 14.0 deployment target is checked (`vtool` minos 14.0 on both executables).
- `macos-15-intel` (x86_64, macOS 15.7.9, Swift 6.1.2): `swift test --jobs 2` reported 126 tests and zero failures, the release build, ad-hoc signing, ZIP extraction with strict signature check, executable comparison (`lipo -archs` equals `x86_64`) and the packaged-CLI synthetic smoke passed. The downloaded evidence artifact matched GitHub's digest; `build-metadata.json` records 126 tests, 0 failures, architecture `x86_64`, minimum macOS 14.0.
- Scope: unit tests and generated synthetic headers only. No Intel GUI, real media, physical SD or exact-artifact runtime on an Intel Mac. The Intel package is evidence only and is not a distributed build.

## Build 14 — run #111 (CI only; not run on a Mac)

- Commit `54c1c7f3661dd5e0143e9231baf305d2c059f75d`, [Actions run #111](https://github.com/nmt3325/pc-browser-mac/actions/runs/43570139966): 347 tests, 0 failures; the signed app was built, the extracted package was verified and the GUI check passed (report `passed: true`, including the ログデータ変換 dialog with a made-up journal).
- Artifact `PC-Browser-Mac-arm64-111`, zip digest SHA-256 `5f840c513393dd3d485710e0838f6fe06d618a72c5bc4b8bdb99a32c349090c2`.
- Added since build 13 (run #82): the legacy menu bar and 150-item inventory, the 37-model table and automatic model detection, the Q-01 settings editor on copies, event/continuous/history lists, report window/page/CSV, trigger list, history report, journal KML, and the destructive-operation guard. Their evidence is CI plus the original-application comparisons in `validation-history.md`.
- **No Mac run at the time:** the verification Macs were unreachable after build 13. The exact-artifact checks (checksum, signature, real-data lists, reports, KML) were made later on the run #128 artifact; see "Build 14 — run #128 artifact on a Mac" below.

## Build 14 — run #126 (CI only; not run on a Mac)

- Commit `93bce8dcd28be532542623ecda8a7990bc52cca2`, [Actions run #126](https://github.com/nmt3325/pc-browser-mac/actions/runs/43585004649): 378 tests, 0 failures; the signed app was built, the extracted package was verified, the GUI check passed and the settings smoke passed, including its section for 録画データ削除 / 記録設定データ初期化 on synthetic copies (a delete copy that differs from its input in two sectors, a second delete, and an initialise copy that differs in four sectors, each compared with byte-exact expectations).
- Artifact `PC-Browser-Mac-arm64-126`, app zip digest SHA-256 `139d8e8ae6b80636b0d2ea214dded4f50f3595c43defb39561d574d4b7ddea58`.
- Added since run #111: the card password (set, change, clear, asked when a card is opened; Q-01 class) and 録画データ削除 / 記録設定データ初期化 on new image copies (`recording-data-operations.md`). Evidence: CI with synthetic cards and the original-application comparisons in `validation-history.md`; nothing was written to a real card and nothing was run on a Mac.
- **No Mac run at the time:** the verification Macs were still unreachable. The same code was verified on a Mac through the run #128 artifact (next section).

## Build 14 — run #128 artifact on a Mac (exact artifact, image of the sample card)

- Artifact `PC-Browser-Mac-arm64-128` (commit `50506f811dcedb28f69035288e13227570c4aea0`; its code is the run #126 code of commit `93bce8dc`, the later commits only changed documentation). Outer zip SHA-256 `f479028663e4e10a34489eb73e6a9f10174af3d79cbd3e8650e6680244591e50` (equals GitHub's digest). Run on an Apple-silicon Mac with macOS 15.7.7.
- Package: `codesign --verify --deep --strict` valid (ad-hoc signature), thin arm64 executable, build 14, minimum macOS 14.0. Gatekeeper rejects the app because it is not notarized (as documented).
- Image of the sample card, opened read-only (`O_RDONLY`; input size and modification time unchanged afterwards): `--inspect --catalog-only --load-all` found 23 recordings (about 439,000 frames) and no hidden regions; the cold read of the 31 GB image took about 110 s. `--lists` gave 5 events, 18 video sessions and 517 journal rows (builds before the lagging-clock rule gave 519; the original shows 517).
- Journal history report: the summary CSV (33,079 bytes) and the data CSV (63,871,406 bytes) written on the Mac are byte-identical to the independent Python reference model run on the same image. Against the original's own files the earlier comparison stands (514 of about 520 summary lines identical, 17 data lines differ; `history-report.md`).
- Journal KML written on the Mac (61,053,079 bytes, 346,841 lines) against the original's KML of the same journal: same size and line count; 1,905 lines differ only in the 12th decimal of a coordinate (largest difference 1.02e-12 degrees), the known x87 effect (`kml-export.md`).
- BAK writer: all 13 parts of the 6 genuine Windows sets were reproduced byte for byte (file name and SHA-256) when the Mac build wrote them on the Mac (`validation-bak.md`).
- Delete / initialise on APFS clones (`cp -c`) of the card image: a full 31.5 GB comparison with the source showed exactly 2 sectors (12 bytes) changed by delete and exactly 4 sectors (54 bytes) by initialise. The catalog of the clones then showed 0 recordings and 3 hidden regions after delete, and 5 events with continuous and history hidden after initialise (`recording-data-operations.md`). The original image was not modified.
- Not run on a Mac in this pass: decoding and the exports derived from it (MP4, AVI, print, report PDF), AVI beyond 4 GiB, destination-full behaviour, and the packaged GUI check (it does not finish against the whole 31 GB image because its first-frame wait is shorter than the catalog time; the GUI evidence stays with the synthetic and BAK sets of CI).

## Explicit remaining gaps

See `validation-gaps.md` for the maintained list. In short: Mac runs of the decode/export paths (MP4, AVI, print, report PDF), AVI beyond 4 GiB and destination-full behaviour of build 14 (its lists, reports, KML, BAK writer and delete/initialise were run on a Mac); physical SD, camera, printer and Intel/macOS 14 GUI; original factory calibration and pixel equivalence of 360°/NIGHT; multi-camera synchronisation; gyro units and external-input meaning; settings of the five other dialog classes; password, delete and initialise exist only for new image copies of Q-01-class cards (the original's reader rule at card generation 2 and above is unexplained; never tried on hardware); format and firmware update (guarded, never executed); PC Viewer backups and restoring to a card; Google Earth's display of the KML; Developer ID signing and notarization.

Private image/media/GPS fixtures and original proprietary binaries remain outside Git and CI. Header-only sparse IMG catalog validation does not demonstrate complete video payload reception.
