# Validation history — runs 22 to 126 (original-application oracle)

This page records how the Mac port was checked against the **original Windows PC Browser 1.9.60.0** after build 8, and what each check did or did not establish. It never contains private card data: record names, clock values, counters, sector numbers, card or device identifiers and password values stay on the analysis host and the home Mac and are described here only in aggregate.

Rules that applied to every run:

- Builds and unit tests ran **only in GitHub Actions**. The dc Macs ran the exact downloaded artifact, never a rebuild; each artifact SHA-256 and the bundle build number were re-checked before use.
- The original image, SD card and installer were read-only. Nothing was written to an original medium.
- Proprietary binaries, patched copies of the original executable, real-image extracts and listing reports were never committed. Only the generic scripts under `tools/wine-oracle/` are tracked.
- Failing tests were never deleted, skipped or weakened. A test was changed only when the oracle proved that the assumption inside the test was wrong, and the evidence is stated below.

## Oracle method

1. The original executable runs under Wine on the Linux analysis host. A small import hook (`tools/wine-oracle/hook.c` plus the `patch*.py` byte patchers) logs the file I/O and, for the dialog work, the control traffic of the original application. The hook swallows every write that would reach the physical image, so the sample card stays pristine.
2. The same card image is read by the Mac core on the home Mac (macOS 15.7.7, Apple Silicon) through `pcbrowser-cli` and the report/list commands of the exact CI artifact.
3. The two outputs are compared field by field: event list, journal list, recording and block counts, trigger labels, backup parts.

## Results on the real card (aggregate)

