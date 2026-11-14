# ログデータ変換（Google Earth用KML）

原版の「ログデータ変換」（メニュー374、ツールバーの「ログ変換」＝コマンド8006、ダイアログ名「ログデータ変換」／枠「GPSログ／Earth」）が書き出すKMLファイルの形式と、Macでの実装です。
実カード1枚の履歴記録（秒単位ジャーナル、`docs/history-report.md`）を原版（Wine上）で変換した出力を基準に測定しました。実カード由来の値（時刻・座標・機器ID・セクター番号など）はこのリポジトリのどこにも置いていません。試験はすべて作り物のジャーナルで行います。

## ダイアログ

| 項目 | 既定値 | 範囲 |
|---|---|---|
| 保存する場所 | `ドキュメント/Yupiteru/PC Browser/` | フォルダー（参照ボタンあり） |
| ファイル名 | `YP_<yyyymmdd>_<hhmmss>`（先頭行の開始時刻）＋`.kml` | |
| ポイント（チェック） | オン | |
| 　間隔 | 10 | 1〜30 |
| ルート（チェック） | オン | |
| 　幅 | 5 | 1〜10 |
| 　色 | 黒 | 色ボタン |
| 　透明度 | 100 | 0〜255 |
| Google Earth Pro起動 | オン | |
| スタート／キャンセル | | |

* 設定は次回の表示に引き継がれません（毎回既定値）。
* 変換は **履歴記録の全記録** が対象で、一覧で選んだ行には関係しません（先頭行だけ選択状態に見えても全行が出力されます）。
* ログ変換は録画を読み込んでいなくても有効です。
* 完了時にメッセージ「完了しました」（OK）を表示します。
* ポイントとルートを両方オフにしても、ヘッダーだけのファイルを書き出して「完了しました」を表示します。

## ファイルの形式

UTF-8（BOMあり）、**すべての行が CRLF で終わります**（最終行も）。数値はゼロ埋めの桁数が決まっています。

```
<?xml version="1.0" encoding="UTF-8"?><kml xmlns="http://earth.google.com/kml/2.1">
<Document><name>YYYY年 MM月 DD日(曜)</name>
<Style id="line_style">
<LineStyle><color>AABBGGRR</color><width>W</width></LineStyle></Style>
```

続いて、ポイントがオンなら:

```
<Folder><name>ポイント</name>
<Placemark><name>HH:MM:SS</name>
<Style><IconStyle><color>FF00FF00</color><scale>0.8</scale><Icon><href>http://map.yupiteru-itymap.com/icon/arrow_r_2.png</href></Icon><heading>H</heading></IconStyle></Style>
<Point><coordinates>経度,緯度,0</coordinates></Point>
<description><![CDATA[<table><tr><td>日付</td><td>YYYY年MM月DD日(曜)</td></tr><tr><td>時刻</td><td>HH時MM分SS秒</td></tr><tr><td>速度(GPS値)</td><td>S.Skm/h</td></tr><tr><td>進行方向</td><td>D.D度</td></tr></table>]]></description>
<LookAt><longitude>経度</longitude><latitude>緯度</latitude><tilt>50</tilt><range>400</range><heading>H</heading></LookAt>
</Placemark>
…（ポイントごとに繰り返し）
</Folder>
```

ルートがオンなら:

```
<Folder><name>ルート</name>
<Placemark><name>YYYY年MM月DD日 HH時MM分SS秒</name>
<styleUrl>#line_style</styleUrl>
<LineString id="CarRoute"><tessellate>1</tessellate>
<coordinates>経度,緯度,0 経度,緯度,0 … （測位した全記録。各組の後ろに空白1つ、全体で1行）
</coordinates></LineString>
</Placemark>
</Folder>
```

最後に `</Document>` と `</kml>`。

### 規則（実測）

* **ドキュメント名**は先頭記録の表示時刻の日付（`YYYY年 MM月 DD日(曜)`、年と月の後に空白あり）。**ルートの名前**は同じ時刻（`YYYY年MM月DD日 HH時MM分SS秒`、年月日の後に空白なし）。曜日は 月火水木金土日。
* **線の色**は `AABBGGRR`（透明度の16進2桁・青・緑・赤、大文字）。既定は `64000000`、透明度200なら `C8…`。幅は整数。
* **ポイント**: ジャーナル全体を通した記録番号 n（0始まり。測位していない記録も数える）が `n % 間隔 == 0` で、かつその記録の測位フラグが 2D か 3D のもの。ポイントの名前・時刻はその記録の **GPS時計**（データCSVのGPS時計と同じ）。
* **ルート**: 測位フラグが 2D／3D の全記録（間隔に関係なく）。
* **方位** `H` は 進行方向[1e-5度] × 1e-5 を倍精度で計算し、**偶数への丸め（round half to even）** で整数にしたもの（実測で、ちょうど .5 になる値でも偶数側に丸まることを確認。360 になる値もある）。説明欄の「進行方向」は同じ値の `%.1f`。
* **速度**は 速度[mm/s] × 0.036 の `%.1f`（km/h）。
* 座標は、データCSVと同じ変換（機器の旧日本測地系 → WGS84、`DeviceGeodesy`）の結果を `%.12f` で出力。高度は常に 0。LookAt の経度・緯度はポイントと同じ値、方位は Style の方位と同じ。
* アイコン（色 `FF00FF00`・縮尺 0.8・`arrow_r_2.png`）は固定です。アドレスは原版のとおりメーカーの地図サイトを指します（このアプリが接続することはありません。Google Earth側が表示時に取得します）。

