# GitHub Actionsビルド

通常の.app生成は[Build macOS app](https://github.com/nmt3325/pc-browser-mac/actions/workflows/macos.yml)で行う。自宅Mac・dc・SDカード・追加の秘密情報は不要。

## 起動条件と成果物

- `main`へのpush、Pull Request、手動の`Run workflow`で実行する。
- GitHub-hostedの`macos-15` ARM64ランナーを使用。Intel／Universal版はこのworkflowでは生成しない。
- `PC-Browser-Mac-arm64-<run番号>` artifactに、.appを収めたZIP、同じcommitのソースZIP、`SHA256SUMS`、`build-metadata.json`、`ci-smoke.json`、説明を保存する。保持30日。
- 合成テストのログは別artifactに保持14日。失敗時も可能な限り保存する。
- `v*`タグでは、ビルド成功後に同じ成果物をGitHub Releaseへ公開する。ハイフンを含む版はprerelease。既存releaseは上書きしない。
- `APP_VERSION`はタグの`v`を除いた値、通常branchではbuild scriptの既定値。ビルド番号・commit・実行URLを成果物から確認する。

## 検査

1. Swiftの合成単体テストを実行。失敗したらビルド・配布へ進まない。
2. Swift releaseビルドと読み取り専用ヘルパーの生成、アドホック署名。両方の最小対象OSを14.0に設定する。
3. arm64であること、Info.plist、署名を検査。ZIPへ格納して別ディレクトリーに展開し、署名と両実行ファイルの完全一致を再確認する。
4. **展開した.appのCLI**で、CI内で生成した合成IMGの高速カタログと遅延詳細読み込みを実行する。3保存ブロックが1録画、索引概数6、詳細取得前0／取得後6フレームになること、入力不変を検査する。D103の非0累積位置も含む。
5. 配布ZIPにIMG・H.264・音声・動画・位置ログ等を混入させない検査と、SHA-256を実行する。

Actionsのソースcommit、テスト数・失敗数、OS／Swift、ZIPのSHA-256、署名・CLI検査結果を`build-metadata.json`へ記録する。GitHub Actionsが成功したことと、過去の実データ試験の結果は分けて扱う。

## このCIで検査しないもの

実カード、私的映像、GPS実座標、機密設定はアップロードしない。GUI操作、音声の実再生、Metal各表示、MapKit、実SDの管理者認証、メーカー光学校正、全カード映像のデコード、長時間AV同期をこのCIで通過したとは表示しない。それらの過去の確認範囲は[検証記録](validation-catalog.md)に記載する。

Apple Developerの署名証明書とApple公証は未設定。成果物はアドホック署名であり、公証済みアプリではない。

ビルドjobの権限は`contents: read`、tag公開jobだけ`contents: write`。checkoutに認証情報を残さず、使用する公式Actionは検証したリリースのcommit SHAに固定している。

Runnerラベルは[GitHub公式のrunner一覧](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)を参照。
