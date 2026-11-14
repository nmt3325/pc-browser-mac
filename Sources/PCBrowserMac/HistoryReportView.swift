import SwiftUI
import AppKit
import PDFKit
import PCBrowserCore

/// 履歴記録レポート of the original: the list of the selected rows (eleven columns and a 合計 line) above a blank graph area, and a
/// bar with 印刷, the CSV folder, 参照, CSV出力 and 閉じる. The area is blank in the original for this report too.
struct HistoryReportView: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var report: LegacyHistoryReport?
    @State private var failure: String?
    @State private var folderPath = ReportFiles.defaultFolder.path
    @State private var exporting = false
    @State private var showPreview = false

    /// Column widths of the list, in the order of `LegacyHistoryReport.columnTitles`.
    static let columnWidths: [CGFloat] = [84, 142, 62, 82, 94, 94, 40, 108, 70, 70, 40]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LegacyHistoryReport.title).font(.system(size: 20, weight: .bold))
            if let report {
                Text("\(report.rowCount)行 · \(report.dataLineCount)件の記録 · 元データは読み取り専用").font(.caption).foregroundStyle(.secondary)
                table(report)
                graphArea
            } else if let failure {
                Text(failure).foregroundStyle(.red)
                Spacer(minLength: 0)
            } else {
                ProgressView("レポートを作成しています…")
                Spacer(minLength: 0)
            }
            Divider()
            bottomBar
        }
        .padding(20).frame(width: 1040, height: 640)
        .task { await load() }
        .sheet(isPresented: $showPreview) {
            if let report { HistoryReportPreview(model: model, report: report) }
        }
    }

    private func load() async {
        if let override = model.historyReportOverride { report = override; return }
        guard let log = model.historyLog else { failure = "履歴記録が読み込まれていません"; return }
        let selection = model.selectedJournalRows
        let built = await Task.detached(priority: .userInitiated) { LegacyHistoryReport(log: log, rows: selection) }.value
        if let built { report = built } else { failure = "レポートにする行がありません" }
    }

    private func table(_ report: LegacyHistoryReport) -> some View {
        VStack(spacing: 0) {
            gridRow(LegacyHistoryReport.columnTitles, bold: true, header: true)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<report.rowCount, id: \.self) { i in
                        gridRow(report.cells(i), bold: false, header: false).background(i % 2 == 0 ? Color.clear : Color.gray.opacity(0.08))
                    }
                }
            }
            Divider()
            gridRow(report.totalCells, bold: true, header: false)
        }
        .frame(height: 300)
        .border(Color.gray.opacity(0.6))
    }

    private func gridRow(_ cells: [String], bold: Bool, header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<cells.count, id: \.self) { c in
                Text(cells[c])
                    .font(.system(size: header ? 11 : 12, weight: bold ? .bold : .regular).monospacedDigit())
                    .lineLimit(1)
                    .frame(width: Self.columnWidths[c], alignment: header || c < 2 ? .leading : .trailing)
                    .padding(.horizontal, 4)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 2)
    }

    /// The original leaves this panel empty for the history report.
    private var graphArea: some View {
        Rectangle().fill(Color(nsColor: .textBackgroundColor)).border(Color.gray.opacity(0.6)).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button("印刷") { showPreview = true }
            TextField("CSVの保存先フォルダー", text: $folderPath).textFieldStyle(.roundedBorder).frame(minWidth: 300)
            Button("参照") { chooseFolder() }
            Button("CSV出力") { exportCSV() }
            Spacer()
            Text(exporting ? "書き出し中…" : "元データは読み取り専用").font(.caption).foregroundStyle(.secondary)
            Button("閉じる") { model.historyReportOverride = nil; dismiss() }.keyboardShortcut(.cancelAction)
        }.disabled(report == nil || exporting)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "CSVの保存先フォルダー"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }

    /// Asks as the original does (はい/いいえ), writes the CSV pair and reports 完了しました.
    private func exportCSV() {
        guard let report, !exporting else { return }
        let folder = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
        let protected = [model.sourceURL].compactMap { $0 }
        if let reason = ReportFiles.refusal(history: report, folder: folder, protecting: protected) { model.errorMessage = reason; return }
        let ask = NSAlert()
        ask.messageText = "CSV出力"
        ask.informativeText = folder.path + "/" + report.summaryFileName + "\n" + folder.path + "/" + report.dataFileName + " に保存します。よろしいですか？"
        ask.addButton(withTitle: "はい"); ask.addButton(withTitle: "いいえ")
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        exporting = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { _ = try ReportFiles.writeCSV(history: report, to: folder, protecting: protected) }.value
                exporting = false
                let done = NSAlert()
                done.messageText = "CSV出力"; done.informativeText = "完了しました"; done.addButton(withTitle: "OK")
                done.runModal()
            } catch {
                exporting = false
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

/// Print preview of the history report: the list on landscape A4 pages (印刷, プリンタ設定, PDF保存 — the last is a Mac addition).
struct HistoryReportPreview: View {
    @ObservedObject var model: BrowserModel
    let report: LegacyHistoryReport
    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var pdfData: Data?

    var body: some View {
        VStack(spacing: 12) {
            ReportPDFView(document: document).frame(width: 860, height: 600).border(Color.gray.opacity(0.6))
            HStack(spacing: 10) {
                Button("印刷") { printPages() }
                Button("プリンタ設定") { _ = NSPageLayout().runModal(with: NSPrintInfo.shared) }
                Button("PDF保存…") { if let pdfData { model.saveReportPDF(pdfData, name: report.fileStem) } }
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .task {
            do { let data = try HistoryReportPage.pdf(report); pdfData = data; document = PDFDocument(data: data) }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func printPages() {
        guard let document, let operation = document.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true) else { model.errorMessage = "レポートを印刷できません"; return }
        operation.showsPrintPanel = true; operation.showsProgressPanel = true
        operation.run()
    }
}

/// The printed form of the history report: landscape A4 pages with the title, the list header, the rows and, behind the last row, the 合計 line.
enum HistoryReportPage {
    static let size = CGSize(width: 842, height: 595)
    static let margin: CGFloat = 40
    static let rowHeight: CGFloat = 15
    static let firstRowY: CGFloat = 84
    static let widths: [CGFloat] = [70, 120, 56, 70, 80, 80, 36, 94, 60, 60, 36]
    static var rowsPerPage: Int { Int((size.height - margin - firstRowY) / rowHeight) - 1 }

    static func pageCount(_ report: LegacyHistoryReport) -> Int { max(1, (report.rowCount + rowsPerPage - 1) / rowsPerPage) }

    /// Draws page `page` (0-based) into the current flipped graphics context of `size`.
    static func draw(_ report: LegacyHistoryReport, page: Int) {
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        LegacyReportDrawing.text(LegacyHistoryReport.title, at: CGPoint(x: margin, y: 28), size: 15, bold: true)
        LegacyReportDrawing.text("\(report.rowCount)行 · \(page + 1) / \(pageCount(report))", at: CGPoint(x: size.width - margin, y: 32), size: 9, color: LegacyReportDrawing.labelColor, alignment: .right)
        func line(_ cells: [String], y: CGFloat, bold: Bool) {
            var x = margin
            for (c, cell) in cells.enumerated() {
                let right = c >= 2 && !(bold && cells.first == "日付")
                LegacyReportDrawing.text(cell, at: CGPoint(x: right ? x + widths[c] - 4 : x + 2, y: y), size: 8.5, bold: bold, alignment: right ? .right : .left)
                x += widths[c]
            }
        }
        line(LegacyHistoryReport.columnTitles, y: firstRowY - 20, bold: true)
        let rule = NSBezierPath()
        rule.lineWidth = 0.6
        rule.move(to: CGPoint(x: margin, y: firstRowY - 5))
        rule.line(to: CGPoint(x: size.width - margin, y: firstRowY - 5))
        NSColor.black.setStroke()
        rule.stroke()
        let first = page * rowsPerPage
        var y = firstRowY
        for i in first..<min(report.rowCount, first + rowsPerPage) {
            line(report.cells(i), y: y, bold: false)
            y += rowHeight
        }
        if first + rowsPerPage >= report.rowCount {
            rule.removeAllPoints()
            rule.move(to: CGPoint(x: margin, y: y))
            rule.line(to: CGPoint(x: size.width - margin, y: y))
            rule.stroke()
            line(report.totalCells, y: y + 3, bold: true)
        }
    }

    /// All pages as one vector PDF.
    static func pdf(_ report: LegacyHistoryReport) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw BrowserError.io("レポートPDFのメモリーを確保できません") }
        var box = CGRect(origin: .zero, size: size)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw BrowserError.io("レポートPDFを作成できません") }
        for page in 0..<pageCount(report) {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            draw(report, page: page)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// One page as a bitmap (GUI self-check evidence).
    static func image(_ report: LegacyHistoryReport, page: Int, scale: CGFloat = 1.5) -> NSImage? {
        LegacyReportDrawing.image(size: size, scale: scale) { _ in draw(report, page: page) }
    }

    // MARK: Synthetic content (GUI self-check and visual evidence; contains no card data)

    /// A made-up journal: three drives written into a 900-slot ring that wraps, one with a shock, one without any fix.
    static func syntheticReport() -> LegacyHistoryReport? { syntheticLog().flatMap { LegacyHistoryReport(log: $0) } }

    /// The journal behind `syntheticReport()`.
    static func syntheticLog() -> HistoryLog? {
        func clock(_ t: Int64) -> [UInt8] {
            let c = CivilTime.components(t)
            return [UInt8(c.year - 2000), UInt8(c.month), UInt8(c.day), UInt8(c.hour), UInt8(c.minute), UInt8(c.second)]
        }
        let base = CivilTime.seconds(year: 2026, month: 11, day: 11, hour: 9, minute: 0, second: 0)
        var slots = [Data](repeating: Data(count: 256), count: 900)
        func put(_ slot: Int, kind: UInt32, a: Int64, b: Int64, fix: UInt8, speed: UInt16, trigger: UInt8, lat: Int32, lon: Int32) {
            var d = Data(count: 256)
            func le(_ value: UInt32, _ o: Int) { for i in 0..<4 { d[o + i] = UInt8(truncatingIfNeeded: value >> UInt32(8 * i)) } }
            le(kind, 0)
            d.replaceSubrange(0x0E..<0x14, with: clock(a))
            d.replaceSubrange(0x1E..<0x24, with: clock(b))
            d[0x25] = fix
            le(UInt32(bitPattern: lat), 0x2E); le(UInt32(bitPattern: lon), 0x32)
            d[0x36] = UInt8(speed & 0xFF); d[0x37] = UInt8(speed >> 8)
            d[0xA6] = trigger
            d.replaceSubrange(0x9A..<0xA4, with: Data("SYNTH00000".utf8))
            slots[slot] = d
        }
        var slot = 700
        var clockB = base
        for (drive, seconds) in [120, 90, 45].enumerated() {
            for i in 0..<seconds {
                let t = clockB + Int64(i)
                let moving = drive != 1
                put(slot % 900, kind: 0xFFFFE202, a: t, b: t, fix: moving ? 3 : 0, speed: moving ? UInt16(400 + 150 * (i % 7)) : 0,
                    trigger: drive == 0 && i == 40 ? 1 : 0, lat: Int32(21_000_000 + i * 12), lon: Int32(83_400_000 + i * 20))
                slot += 1
            }
            slot += 4
            clockB += Int64(seconds + 600)
        }
        var image = Data()
        for s in slots { image.append(s) }
        return try? HistoryLog.read(source: MemorySource(image), area: 0..<450)
    }
}
