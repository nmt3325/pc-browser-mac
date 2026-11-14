import SwiftUI
import AppKit
import PDFKit
import PCBrowserCore

/// What the report dialog shows: the report of the selected recording, its reference images (event reports) and the figures.
@MainActor final class LegacyReportContent: ObservableObject {
    @Published private(set) var report: LegacyReport?
    @Published private(set) var thumbnails: [CGImage?] = []
    @Published private(set) var thumbnailsLoaded = false
    @Published private(set) var speedImage: NSImage?
    @Published private(set) var accelerationImage: NSImage?
    @Published private(set) var mapImage: NSImage?
    @Published private(set) var failure: String?

    static let figureWidth: CGFloat = 470
    static let graphHeight: CGFloat = 128
    static let graphRect = CGRect(x: 36, y: 8, width: 404, height: 98)

    func load(model: BrowserModel) async {
        guard let recording = model.recording else { failure = "レポートには読み込み済みの録画が必要です"; return }
        let label = model.eventEntries.first { $0.id == recording.id }?.trigger
        var device: String?
        if let index = model.index, let source = model.source { device = DeviceIdentity.read(from: source, control: index.control) }
        do { show(try LegacyReport.make(recording, eventLabel: label, deviceID: device)) } catch { failure = error.localizedDescription; return }
        guard let report, report.kind == .event, let source = model.source else { thumbnailsLoaded = true; return }
        let indices = report.thumbnailPacketIndices(), packets = recording.packets, settings = model.projection
        thumbnails = await Task.detached(priority: .userInitiated) { await Self.renderThumbnails(source: source, packets: packets, indices: indices, settings: settings) }.value
        thumbnailsLoaded = true
    }

    /// Replaces the report and redraws its figures (also used by the GUI self-check with a synthetic report).
    func show(_ built: LegacyReport, thumbnails images: [CGImage?] = []) {
        report = built
        thumbnails = images
        let size = CGSize(width: Self.figureWidth, height: Self.graphHeight), rect = Self.graphRect
        speedImage = LegacyReportDrawing.image(size: size) { _ in LegacyReportDrawing.speedGraph(built, in: rect, labelSize: 10) }
        accelerationImage = LegacyReportDrawing.image(size: size) { _ in LegacyReportDrawing.accelerationGraph(built, in: rect, labelSize: 10) }
        let mapHeight: CGFloat = built.kind == .event ? 170 : 200
        mapImage = LegacyReportDrawing.image(size: CGSize(width: Self.figureWidth, height: mapHeight)) { _ in
            let box = CGRect(x: 0.5, y: 0.5, width: Self.figureWidth - 1, height: mapHeight - 21)
            LegacyReportDrawing.map(in: box, route: built.route(aspect: Double(box.width / box.height)), labelSize: 11)
            LegacyReportDrawing.text(LegacyReportPage.routeNote, at: CGPoint(x: 0, y: mapHeight - 15), size: 9, color: LegacyReportDrawing.labelColor)
        }
    }

    nonisolated static func renderThumbnails(source: any ByteSource, packets: [FramePacket], indices: [Int], settings: ProjectionSettings) async -> [CGImage?] {
        let renderer = FrameRenderer(source: source, packets: packets)
        guard let projector = try? NativeProjection() else { return indices.map { _ in nil } }
        var images: [CGImage?] = []
        for index in indices {
            if Task.isCancelled { break }
            if let raw = try? await renderer.render(index), let image = try? projector.render(raw, settings: settings, width: 480) { images.append(image) } else { images.append(nil) }
        }
        return images
    }
}

