# PC Browser Mac

Yupiteru PC Browser録画用SDカード／IMGをMacで確認する、独立したネイティブGUIです。
**v0.2.0-beta.2 / build 15（ベータ版）。Windows版PC Browser 1.9.60.0の全機能互換には達していません。** 達成した範囲と未達の範囲は[機能差分](docs/feature-parity.md)・[未検証事項](docs/validation-gaps.md)・[原版メニュー全150項目の棚卸し](docs/menu-inventory.md)に項目ごとに書いています。

旧版の450フレームごとの区切りは、30fpsで約15秒の内部保存単位でした。今回は録画開始・継続の参照を解析し、同じセッション・CH・メディア形式のブロックを1本のタイムラインで扱います。最初に映像・音声を全走査せず、カタログを逐次表示し、選択した録画の詳細だけを後から読み込みます。[実装根拠](docs/session-catalog.md)・[検証記録](docs/validation-full-port.md)を参照してください。

GitHub Actions（run #132＝コミット`b600745f`、文書だけ更新した`c8c945fc`のrun #133）で、単体テスト**387件**・署名済みアプリのZIP展開後検査・GUI自己検査・梱包がすべて成功しています（16分割表示を加えてから初めての成功）。run #133の成果物をプレリリース[v0.2.0-beta.2](https://github.com/nmt3325/pc-browser-mac/releases/tag/v0.2.0-beta.2)として公開しました。build 13（run #82）の同一成果物はdcのMacで実データ検証し、build 14（run #128）の成果物も実カードのイメージで一覧・レポートCSV・KML・BAK書き出し・複製への削除／初期化を確認しましたが、**build 15（16分割表示を含む最新の成果物）は、検証用のMacに接続できなかったため、実Macではまだ検証していません。** 実映像の部分バックアップでの一覧は0.05秒、全カード由来のヘッダー専用fixtureは34録画・993ブロック・推定439,666枚で旧版と完全一致しました（build 8での測定）。全SDの全映像検証、物理SD、全機種、工場光学校正の完了を意味しません。

## 主な機能

