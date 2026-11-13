import AppKit
import CoreText
import PDFKit
import PCBrowserCore

enum ReportExport {
    static func referenceFrames(recording: Recording, currentFrame: Int) -> [Int] {
        guard !recording.packets.isEmpty else { return [] }
        let timeline = RecordingTimeline(packets: recording.packets), focus = min(recording.packets.count - 1, max(0, currentFrame)), time = timeline.starts[focus]
        return Array(Set([0, timeline.frame(at: max(0, time - 2)), focus, timeline.frame(at: time + 2), recording.packets.count - 1])).sorted()
    }
    static func pdf(report: RecordingReport, source: any ByteSource, recording: Recording, currentFrame: Int, projection: ProjectionSettings, to output: URL,
                    cancelled: @escaping @Sendable () -> Bool = { false }, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try MediaExport.checkNew(output)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PCBrowser-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: folder) }
        let contacts = folder.appendingPathComponent("frames.pdf"), indices = referenceFrames(recording: recording, currentFrame: currentFrame)
        _ = try await FrameExport.printPDF(source: source, recording: recording, indices: indices, framesPerPage: 4, settings: projection, to: contacts, cancelled: cancelled, progress: { progress($0 * 0.8) })
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw BrowserError.io("レポートPDFのメモリーを確保できません") }
        var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw BrowserError.io("レポートPDFを作成できません") }
        func n(_ value: Double?, suffix: String = "") -> String { value.map { String(format: "%.3f", $0) + suffix } ?? "—" }
        // Never request the ambiguous family name "Hiragino Sans": it can
        // resolve to an ultra-light face, making printed Japanese nearly gray.
        let bodyFont = NSFont(name: "HiraginoSans-W3", size: 11) ?? NSFont.systemFont(ofSize: 11, weight: .regular)
        let ink = NSColor(srgbRed: 0.17, green: 0.17, blue: 0.17, alpha: 1)
        let text = NSMutableAttributedString(string: "")
        func append(_ string: String, font: NSFont? = nil, space: CGFloat = 4) {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineHeightMultiple = 1.35; paragraph.paragraphSpacing = space
            text.append(NSAttributedString(string: string + "\n", attributes: [.font: font ?? bodyFont, .foregroundColor: ink, .paragraphStyle: paragraph]))
        }
        func heading(_ string: String) { append(string, font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), space: 8) }
        append("PC Browser Mac — 録画レポート", font: NSFont.systemFont(ofSize: 18, weight: .semibold), space: 20)
        append(report.startWallTime + " — " + report.endWallTime)
        append("CH \(report.channel) / \(report.frames)フレーム / \(report.storageBlocks)保存ブロック", space: 16)
        heading("録画の概要")
        for line in ["録画内の時間: " + n(report.durationSeconds, suffix: " 秒"),
                     "平均速度（有効区間）: " + n(report.meanSpeedKMH, suffix: " km/h"),
                     "最高速度: " + n(report.maximumSpeedKMH, suffix: " km/h"),
                     "速度からの推定距離: " + n(report.distanceEstimateKM, suffix: " km"),
                     "GPS / 速度の有効時間: " + n(report.speedCoverageSeconds, suffix: " 秒")] { append(line) }
        append("", space: 4); heading("集計の範囲と制約")
        append("有効GPS / 速度を持つ区間の台形積分。2秒超の欠測は除外します。")
        append("距離は計算値です。原版と同じ集計規則・機種別イベント判定ではありません。")
        append("カード時刻にUTCは推測付加しません。センサー・入力・イベントの意味は未確定です。", space: 16)
        heading("センサー範囲（raw counts）")
        append("加速度 raw XYZ: " + report.accelerationRaw.map { "\($0.minimum)…\($0.maximum)" }.joined(separator: " / "))
        append("ジャイロ raw XYZ: " + report.gyroRaw.map { "\($0.minimum)…\($0.maximum)" }.joined(separator: " / "))
        append("イベント raw: " + report.eventRawDistribution.map { String(format: "%02X:%d枚", $0.value, $0.frames) }.joined(separator: " / "), space: 16)
        heading("添付画像")
        append("指定した参照位置・前後2秒・開始／終了（重複は除外）を末尾に添付します。")
        append("自動イベント検出ではありません。元カードは変更していません。", space: 16)
        heading("備考（このMacで入力）")
        append(report.notes)
        let setter = CTFramesetterCreateWithAttributedString(text), path = CGPath(rect: CGRect(x: 40, y: 54, width: 515, height: 744), transform: nil)
        var offset = 0
        while offset < text.length {
            if cancelled() { context.closePDF(); throw BrowserError.io("レポートをキャンセルしました") }
            context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(media); context.textMatrix = .identity
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil), visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { context.endPDFPage(); context.closePDF(); throw BrowserError.io("レポートのページ送りが停止しました") }
            CTFrameDraw(frame, context); context.endPDFPage(); offset += visible.length
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data), let frames = PDFDocument(url: contacts) else { throw BrowserError.io("レポートPDFを結合できません") }
        for i in 0..<frames.pageCount { if let page = frames.page(at: i) { document.insert(page, at: document.pageCount) } }
        // Keep portrait text and landscape contact sheets at their own sizes,
        // but number the entire report, not a second 1/N image sub-document.
        let result = try numbered(document, cancelled: cancelled)
        if cancelled() { throw BrowserError.io("レポートをキャンセルしました") }
        try result.write(to: output, options: .withoutOverwriting); progress(1)
    }
    private static func numbered(_ document: PDFDocument, cancelled: () -> Bool) throws -> Data {
        let data = NSMutableData()
        guard document.pageCount > 0, let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw BrowserError.io("レポートPDFを確定できません") }
        var closed = false
        defer { if !closed { context.closePDF() } }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor(srgbRed: 0.3, green: 0.3, blue: 0.3, alpha: 1)]
        for i in 0..<document.pageCount {
            if cancelled() || Task.isCancelled { throw BrowserError.io("レポートをキャンセルしました") }
            guard let page = document.page(at: i) else { throw BrowserError.io("レポートのページがありません") }
            var box = page.bounds(for: .mediaBox)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            context.textMatrix = .identity
            page.draw(with: .mediaBox, to: context)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: box.minX, y: box.minY, width: box.width, height: 36))
            func footer(_ string: String, right: Bool) {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                context.textPosition = CGPoint(x: right ? box.maxX - 32 - width : box.minX + 32, y: box.minY + 18)
                CTLineDraw(line, context)
            }
            footer("PC Browser Mac · 録画レポート", right: false)
            footer("\(i + 1) / \(document.pageCount)", right: true)
            context.endPDFPage()
        }
        // Flush the consumer before copying the backing data.
        context.closePDF(); closed = true
        return data as Data
    }

}

