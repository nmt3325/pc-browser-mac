import AppKit
import SwiftUI
import PCBrowserCore

/// Geometry of the picture inside its view (aspect-fit) and the picture's pixel size.
struct VideoLayout {
    var origin: CGPoint
    var size: CGSize
    var pixelWidth: Double
    var pixelHeight: Double

    init?(viewSize: CGSize, imageSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        origin = CGPoint(x: (viewSize.width - fitted.width) / 2, y: (viewSize.height - fitted.height) / 2)
        size = fitted
        pixelWidth = Double(imageSize.width)
        pixelHeight = Double(imageSize.height)
    }
    /// View point → picture pixel coordinates (not clamped).
    func pixel(_ point: CGPoint) -> CGPoint {
        CGPoint(x: Double(point.x - origin.x) / Double(size.width) * pixelWidth, y: Double(point.y - origin.y) / Double(size.height) * pixelHeight)
    }
}

extension BrowserModel {
    var viewStateLabel: String { projection.view.stateLabel }
    var viewTransformIsActive: Bool { !projection.view.isIdentity }

    /// Plays one of the original menu playback commands (350–356; the detached window repeats them as 570–576).
    func performPlayback(commandID id: Int) {
        let command: PlaybackTransport.Command
        switch id {
        case 350: command = .play
        case 351: command = .fastForward
        case 352: step(1); return
        case 353: command = .reversePlay
        case 354: step(-1); return
        case 355: command = .rewind
        case 356: pause(); return
        default: return
        }
        // The original's state machine: 再生 x1 → x0.5, 早送り／早戻し x2 → x4 → x8 → x16, 逆再生 x1 → x0.5 (PlaybackTransport).
        let current = playing ? PlaybackTransport.State(rate: playbackRate, backwards: reverse) : PlaybackTransport.State.stopped
        let next = PlaybackTransport.next(after: current, command: command, hasAudio: hasAudioTrack)
        if next.isStopped { pause() } else { play(rate: next.rate, backwards: next.backwards) }
    }

    func setViewMouseMode(_ mode: ViewMouseMode) { viewMouseMode = viewMouseMode == mode ? .standard : mode }

    /// Runs one operation of the original right-click menu (command IDs 501–517, 521–530 and 2).
    func performViewCommand(_ kind: ViewCommandKind) {
        switch kind {
        case .reset:
            projection.resetViewOperations()
            viewMouseMode = .standard
        case .areaZoom, .move, .rotateDrag, .lensMove, .lensSize:
            if let mode = kind.mouseMode { setViewMouseMode(mode) }
        case .flipHorizontal: projection.view.flipHorizontal()
        case .flipVertical: projection.view.flipVertical()
        case .flipFrontBack: projection.yaw = ViewTransform.wrappedYaw(projection.yaw + 180)
        case .zoomIn: projection.view.zoomIn()
        case .zoomOut: projection.view.zoomOut()
        case .rotateClockwise: promptRotation(clockwise: true)
        case .rotateCounterClockwise: promptRotation(clockwise: false)
        case .lensReset:
            projection.resetLensCircles()
            viewMouseMode = .standard
        case .night: projection.night.toggle()
        case .detachWindow: detachedPreview()
        case .closeWindow: NSApp.keyWindow?.performClose(nil)
        }
    }

    /// 回転(角度指定): asks for a whole-degree angle (1–359) exactly like the original and rotates.
    func promptRotation(clockwise: Bool) {
        pause()
        let alert = NSAlert()
        alert.messageText = clockwise ? "時計回りに回転（角度指定）" : "反時計回りに回転（角度指定）"
        alert.informativeText = "回転する角度を1〜359度の整数で入力してください。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
        field.stringValue = "90"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        while alert.runModal() == .alertFirstButtonReturn {
            if let angle = ViewTransform.parseAngleInput(field.stringValue) {
                if clockwise { projection.view.rotateClockwise(Double(angle)) } else { projection.view.rotateCounterClockwise(Double(angle)) }
                return
            }
            let error = NSAlert()
            error.alertStyle = .warning
            error.messageText = "エラー"
            error.informativeText = ViewTransform.angleErrorMessage
            error.addButton(withTitle: "OK")
            error.runModal()
        }
    }

    // MARK: Pointer handling for the picture view

    private func pictureLayout(in viewSize: CGSize) -> VideoLayout? {
        guard let image else { return nil }
        return VideoLayout(viewSize: viewSize, imageSize: image.size)
    }

    func viewDragChanged(start: CGPoint, location: CGPoint, viewSize: CGSize) {
        if viewDragStart == nil { viewDragStart = projection }
        guard let base = viewDragStart, let layout = pictureLayout(in: viewSize) else { return }
        let deltaX = Double(location.x - start.x), deltaY = Double(location.y - start.y)
        var next = base
        switch viewMouseMode {
        case .standard:
            guard base.mode != .raw else { return }
            next.yaw = max(-180, min(180, base.yaw + deltaX / 3))
        case .move:
            let scaleX = layout.pixelWidth / Double(layout.size.width), scaleY = layout.pixelHeight / Double(layout.size.height)
            next.view.pan(byDisplayDeltaX: deltaX * scaleX, y: deltaY * scaleY, width: layout.pixelWidth, height: layout.pixelHeight)
        case .rotate:
            let from = layout.pixel(start), to = layout.pixel(location)
            next.view.rotate(dragFromX: Double(from.x), y: Double(from.y), toX: Double(to.x), y: Double(to.y), aroundX: layout.pixelWidth / 2, y: layout.pixelHeight / 2)
        case .areaZoom:
            viewSelection = CGRect(x: min(start.x, location.x), y: min(start.y, location.y), width: abs(location.x - start.x), height: abs(location.y - start.y))
            return
        case .lensMove:
            next.moveLensCircles(dx: deltaX / Double(layout.size.width), dy: deltaY / Double(layout.size.height))
        case .lensSize:
            next.scaleLensCircles(by: exp(-deltaY / 200))
        }
        if next != projection { projection = next }
    }