- **読み取り専用・高速一覧**：IMG、外部SDカード、選択録画の`.pcbbackup`。管理情報とD101/D102ヘッダーでカタログを逐次表示。選択録画の詳細は遅延照合し、映像・音声本体は必要時に取得。孤立データ用の全領域「復旧走査」は別操作。
- **連続録画**：D103/D105の開始参照・シリアル・累積位置に沿って内部保存ブロックを結合。循環領域末尾→先頭も同じ録画として扱い、録画開始参照を検証できない断片は別に残す。
- **映像**：VideoToolboxによるH.264デコード、フレーム送り／戻し、シーク、秒数移動、正逆再生、0.5／1／1.5／2／4倍速。FFmpegのインストールは不要。
- **音声**：D103/D105の形式ヘッダーからPCMを抽出。内部ブロック境界でPCM末尾を映像時間へ合わせ、ずれの蓄積を防止。今回の実データは8 kHz・8 bit unsigned・モノラル。音量、ミュート、WAV出力。通常の前進再生では音声クロックに映像を追従させます。逆再生・4倍速は消音。
- **GPS／地図**：バイナリ座標、衛星数、速度。Windows版から追ったTokyo→WGS84変換と手動のWGS84指定。MapKitの経路・現在位置・追従・航空写真。CSV／KML／GPX出力。外部NMEAはカード時刻のタイムゾーンとログ補正秒を明示したときだけ地図・速度・字幕へ同期。記録外への外挿や長い欠落区間の補間はしません。KMLの点／線・色・透明度・線幅・密度を設定できます。
- **360°表示**：元魚眼、フラット／VR、360°パノラマ、前後2画面、4分割、ドーム、リング、全球、16方向ビュー（Mac独自）、16分割（原版と同じ直近16コマの一覧。FDR機種のみ）。Metal処理、ドラッグで方向変更、yaw／pitch／roll／画角、手動レンズ校正、NIGHT／露出、元映像拡大。校正プリセットの保存／読込。
- **確認・保存**：日時／CH／録画ID／速度検索、しおり、並び順、複数録画選択、IN／OUT範囲、PNG／JPEG、フレーム／秒間隔の連続PNG、WAV、音声付きH.264 MP4・Motion JPEG/OpenDML AVI、カード時刻・速度・座標・rawセンサー／入力の選択字幕、1コマ／4コマのページ分割PDF・印刷、別ウインドウ表示。
- **レポート・検索**：同一フレーム内で加速度／ジャイロraw閾値・イベントraw・入力rawをAND検索。録画統計、速度の有効区間、距離推定、ローカル備考をCSV／JSON／改ページPDFに出力。原版のイベント判定や事故報告書との同等性は未確認です。
- **センサー・設定閲覧**：加速度／ジャイロの符号付きraw値とグラフ、FAT16のCONFIG内INI等の読み取り。パスワード等の値は隠して表示。
- **新規IMGへの複製**：完全入力のみ新しい通常ファイルへコピーし、空き容量の事前検査・SHA-256書き込み時検査と全読み戻し照合。部分バックアップを完全IMGと偽りません。物理SDへの復元ではありません。
- **原版の一覧・レポート**：イベント記録／常時録画／履歴記録の3タブの一覧、イベントと常時録画のレポート（CSVは1枚の実カードで原版とバイト一致）、備考、トリガー一覧（種類の選択）、レポート印刷ダイアログ、履歴記録レポート（集計CSVは原版と約520行中514行が同一、データCSVは約60万行中17行が異なる。[履歴](docs/history-report.md)・[レポート](docs/report-format.md)）。原版メニュー全150項目の対応状況は[棚卸し](docs/menu-inventory.md)（実装36・一部81・未実装13・資料なし／検証不能3・方針で拒否1・ハンドラーなし13ほか）。
- **ログデータ変換（Google Earth用KML）**：履歴記録から原版と同じ形式のKMLを書き出し（既定ファイル名・色・幅・密度）。1枚の実カードで原版の出力と比較し、一致しない箇所（小数第12位の約1.5％、時計の2点）を[記録](docs/kml-export.md)に載せています。
- **機種の判定**：原版の37機種の一覧と、カードの機種コードから機種名・ダイアログの種類（6クラス）を選ぶ表。Q-01系（クラス81）以外の設定保存形式は未解析です（[機種表](docs/settings-format.md)）。
- **設定の編集（Q-01系のみ・複製にだけ書き込み）**：記録設定とCONFIGの指示ファイルを、新しいIMGコピーにだけ書き込みます。書き込む内容は原版が書いたセクターと比較して決めたものだけで、原本・マウント済みボリュームには書きません（[保存形式](docs/settings-format.md)）。パスワードの設定・解除、録画データ削除、記録設定データ初期化も同じ方針で複製にだけ実行します（[削除・初期化](docs/recording-data-operations.md)）。フォーマット・FW更新は[実行せず保護の仕組みだけ実装](docs/destructive-operations.md)しています。

機能が存在することと検証を通過したことは区別しています。[最新の検証記録](docs/validation-full-port.md)・[従来機能の検証記録](docs/validation-expanded.md)と[Windows版との機能差分](docs/feature-parity.md)を参照してください。

## 重要な制限

