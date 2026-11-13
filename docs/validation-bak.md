# Windows BAK writer — comparison with genuine PC Browser 1.9.60.0 output

Status: **verified for 6 genuine run folders (13 parts, 126.9-246.2 MB each) - the Mac writer reproduces every part byte for
byte, including the file names**. Scope and limits are listed at the end; nothing here is a claim of full Windows
interoperability.

## Method (reproducible, no private data in the repository)

1. The original PC Browser 1.9.60.0 (Windows exe, run under Wine on a Linux machine with a hook DLL that serves a private
   image of a real Q-01 card as `\\.\E:`; see `tools/wine-oracle/`) wrote 6 backup runs from selected recordings of that card.
   The runs cover: a single recording whose first block is partly damaged; two adjacent recordings (two runs); a recording
   whose start was overwritten by the ring wrap (5 parts); two recordings from different card regions in one run; and a
   recording whose first block has ordinal 900.
2. Each genuine run folder was opened by the Mac app (`--inspect <folder>`; `WindowsBackupSet` merges the sparse parts) and
   the same recordings were re-selected and written again with the Mac writer, using the genuine run name and key index:
   `PCBrowserMac --inspect <genuine folder> --bak-write <out> --bak-select <rows> --bak-created <run name>
   --bak-time-zone Asia/Tokyo --bak-key-index <index> --bak-verify`.
3. For every genuine `.bak` the script looks up a file with the **same name** in the output and compares SHA-256.

The comparison ran on the exact CI artifacts on a separate arm64 Mac (never rebuilt there). Private BAK files stayed on local
machines; they are not in Git or CI.

## Result with the exact artifact of Actions run 60 (commit `5b455782`, 195 tests, 0 failures)

| Set | Selected rows | Genuine parts | Identical parts (name + SHA-256) | Part sizes (bytes) |
|---|---|---|---|---|
| single recording | 1 | 2 | 2 | 229,850,640 / 139,112,848 |
| two recordings | 1, 2 | 2 | 2 | 212,126,736 / 196,992,016 |
| two recordings (other run) | 1, 2 | 1 | 1 | 241,095,248 |
| recording starting at a ring wrap | 1 | 5 | 5 | 231,428,624 / 222,717,488 / 226,989,104 / 239,549,488 / 126,944,688 |
| two regions mixed | 1, 2 | 2 | 2 | 246,209,072 / 232,565,776 |
| first block ordinal 900 | 1 | 1 | 1 | 232,221,200 |
| **Total** | | **13** | **13** | |

SHA-256 prefixes of the genuine parts (identical to the Mac output): 9c3ecb1c, 8491e2f2, 75b9d6cf, 22887112, 9c61d10b,
0fb0c905, e1b959c3, bcb25bf9, ea5e9694, 84f9a5e2, eb7f654f, d338846d, d88c6d36.

## What the comparison found and fixed (history)

* Run 58 (192 tests): all 13 parts identical in **content**, but the name counter differed in 4 sets. The Mac used the serial of
  the first intact packet; the original uses the serial of **frame 0** of the recording. The difference equals the ordinal of
  the first block (4,950 / 15,750 / 68,850 / 900 frames) in each set where the recording's start had been overwritten.
* Run 59 (194 tests): subtracting the ordinal of the first intact packet fixed 4 sets but broke the recording whose first block
  has ordinal 0 with only 389 of 450 frames intact (the counter was 24,000 frames too low).
* Run 60 (195 tests): subtract the block's **metadata ordinal** (header offset 0x98) instead. All 6 sets / 13 parts identical.
* Earlier (runs 52-57): "at most 11 chunks per part" was removed (genuine parts hold up to 12 chunks), the byte limit unit is a
  chunk with the ring-end-cut pair counted as one, and a recording-boundary reserve of 40 MiB was chosen (see
  `docs/windows-bak-format.md`).

## Limits (explicitly not verified)

* The writer's source in the comparison was the **genuine parts** read through the Mac reader, not a live card. Both
  contain the same sectors, but the full-card read path of the writer against the original has not been compared.
* Only 常時録画 selections; no genuine event/history backup was available.
* The recording-boundary reserve R is a value inside the range consistent with three observations, not the original's rule.
* PC Viewer-type backups, complete (unselected) card copies and restoring a backup to a card are not implemented/verified.
* Re-importing a Mac-written run into the original application was not run separately; the output is byte-identical to
  genuine parts, so it can only differ from them for selections outside these 13 parts.
