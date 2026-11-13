import AppKit
import CoreText
import PCBrowserCore

struct FrameExportSummary: Codable, Sendable {
    let frames: Int, pages: Int, sourceIndices: [Int]
}
enum FrameExport {
    static func validate(_ indices: [Int], recording: Recording) throws {
        guard !indices.isEmpty, indices.allSatisfy({ recording.packets.indices.contains($0) }),
              zip(indices, indices.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else { throw BrowserError.invalid("静止画の抽出範囲が不正です") }
    }
    static func sequence(source: any ByteSource, recording: Recording, indices: [Int], settings: ProjectionSettings, to output: URL,
                         cancelled: @escaping @Sendable () -> Bool = { false }, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> FrameExportSummary {
        try validate(indices, recording: recording); try MediaExport.checkNew(output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let marker = output.appendingPathComponent("INCOMPLETE.txt")
        try Data("This sequence is incomplete until manifest.json is present.\n".utf8).write(to: marker, options: .withoutOverwriting)
        let renderer = FrameRenderer(source: source, packets: recording.packets), projector = try NativeProjection()
        for (number, index) in indices.enumerated() {
            if cancelled() || Task.isCancelled { throw BrowserError.io("静止画出力を中断しました。出力済み画像とINCOMPLETE.txtは保存先に残っています") }
            let raw = try await renderer.render(index)
            try autoreleasepool {
                let image = try projector.render(raw, settings: settings, width: 2560)
                try MediaExport.still(image, to: output.appendingPathComponent(String(format: "frame-%08d.png", index)))
            }
            progress(Double(number + 1) / Double(indices.count))
        }
        if cancelled() || Task.isCancelled { throw BrowserError.io("静止画出力を中断しました") }
        let result = FrameExportSummary(frames: indices.count, pages: 0, sourceIndices: indices)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: output.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        try FileManager.default.removeItem(at: marker); return result
    }
    static func printPDF(source: any ByteSource, recording: Recording, indices: [Int], framesPerPage: Int,
                         settings: ProjectionSettings, to output: URL, cancelled: @escaping @Sendable () -> Bool = { false },
                         progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> FrameExportSummary {
        try validate(indices, recording: recording); try MediaExport.checkNew(output)
        guard framesPerPage == 1 || framesPerPage == 4 else { throw BrowserError.invalid("印刷は1ページ1枚または4枚です") }
        let staging = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial.pdf")
        var box = CGRect(x: 0, y: 0, width: 792, height: 612)
        guard let context = CGContext(staging as CFURL, mediaBox: &box, nil) else { throw BrowserError.io("印刷用PDFを作成できません") }
        var closed = false, committed = false
        defer { if !closed { context.closePDF() }; if !committed { try? FileManager.default.removeItem(at: staging) } }
        let pages = (indices.count + framesPerPage - 1) / framesPerPage
        let renderer = FrameRenderer(source: source, packets: recording.packets), projector = try NativeProjection()
        func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat = 10) {
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes)), context)
        }
        for (number, index) in indices.enumerated() {
            if cancelled() || Task.isCancelled { throw BrowserError.io("印刷用PDFの作成を中断しました") }
            let cell = number % framesPerPage
            if cell == 0 {
                context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
                text("PC Browser Mac | \(recording.startTime) | CH \(recording.channel)", x: 24, y: 583, size: 12)
                text("\(number / framesPerPage + 1) / \(pages)", x: 720, y: 18)
            }
            let raw = try await renderer.render(index)
            try autoreleasepool {
                let projected = try projector.render(raw, settings: settings, width: framesPerPage == 1 ? 1920 : 1280)
                // Keep each PDF page bounded and embed compressed JPEG rather than
                // retaining all decoded images in an NSView for the print job.
                guard let jpeg = NSBitmapImageRep(cgImage: projected).representation(using: .jpeg, properties: [.compressionFactor: 0.9]),
                      let provider = CGDataProvider(data: jpeg as CFData),
                      let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw BrowserError.io("印刷画像を作成できません") }
                let region: CGRect
                if framesPerPage == 1 { region = CGRect(x: 24, y: 62, width: 744, height: 490) }
                else { region = CGRect(x: 24 + CGFloat(cell % 2) * 378, y: cell < 2 ? 327 : 71, width: 366, height: 220) }
                let scale = min(region.width / CGFloat(image.width), region.height / CGFloat(image.height))
                let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
                context.draw(image, in: CGRect(x: region.midX - width / 2, y: region.midY - height / 2, width: width, height: height))
                text("\(recording.packets[index].cardTime)  |  frame \(index + 1)", x: region.minX, y: region.minY - 18)
            }
            if cell == framesPerPage - 1 || number == indices.count - 1 { context.endPDFPage() }
            progress(Double(number + 1) / Double(indices.count))
        }
        context.closePDF(); closed = true
        if cancelled() || Task.isCancelled { throw BrowserError.io("印刷用PDFの作成を中断しました") }
        try FileManager.default.moveItem(at: staging, to: output); committed = true
        return .init(frames: indices.count, pages: pages, sourceIndices: indices)
    }
}