- **工場校正済みの360°補正ではありません。** 明示的な標準等距離射影モデルです。提供映像に合わせた初期の向きと、中心・半径・前後回転・FOVを調整できますが、メーカー固有のレンズ歪曲、光学中心、継ぎ目、機種差を完全再現していません。180°VRパノラマ、16分割の内容、複数カメラ（分割画面）の同期は未実装または未確認です。
- **G値の変換は原版の表示（生値を1000で割って切り捨て）に合わせましたが、ジャイロの物理単位・軸方向、外部入力の意味、車速パルスの保存位置は未確定です。** 一覧の種類分けとトリガーは1枚の実カードで確認しただけです。
- Windows版PC BrowserのBAKは、読み取りとMac側の書き込みを実装し、原版が書いた6実行・13ファイルとバイト単位で一致しました（[検証](docs/validation-bak.md)）。PC Viewer形式、物理SDへの復元、原版でのMac製BAKの読み込み試験は未対応・未検証です。暗号化・パスワード保護カード、全機種・全カード形式も未対応です。AVIは実データ40秒・強制44セグメントで独立デコード済みですが、4GiB超・長時間の実映像出力は未検証です。
- **SDへの設定保存・パスワード・削除・初期化はQ-01系のカードの複製に対してだけです。** 実機のカードでは試しておらず、世代番号2以上のカードで原版が録画を隠す規則は未解明です（肯定的な証拠があるときだけ隠します）。フォーマットとFW更新は実装していません。原版のフォーマットは、Wine上の模擬ディスクで分割テーブル・FAT16の起動セクターなどを書くところまでは観察しましたが、機種固有の管理情報の書き込みは観察できていません。未解析の値を推測して原本に書き込みません。
- カード時刻にタイムゾーンを推測して付加しません。フレーム時刻とPCM長の差、重複するフレームスロットがあるため、工場実装と完全なAV同期の一致は未保証です。差が大きい場合は画面に表示します。
- 地図タイルの取得はインターネット接続が必要。外部NMEAログは明示的なタイムゾーン設定・同期の有効化が必要です。ホストMacのタイムゾーンを勝手に使いません。
- 実SD読み取りのエンドツーエンド動作、Intel実機でのGUI・実メディア（CIのIntelランナーでの単体テスト126件とCLI合成スモークはbuild 10時点）、macOS 14上の実行、全録画の全映像連続デコード、破損・循環記録の全パターン、他機種のカード、原版の印刷レイアウトとの比較、Google Earth内の表示は未検証です。音声のメモリー内準備は1連続録画64MiBまでです。

## ビルドと起動

**通常のビルドはGitHub Actionsで行います。** `main`へのpush、Pull Request、手動の「Run workflow」でApple Silicon用の.appをビルドし、合成テスト・ZIP展開後の署名検査・アプリCLIの合成データ検査を実行します。個人のMacやdc接続は不要です。

