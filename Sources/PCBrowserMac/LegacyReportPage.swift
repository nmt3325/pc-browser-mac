import AppKit
import PDFKit
import PCBrowserCore

/// The printed page of the original's report (レポート印刷プレビュー): a bordered A4 portrait page with the title, the
/// label/value rows, the speed and acceleration graphs, the route box, for event reports the five reference images, and
/// the 備考 box. Positions follow the print preview of the original scaled to A4 points.
enum LegacyReportPage {
    static let size = CGSize(width: 595, height: 842)
    static let thumbnailSize = CGSize(width: 153, height: 104)
    static let thumbnailOrigins = [CGPoint(x: 44, y: 442), CGPoint(x: 224, y: 442), CGPoint(x: 44, y: 585), CGPoint(x: 224, y: 585), CGPoint(x: 403, y: 585)]
    static let notesBox = CGRect(x: 34, y: 710, width: 523, height: 104)
    static let routeNote = "※走行経路のみを描画しています（地図タイルは使用していません）"

    static func speedRect(_ kind: LegacyReportKind) -> CGRect { CGRect(x: 88, y: kind == .event ? 177 : 229, width: 413, height: 96) }
    static func accelerationRect(_ kind: LegacyReportKind) -> CGRect { CGRect(x: 88, y: kind == .event ? 307 : 361, width: 413, height: 96) }
    static func mapRect(_ kind: LegacyReportKind) -> CGRect { kind == .event ? CGRect(x: 354, y: 60, width: 156, height: 104) : CGRect(x: 88, y: 489, width: 413, height: 208) }

    /// Draws the page into the current graphics context, which must be flipped and span `size`.
    /// `thumbnails` are the five reference images of an event report (missing ones are drawn as empty boxes).
    static func draw(_ report: LegacyReport, thumbnails: [CGImage?], notes: String) {
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        let border = NSBezierPath(rect: CGRect(x: 20, y: 20, width: size.width - 40, height: size.height - 40))
        border.lineWidth = 1
        NSColor.black.setStroke()
        border.stroke()

        LegacyReportDrawing.text(report.kind.title, at: CGPoint(x: 44, y: 34), size: 17, bold: true)
        var y: CGFloat = 70
        for row in report.rows {
            LegacyReportDrawing.text(row.label, at: CGPoint(x: 73, y: y), size: 12)
            for (i, line) in row.lines.enumerated() {
                LegacyReportDrawing.text(line, at: CGPoint(x: 195, y: y + 20 * CGFloat(i)), size: 12)
            }
            y += 20 * CGFloat(max(1, row.lines.count)) + 8
        }

        LegacyReportDrawing.speedGraph(report, in: speedRect(report.kind), labelSize: 9)
        LegacyReportDrawing.accelerationGraph(report, in: accelerationRect(report.kind), labelSize: 9)

        let map = mapRect(report.kind)
        LegacyReportDrawing.map(in: map, route: report.route(aspect: Double(map.width / map.height)), labelSize: 9)
        if report.kind == .continuous {
            LegacyReportDrawing.text(routeNote, at: CGPoint(x: map.minX, y: map.maxY + 4), size: 8, color: LegacyReportDrawing.labelColor)
        } else {
            for (i, caption) in LegacyReport.eventThumbnailCaptions.enumerated() {
                let image = i < thumbnails.count ? thumbnails[i] : nil
                LegacyReportDrawing.thumbnail(image, caption: caption, in: CGRect(origin: thumbnailOrigins[i], size: thumbnailSize), captionSize: 10)
            }
        }

        let box = NSBezierPath(rect: notesBox)
        box.lineWidth = 0.8
        NSColor.black.setStroke()
        box.stroke()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: notesBox).addClip()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSMutableAttributedString(string: "備考：", attributes: [.font: LegacyReportDrawing.font(11, bold: true), .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
        text.append(NSAttributedString(string: notes, attributes: [.font: LegacyReportDrawing.font(10), .foregroundColor: NSColor.black, .paragraphStyle: paragraph]))
        text.draw(in: notesBox.insetBy(dx: 8, dy: 6))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The page as a one-page PDF (vector).
    static func pdf(_ report: LegacyReport, thumbnails: [CGImage?], notes: String) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw BrowserError.io("レポートPDFのメモリーを確保できません") }
        var box = CGRect(origin: .zero, size: size)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw BrowserError.io("レポートPDFを作成できません") }
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(report, thumbnails: thumbnails, notes: notes)
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// The page as a bitmap (for GUI self-check evidence).
    static func image(_ report: LegacyReport, thumbnails: [CGImage?], notes: String, scale: CGFloat = 1.5) -> NSImage? {
        LegacyReportDrawing.image(size: size, scale: scale) { _ in draw(report, thumbnails: thumbnails, notes: notes) }
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let representation = NSBitmapImageRep(data: tiff) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }

    // MARK: Synthetic content (GUI self-check and visual evidence; contains no card data)

    /// A made-up drive: a 40 second loop with speed up to 60 km/h, a shock at 20 s (event) and a few sideways accelerations.
    static func syntheticReport(kind: LegacyReportKind) -> LegacyReport {
        func stamp(_ second: Int) -> CardTimestamp? {
            CardTimestamp.parse(Data([26, 11, 11, 10, UInt8(second / 60), UInt8(second % 60), 0]), offset: 0)
        }
        let count = 40
        var frames: [LegacyReportFrame] = []
        for i in 0..<count {
            let t = Double(i) / Double(count - 1)
            let speed = Int(30 + 30 * sin(t * 2 * .pi))
            let x = Int16(300 * sin(t * 6 * .pi)), y = Int16(500 * cos(t * 4 * .pi)), z = Int16(1000 + 150 * sin(t * 10 * .pi))
            let lat = Int32(21_000_000 + 4_000 * sin(t * 2 * .pi)), lon = Int32(83_400_000 + 6_000 * (1 - cos(t * 2 * .pi)))
            let shock = kind == .event && i == 20
            let trigger = EventTrigger.Sample(flags: shock ? 1 : 0, mask: shock ? 1 : 0)
            frames.append(LegacyReportFrame(phase: kind == .event ? (i < 20 ? EventBlockType.trigger : EventBlockType.post) : 0, clock: stamp(i),
                                            speed: speed, acceleration: [x, y, shock ? 2400 : z], gps: .fix3D,
                                            latitudeRaw: lat, longitudeRaw: lon, altitudeRaw: 0, trigger: trigger))
        }
        return LegacyReport(kind: kind, frames: frames, packetIndices: Array(0..<count), deviceID: "SYNTH-0000",
                            eventLabel: kind == .event ? "衝撃" : "", eventFrame: kind == .event ? 20 : nil)
    }

    /// Gradient test pictures standing in for video frames.
    static func syntheticThumbnails() -> [CGImage?] {
        (0..<5).map { i -> CGImage? in
            let w = 160, h = 90
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let shade = CGFloat(i + 1) / 6
            context.setFillColor(CGColor(red: shade, green: 0.4, blue: 1 - shade, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.setFillColor(CGColor(gray: 1, alpha: 0.8))
            context.fill(CGRect(x: 20 + i * 18, y: 30, width: 30, height: 30))
            return context.makeImage()
        }
    }
}
