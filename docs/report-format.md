# Report (レポート表示) — what the original does and what the Mac port reproduces

This page documents the report window, its printed page and its CSV files. Every rule marked **verified** was compared
byte for byte against files that the Windows application wrote from a card image (the comparison itself used private
data and is not part of this repository; the unit tests use made-up frames). Rules marked **inferred** or **open** are
listed again at the end so nothing is mistaken for a measured fact.

## Three kinds of report

| Kind | Opened from | Title | Rows |
| --- | --- | --- | --- |
| Event (`イベント記録レポート`) | an event recording | event date/time, speed (average, maximum), event type | per frame of the trigger and post-trigger blocks |
| Continuous (`常時録画レポート`) | a continuous recording | start～end, driving time, speed, distance, event count | per frame of the whole recording |
| History (`履歴記録レポート`, dialog 171) | the journal (常時録画履歴) tab | list of journal rows with totals | one summary row per journal row, one data line per second |

The first two are described below. The history report works on the one-record-per-second journal instead of video frames
and has its own page: [history-report.md](history-report.md). The data CSV of the journal and the Google Earth file made by
`ログデータ変換` (menu 374, also from the journal) are described in [history-report.md](history-report.md) and
[kml-export.md](kml-export.md).

Event recordings contain a few pre-roll frames before the trigger block; the original's report starts at the trigger
block, so the Mac port drops the pre-roll frames from the rows too (**verified** by row counts).

## Window (dialog 170)

* Left: the title and the label/value rows; event reports also show five reference images (開始, イベント2秒前,
  イベント発生時, イベント2秒後, 終了 – two in the first row, three in the second).
* Right: the speed graph, the acceleration graph (X red, Y green, Z blue; **verified** against the data CSV by comparing
  plotted pixels with the exported values), and the route box.
* Bottom bar: `印刷`, the folder for the CSV files (default `Documents\Yupiteru\PC Browser`), `参照`, `CSV出力`, `閉じる`.
* The graphs share these scales: speed 0 … the maximum rounded up to a multiple of ten (never below 10), labelled top,
  half and 0; acceleration ±1.0 G while every value fits, else ±2.0 G, doubling (labels ±limit, ±limit/2, 0.0); three
  clock labels (start, middle, end) under each graph; dashed grid lines; the event report draws a dashed black marker
  with the event clock inside the acceleration graph only.
* The original paints a map made from the Geospatial Information Authority's tiles behind the route. The Mac port draws
  the route only (no tiles, no network access) and says so under the route box.

## Printed page (dialog 172)

A bordered A4 portrait page: bold title, the same label/value rows, both graphs, the route box and – for events – the
five reference images, and a 備考 box. The window offers `印刷`, `プリンタ設定`, `備考記入` (up to 16,384 characters) and
`閉じる`. The Mac port reproduces the layout from the original's print preview scaled to A4 points (positions in
`LegacyReportPage`) and prints through the macOS print panel. The notes stay on this Mac.

## CSV files (`CSV出力`)

The original asks `<folder>\<file> に保存します。よろしいですか？` (はい／いいえ, title `CSV出力`) and then reports
`完了しました`. Two files are written, in Windows code page 932 with LF line ends:

* `<yyyyMMddHHmmss of the event>_イベント記録レポート_集計.csv` / `…_データ.csv` (event)
* `<start14>_<end14>_常時録画レポート_集計.csv` / `…_データ.csv` (continuous)

The Mac port never overwrites a file, never writes into the source of the report and refuses removable media; if the
names already exist the user chooses another folder.

### Data file (**verified** byte for byte)

Header: `日付,時刻,本体時計日付,本体時計時刻,速度[km/h],加速度X[G],加速度Y[G],加速度Z[G],緯度,経度,GPS測位フラグ,イベント種類,SDカードID,機器ID`

| Column | Rule |
| --- | --- |
| 日付, 時刻 | `yyyy/MM/dd`, `HH:mm:ss` of the frame's clock |
| 本体時計日付, 本体時計時刻 | the second clock stored in the frame header |
| 速度 | whole km/h, raw value × 0.036 cut (not rounded) |
| 加速度X/Y/Z | thousandths of a G cut to two decimals (`-0.51`, `1.00`) |
| 緯度, 経度 | empty in every file compared (cause unknown, see below) |
| GPS測位フラグ | `3D測位` for every compared row (fix 1, seven satellites) |
| イベント種類 | the trigger label, only on frames whose header names a cause; empty elsewhere |
| SDカードID | empty |
| 機器ID | the ten-character unit number of the card |

### Summary file (**verified**)

* Event: `日付,発生時刻,平均速度[km/h],最高速度[km/h],イベント種類` – average with one decimal, maximum whole.
* Continuous: `日付,時刻,運転時間,平均速度[km/h],最高速度[km/h],走行距離[km],イベント回数` – the time column is
  `HH:mm:ss～HH:mm:ss` (full-width tilde, 0x8160 in CP932), driving time as `58秒`, `03分58秒`, … , distance in
  kilometres with three decimals, the event count is the number of frames that name a cause.
* Average speed = mean of the per-row whole-km/h values; driving time = last clock minus first clock.
* Distance = sum of Hubeny distances (WGS84 ellipsoid) between consecutive 3D-fix rows after the device datum
  conversion; unchanged positions add nothing. The window prints it as `593 m` below 1 km and `1.234 km` above.

## Not established (kept visible on purpose)

* **Latitude/longitude columns are empty** in all compared exports although the frames carry positions; the reason
  (a setting, the model, the date of the data) is unknown. The Mac port reproduces the empty columns. (The *journal's*
  data CSV does carry coordinates and is reproduced with them; see `history-report.md`.)
* **GPS flag**: only `3D測位` was observed in the event and continuous exports. `非測位` and `2D測位` appear in the journal's
  data CSV; for frames they are inferred from the satellite count.
* **Durations of one hour or more and distances of one kilometre or more** were not observed in the original's window;
  the formats `HH時間MM分SS秒` and `x.xxx km` follow the original's time-span and distance routines.
* **Event label of a frame without a cause** in a continuous report is empty (observed); labels for combined causes
  follow the event list's naming (`衝撃, など`).
* The history report (dialog 171, list 31120) is implemented from its own comparison (`history-report.md`); its remaining
  residuals (clock of two entries, duration of lone marker rows) are listed there.
* ログデータ変換 (menu 374) is the Google Earth export of the journal, **not** a CSV; it is implemented and compared with the
  original in `kml-export.md`. Its event-tab / continuous-tab variants were not compared (the original crashed in that
  experiment), and the display inside Google Earth was not checked.
* Whether `印刷` of the original renders exactly like the Mac PDF could not be compared on paper; the layout follows
  the original's print preview only.
* Numbers with one decimal are rounded like C `printf` (exact binary value), not like Foundation's shortest-decimal rounding;
  this was measured on the history report and applies to the other reports (`validation-history.md`).
