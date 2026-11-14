# 履歴記録 (per-second journal) and 履歴記録レポート — rules, formats and evidence

This page documents how the original Windows application (PC Browser 1.9.60.0) turns the card's per-second journal into
its list (dialog 171, list 31120) and into the `履歴記録レポート` CSV pair, and how the Mac port reproduces it
(`HistoryJournal.swift`, `HistoryReport.swift`). The rules were measured on a full card (a journal that had wrapped
around its ring) by comparing the original's own list and CSV exports with the output of the Mac model. The comparison used
private data; it is described here only in aggregate. Every rule below is tagged **verified** (reproduced by the original's
export on the real card), **empirical** (fits one card, the cause of the rule is not understood) or **inferred**.

> Terminology: earlier notes of this repository called the list "Journal (常時録画履歴)". The original's menu and window say
> **履歴記録**; the name 常時録画 belongs to the continuous *video* recordings and has nothing to do with this journal.

## Journal area and records

The region table of the card names the journal area: a ring of 256-byte records, at most one week of one-second records
(604,800) plus four reserved slots behind them. A record is `E202` (per-second sample), `E201` (marker, written when the
unit starts or stops a recording) or empty (all zero). Fields that the list and report read (little endian):

| Offset | Field |
| --- | --- |
| 0x00 | magic `0xFFFFE202` sample, `0xFFFFE201` marker, `0` empty |
| 0x0E | clock A (GPS-synchronised): year-2000, month, day, hour, minute, second bytes |
| 0x1E | clock B (free running body clock), same layout; the video packets carry this clock |
| 0x25 | fix flag (2 = 2D, 3 = 3D, anything else = no fix) |
| 0x2E / 0x32 | latitude / longitude, 1/600000 degree (Tokyo datum) |
| 0x36 | speed word, 0.036 km/h per unit, **truncated** to whole km/h |
| 0x3A | heading, 1e-5 degree |
| 0x3E | altitude, millimetres |
| 0x9A | ten-character unit number (0–9, A–Z) |
| 0xA6 | trigger bits |
| 0xAC / 0xAE / 0xB0 | acceleration X / Y / Z, signed, thousandths of a G |

A clock whose bytes are not a valid date counts as "no clock" and is shown as `0000/00/00 00:00:00` in the data file.

## Row model (**verified** against the original's list and exports)

1. **Ring.** `R = min(slot count, 604,800)`. The newest sample is the **first** sample with the largest valid clock B (ties
   go to the lower slot). Scanning starts at the first **even** slot behind it and runs `R` slots, wrapping once; position
   `p` is slot `(start + p) mod R`.
2. **Runs.** A *run* is a maximal sequence of consecutive E202 samples in scan order. Rows are built from runs.
3. **Gaps.** Between two runs lies a gap of other slots (markers, empty slots, unknown magics).
   * The first gap of at most three slots *before* the physical ring end and the first such gap *after* it do **not**
     split a row (the two runs are one row). This rule is **empirical**: it was measured on one wrapped card and has no
     known cause; gaps of four or more slots and every later short gap split rows.
   * A gap of four or more slots that contains **three or more markers** produces an extra **marker row**: the first two
     non-empty slots of the gap close the previous row, the remaining non-empty slots are the entries of a one-second
     marker row (listed with the 履歴記録 marker icon, kind `marker`).
   * Any other gap: its markers (E201) become entries at the end of the row before it; empty slots and slots with an unknown
     magic are skipped.
   * After the last run the remaining non-empty slots up to the end of the scan are the **closing tail** of the last row.
4. **Entries.** A row's entries are the E201/E202 slots from its first run to its last run, then its tail. When the first
   run begins at scan position 0 the entries start at position 1 (the original's loop starts one entry late there; verified
   by the row counts of the wrapped card). A row that would write no entry is dropped, except the last one. One closing
   entry that has no slot ends the last row.
5. **Which record a data line shows.** The data of entry *n* is read from the slot of entry *n − 1* (entry 0 from scan
   position 0): the original writes each line from the record it has already moved past. The position-dependent columns
   (speed, acceleration, latitude/longitude, heading, fix flag, trigger, unit number) follow this rule.

## Clocks (**verified** except where noted)

For every entry the model keeps a GPS clock, a body clock and the clock that the list shows:

