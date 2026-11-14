import SwiftUI
import PCBrowserCore

// A finite proposed width is essential: macOS Form can otherwise use a long
// help string or picker label as its ideal width and clip the entire sheet.
struct SettingsPane<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(width: max(0, geometry.size.width - 32), alignment: .leading)
                    .padding(16)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
struct SettingsHelp: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct SettingsGroup<Content: View>: View {
    let title: String
    private let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}
struct ViewerSettings: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("表示・校正とカード情報").font(.title2); Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction) }
            TabView(selection: $model.settingsTab) {
                SettingsPane {
                    SettingsGroup("360°標準魚眼モデル") {
                        SettingsHelp("メーカー固有の光学校正値は未確定です。下の幾何パラメーターで調整できます。Windows版と完全一致する補正を保証するものではありません。")
                        settingSlider("水平（yaw）", value: $model.projection.yaw, range: -180...180)
                        settingSlider("上下（pitch）", value: $model.projection.pitch, range: -89...89)
                        settingSlider("回転（roll）", value: $model.projection.roll, range: -180...180)
                        settingSlider("画角", value: $model.projection.fieldOfView, range: 30...150)
                        settingSlider("レンズFOV", value: $model.projection.lensFOV, range: 180...220)
                        settingSlider("前レンズの回転", value: $model.projection.frontRotation, range: -180...180)
                        settingSlider("後レンズの回転", value: $model.projection.rearRotation, range: -180...180)
                        settingSlider("レンズ半径 / 高さ", value: $model.projection.radiusScale, range: 0.5...1.3)
                        settingSlider("前中心X", value: $model.projection.frontCenterX, range: 0...0.5)
                        settingSlider("前中心Y", value: $model.projection.frontCenterY, range: 0...1)
                        settingSlider("後中心X", value: $model.projection.rearCenterX, range: 0.5...1)
                        settingSlider("後中心Y", value: $model.projection.rearCenterY, range: 0...1)
                    }
                    SettingsGroup("明るさ・拡大") {
                        Toggle("NIGHT（独自ガンマ補正）", isOn: $model.projection.night)
                        settingSlider("露出（EV）", value: $model.projection.exposure, range: -2...3)
                        settingSlider("元映像の拡大率", value: $model.projection.rawZoom, range: 1...4)
                    }
                }.tabItem { Text("表示・360°校正") }.tag(0)
                SettingsPane {
                    SettingsGroup("カードのGPS・音声") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("GPSの座標系").font(.callout)
                            Picker("GPSの座標系", selection: $model.datum) { ForEach(GPSDatum.allCases, id: \.self) { Text($0.label).tag($0) } }
                                .labelsHidden().frame(maxWidth: .infinity)
                        }
                        SettingsHelp("標準は原版VA 0x56DE20から確認したTokyo→WGS84変換です。ヘッダーの緯度経度は1/600000度、速度はraw×0.036 km/hとして読み出します。")
                        SettingsHelp("カード時刻にはタイムゾーンがないため、表示・CSVにUTCを推測して付加しません。音声形式は録画のD103/D105ヘッダーから読み取ります。")
                        Text("音声: " + model.audioStatus).font(.callout).fixedSize(horizontal: false, vertical: true)
                        SettingsHelp("加速度は原版と同じ換算（raw÷1000 G、0.01単位で切り捨て、軸順X/Y/Z）で表示します。ジャイロは符号付きraw値のままで、原版の換算は未確定です。")
                    }
                    GPSSynchronizationPreferences(model: model)
                    SettingsGroup("センサー換算（任意）") {
                        SettingsHelp("加速度は未入力なら原版と同じ1000 counts/Gで表示します（制御した値を原版に与えて確認済み）。ジャイロは原版の換算係数が未確定のため、未入力ならraw表示です。既知の係数を入力すると、センサー表示を原版の目盛り（拡大±1.0／標準±2.0／縮小1±3.0／縮小2±4.0、ジャイロは±36／72／108／144）で物理値表示します。")
                        Picker("表示スケール", selection: $model.sensorScale) { ForEach(GSensorScale.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                        CalibrationField(title: "加速度 counts/G", hint: "空欄＝1000（原版）", value: $model.sensorCalibration.accelerationCountsPerUnit)
                        CalibrationField(title: "ジャイロ counts/単位", hint: "例: 131", value: $model.sensorCalibration.gyroCountsPerUnit)
                    }
                }.tabItem { Text("音声・GPS") }.tag(1)
                ExportPreferences(model: model).tabItem { Text("書き出し・印刷") }.tag(2)
                RawSensorSearchPreferences(model: model).tabItem { Text("raw検索") }.tag(3)
                SettingsPane {
                    Text("カード設定の読み出し（読み取り専用）").font(.headline)
                    if model.cardFiles.isEmpty { SettingsHelp("この入力には読み出せるFAT16設定ファイルがありません。部分バックアップに設定領域は含まれないことがあります。") }
                    ForEach(model.cardFiles) { file in
                        SettingsGroup(file.path) {
                            ForEach(file.items) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.section + " / " + item.key).foregroundStyle(.secondary)
                                    Text(item.displayValue).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }.font(.caption)
                            }
                        }
                    }
                    Text("録画設定の変更はツールバーの「記録設定」から新しいIMGコピーにだけ書き込めます。原本カードへの書き戻し、パスワード解除、録画消去、フォーマットは実装していません。")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }.tabItem { Text("カード情報") }.tag(4)
            }
            HStack {
                Button("校正プリセットを読み込む", action: model.loadCalibration)
                Button("プリセットを保存", action: model.saveCalibration)
                Spacer()
                Button("表示設定を初期値に") { model.projection = ProjectionSettings() }
            }
        }.padding(20).frame(width: 720, height: 700)
    }
    private func settingSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 135, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.3f", value.wrappedValue)).monospacedDigit().frame(width: 65, alignment: .trailing)
        }.font(.caption)
    }
}
struct CalibrationField: View {
    let title: String
    let hint: String
    @Binding var value: Double?
    @State private var text = ""
    var body: some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            TextField(hint, text: $text).textFieldStyle(.roundedBorder).onSubmit { commit() }
            Button("適用") { commit() }
            Button("消去") { text = ""; value = nil }
        }.font(.caption).onAppear { text = value.map { String($0) } ?? "" }
    }
    private func commit() {
        if let parsed = Double(text.trimmingCharacters(in: .whitespaces)), parsed.isFinite, parsed > 0 { value = parsed } else { value = nil; text = "" }
    }
}
struct CapabilitiesView:View {
    @Environment(\.dismiss) private var dismiss
    let rows:[(String,String)]=[
        ("IMG / SD / 選択録画バックアップ","対応形式: YP_FORMAT_1.01・D101/D102・H.264。SD経路は管理者読み取り専用ヘルパー。"),
        ("音声 / GPS / 地図","PCM形式ヘッダー、Tokyo→WGS84、速度、MapKitルート・現在位置、KML / GPX / CSV。"),
        ("360°表示","フラット、パノラマ、前後、4／16分割、ドーム、リング、全球。標準魚眼モデル・手動校正。"),
        ("記録設定（Q-01系）","ツールバーの「記録設定」で、IMGから録画方法・コマ数・履歴・上書き・Gセンサー・ID・日時／設置角度の指示ファイルを読み出し、新しいIMGコピーにだけ書き込みます。")
        ,("確認と書き出し","シーク、逆再生、速度、NIGHT、回転、しおり、検索、PNG/JPEG、音声付きMP4 / Motion JPEG AVI、選択字幕、WAV、間隔指定静止画・ページ印刷。"),
        ("全機能互換ではありません","機種別工場校正、暗号化カード、全機種形式、原本SDカードへの設定書き戻し、フォーマット／削除は未対応。記録設定はQ-01系のIMGを新しいコピーへ書く形で対応。"),
        ("原版メニュー対応表","メニューバーの「Mac独自 ▸ 原版メニュー対応表」で、原版の全コマンドごとに実装状況・ブロック理由・原本保護の判断を確認できます。"),
        ("検証範囲","実IMG全体の解析と、実映像のMacテストを区別します。物理SD、長時間全録画デコード、Intel、署名・公証は別途検証が必要です。")]
    var body:some View {VStack(alignment:.leading,spacing:16){HStack{Text("PC Browser Mac · 対応状況").font(.title2);Spacer();Button("閉じる"){dismiss()}.keyboardShortcut(.cancelAction)};ForEach(Array(rows.enumerated()),id:\.offset){_,row in VStack(alignment:.leading,spacing:5){Text(row.0).font(.headline);Text(row.1).font(.callout).foregroundStyle(.secondary)}};Spacer(minLength:0)}.padding(25).frame(width:700,height:590)}
}