extension BrowserModel {
    func reportNotes() -> String {
        guard let recording else { return "" }
        return UserDefaults.standard.string(forKey: "pcbrowser.notes." + (sourceURL?.path ?? sourceName) + "." + recording.id) ?? ""
    }
    func saveReportNotes(_ notes: String) {
        guard let recording else { return }
        UserDefaults.standard.set(String(notes.prefix(16384)), forKey: "pcbrowser.notes." + (sourceURL?.path ?? sourceName) + "." + recording.id)
    }
    func exportReport(_ kind: String, notes: String) {
        guard let recording, let source, let output = destination("PCBrowser-report", extension: kind) else { return }
        saveReportNotes(notes)
        let projection = projection, currentFrame = frameIndex
        performExport("録画レポート " + kind.uppercased()) { flag, progress in
            let report = try RecordingReport.make(recording, notes: notes)
            if kind == "pdf" { try await ReportExport.pdf(report: report, source: source, recording: recording, currentFrame: currentFrame, projection: projection, to: output, cancelled: { flag.cancelled }, progress: progress) }
            else {
                let data: Data
                if kind == "csv" { data = Data(RecordingReport.csv([report]).utf8) }
                else { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; data = try encoder.encode(report) }
                if flag.cancelled { throw BrowserError.io("キャンセルしました") }; try data.write(to: output, options: .withoutOverwriting); progress(1)
            }
        }
    }
    func printReport(notes: String) {
        guard let recording, let source else { return }; saveReportNotes(notes)
        let projection = projection, currentFrame = frameIndex, output = FileManager.default.temporaryDirectory.appendingPathComponent("PCBrowser-report-\(UUID().uuidString).pdf")
        performExport("録画レポートの印刷準備") { flag, progress in
            defer { try? FileManager.default.removeItem(at: output) }
            let report = try RecordingReport.make(recording, notes: notes)
            try await ReportExport.pdf(report: report, source: source, recording: recording, currentFrame: currentFrame, projection: projection, to: output, cancelled: { flag.cancelled }, progress: progress)
            try await MainActor.run {
                guard let doc = PDFDocument(url: output), let operation = doc.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true) else { throw BrowserError.io("レポートを印刷できません") }
                operation.showsPrintPanel = true; operation.showsProgressPanel = true; operation.run()
            }
        }
    }
    func copyInputImage() {
        guard let source else { return }
        guard !source.isPartialCopy, source.scanRanges == nil else { errorMessage = "部分バックアップは完全なSDイメージには複製できません"; return }
        guard let output = destination("PCBrowser-image-copy", extension: "img") else { return }
        let alert = NSAlert(); alert.messageText = "入力の全バイトを新しいIMGへ複製"; alert.informativeText = "\(ByteCountFormatter.string(fromByteCount: Int64(source.byteCount), countStyle: .file))以上の空き容量が必要です。複製後はSHA-256で読み戻し検証します。入力自体の完全性を保証する機能ではありません。元カード・既存ファイル・物理デバイスへの復元は行いません。"; alert.addButton(withTitle: "新しいIMGへ複製"); alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performExport("イメージ複製・読み戻し検証") { flag, progress in _ = try ImageCopy.write(source: source, to: output, cancelled: { flag.cancelled }, progress: progress) }
    }
}