* The record that *carries the fix* is the lagging slot (the previous entry's slot). If that record has a 2D/3D fix the
  GPS clock is defined, otherwise the line prints `0000/00/00,00:00:00`.
* GPS clock: for markers and the closing entry it is the last GPS clock plus one second (when one exists); for samples it
  is clock A of the entry's own slot, except that a sample whose own clock A equals both neighbours' own clock A (a
  clock that stands still) counts up from the last GPS clock instead.
* Body clock: the lagging slot's clock B; if it is missing, last body clock + 1; if it steps backwards, last + 1.
* Shown clock (list, summary, file names): the GPS clock when there is one, otherwise the body clock, otherwise the entry's
  own clock minus one second, otherwise the previous shown clock plus one, otherwise 2000/01/01 00:00:00.
* **Duration** of a row: the span between the shown clocks of its last and first entry if that differs from
  `entries − 1` by at most five seconds, else the entry count; at least one second.

Because of the lag the first data line of a row shows the *previous* row's last record. That is what the original writes
(**verified** by the data file), not an off-by-one in the Mac port.

## Summary file (`…_集計.csv`, **verified** format)

Header `日付,時刻,運転時間,走行距離[km],平均速度[km/h],最高速度[km/h],衝撃,急発進/急ブレーキ,急ハンドル,ワンタッチ,回数`
(eleven columns), then one line per selected row and a `合計` line, each line ending with a comma; Windows code page 932,
**LF** line ends.

| Column | Rule |
| --- | --- |
| 日付 | date of the row's first shown clock, `yyyy/MM/dd` |
| 時刻 | `HH:mm:ss～HH:mm:ss` (first and last shown clock; the tilde is U+FF5E = 0x8160 in CP932) |
| 運転時間 | the row duration as `HH:mm:ss` (hours grow beyond two digits) |
| 走行距離[km] | sum of Hubeny distances (WGS84, after the Tokyo-datum conversion) between consecutive **3D** fixes whose position changed; three decimals |
| 平均速度[km/h] | mean of the whole-km/h speeds of all entries of the row; one decimal |
| 最高速度[km/h] | largest whole-km/h speed |
| 衝撃, 急発進/急ブレーキ, 急ハンドル, ワンタッチ | entries with trigger bit `0x01`, `0x02`, `0x04`, `0x10` |
| 回数 | entries with any of the bits `0x1F` (so 急旋回, bit `0x08`, counts here only) |

A row without any 2D/3D fix leaves distance, average and maximum **empty**. The 合計 line sums the duration, the distance and
the five counters and leaves the two speed columns empty. The selection of the report is the contiguous range between the
first and the last selected row (all rows when nothing is selected).

File names: `<yyyyMMddHHmmss of the first row start>_<… of the last row end>_履歴記録レポート_集計.csv` and `…_データ.csv`.

## Data file (`…_データ.csv`, **verified** format)

Header `GPS時計日付,GPS時計時刻,本体時計日付,本体時計時刻,速度[km/h],加速度X[G],加速度Y[G],加速度Z[G],緯度,経度,進行方向,GPS測位フラグ,イベント種類,SDカードID,機器ID`
(fifteen columns). One line per entry of the selected rows:

* the GPS and body clock as `yyyy/MM/dd,HH:mm:ss` (`0000/00/00,00:00:00` when undefined);
* speed in whole km/h, acceleration cut (not rounded) to two decimals, latitude/longitude in WGS84 with six decimals
  (`0.000000` when the record has no position), heading with one decimal;
* `3D測位`, `2D測位` or `非測位`;
* the event name of the **first** set bit in the order 衝撃 (`0x01`), 急発進/急ブレーキ (`0x02`), 急ハンドル (`0x04`),
  急旋回 (`0x08`), ワンタッチ (`0x10`); other bits give no name. Only 衝撃 occurs in the exports of the real card (three
  lines), so the other four names and the order are **inferred** (they are the names that the original's code and its
  video-event list use for the same bits), not seen in a journal export;
* the (always empty) SD card ID and the unit number (empty when it is not ten characters of 0–9/A–Z).

### Rounding (**verified**, found by the byte comparison)

The original formats `%.1f`/`%.3f`/`%.6f` with the C library: the decimal expansion of the **exact binary value**, rounded
half-even. Rounding the *shortest decimal form* instead (what Foundation does when `String(format:locale:)` is used) differs:
`1.85` is stored a little above the decimal and prints `1.9` (the shortest form `1.85` would give `1.8`), `247.35` is stored
a little below and prints `247.3` (the shortest form would give `247.4`). In the real journal 8,371 of about 603,500 heading
values lie on such a boundary and the original's file followed the exact-binary rule for all of them. The Mac port therefore
uses `String(format:)` **without** a locale (`testOneDecimalFiguresRoundTheExactBinaryValueLikePrintf` pins this).

## Evidence (aggregate)

Compared on one real card whose journal had wrapped (≈ 604,000 records, ≈ 520 rows):

| Check | Result |
| --- | --- |
| Row start clocks of the list | all found in the model |
| Row durations of the list (517 rows) | 516 equal, 1 differs |
| Summary CSV (≈ 520 lines) | 514 lines byte-identical; six differ: the clocks of the three lone-marker rows, the end clock of one more row, the duration of one row (the model's value is twice the original's) and, as a consequence, the 合計 line |
| Data CSV (≈ 604,500 lines, 15 columns) | identical except 17 lines (about 14 GPS clock cells and 3 body clock cells, 0.003 %) |
| Heading rounding | 8,371 boundary values, all exact-binary |

The differential test against the reference implementation (`tools/history_reference.py`, an independent Python
transcription of these rules) uses 48 seeded random journals (805 rows, 209 of them marker rows) and compares the
summary and data files byte for byte; the hand-built scenarios of `HistoryReportTests` fix the rows, clocks, counters,
formats, selection, cancel and file encoding. Neither test uses any data from a card.

## Not established

* The **short-gap-beside-the-ring-end** rule was measured on one card; whether it follows from a structure the original
  keeps (for example a per-block writer) is unknown. On a journal that has not wrapped the ring end lies in the empty
  area behind the data, so the rule does not come into play.
* The **three-marker rule** (≥ 3 markers in a gap of ≥ 4 slots) fits all 3 lone-marker rows of the card; the clocks of those
  rows still differ from the original in the model (see the evidence table).
* The one row whose duration disagrees by a factor of two has not been explained; the duration tolerance (five seconds)
  and the clock-step rules are the candidates.
* Trigger bits above `0x10` and combined causes are not mapped; the first-set-bit order is **inferred** from the video
  event side.
* The original's list prints rows in its own order; the Mac list is sorted by start time (documented in
  `validation-history.md`).
* The Mac artifact of run #128 wrote summary and data CSVs for the sample card on a Mac that are byte-identical to the independent
  reference model on the same image; the comparison with the original's own files was made on the Linux machine
  (see `validation-full-port.md` and `validation-gaps.md`).
