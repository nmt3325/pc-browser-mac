import XCTest
@testable import PCBrowserCore

final class ViewTransformTests: XCTestCase {
    private func close(_ a: Double, _ b: Double, accuracy: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a, b, accuracy: accuracy, file: file, line: line)
    }

    func testInitialStateAndLabels() {
        var t = ViewTransform()
        XCTAssertTrue(t.isIdentity)
        XCTAssertEqual(t.stateLabel, "画像状態：正転")
        t.rotateClockwise(90)
        XCTAssertEqual(t.stateLabel, "画像状態：正転  90°")
        t.flipHorizontal()
        XCTAssertEqual(t.stateLabel, "画像状態：反転  270°")
        t.reset()
        XCTAssertTrue(t.isIdentity)
        XCTAssertEqual(t.stateLabel, "画像状態：正転")
    }

    func testFlipsMirrorTheDisplayedPicture() {
        var start = ViewTransform()
        start.rotateClockwise(37)
        start.setZoom(2)
        start.pan(byDisplayDeltaX: 10, y: -5, width: 200, height: 100)
        start.flipHorizontal()
        start.rotateCounterClockwise(11)
        let w = 200.0, h = 100.0
        var horizontal = start, vertical = start
        horizontal.flipHorizontal()
        vertical.flipVertical()
        let before = start.matrix(width: w, height: h), afterH = horizontal.matrix(width: w, height: h), afterV = vertical.matrix(width: w, height: h)
        for (x, y) in [(0.0, 0.0), (200.0, 0.0), (50.0, 70.0), (123.0, 45.0)] {
            let o = before.apply(x: x, y: y), a = afterH.apply(x: x, y: y), b = afterV.apply(x: x, y: y)
            close(a.x, w - o.x); close(a.y, o.y)
            close(b.x, o.x); close(b.y, h - o.y)
        }
    }

    func testFlipsComposeAndUndo() {
        var t = ViewTransform()
        t.flipHorizontal(); t.flipHorizontal()
        XCTAssertTrue(t.isIdentity)
        t.flipVertical(); t.flipVertical()
        XCTAssertTrue(t.isIdentity)
        t.flipHorizontal(); t.flipVertical()
        XCTAssertFalse(t.mirrored)
        XCTAssertEqual(t.angleDegrees, 180)
        XCTAssertEqual(t.stateLabel, "画像状態：正転  180°")
    }

    func testQuarterTurnMovesCornersClockwise() {
        var t = ViewTransform()
        t.rotateClockwise(90)
        let m = t.matrix(width: 100, height: 100)
        let topLeft = m.apply(x: 0, y: 0), rightMiddle = m.apply(x: 100, y: 50)
        close(topLeft.x, 100); close(topLeft.y, 0)
        close(rightMiddle.x, 50); close(rightMiddle.y, 100)
    }

    func testRotationNormalisationAndAngleInput() {
        var t = ViewTransform()
        t.rotateClockwise(400)
        close(t.rotation, 40)
        t.reset()
        t.rotateCounterClockwise(50)
        close(t.rotation, 310)
        XCTAssertEqual(ViewTransform.normalizedAngle(-720), 0)
        XCTAssertEqual(ViewTransform.normalizedAngle(.nan), 0)
        XCTAssertEqual(ViewTransform.parseAngleInput("90"), 90)
        XCTAssertEqual(ViewTransform.parseAngleInput("９０"), 90)
        XCTAssertEqual(ViewTransform.parseAngleInput(" 359 "), 359)
        XCTAssertEqual(ViewTransform.parseAngleInput("1"), 1)
        for bad in ["0", "360", "-5", "1.5", "", "abc", "９０度"] { XCTAssertNil(ViewTransform.parseAngleInput(bad), bad) }
        XCTAssertEqual(ViewTransform.angleErrorMessage, "角度は1度から359度の間で入力してください。")
        XCTAssertEqual(ViewTransform.wrappedYaw(190), -170)
        XCTAssertEqual(ViewTransform.wrappedYaw(-190), 170)
    }

    func testZoomLimitsAndPanClamping() {
        var t = ViewTransform()
        for _ in 0..<40 { t.zoomIn() }
        XCTAssertEqual(t.zoom, ViewTransform.maximumZoom)
        for _ in 0..<40 { t.zoomOut() }
        XCTAssertEqual(t.zoom, 1)
        XCTAssertEqual(t.centerX, 0.5)
        XCTAssertTrue(t.isIdentity)
        t.setZoom(.nan)
        XCTAssertEqual(t.zoom, 1)
        t.setZoom(2)
        t.pan(byDisplayDeltaX: -10_000, y: 10_000, width: 100, height: 100)
        close(t.centerX, 0.75); close(t.centerY, 0.25)
        let nonFinite = ViewTransform(); var broken = nonFinite
        broken.centerX = .infinity; broken.zoom = 3
        close(broken.clamped.centerX, 0.5)
    }

    func testPanKeepsContentUnderThePointer() {
        var t = ViewTransform()
        t.setZoom(2)
        let before = t.matrix(width: 100, height: 100)
        t.pan(byDisplayDeltaX: 20, y: 0, width: 100, height: 100)
        close(t.centerX, 0.4)
        let after = t.matrix(width: 100, height: 100)
        let o = before.apply(x: 30, y: 40), n = after.apply(x: 30, y: 40)
        close(n.x, o.x + 20); close(n.y, o.y)
        // The same holds when the picture is rotated and mirrored.
        var rotated = ViewTransform()
        rotated.flipHorizontal(); rotated.rotateClockwise(30); rotated.setZoom(3)
        let b = rotated.matrix(width: 160, height: 90)
        rotated.pan(byDisplayDeltaX: 7, y: -4, width: 160, height: 90)
        let a = rotated.matrix(width: 160, height: 90)
        let p = b.apply(x: 70, y: 40), q = a.apply(x: 70, y: 40)
        close(q.x, p.x + 7); close(q.y, p.y - 4)
    }

    func testAreaZoomCentresTheSelectedRegion() {
        var t = ViewTransform()
        t.zoomToDisplayRect(x: 0, y: 0, width: 50, height: 50, displayWidth: 100, displayHeight: 100)
        close(t.zoom, 2); close(t.centerX, 0.25); close(t.centerY, 0.25)
        var small = ViewTransform()
        small.zoomToDisplayRect(x: 50, y: 25, width: 25, height: 25, displayWidth: 100, displayHeight: 100)
        close(small.zoom, 4)
        let m = small.matrix(width: 100, height: 100)
        let centre = m.apply(x: 62.5, y: 37.5)
        close(centre.x, 50); close(centre.y, 50)
        var ignored = ViewTransform()
        ignored.zoomToDisplayRect(x: 10, y: 10, width: 0.2, height: 0.2, displayWidth: 100, displayHeight: 100)
        XCTAssertTrue(ignored.isIdentity)
        ignored.zoomToDisplayRect(x: .nan, y: 0, width: 10, height: 10, displayWidth: 100, displayHeight: 100)
        XCTAssertTrue(ignored.isIdentity)
    }

    func testDragRotationUsesTheSweptAngle() {
        var t = ViewTransform()
        t.rotate(dragFromX: 100, y: 50, toX: 50, y: 100, aroundX: 50, y: 50)
        close(t.rotation, 90)
        t.rotate(dragFromX: 50, y: 100, toX: 100, y: 50, aroundX: 50, y: 50)
        XCTAssertEqual(t.angleDegrees, 0)
        XCTAssertTrue(t.isIdentity)
    }

    func testCodableRoundTripAndOlderSettingsStillLoad() throws {
        var t = ViewTransform()
        t.flipVertical(); t.setZoom(2.5); t.rotateClockwise(15)
        let decoded = try JSONDecoder().decode(ViewTransform.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(decoded, t)
        XCTAssertEqual(try JSONDecoder().decode(ViewTransform.self, from: Data("{}".utf8)), ViewTransform())
        var settings = ProjectionSettings()
        settings.mode = .ring; settings.view = t; settings.night = true
        let again = try JSONDecoder().decode(ProjectionSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(again, settings)
        // Settings saved by earlier builds have no "view" key and may miss other keys.
        let old = try JSONDecoder().decode(ProjectionSettings.self, from: Data(#"{"mode":"perspective","yaw":12,"night":true}"#.utf8))
        XCTAssertEqual(old.mode, .perspective)
        XCTAssertEqual(old.yaw, 12)
        XCTAssertTrue(old.night)
        XCTAssertTrue(old.view.isIdentity)
        XCTAssertEqual(old.frontCenterX, ProjectionSettings().frontCenterX)
    }

    func testLensAndResetHelpers() {
        var s = ProjectionSettings()
        s.moveLensCircles(dx: 0.1, dy: 0.05)
        close(s.frontCenterX, 0.35); close(s.rearCenterX, 0.85); close(s.frontCenterY, 0.55); close(s.rearCenterY, 0.55)
        s.scaleLensCircles(by: 2)
        close(s.radiusScale, 1.3)
        s.scaleLensCircles(by: 0)
        close(s.radiusScale, 1.3)
        s.resetLensCircles()
        XCTAssertEqual(s.frontCenterX, 0.25); XCTAssertEqual(s.radiusScale, 0.98); XCTAssertEqual(s.rearCenterX, 0.75)
        s.night = true; s.mode = .dome; s.yaw = 50; s.pitch = 10; s.roll = 20; s.fieldOfView = 60; s.rawZoom = 3
        s.view.rotateClockwise(30); s.view.setZoom(2)
        s.resetViewOperations()
        XCTAssertTrue(s.view.isIdentity)
        XCTAssertEqual(s.yaw, 0); XCTAssertEqual(s.pitch, 0); XCTAssertEqual(s.roll, 0)
        XCTAssertEqual(s.fieldOfView, 100); XCTAssertEqual(s.rawZoom, 1)
        XCTAssertTrue(s.night, "reset must not touch NIGHT or the display mode")
        XCTAssertEqual(s.mode, .dome)
    }

    func testViewCommandIDsMatchTheOriginalMenu() {
        XCTAssertEqual(ViewCommands.kind(commandID: 501), .reset)
        XCTAssertEqual(ViewCommands.kind(commandID: 505), .flipHorizontal)
        XCTAssertEqual(ViewCommands.kind(commandID: 525), .flipHorizontal)
        XCTAssertEqual(ViewCommands.kind(commandID: 506), .flipVertical)
        XCTAssertEqual(ViewCommands.kind(commandID: 507), .flipFrontBack)
        XCTAssertEqual(ViewCommands.kind(commandID: 510), .rotateClockwise)
        XCTAssertEqual(ViewCommands.kind(commandID: 511), .rotateCounterClockwise)
        XCTAssertEqual(ViewCommands.kind(commandID: 516), .detachWindow)
        XCTAssertEqual(ViewCommands.kind(commandID: 517), .night)
        XCTAssertEqual(ViewCommands.kind(commandID: 2), .closeWindow)
        for id in [500, 520, 531, 560, 1, 3] { XCTAssertNil(ViewCommands.kind(commandID: id), "\(id)") }
        // Mouse-mode numbers stored by the original handlers.
        XCTAssertEqual(ViewCommandKind.areaZoom.mouseMode?.rawValue, 1)
        XCTAssertEqual(ViewCommandKind.move.mouseMode?.rawValue, 2)
        XCTAssertEqual(ViewCommandKind.rotateDrag.mouseMode?.rawValue, 3)
        XCTAssertEqual(ViewCommandKind.lensMove.mouseMode?.rawValue, 6)
        XCTAssertEqual(ViewCommandKind.lensSize.mouseMode?.rawValue, 7)
        XCTAssertNil(ViewCommandKind.zoomIn.mouseMode)
        XCTAssertEqual(ViewCommands.displayMode(commandID: 555), .raw)
        XCTAssertEqual(ViewCommands.displayMode(commandID: 559), .dome)
        XCTAssertNil(ViewCommands.displayMode(commandID: 560))
        XCTAssertEqual(ViewCommands.playbackCommandID(forDetached: 570), 350)
        XCTAssertEqual(ViewCommands.playbackCommandID(forDetached: 576), 356)
        XCTAssertNil(ViewCommands.playbackCommandID(forDetached: 569))
    }

    func testEveryContextMenuCommandIsMappedOrExplicitlyPending() {
        let pending: Set<Int> = [500, 520, 531, 560]
        let multiCamera = Set(521...530)
        for command in LegacyMenuInventory.commands(in: "右クリック") {
            let id = command.id
            let handled = ViewCommands.kind(commandID: id) != nil || ViewCommands.displayMode(commandID: id) != nil
                || ViewCommands.playbackCommandID(forDetached: id) != nil
            XCTAssertEqual(handled, !pending.contains(id), "context-menu command \(id) \(command.label)")
            if multiCamera.contains(id) { XCTAssertEqual(command.status, .unimplemented, "\(id): tile menus wait for multi-camera display") }
            if (570...576).contains(id) || id == 2 || id == 501 || id == 510 || id == 511 || id == 516 { XCTAssertEqual(command.status, .implemented, "\(id)") }
        }
    }
}