/// レポート表示 of the original: values and reference images on the left, the graphs and the route on the right, and a bar
/// with 印刷, the CSV folder, 参照, CSV出力 and 閉じる.
struct RecordingReportView: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var content = LegacyReportContent()
    @State private var notes = ""
    @State private var folderPath = ReportFiles.defaultFolder.path
    @State private var showPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = content.report {
                HStack(alignment: .top, spacing: 20) {
                    leftColumn(report).frame(width: 420, alignment: .topLeading)
                    rightColumn
                }
            } else if let failure = content.failure {
                Text(failure).foregroundStyle(.red)
            } else {
                ProgressView("レポートを作成しています…")
            }
            Spacer(minLength: 0)
            Divider()
            bottomBar
        }
        .padding(20).frame(width: 960, height: 640)
        .task { notes = model.reportNotes(); await content.load(model: model) }
        .onDisappear { model.saveReportNotes(notes) }
        .sheet(isPresented: $showPreview) {
            if let report = content.report { LegacyReportPreview(model: model, report: report, thumbnails: content.thumbnails, notes: $notes) }
        }
    }

    private func leftColumn(_ report: LegacyReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(report.kind.title).font(.system(size: 20, weight: .bold))
            Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 10) {
                ForEach(Array(report.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) { ForEach(Array(row.lines.enumerated()), id: \.offset) { _, line in Text(line).monospacedDigit() } }
                    }
                }
            }.font(.system(size: 14))
            if report.kind == .event {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) { thumbnail(0); thumbnail(1) }
                    HStack(alignment: .top, spacing: 10) { thumbnail(2); thumbnail(3); thumbnail(4) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func thumbnail(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LegacyReport.eventThumbnailCaptions[i]).font(.caption)
            ZStack {
                Color.black
                if i < content.thumbnails.count, let image = content.thumbnails[i] { Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit() }
                else { Text(content.thumbnailsLoaded ? "画像なし" : "読み込み中…").font(.caption2).foregroundStyle(.gray) }
            }.frame(width: 128, height: 86).border(Color.gray.opacity(0.7))
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("速度 [km/h]").font(.caption).foregroundStyle(.secondary)
            figure(content.speedImage)
            Text("加速度 [G]　X 赤 / Y 緑 / Z 青").font(.caption).foregroundStyle(.secondary)
            figure(content.accelerationImage)
            Text("走行経路").font(.caption).foregroundStyle(.secondary)
            figure(content.mapImage)
        }
    }

    @ViewBuilder private func figure(_ image: NSImage?) -> some View {
        if let image { Image(nsImage: image).resizable().interpolation(.high).frame(width: image.size.width, height: image.size.height) }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button("印刷") { model.saveReportNotes(notes); showPreview = true }
            TextField("CSVの保存先フォルダー", text: $folderPath).textFieldStyle(.roundedBorder).frame(minWidth: 300)
            Button("参照") { chooseFolder() }
            Button("CSV出力") { exportCSV() }
            Menu("その他") {
                Button("技術詳細（JSON）を保存…") { model.exportReportJSON(notes: notes) }
            }.fixedSize()
            Spacer()
            Text(model.busy ? "書き出し中…" : "元データは読み取り専用").font(.caption).foregroundStyle(.secondary)
            Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
        }.disabled(content.report == nil)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "CSVの保存先フォルダー"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }

    /// Asks as the original does (はい/いいえ), writes the CSV pair and reports 完了しました.
    private func exportCSV() {
        guard let report = content.report else { return }
        let folder = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
        if let reason = ReportFiles.refusal(report, folder: folder, protecting: [model.sourceURL].compactMap { $0 }) { model.errorMessage = reason; return }
        let ask = NSAlert()
        ask.messageText = "CSV出力"
        ask.informativeText = folder.path + "/" + report.summaryFileName + "\n" + folder.path + "/" + report.dataFileName + " に保存します。よろしいですか？"
        ask.addButton(withTitle: "はい"); ask.addButton(withTitle: "いいえ")
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        do { try ReportFiles.writeCSV(report, to: folder, protecting: [model.sourceURL].compactMap { $0 }) }
        catch { model.errorMessage = error.localizedDescription; return }
        let done = NSAlert()
        done.messageText = "CSV出力"; done.informativeText = "完了しました"; done.addButton(withTitle: "OK")
        done.runModal()
    }
}

