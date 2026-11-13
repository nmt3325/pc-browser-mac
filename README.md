# PC Browser Mac

Yupiteru PC Browser録画用SDカード／IMGをMacで確認する、独立したネイティブGUIです。
**v0.2.0-beta.1：音声・GPS／地図・360°表示に対応した拡張ベータ版です。Windows版の全機能互換を達成した完成版ではありません。**

Mac実機で単体テスト48件、実データ1,200フレームのVideoToolboxデコード、9種類のMetal表示、音声付きMP4出力、GUIのシーク・正逆再生・音声準備・経路読込を確認しました。秒境界で映像出力時刻が重複する不具合と、初期の魚眼補正の上下向きを修正しています。検証対象は実カード由来の部分バックアップで、物理SDの読込や全機種対応を保証するものではありません。

## 主な機能

- **読み取り専用**：IMG、外部SDカード、選択録画の`.pcbbackup`。D101/D102の長さ・参照・複製ヘッダーを照合して索引を作成。
- **映像**：VideoToolboxによるH.264デコード、フレーム送り／戻し、シーク、秒数移動、正逆再生、0.5／1／1.5／2／4倍速。FFmpegのインストールは不要。
- **音声**：D103/D105の形式ヘッダーからPCMを抽出。今回の実データは8 kHz・8 bit unsigned・モノラル。音量、ミュート、WAV出力。通常の前進再生では音声クロックに映像を追従させます。逆再生・4倍速は消音。
- **GPS／地図**：バイナリ座標、衛星数、速度。Windows版から追ったTokyo→WGS84変換と手動のWGS84指定。MapKitの経路・現在位置・追従・航空写真。CSV／KML／GPX出力、外部NMEAログ読込。
- **360°表示**：元魚眼、フラット／VR、360°パノラマ、前後2画面、4／16分割、ドーム、リング、全球。Metal処理、ドラッグで方向変更、yaw／pitch／roll／画角、手動レンズ校正、NIGHT／露出、元映像拡大。校正プリセットの保存／読込。
- **確認・保存**：日時／CH／録画ID／速度検索、しおり、並び順、複数録画選択、IN／OUT範囲、PNG／JPEG、連続PNG、WAV、音声付きH.264 MP4、カード時刻・速度・座標字幕、1コマ／4コマ印刷、別ウインドウ表示。
- **センサー・設定閲覧**：加速度／ジャイロの符号付きraw値とグラフ、FAT16のCONFIG内INI等の読み取り。パスワード等の値は隠して表示。

機能が存在することと検証を通過したことは区別しています。[検証記録](docs/validation-expanded.md)と[Windows版との機能差分](docs/feature-parity.md)を参照してください。

## 重要な制限

- **工場校正済みの360°補正ではありません。** 明示的な標準等距離射影モデルです。提供映像に合わせた初期の向きと、中心・半径・前後回転・FOVを調整できますが、メーカー固有のレンズ歪曲、光学中心、継ぎ目、機種差を完全再現していません。
- **G／ジャイロはraw値です。** 物理単位、軸方向、機種別校正は未確定。Windows版のイベント／常時／履歴分類も未確定です。
- AVI／MotionJPEG出力、Windows版バックアップ形式の生成、暗号化・パスワード保護カード、全機種・全カード形式は未対応。
- **SDへの設定保存、消去、フォーマット、パスワード解除、FW更新は実装していません。** 未解析の値を推測して原本に書き込みません。
- カード時刻にタイムゾーンを推測して付加しません。フレーム時刻とPCM長の差、重複するフレームスロットがあるため、工場実装と完全なAV同期の一致は未保証です。差が大きい場合は画面に表示します。
- 地図タイルの取得はインターネット接続が必要。外部NMEAログは自動で映像と同期しません。
- 実SD読み取りのエンドツーエンド動作、Intel、全録画の連続デコード、破損・循環記録の全パターンは未検証です。

## ビルドと起動

macOS 14以降、Xcode Command Line Toolsが必要です。外部Swiftパッケージへの依存はありません。配布バイナリーはApple Silicon用。アドホック署名で、Appleの公証は未取得です。

配布ZIPを展開して.appをアプリケーションフォルダーに置きます。初回にmacOSが開くことを拒否した場合は、システム設定の「プライバシーとセキュリティ」で対象アプリの「このまま開く」を選択してください。システム全体の保護機能を無効化する必要はありません。

```sh
swift test --jobs 2
./scripts/build-app.sh
open "build/PC Browser Mac.app"
```

### IMGとバックアップ

「開く」でIMGまたは`.pcbbackup`を選択します。全領域の走査はバックグラウンドで行い、キャンセルできます。選択録画バックアップはMac版独自のコンパクトなディレクトリー形式です。SHA-256検証付きで再生できますが、**完全なSDクローンでもWindows版バックアップ互換でもありません**。欠落領域は未取得として扱い、常に「部分コピー」と表示します。

### 実SDカード

「SDカード」から外部の物理ディスクを選び、管理者認証した場合のみ読み取り専用ヘルパーを起動します。内蔵ディスクやパーティション単体は対象にしません。ヘルパーは常駐・setuid化せず、検証したディスクを`O_RDONLY`で開いたFDだけを渡します。マウント解除・消去は行いません。

アプリの読み取り専用と、macOS自身の通常マウントが無書き込みであることは別です。原本保全の解析にはIMGを使ってください。

## CLIでの検証

```sh
.build/debug/PCBrowserMac --inspect /path/to/card.img --report /tmp/index.json
.build/debug/PCBrowserMac --inspect /path/to/selected.pcbbackup \
  --decode-check --max-decode 180 --features-check --report /tmp/features.json
.build/debug/PCBrowserMac --inspect /path/to/selected.pcbbackup \
  --export-prefix /tmp/new-check/sample --backup-check --report /tmp/export.json
.build/debug/PCBrowserMac --inspect /path/to/selected.pcbbackup \
  --movie /tmp/new-preview.mp4 --movie-start 12 --frames 90 \
  --projection perspective --subtitles --night --report /tmp/movie.json
```

`--scan-limit`は録画領域先頭からの走査量で、結果は必ず部分走査と表示します。`--decode-check`の初期上限は180フレーム。`--max-decode 0`は索引に含まれる全フレームを検証します。`--export-prefix`は9表示モードのPNG、CSV／KML／GPX／WAVを新規保存します。`--backup-check`は選択バックアップのハッシュ検証と再走査を行います。既存の出力には上書きしません。

## 解析とデータの扱い

Windows PC Browser 1.9.60.0をkorakuen上のCraft Anything CLI **`--deep`**で調べ、Ghidra補助解析と実IMGの読み取り専用観察で形式を照合しました。[追加解析記録](docs/format-expanded.md)に根拠と未確定事項を分けています。

録画、位置情報、設定値、SD／IMG、検証映像、スクリーンショットはGitにコミットしません。単体テストは合成データです。
