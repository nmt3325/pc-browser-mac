import SwiftUI
import PCBrowserCore

struct ExportPreferences: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        SettingsPane {
            SettingsGroup("連続静止画・印刷の間隔") {
                Picker("単位", selection: $model.samplingBySeconds) { Text("フレーム間隔").tag(false); Text("秒間隔").tag(true) }.pickerStyle(.segmented)
                if model.samplingBySeconds {
                    HStack { Text("間隔（秒）"); Spacer(); TextField("間隔（秒）", value: $model.samplingSeconds, format: .number).labelsHidden().frame(width: 120) }
                } else { Stepper("\(model.samplingFrames)フレームごと", value: $model.samplingFrames, in: 1...100000) }
                SettingsHelp("IN / OUTの範囲内で先頭から抽出します。時刻の空白で同じ画像を繰り返し出力しません。印刷は1ページ1枚または4枚です。全フレームは膨大になるためページ数を確認してください。")
                HStack {
                    Text("印刷レイアウト")
                    Picker("印刷レイアウト", selection: $model.printFramesPerPage) { Text("1枚 / ページ").tag(1); Text("4枚 / ページ").tag(4) }.labelsHidden()
                }
            }
            SettingsGroup("MP4 / AVI の字幕") {
                Toggle("動画に字幕を重ねる", isOn: $model.exportSubtitles)
                field("カード時刻", .date); field("速度", .speed); field("緯度・経度", .gps)
                field("加速度 XYZ（raw）", .acceleration); field("ジャイロ XYZ（raw）", .gyro)
                field("入力バイト（raw）", .inputs); field("イベントバイト（raw）", .event)
                SettingsHelp("入力・イベントの機種別ビット割当は未確定です。ウインカー／ブレーキを推測表示しません。")
            }
            SettingsGroup("KML / Google Earth") {
                Toggle("ルート（線）", isOn: $model.trackStyle.showRoute); Toggle("地点", isOn: $model.trackStyle.showPoints)
                HStack { Text("線の色（RGB 6桁）"); Spacer(); TextField("線の色（RGB 6桁）", text: $model.trackStyle.lineRGB).labelsHidden().frame(width: 150) }
                HStack { Text("地点の色（RGB 6桁）"); Spacer(); TextField("地点の色（RGB 6桁）", text: $model.trackStyle.pointRGB).labelsHidden().frame(width: 150) }
                Stepper("不透明度 \(model.trackStyle.alpha) / 255", value: $model.trackStyle.alpha, in: 0...255)
                HStack { Text("線幅"); Slider(value: $model.trackStyle.width, in: 1...10, step: 1); Text("\(Int(model.trackStyle.width))") }
                Stepper("\(model.trackStyle.density)地点ごと（終端は保持）", value: $model.trackStyle.density, in: 1...30)
                Toggle("KML保存後にインストール済みGoogle Earthを開く", isOn: $model.openEarthAfterExport)
                SettingsHelp("ログ書き出しは元カードのGPSを使用します。外部NMEAは表示・動画字幕のみに使用し、元データと混同しません。")
            }
        }
    }
    private func field(_ label: String, _ value: SubtitleFields) -> some View {
        Toggle(label, isOn: Binding(get: { model.subtitleFields.contains(value) }, set: { enabled in
            if enabled { model.subtitleFields.insert(value) } else { model.subtitleFields.remove(value) }
        })).disabled(!model.exportSubtitles)
    }
}

struct GPSSynchronizationPreferences: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        SettingsGroup("外部NMEAログの時刻同期") {
            Button("外部NMEAログを開く", action: model.importNMEA)
            SettingsHelp(model.externalGPSStatus)
            Toggle("外部ログを地図・速度・動画字幕に使う", isOn: $model.useExternalGPS).disabled(model.externalGPSTrack == nil)
            VStack(alignment: .leading, spacing: 6) {
                Text("ドラレコ時刻のタイムゾーン（明示指定）").font(.callout)
                Picker("ドラレコ時刻のタイムゾーン", selection: $model.deviceTimeZoneID) {
                    Text("未指定 — 同期しない").tag("")
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(maxWidth: .infinity)
            }
            HStack {
                Text("ログ側の補正秒")
                Spacer()
                TextField("ログ側の補正秒", value: $model.gpsLogOffset, format: .number).labelsHidden().frame(width: 120)
            }
            SettingsHelp("正の補正値は、より後のログ時刻を参照します。")
            Text(model.gpsSynchronizationStatus).font(.caption).fixedSize(horizontal: false, vertical: true)
            SettingsHelp("UTC日付付きRMCのみ同期できます。時刻不明・10秒超の欠測・範囲外は補間せず位置なしとします。初期状態では同期しません。")
        }
    }
}