[Actions](https://github.com/nmt3325/pc-browser-mac/actions/workflows/macos.yml)の成功した実行から、`PC-Browser-Mac-arm64-<run番号>` artifactをダウンロードしてください。中にはアプリZIP、ソースZIP、SHA256SUMS、ビルド記録が入っています。`v*`タグでは検証成功後にGitHub Releaseも作成します。[CIの詳細](docs/ci-build.md)を参照。

### 動作要件と起動

macOS 14以降（配備ターゲット14.0。macOS 14のランナーは利用できず、macOS 14上の実行は未確認）。実際のテストはmacOS 15.8.2・Apple Siliconで行っています。外部Swiftパッケージへの依存はありません。配布バイナリーはApple Silicon用。アドホック署名で、Appleの公証は未取得です。

配布ZIPを展開して.appをアプリケーションフォルダーに置きます。初回にmacOSが開くことを拒否した場合は、システム設定の「プライバシーとセキュリティ」で対象アプリの「このまま開く」を選択してください。システム全体の保護機能を無効化する必要はありません。

この作業のビルドと単体テストはGitHub Actionsのみで実施しています。dc MacではCI成果物を展開して実行し、再ビルドしません。

### IMGとバックアップ

「開く」でIMGまたは`.pcbbackup`を選択します。通常は高速カタログを先に表示し、全領域を走査しません。索引数は概数、選択した録画は全ヘッダー照合後に再生します。必要なら「復旧走査」で全領域を調べられます。各処理はキャンセルできます。GPS・音声・速度の詳細フィルターで未確認録画が残る場合は「全録画の詳細検索」を実行してください。選択録画バックアップはMac版独自のコンパクトなディレクトリー形式です。GUIではSHA-256を一覧表示後に照合し、完了まで未照合と表示します。不一致なら表示を停止します。**完全なSDクローンでもWindows版バックアップ互換でもありません**。欠落領域は未取得として扱い、常に「部分コピー」と表示します。

### 実SDカード

「SDカード」から外部の物理ディスクを選び、管理者認証した場合のみ読み取り専用ヘルパーを起動します。内蔵ディスクやパーティション単体は対象にしません。ヘルパーは常駐・setuid化せず、検証したディスクを`O_RDONLY`で開いたFDだけを渡します。マウント解除・消去は行いません。

アプリの読み取り専用と、macOS自身の通常マウントが無書き込みであることは別です。原本保全の解析にはIMGを使ってください。

## CLIでの検証

```sh
.build/debug/PCBrowserMac --inspect /path/to/card.img --catalog-only --report /tmp/index.json
# 必要なときだけ全領域の復旧走査
.build/debug/PCBrowserMac --inspect /path/to/card.img --recovery-scan --report /tmp/recovery.json
.build/debug/PCBrowserMac --inspect /path/to/selected.pcbbackup \
  --decode-check --max-decode 180 --features-check --report /tmp/features.json
.build/debug/PCBrowserMac --inspect /path/to/selected.pcbbackup \
  --export-prefix /tmp/new-check/sample --backup-check --report /tmp/export.json
.build/debug/PCBrowserMac --inspect /path/to/selected.pcbbackup \
  --movie /tmp/new-preview.mp4 --movie-start 12 --frames 90 \
  --projection perspective --subtitles --night --report /tmp/movie.json
```

追加機能のCLI例（出力先はすべて新規にします）：

```sh
PCBrowserMac --inspect /path/to/selected.pcbbackup \
  --avi /tmp/new-preview.avi --subtitles --subtitle-all --report /tmp/avi.json
PCBrowserMac --inspect /path/to/selected.pcbbackup \
  --sequence-dir /tmp/new-stills --sample-seconds 5 \
  --print-pdf /tmp/new-contact.pdf --print-layout 4 --report /tmp/stills.json
PCBrowserMac --inspect /path/to/selected.pcbbackup \
  --gps-log /path/to/track.nmea --device-time-zone Asia/Tokyo --gps-offset 0 \
  --movie /tmp/new-synchronized.mp4 --subtitles --report /tmp/gps.json
PCBrowserMac --inspect /path/to/selected.pcbbackup \
  --raw-query --raw-accel-axis 0 --raw-accel-min 500 \
  --recording-report-prefix /tmp/new-recording \
  --recording-report-pdf /tmp/new-recording.pdf --report-focus-frame 600 \
  --report-notes '確認メモ' --report /tmp/report-check.json
PCBrowserMac --inspect /path/to/complete-card.img --catalog-only \
  --copy-image /tmp/new-card-copy.img --report /tmp/copy-check.json
```

原版の一覧・レポート・KML・設定（出力先は新規。実データを含むため結果はGitに入れないでください）：

```sh
PCBrowserMac --inspect /path/to/card.img --lists
PCBrowserMac --inspect /path/to/card.img --legacy-report-dir /tmp/new-report
PCBrowserMac --inspect /path/to/card.img --legacy-history-report-dir /tmp/new-history
PCBrowserMac --inspect /path/to/card.img --legacy-history-kml-dir /tmp/new-kml
PCBrowserMac --legacy-inventory /tmp/new-inventory.json   # 原版メニュー全150項目の対応状況
PCBrowserMac --settings-show /path/to/card.img
PCBrowserMac --settings-apply /path/to/card.img --out /tmp/new-copy.img --plan-only --set key=value
```

`--raw-query`は明示的に全録画のヘッダーを読みますが、映像はデコードしません。センサー値・イベント値の物理的意味は推測しません。外部GPS同期後も元データのCSV／レポートは書き換えません。タイムゾーン未設定時は外部ログの同期を拒否します。

`--catalog-only`は映像・音声本体を読まないカタログ検査で、バックアップの全体ハッシュも照合しません。`--load-all`は全録画のフレームヘッダーを明示照合します（映像デコードとは別）。`--catalog-details`はブロック参照を出力するため、プライベートな検証記録として扱ってください。`--scan-limit`は録画領域先頭からの走査量で、結果は必ず部分走査と表示します。`--decode-check`の初期上限は180フレーム。`--max-decode 0`は索引に含まれる全フレームを検証します。`--export-prefix`は9表示モードのPNG、CSV／KML／GPX／WAVを新規保存します。`--backup-check`は選択バックアップのハッシュ検証と再走査を行います。既存の出力には上書きしません。

## 解析とデータの扱い

Windows PC Browser 1.9.60.0をkorakuen上のCraft Anything CLI **`--deep`**で調べ、Ghidra補助解析と実IMGの読み取り専用観察で形式を照合しました。[追加解析記録](docs/format-expanded.md)に根拠と未確定事項を分けています。

録画、位置情報、設定値、SD／IMG、検証映像、スクリーンショットはGitにコミットしません。単体テストは合成データです。
