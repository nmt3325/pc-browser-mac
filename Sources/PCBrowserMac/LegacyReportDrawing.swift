import AppKit
import PCBrowserCore

/// Drawing of the original report's figures (speed and acceleration graphs, route box, reference images) into the current
/// graphics context, which must be flipped (y points down). The dialog and the printed page use the same routines.
enum LegacyReportDrawing {
    static let graphBackground = NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1)
    /// The acceleration lines of the original: X red, Y green, Z blue; speed is white.
    static let axisColors = [NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), NSColor(srgbRed: 0, green: 0.67, blue: 0, alpha: 1), NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)]
    static let labelColor = NSColor(white: 0.25, alpha: 1)

    struct Line {
        var points: [ReportPoint]
        var color: NSColor
    }

    static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "HiraginoSans-W6" : "HiraginoSans-W3", size: size) ?? NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    /// Draws one line of text whose top-left (or top-centre / top-right) is `point`; returns the text width.
    @discardableResult
    static func text(_ string: String, at point: CGPoint, size: CGFloat, bold: Bool = false, color: NSColor = .black, alignment: NSTextAlignment = .left) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font(size, bold: bold), .foregroundColor: color]
        let width = (string as NSString).size(withAttributes: attributes).width
        var origin = point
        if alignment == .center { origin.x -= width / 2 } else if alignment == .right { origin.x -= width }
        (string as NSString).draw(at: origin, withAttributes: attributes)
        return width
    }

    /// A graph with the original's dark grey ground, dashed grid (quarters of the time and one line per label), the lines,
    /// the dashed event marker with its clock, axis labels on the left and three clock labels underneath.
    static func graph(in rect: CGRect, lines: [Line], yLabels: [String], xLabels: [String], marker: (position: Double, label: String)?, labelSize: CGFloat) {
        graphBackground.setFill()
        rect.fill()
        let dash: [CGFloat] = [2, 2]
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        grid.setLineDash(dash, count: 2, phase: 0)
        for k in 1...3 {
            let x = rect.minX + rect.width * CGFloat(k) / 4
            grid.move(to: CGPoint(x: x, y: rect.minY))
            grid.line(to: CGPoint(x: x, y: rect.maxY))
        }
        let steps = max(1, yLabels.count - 1)
        for i in 0...steps {
            let y = rect.minY + rect.height * CGFloat(i) / CGFloat(steps)
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.line(to: CGPoint(x: rect.maxX, y: y))
        }
        NSColor(white: 0.2, alpha: 1).setStroke()
        grid.stroke()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let columns = max(1, Int(rect.width))
        for line in lines {
            let reduced = ReportGraph.decimate(line.points, columns: columns)
            guard let first = reduced.first else { continue }
            let path = NSBezierPath()
            path.lineWidth = 0.8
            path.lineJoinStyle = .round
            path.move(to: CGPoint(x: rect.minX + rect.width * CGFloat(first.x), y: rect.minY + rect.height * CGFloat(first.y)))
            for p in reduced.dropFirst() {
                path.line(to: CGPoint(x: rect.minX + rect.width * CGFloat(p.x), y: rect.minY + rect.height * CGFloat(p.y)))
            }
            line.color.setStroke()
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        if let marker {
            let x = rect.minX + rect.width * CGFloat(marker.position)
            let line = NSBezierPath()
            line.lineWidth = 0.9
            line.setLineDash(dash, count: 2, phase: 0)
            line.move(to: CGPoint(x: x, y: rect.minY))
            line.line(to: CGPoint(x: x, y: rect.maxY))
            NSColor.black.setStroke()
            line.stroke()
            text(marker.label, at: CGPoint(x: x, y: rect.maxY - labelSize - 2), size: labelSize, color: .white, alignment: .center)
        }
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 0.5
        NSColor(white: 0.55, alpha: 1).setStroke()
        border.stroke()
        for (i, label) in yLabels.enumerated() {
            let y = rect.minY + rect.height * CGFloat(i) / CGFloat(steps) - labelSize / 2 - 1
            text(label, at: CGPoint(x: rect.minX - 3, y: y), size: labelSize, color: labelColor, alignment: .right)
        }
        let positions: [CGFloat] = [rect.minX, rect.midX, rect.maxX]
        for (i, label) in xLabels.prefix(3).enumerated() {
            text(label, at: CGPoint(x: positions[i], y: rect.maxY + 3), size: labelSize, color: labelColor, alignment: .center)
        }
    }

    /// The route box: white ground, thin frame, the track in blue with a green start, a red end and an orange event point.
    /// Only the track is drawn (no map tiles).
    static func map(in rect: CGRect, route: LegacyReportRoute, labelSize: CGFloat) {
        NSColor.white.setFill()
        rect.fill()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 0.6
        NSColor.black.setStroke()
        border.stroke()
        guard let first = route.points.first else {
            text("位置情報なし", at: CGPoint(x: rect.midX, y: rect.midY - labelSize / 2), size: labelSize, color: .gray, alignment: .center)
            return
        }
        func place(_ p: ReportPoint) -> CGPoint { CGPoint(x: rect.minX + rect.width * CGFloat(p.x), y: rect.minY + rect.height * CGFloat(p.y)) }
        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.lineJoinStyle = .round
        path.move(to: place(first))
        for p in route.points.dropFirst() { path.line(to: place(p)) }
        NSColor(srgbRed: 0.1, green: 0.4, blue: 0.85, alpha: 1).setStroke()
        path.stroke()
        func dot(_ point: ReportPoint?, _ color: NSColor, _ radius: CGFloat) {
            guard let point else { return }
            let c = place(point)
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)).fill()
        }
        dot(route.start, NSColor(srgbRed: 0.1, green: 0.65, blue: 0.2, alpha: 1), 3)
        dot(route.end, NSColor(srgbRed: 0.85, green: 0.15, blue: 0.1, alpha: 1), 3)
        dot(route.event, NSColor(srgbRed: 0.95, green: 0.55, blue: 0.05, alpha: 1), 3.5)
    }

    /// A reference image on black with its caption above it; the picture keeps its aspect ratio.
    static func thumbnail(_ image: CGImage?, caption: String, in rect: CGRect, captionSize: CGFloat) {
        text(caption, at: CGPoint(x: rect.minX, y: rect.minY - captionSize - 4), size: captionSize)
        NSColor.black.setFill()
        rect.fill()
        if let image {
            let ratio = CGFloat(image.width) / CGFloat(max(1, image.height))
            var fit = rect
            if rect.width / rect.height > ratio {
                fit.size.width = rect.height * ratio
                fit.origin.x += (rect.width - fit.width) / 2
            } else {
                fit.size.height = rect.width / ratio
                fit.origin.y += (rect.height - fit.height) / 2
            }
            NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                .draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            text("画像なし", at: CGPoint(x: rect.midX, y: rect.midY - captionSize / 2), size: captionSize, color: .lightGray, alignment: .center)
        }
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 0.5
        NSColor.gray.setStroke()
        border.stroke()
    }

    /// The two graphs of a report in the shape both the dialog and the page use.
    static func speedLines(_ report: LegacyReport) -> [Line] { [Line(points: report.speedSeries(), color: .white)] }
    static func accelerationLines(_ report: LegacyReport) -> [Line] {
        (0..<3).map { Line(points: report.accelerationSeries(axis: $0), color: axisColors[$0]) }
    }
    /// The event marker belongs to the acceleration graph only.
    static func speedGraph(_ report: LegacyReport, in rect: CGRect, labelSize: CGFloat) {
        graph(in: rect, lines: speedLines(report), yLabels: report.speedAxisLabels, xLabels: report.timeAxisLabels, marker: nil, labelSize: labelSize)
    }
    static func accelerationGraph(_ report: LegacyReport, in rect: CGRect, labelSize: CGFloat) {
        var marker: (position: Double, label: String)?
        if let position = report.eventMarkerPosition, let label = report.eventMarkerLabel { marker = (position: position, label: label) }
        graph(in: rect, lines: accelerationLines(report), yLabels: report.accelerationAxisLabels, xLabels: report.timeAxisLabels, marker: marker, labelSize: labelSize)
    }

    /// Draws into an image immediately (2x pixels), with a flipped coordinate system and a white ground.
    static func image(size: CGSize, scale: CGFloat = 2, draw: (CGRect) -> Void) -> NSImage? {
        let wide = Int(size.width * scale), high = Int(size.height * scale)
        guard wide > 0, high > 0,
              let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8, samplesPerPixel: 4,
                                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bitmapContext = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        representation.size = size
        let context = bitmapContext.cgContext
        context.translateBy(x: 0, y: CGFloat(high))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let bounds = CGRect(origin: .zero, size: size)
        NSColor.white.setFill()
        bounds.fill()
        draw(bounds)
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: size)
        result.addRepresentation(representation)
        return result
    }
}
