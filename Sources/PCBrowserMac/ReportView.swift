import SwiftUI
import PCBrowserCore

struct RecordingReportView: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var report: RecordingReport?
    @State private var notes = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("録画レポート").font(.title2); Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView {
                if let report {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(report.startWallTime + " — " + report.endWallTime).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 10) {
                            row("録画内の時間", String(format: "%.2f 秒", report.durationSeconds), "フレーム / 保存ブロック", "\(report.frames) / \(report.storageBlocks)")
                            row("平均速度（有効区間）", speed(report.meanSpeedKMH), "最高速度", speed(report.maximumSpeedKMH))
                            row("速度からの推定距離", report.distanceEstimateKM.map { String(format: "%.3f km", $0) } ?? "—", "GPS / 速度の有効時間", String(format: "%.2f 秒", report.speedCoverageSeconds))
                        }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        Text("有効GPSと速度を持つ区間を台形積分した計算値です。2秒を超える欠測を除外します。総走行距離・運転時間を保証する値でも、原版レポートと同じ集計規則でもありません。カード時刻にUTCは推測付加しません。").font(.caption).foregroundStyle(.secondary)
                        GroupBox("センサー範囲（raw counts）") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("加速度 " + ranges(report.accelerationRaw)); Text("ジャイロ " + ranges(report.gyroRaw))
                                Text("イベントraw: " + report.eventRawDistribution.map { String(format: "%02X = %d枚", $0.value, $0.frames) }.joined(separator: " / "))
                            }.font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                        Text("イベント種別・発生回数は機種別の意味が未確定のため推測しません。").font(.caption).foregroundStyle(.secondary)
                        Text("備考").font(.headline)
                        TextEditor(text: $notes).font(.body).frame(minHeight: 100).border(.quaternary)
                        Text("16,384文字まで。このMacに保存します（閉じると保存、元SDは変更なし）。PDFには参照中の位置と前後2秒・開始／終了の画像を添えます。自動イベント検出ではありません。").font(.caption).foregroundStyle(.secondary)
                    }
                } else { ProgressView("レポートを作成しています…") }
            }
            HStack {
                Button("CSV") { model.exportReport("csv", notes: notes) }; Button("JSON") { model.exportReport("json", notes: notes) }
                Button("PDF") { model.exportReport("pdf", notes: notes) }; Button("印刷") { model.printReport(notes: notes) }
                Spacer(); Text(model.busy ? "書き出し中…" : "元データは読み取り専用").font(.caption).foregroundStyle(.secondary)
            }.disabled(report == nil || model.busy)
        }.padding(22).frame(width: 790, height: 640)
        .task {
            notes = model.reportNotes()
            guard let recording = model.recording else { return }
            do { report = try await Task.detached { try RecordingReport.make(recording) }.value }
            catch { model.errorMessage = error.localizedDescription }
        }
        .onDisappear { model.saveReportNotes(notes) }
    }
    private func speed(_ value: Double?) -> String { value.map { String(format: "%.2f km/h", $0) } ?? "—" }
    private func ranges(_ values: [RawAxisRange]) -> String { values.enumerated().map { "\(["X", "Y", "Z"][$0.offset]) \($0.element.minimum)…\($0.element.maximum)" }.joined(separator: " / ") }
    private func row(_ left: String, _ a: String, _ right: String, _ b: String) -> some View {
        GridRow { Text(left).foregroundStyle(.secondary); Text(a).monospacedDigit(); Text(right).foregroundStyle(.secondary); Text(b).monospacedDigit() }.font(.caption)
    }
}

struct RawSensorSearchPreferences: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        Form {
            Toggle("rawセンサー／イベント条件を使う", isOn: $model.rawQuery.enabled)
            Section("絶対値が閾値以上（0 = 条件なし）") {
                Picker("加速度の軸", selection: $model.rawQuery.accelerationAxis) { ForEach(0..<3) { Text(["X", "Y", "Z"][$0]).tag($0) } }
                TextField("加速度 |raw| ≥", value: $model.rawQuery.minimumAbsoluteAcceleration, format: .number)
                Picker("ジャイロの軸", selection: $model.rawQuery.gyroAxis) { ForEach(0..<3) { Text(["X", "Y", "Z"][$0]).tag($0) } }
                TextField("ジャイロ |raw| ≥", value: $model.rawQuery.minimumAbsoluteGyro, format: .number)
            }
            Section("rawバイトの一致（10進）") {
                Stepper("イベント: \(model.rawQuery.eventByte < 0 ? "指定なし" : String(model.rawQuery.eventByte))", value: $model.rawQuery.eventByte, in: -1...255)
                Picker("入力バイト", selection: $model.rawQuery.inputIndex) { Text("指定なし").tag(-1); ForEach(0..<6) { Text("raw[\($0)]").tag($0) } }
                Stepper("入力値: \(model.rawQuery.inputValue)", value: $model.rawQuery.inputValue, in: 0...255)
            }
            Text("条件は同じフレーム内ですべて一致した録画を表示します。物理G・角速度・ウインカー／ブレーキ・トリガ名の意味は推測しません。閾値は0…32768に制限します。").font(.caption).foregroundStyle(.secondary)
            Text("未検索の録画は勝手に除外しません。条件変更後はサイドバーの「全録画の詳細検索」で確定してください。映像本体のデコードは行いません。").font(.caption).foregroundStyle(.secondary)
            Button("条件を解除") { model.rawQuery = RawSensorQuery() }
        }.padding(16)
    }
}
