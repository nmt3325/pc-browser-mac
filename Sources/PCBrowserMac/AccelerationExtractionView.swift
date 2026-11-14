import SwiftUI
import PCBrowserCore

/// The tabs under the preview; 映像抽出 selects its own tab when it starts.
enum BottomTab: Hashable { case info, sensors, range, triggers, acceleration }

/// One line of the 映像抽出 result list: the original's No. column and the scene.
struct AccelerationRow: Identifiable {
    let no: Int
    let entry: AccelerationEntry
    var id: String { entry.id }
}

/// State of the 映像抽出 of the loaded input: the 個数 slider, the progress of the run and the result list.
@MainActor final class AccelerationExtractionState: ObservableObject {
    static let idleStatus = "リストでチェックした連続録画から、動きの大きい場面を抽出します（映像抽出…）"
    /// 個数 of 「加速度抽出パラメータ調整」; like the original's main window it keeps the value while the program runs.
    @Published var count = AccelerationExtraction.defaultCount
    @Published var running = false
    @Published var progress = 0.0
    @Published var status = AccelerationExtractionState.idleStatus
    @Published var rows: [AccelerationRow] = []
    @Published var deviceID = "—"
    private var token = UUID()
    private var flag = ScanCancellation()

    /// Forgets the result (another input was opened or the input was closed).
    func reset() {
        flag.cancel(); token = UUID()
        running = false; progress = 0; rows = []; deviceID = "—"; status = Self.idleStatus
    }
    func cancel() {
        guard running else { return }
        flag.cancel(); token = UUID()
        running = false; status = "映像抽出を中止しました"
    }
    /// Cuts the recordings into scenes one after the other (each is read, scored and released) and lists the best `count`.
    func run(recordings: [Recording], source: any ByteSource, deviceID: String) {
        guard !running, !recordings.isEmpty else { return }
        let flag = ScanCancellation(), token = UUID(), limit = count, total = recordings.count
        self.flag = flag; self.token = token
        running = true; progress = 0; rows = []; self.deviceID = deviceID
        status = "0/\(total)件の録画を解析しています…"
        Task {
            var scenes: [AccelerationEntry] = []
            do {
                for (n, summary) in recordings.enumerated() {
                    let found = try await Task.detached(priority: .userInitiated) { () throws -> [AccelerationEntry] in
                        let loaded = try CatalogScanner.loadRecording(summary, source: source, cancelled: { flag.cancelled })
                        return AccelerationExtraction.entries(in: loaded)
                    }.value
                    guard self.token == token, !flag.cancelled else { return }
                    scenes += found
                    progress = Double(n + 1) / Double(total)
                    status = "\(n + 1)/\(total)件の録画を解析しました"
                }
                let listed = AccelerationExtraction.ranked(scenes, count: limit)
                rows = listed.enumerated().map { AccelerationRow(no: $0.offset + 1, entry: $0.element) }
                status = listed.isEmpty ? "抽出できる場面がありませんでした（\(total)件の録画・\(scenes.count)場面）"
                                        : "\(total)件の録画の\(scenes.count)場面から、動きポイントの大きい\(listed.count)件を表示しています"
            } catch {
                guard self.token == token else { return }
                status = flag.cancelled ? "映像抽出を中止しました" : "映像抽出を完了できませんでした: " + error.localizedDescription
            }
            if self.token == token { running = false }
        }
    }
}

extension BrowserModel {
    /// The continuous recordings that are checked in the list — the recordings the original's 映像抽出 works on.
    var checkedContinuousRecordings: [Recording] { index?.continuousRecordings.filter { selectedExports.contains($0.id) } ?? [] }

    /// The 映像抽出 button: with nothing checked the original only says so; otherwise the parameter dialog opens.
    func startAccelerationExtraction() {
        guard source != nil, index != nil else { errorMessage = "映像抽出にはSDカードまたはIMGを開く必要があります"; return }
        guard !scanning, !busy else { errorMessage = "読み取りや書き出しが終わってから映像抽出を始めてください"; return }
        guard !acceleration.running else { bottomTab = .acceleration; return }
        guard !checkedContinuousRecordings.isEmpty else { errorMessage = "選択されたデータがありません。"; return }
        showAccelerationParameters = true
    }
    /// OK of 「加速度抽出パラメータ調整」.
    func runAccelerationExtraction() {
        guard let source, let index else { return }
        let targets = checkedContinuousRecordings
        guard !targets.isEmpty else { errorMessage = "選択されたデータがありません。"; return }
        bottomTab = .acceleration
        acceleration.run(recordings: targets, source: source, deviceID: DeviceIdentity.read(from: source, control: index.control) ?? "—")
    }
    /// Choosing a line of the result: shows the recording of the scene, starting at the scene.
    func showAccelerationEntry(_ entry: AccelerationEntry) {
        guard index?.recordings.contains(where: { $0.id == entry.recordingID }) == true else { return }
        listKind = .continuous
        if selectedID == entry.recordingID, recording != nil { seekToFrame(entry.firstFrame); return }
        pendingSeek = (id: entry.recordingID, frame: entry.firstFrame)
        selectedID = entry.recordingID
    }
}

/// 映像抽出 result: No. / 時刻 / 動きポイント / 機器ID, highest 動きポイント first; choosing a line shows that scene.
struct AccelerationExtractionPanel: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var state: AccelerationExtractionState
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("映像抽出…") { model.startAccelerationExtraction() }
                    .disabled(model.index == nil || model.scanning || model.busy || state.running)
                    .help("リストでチェックした連続録画から、加速度の動きが大きい場面を抽出します")
                if state.running {
                    ProgressView(value: state.progress).frame(width: 140)
                    Button("中止") { state.cancel() }
                }
                Text(state.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            if state.rows.isEmpty {
                Spacer(minLength: 0)
            } else {
                Table(state.rows, selection: $selection) {
                    TableColumn("No.") { row in Text(String(row.no)).monospacedDigit() }.width(min: 36, ideal: 44, max: 60)
                    TableColumn("時刻") { row in Text(row.entry.timeText).font(.system(.body, design: .monospaced)) }.width(min: 130, ideal: 150)
                    TableColumn("動きポイント") { row in Text(String(row.entry.points)).monospacedDigit() }.width(min: 90, ideal: 110)
                    TableColumn("機器ID") { _ in Text(state.deviceID) }
                }
                .onChange(of: selection) { _, id in
                    guard let id, let row = state.rows.first(where: { $0.id == id }) else { return }
                    model.showAccelerationEntry(row.entry)
                }
            }
        }
        .padding(8)
        .onChange(of: state.rows.count) { _, _ in selection = nil }
    }
}

/// 加速度抽出パラメータ調整: the 個数 slider (0…100, 30 at first) and OK.
struct AccelerationParameterSheet: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var state: AccelerationExtractionState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("加速度抽出パラメータ調整").font(.headline)
            HStack(spacing: 10) {
                Text("個数")
                Slider(value: Binding(get: { Double(state.count) }, set: { state.count = AccelerationExtraction.clampedCount(Int($0.rounded())) }),
                       in: Double(AccelerationExtraction.countRange.lowerBound)...Double(AccelerationExtraction.countRange.upperBound), step: 1)
                Text("値")
                Text("\(state.count)").monospacedDigit().frame(width: 34, alignment: .trailing)
            }
            Text("リストでチェックした\(model.checkedContinuousRecordings.count)件の連続録画から、動きポイントの大きい順に最大\(state.count)件の場面を抽出します。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") { dismiss(); model.runAccelerationExtraction() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 460)
    }
}
