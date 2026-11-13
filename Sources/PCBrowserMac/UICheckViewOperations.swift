import AppKit
import CoreGraphics
import PCBrowserCore

extension AppDelegate {
    /// Runs the operations behind the picture's right-click menu (command IDs 501–517) on the real decoded frame and
    /// compares pixels. The context menu itself is SwiftUI; this drives the same command path (`dispatch`) and the same
    /// pointer handlers (`viewDragChanged` / `viewDragEnded`) that the menu items and the picture view call.
    func checkViewOperations(result: inout [String: Any], folder: URL) async throws {
        guard let controller = legacyMenu, let recording = model.recording else { throw BrowserError.io("表示操作の検証に必要な録画がありません") }
        model.pause()
        let savedProjection = model.projection, savedMode = model.viewMouseMode
        defer { model.projection = savedProjection; model.viewMouseMode = savedMode }
        var plain = ProjectionSettings()
        plain.mode = .raw
        model.projection = plain
        model.viewMouseMode = .standard
        let frame = min(12, max(0, recording.packets.count - 1))
        func render() async throws -> CGImage {
            await model.renderFrame(frame)
            guard let image = model.displayedFrame else { throw BrowserError.io("表示操作後のフレームを取得できません") }
            return image
        }
        let base = try await render()
        guard base.width >= 16, base.height >= 16 else { throw BrowserError.io("表示操作の基準フレームが小さすぎます") }
        let w = base.width, h = base.height
        let points: [(Int, Int)] = [(w / 8, h / 5), (w / 3, h / 2), (w / 2 + 7, h * 4 / 5), (w * 2 / 3, h / 3), (w * 5 / 6, h * 3 / 4), (w / 4, h * 9 / 10), (w * 3 / 4, h / 10)]
        func near(_ a: [Int], _ b: [Int], _ tolerance: Int = 40) -> Bool {
            a.count == 3 && b.count == 3 && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
        }
        func matching(_ image: CGImage, _ map: (Int, Int) -> (Int, Int)) -> Int {
            points.filter { point in
                let source = map(point.0, point.1)
                return near(ViewTransformRenderer.rgb(image, point.0, point.1), ViewTransformRenderer.rgb(base, source.0, source.1))
            }.count
        }
        var details: [String: Any] = [:]
        func record(_ name: String, _ passed: Bool, _ note: String = "") throws {
            details[name] = passed ? "passed" : "FAILED " + note
            if !passed { throw BrowserError.io("表示操作の検証に失敗しました: \(name) \(note)") }
        }
        let enough = points.count - 1

        controller.dispatch(501)
        try record("initialLabel", model.viewStateLabel == "画像状態：正転" && !model.viewTransformIsActive, model.viewStateLabel)

        controller.dispatch(505)
        var shown = try await render()
        var count = matching(shown) { x, y in (w - 1 - x, y) }
        try record("flipHorizontal", count >= enough && model.viewStateLabel == "画像状態：反転", "\(count)/\(points.count) \(model.viewStateLabel)")
        controller.dispatch(505)
        shown = try await render()
        count = matching(shown) { x, y in (x, y) }
        try record("flipHorizontalTwiceIsStandard", count == points.count && !model.viewTransformIsActive, "\(count)/\(points.count)")

        controller.dispatch(506)
        shown = try await render()
        count = matching(shown) { x, y in (x, h - 1 - y) }
        try record("flipVertical", count >= enough && model.viewStateLabel == "画像状態：反転  180°", "\(count)/\(points.count) \(model.viewStateLabel)")
        controller.dispatch(505)
        shown = try await render()
        count = matching(shown) { x, y in (w - 1 - x, h - 1 - y) }
        try record("flipBothIsRotate180", count >= enough && model.viewStateLabel == "画像状態：正転  180°", "\(count)/\(points.count) \(model.viewStateLabel)")

        controller.dispatch(501)
        shown = try await render()
        count = matching(shown) { x, y in (x, y) }
        try record("resetReturnsToStandard", count == points.count && model.viewStateLabel == "画像状態：正転", "\(count)/\(points.count)")

        // 回転(角度指定) asks for the angle in a modal prompt, so the numeric path is applied directly here.
        model.projection.view.rotateClockwise(90)
        shown = try await render()
        try record("rotateClockwise90", model.viewStateLabel == "画像状態：正転  90°" && near(ViewTransformRenderer.rgb(shown, w / 2, h / 2), ViewTransformRenderer.rgb(base, w / 2, h / 2)), model.viewStateLabel)
        controller.dispatch(501)

        controller.dispatch(508)
        try record("zoomIn", abs(model.projection.view.zoom - ViewTransform.zoomStep) < 1e-9 && model.viewTransformIsActive, "\(model.projection.view.zoom)")
        controller.dispatch(509)
        try record("zoomOutReturnsToStandard", !model.viewTransformIsActive, "\(model.projection.view.zoom)")

        let modes: [(Int, ViewMouseMode)] = [(502, .areaZoom), (503, .move), (504, .rotate), (512, .lensMove), (513, .lensSize)]
        for (id, mode) in modes {
            controller.dispatch(id)
            try record("mouseMode\(id)", model.viewMouseMode == mode, "\(model.viewMouseMode)")
            controller.dispatch(id)
            try record("mouseMode\(id)Off", model.viewMouseMode == .standard, "\(model.viewMouseMode)")
        }

        // The picture fills a view of its own pixel size, so view points equal picture pixels.
        let viewSize = CGSize(width: Double(w), height: Double(h))
        let centre = CGPoint(x: Double(w) / 2, y: Double(h) / 2)
        func drag(_ from: CGPoint, _ to: CGPoint) {
            model.viewDragChanged(start: from, location: to, viewSize: viewSize)
            model.viewDragEnded(start: from, location: to, viewSize: viewSize)
        }
        controller.dispatch(502)
        drag(CGPoint(x: 0, y: 0), centre)
        var view = model.projection.view
        try record("areaZoomDrag", abs(view.zoom - 2) < 1e-6 && abs(view.centerX - 0.25) < 1e-6 && abs(view.centerY - 0.25) < 1e-6 && model.viewMouseMode == .standard,
                   "zoom \(view.zoom) centre \(view.centerX),\(view.centerY) mode \(model.viewMouseMode)")
        shown = try await render()
        try record("areaZoomShowsTopLeftQuarter", near(ViewTransformRenderer.rgb(shown, w / 2, h / 2), ViewTransformRenderer.rgb(base, w / 4, h / 4), 60) && near(ViewTransformRenderer.rgb(shown, w / 4, h / 4), ViewTransformRenderer.rgb(base, w / 8, h / 8), 60))
        controller.dispatch(503)
        drag(centre, CGPoint(x: centre.x - 100, y: centre.y))
        view = model.projection.view
        try record("moveDrag", abs(view.centerX - (0.25 + 50.0 / Double(w))) < 1e-6 && abs(view.centerY - 0.25) < 1e-6 && abs(view.zoom - 2) < 1e-6, "centre \(view.centerX),\(view.centerY)")
        controller.dispatch(503)
        controller.dispatch(501)
        controller.dispatch(504)
        drag(CGPoint(x: centre.x + 100, y: centre.y), CGPoint(x: centre.x, y: centre.y + 100))
        try record("rotateDrag", abs(model.projection.view.rotation - 90) < 1e-6, "rotation \(model.projection.view.rotation)")
        controller.dispatch(504)
        controller.dispatch(501)

        controller.dispatch(507)
        try record("flipFrontBack", abs(model.projection.yaw - 180) < 1e-9, "yaw \(model.projection.yaw)")
        controller.dispatch(507)
        try record("flipFrontBackTwice", abs(model.projection.yaw) < 1e-9, "yaw \(model.projection.yaw)")

        controller.dispatch(514)
        controller.dispatch(512)
        drag(centre, CGPoint(x: centre.x + 128, y: centre.y))
        try record("lensMoveDrag", abs(model.projection.frontCenterX - 0.35) < 1e-6 && abs(model.projection.rearCenterX - 0.85) < 1e-6, "\(model.projection.frontCenterX),\(model.projection.rearCenterX)")
        controller.dispatch(512)
        controller.dispatch(513)
        drag(centre, CGPoint(x: centre.x, y: centre.y - 20))
        try record("lensSizeDrag", abs(model.projection.radiusScale - 0.98 * exp(0.1)) < 1e-6, "\(model.projection.radiusScale)")
        controller.dispatch(513)
        controller.dispatch(514)
        let defaults = ProjectionSettings()
        try record("lensResetRestoresCircles", model.projection.frontCenterX == defaults.frontCenterX && model.projection.rearCenterX == defaults.rearCenterX && model.projection.radiusScale == defaults.radiusScale)

        controller.dispatch(517)
        try record("nightOn", model.projection.night)
        controller.dispatch(517)
        try record("nightOff", !model.projection.night)

        // Show a flipped and rotated picture in the real window and keep a screenshot as evidence.
        controller.dispatch(501)
        controller.dispatch(505)
        model.projection.view.rotateClockwise(90)
        _ = try await render()
        try await Task.sleep(nanoseconds: 700_000_000)
        if let content = window?.contentView { try captureOwnView(content, to: folder.appendingPathComponent("view-ops-flip-rotate.png")) }
        controller.dispatch(501)

        let windowsBefore = DetachedWindows.windows.count
        controller.dispatch(516)
        try await Task.sleep(nanoseconds: 500_000_000)
        guard DetachedWindows.windows.count == windowsBefore + 1, let detached = DetachedWindows.windows.last, detached.isVisible, let detachedContent = detached.contentView else {
            throw BrowserError.io("別ウィンドウ表示が開きません")
        }
        try captureOwnView(detachedContent, to: folder.appendingPathComponent("detached-view.png"))
        detached.close()
        DetachedWindows.windows.removeAll { $0 === detached }
        details["detachedWindow"] = "opened, captured and closed"
        details["frame"] = frame
        details["pixelPoints"] = points.count
        details["scope"] = "Decoded frame in raw projection mode; CoreGraphics view transform; the SwiftUI context menu itself is not clicked"
        result["view_operations"] = details
    }
}
