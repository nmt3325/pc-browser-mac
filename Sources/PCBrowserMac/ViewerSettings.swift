import SwiftUI
import PCBrowserCore

struct ViewerSettings:View {
    @ObservedObject var model:BrowserModel
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack{Text("表示・校正とカード情報").font(.title2);Spacer();Button("閉じる"){dismiss()}.keyboardShortcut(.cancelAction)}
            TabView(selection:$model.settingsTab) {
                ScrollView{Form {
                    Section("360°標準魚眼モデル") {
                        Text("メーカー固有の光学校正値は未確定です。下の幾何パラメーターで調整できます。Windows版と完全一致する補正を保証するものではありません。").font(.caption).foregroundStyle(.secondary)
                        settingSlider("水平（yaw）",value:$model.projection.yaw,range:-180...180)
                        settingSlider("上下（pitch）",value:$model.projection.pitch,range:-89...89)
                        settingSlider("回転（roll）",value:$model.projection.roll,range:-180...180)
                        settingSlider("画角",value:$model.projection.fieldOfView,range:30...150)
                        settingSlider("レンズFOV",value:$model.projection.lensFOV,range:180...220)
                        settingSlider("前レンズの回転",value:$model.projection.frontRotation,range:-180...180)
                        settingSlider("後レンズの回転",value:$model.projection.rearRotation,range:-180...180)
                        settingSlider("レンズ半径 / 高さ",value:$model.projection.radiusScale,range:0.5...1.3)
                        settingSlider("前中心X",value:$model.projection.frontCenterX,range:0...0.5)
                        settingSlider("前中心Y",value:$model.projection.frontCenterY,range:0...1)
                        settingSlider("後中心X",value:$model.projection.rearCenterX,range:0.5...1)
                        settingSlider("後中心Y",value:$model.projection.rearCenterY,range:0...1)
                    }
                    Section("明るさ・拡大") {
                        Toggle("NIGHT（独自ガンマ補正）",isOn:$model.projection.night)
                        settingSlider("露出（EV）",value:$model.projection.exposure,range:-2...3)
                        settingSlider("元映像の拡大率",value:$model.projection.rawZoom,range:1...4)
                    }
                }.padding(12)}.tabItem{Text("表示・360°校正")}.tag(0)
                ScrollView { Form {
                    Picker("GPSの座標系",selection:$model.datum){ForEach(GPSDatum.allCases,id:\.self){Text($0.label).tag($0)}}
                    Text("標準は原版VA 0x56DE20から確認したTokyo→WGS84変換です。ヘッダーの緯度経度は1/600000度、速度はraw×0.036 km/hとして読み出します。").font(.caption)
                    Text("カード時刻にはタイムゾーンがないため、表示・CSVにUTCを推測して付加しません。音声形式は録画のD103/D105ヘッダーから読み取ります。").font(.caption)
                    Divider();LabeledContent("音声",value:model.audioStatus)
                    Text("G・ジャイロは符号付きraw値で表示します。機種別の物理単位換算・軸方向は未確定です。").font(.caption).foregroundStyle(.secondary)
                    GPSSynchronizationPreferences(model:model)
                }.padding(16)}.tabItem{Text("音声・GPS")}.tag(1)
                ExportPreferences(model:model).tabItem{Text("書き出し・印刷")}.tag(2)
                RawSensorSearchPreferences(model:model).tabItem{Text("raw検索")}.tag(3)
                ScrollView{VStack(alignment:.leading,spacing:14) {
                    Text("カード設定の読み出し（読み取り専用）").font(.headline)
                    if model.cardFiles.isEmpty {Text("この入力には読み出せるFAT16設定ファイルがありません。部分バックアップに設定領域は含まれないことがあります。").font(.caption)}
                    ForEach(model.cardFiles){file in GroupBox(file.path){ForEach(file.items){item in HStack{Text(item.section+" / "+item.key);Spacer();Text(item.displayValue).textSelection(.enabled)}.font(.caption).padding(3)}}}
                    Text("録画設定のSDへの書き戻し、パスワード解除、録画消去、フォーマットはこの版では実装していません。未解析の設定値を推測して書き込みません。").font(.caption).foregroundStyle(.orange)
                }.padding(16)}.tabItem{Text("カード情報")}.tag(4)
            }
            HStack{Button("校正プリセットを読み込む",action:model.loadCalibration);Button("プリセットを保存",action:model.saveCalibration);Spacer();Button("表示設定を初期値に"){model.projection=ProjectionSettings()}}
        }.padding(20).frame(width:720,height:660)
    }
    private func settingSlider(_ label:String,value:Binding<Double>,range:ClosedRange<Double>)->some View {
        HStack{Text(label).frame(width:145,alignment:.leading);Slider(value:value,in:range);Text(String(format:"%.3f",value.wrappedValue)).monospacedDigit().frame(width:65,alignment:.trailing)}.font(.caption)
    }
}
struct CapabilitiesView:View {
    @Environment(\.dismiss) private var dismiss
    let rows:[(String,String)]=[
        ("IMG / SD / 選択録画バックアップ","対応形式: YP_FORMAT_1.01・D101/D102・H.264。SD経路は管理者読み取り専用ヘルパー。"),
        ("音声 / GPS / 地図","PCM形式ヘッダー、Tokyo→WGS84、速度、MapKitルート・現在位置、KML / GPX / CSV。"),
        ("360°表示","フラット、パノラマ、前後、4／16分割、ドーム、リング、全球。標準魚眼モデル・手動校正。"),
        ("確認と書き出し","シーク、逆再生、速度、NIGHT、回転、しおり、検索、PNG/JPEG、音声付きMP4 / Motion JPEG AVI、選択字幕、WAV、間隔指定静止画・ページ印刷。"),
        ("全機能互換ではありません","機種別工場校正、暗号化カード、全機種形式、SD設定書き戻し、フォーマット／削除は未対応。"),
        ("検証範囲","実IMG全体の解析と、実映像のMacテストを区別します。物理SD、長時間全録画デコード、Intel、署名・公証は別途検証が必要です。")]
    var body:some View {VStack(alignment:.leading,spacing:16){HStack{Text("PC Browser Mac · 対応状況").font(.title2);Spacer();Button("閉じる"){dismiss()}.keyboardShortcut(.cancelAction)};ForEach(Array(rows.enumerated()),id:\.offset){_,row in VStack(alignment:.leading,spacing:5){Text(row.0).font(.headline);Text(row.1).font(.callout).foregroundStyle(.secondary)}};Spacer(minLength:0)}.padding(25).frame(width:700,height:590)}
}
