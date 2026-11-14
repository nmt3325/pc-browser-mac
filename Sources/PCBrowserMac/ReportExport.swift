import AppKit
import PDFKit
import PCBrowserCore

/// Files written for a report: the original's 集計 and データ CSV pair (Windows code page 932) and, as a Mac addition,
/// the printed page as PDF. Existing files are never overwritten and the original card is never an output location.
enum ReportFiles {
    /// The original's default folder, `Documents\Yupiteru\PC Browser`, under the Mac home folder.
    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Yupiteru/PC Browser", isDirectory: true)
    }

    static func targets(_ report: LegacyReport, in folder: URL) -> [URL] {
        [report.summaryFileName, report.dataFileName].map { folder.appendingPathComponent($0) }
    }

    /// Removable media (SD cards in a reader) are never a destination: the card being read is the one to protect.
    static func isRemovableVolume(_ url: URL) -> Bool {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeIsRemovableKey]))?.volumeIsRemovable == true
    }

    /// Why the pair cannot be written into `folder` (shown to the user), or nil.
    static func refusal(_ report: LegacyReport, folder: URL, protecting sources: [URL]) -> String? {
        refusal(names: [report.summaryFileName, report.dataFileName], folder: folder, protecting: sources)
    }
    /// The same check for the 履歴記録レポート pair.
    static func refusal(history report: LegacyHistoryReport, folder: URL, protecting sources: [URL]) -> String? {
        refusal(names: [report.summaryFileName, report.dataFileName], folder: folder, protecting: sources)
    }
    static func refusal(names: [String], folder: URL, protecting sources: [URL]) -> String? {
        if case .refused(let reason) = WriteGuard.checkOutputFolder(folder, protecting: sources) { return reason }
        if isRemovableVolume(folder) { return "取り外し可能なメディア（SDカードなど）へは書き出しません。Macの内蔵ディスク上のフォルダーを選んでください" }
        for name in names where (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)) != nil {
            return "同名のファイルが既にあります: " + name + "（上書きしません。別のフォルダーを選んでください）"
        }
        return nil
    }

    /// Writes the pair (summary first, then the data rows). Nothing is left behind when the second file fails.
    @discardableResult
    static func writeCSV(_ report: LegacyReport, to folder: URL, protecting sources: [URL]) throws -> [URL] {
        if let reason = refusal(report, folder: folder, protecting: sources) { throw BrowserError.invalid(reason) }
        let summary = try LegacyReport.encodeCP932(report.summaryCSV())
        let data = try LegacyReport.encodeCP932(report.dataCSV())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = targets(report, in: folder)
        try summary.write(to: urls[0], options: .withoutOverwriting)
        do { try data.write(to: urls[1], options: .withoutOverwriting) }
        catch { try? FileManager.default.removeItem(at: urls[0]); throw error }
        return urls
    }
}

extension ReportFiles {
    static func targets(_ report: LegacyHistoryReport, in folder: URL) -> [URL] {
        [report.summaryFileName, report.dataFileName].map { folder.appendingPathComponent($0) }
    }
    /// Writes the 履歴記録レポート pair (summary first, then the data lines). Nothing is left behind when the second file fails.
    @discardableResult
    static func writeCSV(history report: LegacyHistoryReport, to folder: URL, protecting sources: [URL], cancelled: () -> Bool = { false }) throws -> [URL] {
        if let reason = refusal(history: report, folder: folder, protecting: sources) { throw BrowserError.invalid(reason) }
        let summary = try report.summaryCSVData()
        let data = try report.dataCSV(cancelled: cancelled)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = targets(report, in: folder)
        try summary.write(to: urls[0], options: .withoutOverwriting)
        do { try data.write(to: urls[1], options: .withoutOverwriting) }
        catch { try? FileManager.default.removeItem(at: urls[0]); throw error }
        return urls
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
    /// The technical summary of the Mac viewer (raw sensor ranges, speed-based distance estimate) as JSON.
    func exportReportJSON(notes: String) {
        guard let recording, let output = destination("PCBrowser-report", extension: "json") else { return }
        saveReportNotes(notes)
        performExport("録画レポート JSON") { flag, progress in
            let report = try RecordingReport.make(recording, notes: notes)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            if flag.cancelled { throw BrowserError.io("キャンセルしました") }
            try data.write(to: output, options: .withoutOverwriting); progress(1)
        }
    }
    /// Saves the printed report page as PDF into a new file.
    func saveReportPDF(_ data: Data, name: String) {
        guard let output = destination(name, extension: "pdf") else { return }
        do { try data.write(to: output, options: .withoutOverwriting); status = "レポートPDFを書き出しました" }
        catch { errorMessage = error.localizedDescription }
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