## 原版との照合結果

原版（Wine上）で同じジャーナルを変換した出力と、独立に書いた参照実装 `tools/kml_reference.py`（同じ規則のPython版）を比較しました。

| ケース | 結果 |
|---|---|
| 全行・既定（間隔10）: ポイント約5.8万・ルート約58万座標 | 総バイト数・全346,841行が一致。違いは Point 607行・LookAt 607行・ルート1行の座標の**小数第12位が±1**（差は1.03e-12以内）のみ。座標値の約1.5％。原版はx87拡張精度で計算しているため（再現していません） |
| 間隔7・幅3・透明度200・ルートなし | 総バイト数・行数が一致。違いは座標の最終桁（862点）と、GPS時計が既知の履歴モデル残差で異なる2点のみ |
| ルートのみ（幅3・透明度200） | ルート行の座標最終桁のみ |
| ポイント・ルートともオフ | ヘッダーだけのファイルが一致 |

小数第12位（1e-12度≈0.1ミクロン）の違いは地図上は表示できない大きさです。

## Macでの実装

* `Sources/PCBrowserCore/JournalKML.swift` — 書き出し本体（`JournalKMLOptions`: 既定値・範囲・色の並び、`JournalKML`: ファイル名・行構成・規則）。
* `Sources/PCBrowserMac/LogConversionView.swift` — 原版と同じ項目のダイアログ。メニュー「ツール ▸ ログデータ変換」、ツールバーの「ログ変換」、履歴記録一覧の「ログ変換」から開きます。一覧がまだ読み込まれていなければ先に読み込みます。履歴記録の領域がない入力では、選んだ録画のGPSをKMLにするMac独自の書き出しに切り替わります。
* 命令行: `--legacy-history-kml-dir DIR`（`--journal-kml-density N`、`--journal-kml-width N`、`--journal-kml-alpha N`、`--journal-kml-rgb RRGGBB`、`--journal-kml-no-points`、`--journal-kml-no-route`）。新しいフォルダにだけ書き、元のIMG／SDカードには書きません。
* 書き出し先は新規ファイルのみです（既存ファイルは上書きせず、取り外し可能メディアと元データの置き場所は拒否します）。
* 原版との意図的な違い: 「Google Earth Pro起動」は既定ではアプリの設定（既定オフ）に従います。他のアプリを勝手に起動しない方針のためで、ダイアログでオンにすれば保存後にインストール済みのGoogle Earthを開きます。

## 試験

* `JournalKMLTests` — 作り物のジャーナルで、行構成・BOM・CRLF・曜日・間隔と測位の規則・色と範囲・方位の丸め・全行対象・データCSVとの一致・XMLとして正しいこと・キャンセル。
* `KMLReferenceTests` — 乱数で作った30個のジャーナルを `tools/kml_reference.py`（`tools/history_reference.py` でジャーナルを読む）と同じ設定で変換し、行ごとに比較（座標は1e-10度まで許容、ほかは完全一致）。
* GUI自己確認で、作り物のジャーナルを使ってダイアログを表示し画像を保存します。

## 未確認（確認できたことにはしていません）

* イベント記録・常時録画の一覧から行うログ変換（映像パケット由来のGPS）。原版はWine上で、イベント5件を全選択して変換した際に異常終了し、出力を得られませんでした。MacのKML書き出し（録画ごと、`TrackExport.kml`）は原版との照合なしです。
* 色の並び: 黒と透明度だけを実測しました。黒以外の色の青・緑・赤の並びは、KMLの標準（AABBGGRR）に従う想定です。
* 測位フラグが立っていても座標が無効な記録・GPS時計を持たない記録の扱い（このアプリは、ポイントは座標0で書き、GPS時計がないものは出さず、ルートからは除きます。原版の動作は未測定）。
* 保存先に同名ファイルがあるときの原版の動作、ポイント・ルートをオフにしたときに関連項目が使えなくなるかどうか。
* Google Earthでの実際の表示（この環境にGoogle Earthがありません）。