| Check | Original under Wine | Mac artifact (CI #63) | Result |
|---|---|---|---|
| Recordings / video sessions / events | 23 / 18 / 5 | 23 / 18 / 5 | identical counts |
| Event list rows (time and trigger label) | 5 rows | 5 rows | **5/5 identical** |
| Journal rows | 517 | 519 (516 sessions and 3 markers) | start time: 517/517 found; start+duration: 514/517 equal |
| Windows backup parts written by the Mac writer vs. genuine parts | 13 | 13 | **13/13 byte-identical** |
| Candidates rejected by the integrity scan | — | 0 (was 5 before the fixes below) | — |
| `recovery_recommended` | — | true | by design: the card contains circular-recording overwrite remnants |

Open differences, stated so they are not mistaken for parity:

- three journal rows differ in duration by a small amount and the Mac journal lists two additional marker rows that the original does not show;
- the original prints the journal in its own collation; ours is sorted by start time.

## Findings that changed the code

### Trigger label rule

The original names an event by a flag byte and a 24-bit trigger mask that live in the **second sector of the trailer after each block** (flag byte at +0xDB, mask at +0xE7…+0xE9). When the trailer has not been finished, the original falls back to the D102 mirror of the block's first packet (flags 0x40, mask 0x4C…0x4E). Bits 0x01, 0x02, 0x04, 0x08 and 0x10 were established with controlled patches of a scratch copy of the card image (`exp_evt.sh` and `patchevt.py`; one change per experiment, a control run without a patch, every patched byte restored afterwards): the original read the patched copy and its event list showed which label each bit produces. The rule then reproduced all five rows of the real card's own event list. Mask bits that no experiment covered are listed in `validation-gaps.md`.

### Mirror tolerance

The packet header (D101) and its mirror copy (D102) are byte-identical **except** for header bytes `0x40..<0x50` (trigger flags, G-sensor sample and cause mask), which the recorder completes after the header has been written; the original application reads the mirror. The earlier whole-range comparison treated that legitimate difference as a torn pair and moved the affected candidates into `rejected_candidates` (5 on the real card). `PacketMirror.matches` now ignores exactly `0x40..<0x50` and nothing else; after the change the real card reports 0 rejected candidates, while a difference at `0x3F` or `0x50` is still rejected (`testPacketMirrorMayDifferInTheTriggerFieldsOnly`).

### Run 62 — corrected test assumption

`testPacketMirrorMayDifferInTheTriggerFieldsOnly` failed in run 62 on an `XCTAssertFalse` that expected `recoveryRecommended` to be false for its small synthetic image. That expectation was wrong: eight empty sectors behind the data legitimately raise the flag in that image, exactly as the real card reports `recovery_recommended = true`. The assertion was removed with a comment explaining why; the properties the test exists for (zero rejected candidates, six frames from both scanners, the recording loads with six packets, a torn pair at `0x3F` or `0x50` is still rejected) are unchanged. Run 63 then passed all 197 tests with zero failures.

## Settings oracle (after run 63)

The original's "記録設定" dialog was driven under the same hook. Observations:

- the Q-01 card keeps its settings in **raw sectors**, not in `SET.INI`: the first sector after the FAT partition (control sector, which begins with the `YP_FORMAT_1.01__` marker), one settings sector per channel directly after the control sector, and the backups of both directly behind the last journal sector named by the region table (channel copy first, control copy second). A first version of the Mac code assumed the backups sat at the end of the disk; the original's own writes on the real card showed that is wrong, and `RecordingSettingsStore.locate` now follows the region table;
- 「SDカードへ保存」 with unchanged values closes without writing; with changed values it asks for confirmation and then writes the four sector kinds above;
- the dialog data model (which controls exist, their item lists and defaults) is read from the dialog traffic, not guessed.

The byte-level layout and the Mac encoder/decoder are documented in `settings-format.md`.

## Runs 64 to 111 (aggregate)

Everything below was compared on the Linux machine that runs the original (Wine), against the output of CI builds and of the independent reference scripts in `tools/`. No Mac was reachable for these runs; the build-14 artifact (run #111) has therefore not been started on a Mac (`validation-gaps.md`).

| Topic | Evidence | Where documented |
|---|---|---|
| 37-model table and the six settings-dialog classes | model code in the control sector (offset 0x1DC) changed on a scratch copy; window title and dialog size observed per code | `settings-format.md` |
| Event and continuous report files | CSV files of the original and of the Mac port byte-identical on the sample card; report window, page and trigger list compared with the original's | `report-format.md` |
| History list and history report | row starts 517/517, durations 516/517; summary CSV 514 of ≈520 lines identical; data CSV 17 of ≈604,500 lines differ; rounding rule (printf-exact) found by the byte comparison | `history-report.md` |
| List tab labels | tabs are イベント記録 / 常時録画 / 履歴記録 (an earlier label assumption was corrected) | `dialog-port-map.md` |
| Format flow | warning, confirmation and progress dialogs; the volume is opened for writing, partition table, FAT16 boot sector and first FAT sector are written on a scratch image; a Wine stub then stops the flow, so the model-specific management writes are unobserved | `destructive-operations.md` |
| ログデータ変換 (KML) | format measured; Mac output compared with the original's on the sample card; differences listed | `kml-export.md` |
| Original-menu inventory | all 150 menu items classified by state and handler | `menu-inventory.md` |

Lesson recorded from run #109: the GUI check failed because a test assumed the first row of the made-up journal starts at its first record; the original's lagging-clock rule starts it one second earlier, so the expected default file name was corrected (evidence: the reference model and the original's rule; no check was weakened).

## Password and delete / initialise oracle (after run 111)

The same hook-and-Wine method was used on a scratch copy of the sample card's image (writes swallowed and logged). Aggregate findings:

- **Password**: the original asks for the password when it loads a card that has one and refuses to load it on a wrong or cancelled entry; the control sector stores a flag byte and the word `3 × password + 1639`; the dialog's checks and message texts were taken verbatim (`settings-format.md`). Q-01 class only.
- **録画データ削除**: the original writes exactly four sectors (management sector, channel settings sector and the backups of both) and nothing else. The management sector gets a new card generation (old + 1), and each region counter becomes the newest ring generation it had loaded plus one (a region it had not loaded: the new generation). The recorded data is **not** overwritten; readers skip what is not newer than the counter.
- **記録設定データ初期化**: the same four sectors; as 削除, plus the dialog defaults, password cleared, first multi-battery byte reset (second left alone), region table back to the standard 24-hour layout, card ID untouched. A second confirmation (はい／いいえ) appears before it runs.
- **Reader rule**: with the card at generation 1 the original lists a region only while its head header carries the card generation and the head's generation is above the region counter. At generation 2 and above the original listed nothing in the same experiments, which does not fit that rule; this is **not explained** (`recording-data-operations.md`, `validation-gaps.md`). The Mac port hides a region only when both conditions prove it stale.
- The Mac writers are tested in CI against byte-exact expectations on synthetic cards (`RecordingGenerationTests`, `scripts/settings_smoke.py` section 9); nothing was written to a real card.

## What was *not* established by these runs

See `validation-gaps.md`. In particular nothing here is a physical-SD, physical-camera or Intel-hardware result.