    func viewDragEnded(start: CGPoint, location: CGPoint, viewSize: CGSize) {
        defer { viewDragStart = nil; viewSelection = nil }
        guard viewMouseMode == .areaZoom, let base = viewDragStart, let layout = pictureLayout(in: viewSize) else { return }
        let from = layout.pixel(start), to = layout.pixel(location)
        var next = base
        next.view.zoomToDisplayRect(x: Double(min(from.x, to.x)), y: Double(min(from.y, to.y)), width: Double(abs(to.x - from.x)), height: Double(abs(to.y - from.y)),
                                    displayWidth: layout.pixelWidth, displayHeight: layout.pixelHeight)
        if next != projection { projection = next }
        viewMouseMode = .standard
    }
}

/// The picture with the original's pointer modes, selection rectangle and right-click menu.
struct VideoSurface<Content: View>: View {
    @ObservedObject var model: BrowserModel
    let detached: Bool
    let content: () -> Content

    init(model: BrowserModel, detached: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.model = model
        self.detached = detached
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                content()
                if let selection = model.viewSelection {
                    Rectangle().strokeBorder(Color.yellow, lineWidth: 2).background(Color.yellow.opacity(0.12))
                        .frame(width: selection.width, height: selection.height)
                        .position(x: selection.midX, y: selection.midY)
                        .allowsHitTesting(false)
                }
                if model.viewTransformIsActive || model.viewMouseMode != .standard {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(modeCaption).font(.caption2).padding(5).background(.black.opacity(0.5)).foregroundStyle(.white)
                        }
                    }.padding(5).allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture()
                .onChanged { value in model.viewDragChanged(start: value.startLocation, location: value.location, viewSize: geometry.size) }
                .onEnded { value in model.viewDragEnded(start: value.startLocation, location: value.location, viewSize: geometry.size) })
            .contextMenu { VideoContextMenu(model: model, detached: detached) }
        }
    }
    private var modeCaption: String {
        switch model.viewMouseMode {
        case .standard: return model.viewStateLabel
        case .areaZoom: return model.viewStateLabel + " ／ 範囲拡大: ドラッグで範囲を指定"
        case .move: return model.viewStateLabel + " ／ 移動: ドラッグ"
        case .rotate: return model.viewStateLabel + " ／ 回転: ドラッグ"
        case .lensMove: return "周囲カメラ表示調整 ／ 移動: ドラッグ"
        case .lensSize: return "周囲カメラ表示調整 ／ 大きさ: 上下にドラッグ"
        }
    }
}

/// Right-click menu of the picture (same structure and wording as the original menu).
struct VideoContextMenu: View {
    @ObservedObject var model: BrowserModel
    var detached = false

    var body: some View {
        viewItems
        Divider()
        windowItems
    }

    @ViewBuilder private var viewItems: some View {
        Text(model.viewStateLabel)
        Button("標準に戻す") { model.performViewCommand(.reset) }
        Menu("画面操作") {
            modeToggle("範囲拡大", .areaZoom)
            modeToggle("移動", .move)
            modeToggle("回転", .rotate)
        }
        Menu("反転") {
            Button("左右反転") { model.performViewCommand(.flipHorizontal) }
            Button("上下反転") { model.performViewCommand(.flipVertical) }
            Button("前後反転") { model.performViewCommand(.flipFrontBack) }
        }
        Menu("拡大・縮小") {
            Button("拡大") { model.performViewCommand(.zoomIn) }
            Button("縮小") { model.performViewCommand(.zoomOut) }
        }
        Menu("回転(角度指定)") {
            Button("時計回り…") { model.performViewCommand(.rotateClockwise) }
            Button("反時計回り…") { model.performViewCommand(.rotateCounterClockwise) }
        }
        Menu("周囲カメラ表示調整") {
            Button("標準に戻す") { model.performViewCommand(.lensReset) }
            modeToggle("移動", .lensMove)
            modeToggle("大きさ", .lensSize)
        }
        Toggle("NIGHTモード", isOn: Binding(get: { model.projection.night }, set: { model.projection.night = $0 }))
    }

    @ViewBuilder private var windowItems: some View {
        if detached {
            Button("再生") { model.performPlayback(commandID: 350) }
            Button("早送り") { model.performPlayback(commandID: 351) }
            Button("次コマ") { model.performPlayback(commandID: 352) }
            Button("逆再生") { model.performPlayback(commandID: 353) }
            Button("前コマ") { model.performPlayback(commandID: 354) }
            Button("早戻し") { model.performPlayback(commandID: 355) }
            Button("停止") { model.performPlayback(commandID: 356) }
            Divider()
            Button("ウィンドウを閉じる") { model.performViewCommand(.closeWindow) }
        } else {
            Button("別ウィンドウで表示") { model.performViewCommand(.detachWindow) }
        }
    }

    private func modeToggle(_ title: String, _ mode: ViewMouseMode) -> some View {
        Toggle(title, isOn: Binding(get: { model.viewMouseMode == mode }, set: { _ in model.setViewMouseMode(mode) }))
    }
}