/// レポート印刷プレビュー: the printed page with 印刷, プリンタ設定, 備考記入 and 閉じる (PDF保存 is a Mac addition).
struct LegacyReportPreview: View {
    @ObservedObject var model: BrowserModel
    let report: LegacyReport
    let thumbnails: [CGImage?]
    @Binding var notes: String
    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var pdfData: Data?
    @State private var showNotes = false

    var body: some View {
        VStack(spacing: 12) {
            ReportPDFView(document: document).frame(width: 640, height: 770).border(Color.gray.opacity(0.6))
            HStack(spacing: 10) {
                Button("印刷") { printPage() }
                Button("プリンタ設定") { _ = NSPageLayout().runModal(with: NSPrintInfo.shared) }
                Button("備考記入") { showNotes = true }
                Button("PDF保存…") { if let pdfData { model.saveReportPDF(pdfData, name: report.fileStem) } }
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .task(id: notes) { rebuild() }
        .sheet(isPresented: $showNotes) { LegacyReportNotesSheet(notes: $notes) }
    }

    private func rebuild() {
        do {
            let data = try LegacyReportPage.pdf(report, thumbnails: thumbnails, notes: notes)
            pdfData = data; document = PDFDocument(data: data)
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func printPage() {
        guard let document, let operation = document.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true) else { model.errorMessage = "レポートを印刷できません"; return }
        operation.showsPrintPanel = true; operation.showsProgressPanel = true
        operation.run()
    }
}

/// 備考記入 (up to 16,384 characters, kept on this Mac).
struct LegacyReportNotesSheet: View {
    @Binding var notes: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("備考記入").font(.headline)
            TextEditor(text: $draft).font(.body).frame(width: 480, height: 200).border(Color.gray.opacity(0.6))
            Text("\(draft.count) / 16384文字。このMacに保存します（元SDは変更しません）。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction); Button("OK") { notes = String(draft.prefix(16384)); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).onAppear { draft = notes }
    }
}

struct ReportPDFView: NSViewRepresentable {
    let document: PDFDocument?
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true; view.displayMode = .singlePage; view.displaysPageBreaks = false
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}

struct RawSensorSearchPreferences: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        SettingsPane {
            Toggle("rawセンサー／イベント条件を使う", isOn: $model.rawQuery.enabled)
            SettingsGroup("絶対値が閾値以上（0 = 条件なし）") {
                Picker("加速度の軸", selection: $model.rawQuery.accelerationAxis) { ForEach(0..<3) { Text(["X", "Y", "Z"][$0]).tag($0) } }
                TextField("加速度 |raw| ≥", value: $model.rawQuery.minimumAbsoluteAcceleration, format: .number)
                Picker("ジャイロの軸", selection: $model.rawQuery.gyroAxis) { ForEach(0..<3) { Text(["X", "Y", "Z"][$0]).tag($0) } }
                TextField("ジャイロ |raw| ≥", value: $model.rawQuery.minimumAbsoluteGyro, format: .number)
            }
            SettingsGroup("rawバイトの一致（10進）") {
                Stepper("イベント: \(model.rawQuery.eventByte < 0 ? "指定なし" : String(model.rawQuery.eventByte))", value: $model.rawQuery.eventByte, in: -1...255)
                Picker("入力バイト", selection: $model.rawQuery.inputIndex) { Text("指定なし").tag(-1); ForEach(0..<6) { Text("raw[\($0)]").tag($0) } }
                Stepper("入力値: \(model.rawQuery.inputValue)", value: $model.rawQuery.inputValue, in: 0...255)
            }
            SettingsHelp("条件は同じフレーム内ですべて一致した録画を表示します。物理G・角速度・ウインカー／ブレーキ・トリガ名の意味は推測しません。閾値は0…32768に制限します。")
            SettingsHelp("未検索の録画は勝手に除外しません。条件変更後はサイドバーの「全録画の詳細検索」で確定してください。映像本体のデコードは行いません。")
            Button("条件を解除") { model.rawQuery = RawSensorQuery() }
        }
    }
}
