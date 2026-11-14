# GitHub Actionsビルド

通常の.app生成は[Build macOS app](https://github.com/nmt3325/pc-browser-mac/actions/workflows/macos.yml)で行う。自宅Mac・dc・SDカード・追加の秘密情報は不要。

## 起動条件と成果物

- `main`へのpush、Pull Request、手動の`Run workflow`で実行する。
- GitHub-hostedの`macos-15` ARM64ランナーを使用。Intel／Universal版はこのworkflowでは生成しない。
- `PC-Browser-Mac-arm64-<run番号>` artifactに、.appを収めたZIP、同じcommitのソースZIP、`SHA256SUMS`、`build-metadata.json`、`ci-smoke.json`、説明を保存する。保持30日。
- 合成テストのログは別artifactに保持14日。失敗時も可能な限り保存する。
- `v*`タグでは、ビルド成功後に同じ成果物をGitHub Releaseへ公開する。ハイフンを含む版はprerelease。既存releaseは上書きしない。
- タグを直接作れない環境では、`main`に対する手動の`Run workflow`で`release_tag`（例：`v0.2.0-beta.2`）を入力すると、同じ検査を通ったあとに`gh release create`がそのcommitへタグを作ってreleaseを公開する（`main`以外・形式不正・既存releaseのタグは失敗）。リリース本文は`docs/release-notes.md`の固定文に、実行ごとのビルド情報（commit・テスト数・実行URL）を先頭に付けて作る。
- `APP_VERSION`はタグの`v`を除いた値、通常branchではbuild scriptの既定値。ビルド番号・commit・実行URLを成果物から確認する。

## 検査

1. Swiftの合成単体テストを実行。失敗したらビルド・配布へ進まない。
2. Swift releaseビルドと読み取り専用ヘルパーの生成、アドホック署名。両方の最小対象OSを14.0に設定する。
3. arm64であること、Info.plist、署名を検査。ZIPへ格納して別ディレクトリーに展開し、署名と両実行ファイルの完全一致を再確認する。
4. **展開した.appのCLI**で、CI内で生成した合成IMGの高速カタログと遅延詳細読み込みを実行する。3保存ブロックが1録画、索引概数6、詳細取得前0／取得後6フレームになること、入力不変を検査する。D103の非0累積位置も含む。
5. 配布ZIPにIMG・H.264・音声・動画・位置ログ等を混入させない検査と、SHA-256を実行する。

Actionsのソースcommit、テスト数・失敗数、OS／Swift、ZIPのSHA-256、署名・CLI検査結果を`build-metadata.json`へ記録する。GitHub Actionsが成功したことと、過去の実データ試験の結果は分けて扱う。

## 互換性確認（手動・任意）

[Compatibility matrix (manual)](https://github.com/nmt3325/pc-browser-mac/actions/workflows/compat.yml)は`workflow_dispatch`専用。通常のpush／PRでは実行しない。GitHub-hostedの`macos-14`（arm64）と`macos-15-intel`（x86_64）で、合成単体テスト、releaseビルド、ad-hoc署名、ZIP展開後の署名・CLI合成スモークを実行し、`PC-Browser-Mac-compat-<runner>-<run番号>`として証跡を保持14日で保存する。

これは**単体テストとCLI合成スモークのみ**の互換性確認。Intel版・macOS 14実機でのGUI、実メディア、実SD、外部アプリ連携は確認しない。通常配布物は引き続き`macos.yml`のarm64 artifactで、この手動workflowの成果物は配布対象にしない。macOSランナーは分単位課金の倍率が高いため、必要なときだけ実行する。

初回の実行（run 1、commit `b5e2b899f1beba68d7656cc9cacab4328924d2d4`）では、`macos-14`ジョブは工程の前にキャンセルされ（ログなし、理由未確認、ランナー提供終了の可能性）、`macos-15-intel`ジョブは単体テスト126件・ビルド・署名・展開後検証・CLI合成スモークまで成功した。macOS 14上の実行は未確認のまま。

## 公開済み成果物の確認（手動・任意）

[Verify a published release (manual)](https://github.com/nmt3325/pc-browser-mac/actions/workflows/verify-release.yml)は`workflow_dispatch`専用で、入力`tag`（例：`v0.2.0-beta.3`）のreleaseから**公開済みのアセットをそのままダウンロード**する。ビルドはしない。`SHA256SUMS`の全ファイル照合、署名、実行ファイルのarm64、最小対象OSを確認し、展開した.appで`scripts/ci-smoke.py`（CLI合成スモークと、`PCB_REQUIRE_GUI_CHECK=1`によるGUI自己検査）を`macos-14`と`macos-15`（どちらもarm64）で実行する。結果は`verify-release-<runner>-<run番号>` artifactの`verify-release.json`とGUI検査の証拠に保存する。

これは利用者が入手するファイルそのものの検査だが、GitHub-hostedの仮想マシン上の合成データによる確認であり、macOS 14の実機、Intel実機、実カード、実SDの代わりにはならない。

## GUI自己検査の再生時間

GUI自己検査は、再生中の映像が音声クロックから0.35秒以内に付いていることを確認する（しきい値は変えない）。この確認は実行マシンの速さに左右されるため、レポートには再生中に表示したコマ数と1コマの表示時間（平均・最大、ミリ秒。`playback_shown_frames`・`playback_show_mean_ms`・`playback_show_max_ms`）も残す。遅いランナーで不合格になったときに、再生の不具合かマシンの遅さかを区別するための記録である。あわせて、デコード・画像変換・投影それぞれの平均（`playback_decode_mean_ms`・`playback_convert_mean_ms`・`playback_project_mean_ms`）と、デコード／変換したコマ数を残す。

再生は、1コマが要求から画面に出るまでの時間の移動平均（上限0.5秒、`PlaybackLatency`）を測り、その分だけ先に来るコマを要求して音声に合わせる。GPUのないGitHub-hostedの仮想マシンでは1コマに約0.2秒かかる回があり（run 141: 平均222ミリ秒、最大594ミリ秒、2秒間に6コマ）、現在時刻のコマを要求するだけだと表示中のコマがその分だけ遅れ、許容0.35秒を超えて不合格になる回があった（run 138は2回とも0.43〜0.52秒）。実際のM系Mac（macOS 15.7.7）では同じ検査で1コマ平均23ミリ秒・最大46ミリ秒、差は0.06秒だった。

さらに、シークや、コマを飛ばして達したキーフレームのたびに映像デコーダー（VideoToolboxのセッション）を作り直さず再利用する（SPS/PPSが変わったときと、エラーの後だけ作り直す）。レポートには、表示したコマごとの所要時間（`playback_show_log`）と、レンダラー1回ごとの所要時間（`playback_render_call_ms`）も残し、停止がどのコマで起きたかを後から追えるようにした。結果は、run #144（コミット`29b79b31`、差0.244秒、最大316ミリ秒）に対し、run #146（コミット`5eea4d09`、408件）は同じコミットの3回の実行がすべて合格し、映像は音声より0.05〜0.11秒遅れ、2秒間に17〜18コマを表示した（最大234〜378ミリ秒）。3回の合格は、不合格が二度と起きないことを保証するものではない。

## このCIで検査しないもの

実カード、私的映像、GPS実座標、機密設定はアップロードしない。GUI操作、音声の実再生、Metal各表示、MapKit、実SDの管理者認証、メーカー光学校正、全カード映像のデコード、長時間AV同期をこのCIで通過したとは表示しない。それらの過去の確認範囲は[検証記録](validation-catalog.md)に記載する。

Apple Developerの署名証明書とApple公証は未設定。成果物はアドホック署名であり、公証済みアプリではない。

ビルドjobの権限は`contents: read`、tag公開jobだけ`contents: write`。checkoutに認証情報を残さず、使用する公式Actionは検証したリリースのcommit SHAに固定している。

Runnerラベルは[GitHub公式のrunner一覧](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)を参照。
