# 映像抽出 (acceleration extraction) — research notes, NOT implemented

Status: the scoring rule below was read from the static disassembly of the original 1.9.60.0; it was **not** compared with the running original and **no Swift code exists for it**. A faithful port still needs the recording segmentation rule (open item below). Generic text only: no addresses, recordings or card values are recorded here.

## Flow in the original
1. The handler takes the recordings that are **checked** in the main list (checkbox state of every row).
2. A parameter dialog (resource 241, title 「加速度抽出パラメータ調整」) shows a slider with the captions 「個数」 and 「値」; the chosen value is kept in the main window object (default 30). The same dialog is what `docs/dialog-port-map.md` lists as 加速度パラメーター.
3. A modal progress dialog (the shared progress template, task type "acceleration extraction") runs a worker thread. The worker calls the extraction routine and then reports success or failure to the dialog.
4. The routine returns a list of *entries* (candidate scenes). Each entry is checked with the original's duration helper, then shown in a five-column table: No., start time, 動きポイント, and two strings taken from the entry's first block. Afterwards the main list is rebuilt with six columns, and 「ファイル出力」 (resource 242, see `docs/dialog-port-map.md`) writes the result.

## Scoring rule (as read from the code)
* Four sample channels per entry (16-bit signed arrays; their meaning is not confirmed — presumably acceleration/gyro raw values like the ones the app already shows).
* A scale factor `D` (a power of ten) keeps the integer arithmetic exact. Per channel a baseline is the integer mean of the samples, scaled by `D`; per channel the threshold is `t_c × D`, where the four `t_c` are 16-bit parameters of the main window object (two packed dwords).
* For every entry with at least one sample, the counter of channel `c` is the number of samples with `|s × D − baseline_c| > threshold_c`. 動きポイント = the sum of the four counters.
* Entries are kept sorted by 動きポイント, **descending**; an entry is inserted before the first entry with fewer points, so ties keep their order of creation.
* An entry whose last block time stamp (year-2000, month, day, hour, minute, second) is less than **118 s** after its start is discarded.

## Open (why it is not shipped)
* The loop that cuts the selected recordings into entries (about 10 KB of x86 code driven by frame-header marker words) is not traced; without it the entries — and so the points — cannot match the original.
* How the dialog's slider value maps to the four thresholds, and where the 「個数」 (maximum count) truncation happens, is not located.
* Verification plan once traced: run the original under Wine on a copy of the sample card, record the table for the same checked recordings, and compare entry by entry with the Mac implementation in a unit test built from synthetic samples plus a real-data check on the Mac.
