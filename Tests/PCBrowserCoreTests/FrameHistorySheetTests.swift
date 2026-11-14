import XCTest
@testable import PCBrowserCore

/// 表示 ▸ 画面表示 ▸ 16分割表示: sixteen most recent frames, oldest top left, newest bottom right (behaviour observed in the
/// original with generic frame numbers; no recording data is involved here).
final class FrameHistorySheetTests: XCTestCase {
    func testTilesRunFromTheOldestToTheCurrentFrame() {
        let tiles = FrameHistorySheet.tileFrames(current: 100, frameCount: 7121)
        XCTAssertEqual(tiles.count, 16)
        XCTAssertEqual(tiles.compactMap { $0 }, Array(85...100))
        XCTAssertEqual(tiles.first!, 85)
        XCTAssertEqual(tiles.last!, 100)
    }

    func testSteppingShiftsTheTilesByOne() {
        let a = FrameHistorySheet.tileFrames(current: 100, frameCount: 7121)
        let forward = FrameHistorySheet.tileFrames(current: 101, frameCount: 7121)
        XCTAssertEqual(Array(forward.dropLast()), Array(a.dropFirst()))
        XCTAssertEqual(forward.last!, 101)
        let back = FrameHistorySheet.tileFrames(current: 99, frameCount: 7121)
        XCTAssertEqual(Array(back.dropFirst()), Array(a.dropLast()))
        XCTAssertEqual(back.first!, 84)
    }

    func testTilesBeforeTheStartAreEmpty() {
        let tiles = FrameHistorySheet.tileFrames(current: 3, frameCount: 50)
        XCTAssertEqual(Array(tiles.prefix(12)), Array(repeating: nil, count: 12))
        XCTAssertEqual(Array(tiles.suffix(4)), [0, 1, 2, 3])
        XCTAssertEqual(FrameHistorySheet.requiredFrames(current: 3, frameCount: 50), [0, 1, 2, 3])
        XCTAssertEqual(FrameHistorySheet.tileFrames(current: 15, frameCount: 50).first!, 0)
        XCTAssertEqual(FrameHistorySheet.tileFrames(current: 14, frameCount: 50).first!, nil)
    }

    func testNoFramesGiveNoTiles() {
        XCTAssertEqual(FrameHistorySheet.tileFrames(current: 0, frameCount: 0).compactMap { $0 }, [])
        XCTAssertEqual(FrameHistorySheet.tileFrames(current: -1, frameCount: 10).compactMap { $0 }, [])
        XCTAssertEqual(FrameHistorySheet.tileFrames(current: 10, frameCount: 10).compactMap { $0 }, [])
        XCTAssertEqual(FrameHistorySheet.tileFrames(current: 0, frameCount: 10).compactMap { $0 }, [0])
    }

    func testNumbersCountFromOne() {
        XCTAssertEqual(FrameHistorySheet.label(frame: 0), "1")
        XCTAssertEqual(FrameHistorySheet.label(frame: 100), "101")
    }

    func testOnlyTheFDRCapabilityClassHasTheSheet() {
        // Capability classes observed in the original's model table: 0x1000 FDR, 0x2000 Q/S/SRZ, 0x3000 SN/LTE, 0 others.
        XCTAssertTrue(FrameHistorySheet.isAvailable(capability: 0x5a53))
        XCTAssertTrue(FrameHistorySheet.isAvailable(capability: 0x5adb))
        XCTAssertFalse(FrameHistorySheet.isAvailable(capability: 0x2000))
        XCTAssertFalse(FrameHistorySheet.isAvailable(capability: 0x3000))
        XCTAssertFalse(FrameHistorySheet.isAvailable(capability: 0))
        for model in LegacyModelCatalog.all {
            XCTAssertEqual(model.supportsFrameHistorySheet, model.family == "FDR", model.name)
        }
        XCTAssertEqual(LegacyModelCatalog.all.filter(\.supportsFrameHistorySheet).count,
                       LegacyModelCatalog.all.filter { $0.family == "FDR" }.count)
        XCTAssertFalse(LegacyModelCatalog.all.filter { $0.family == "FDR" }.isEmpty)
        XCTAssertFalse(LegacyModelCatalog.all.first { $0.name == "Q-01" }!.supportsFrameHistorySheet)
    }

    func testLayoutPlacesTheTilesRowByRow() {
        let layout = FrameHistorySheet.layout(pictureWidth: 640, pictureHeight: 270, labelHeight: 30, gap: 4)
        XCTAssertEqual(layout.width, 4 * 640 + 5 * 4)
        XCTAssertEqual(layout.height, 4 * 300 + 5 * 4)
        XCTAssertEqual(layout.pictures.count, 16)
        XCTAssertEqual(layout.labels.count, 16)
        XCTAssertEqual(layout.pictures[0], .init(x: 4, y: 4, width: 640, height: 270))
        XCTAssertEqual(layout.labels[0], .init(x: 4, y: 274, width: 640, height: 30))
        XCTAssertEqual(layout.pictures[5], .init(x: 648, y: 308, width: 640, height: 270))
        XCTAssertEqual(layout.pictures[15], .init(x: 1936, y: 916, width: 640, height: 270))
        for (picture, label) in zip(layout.pictures, layout.labels) {
            XCTAssertEqual(label.x, picture.x)
            XCTAssertEqual(label.y, picture.y + picture.height)
            XCTAssertLessThanOrEqual(picture.x + picture.width, layout.width)
            XCTAssertLessThanOrEqual(label.y + label.height, layout.height)
        }
        // Row-major: x grows along a row, y grows from row to row, and cells never overlap.
        for slot in 1..<16 {
            let a = layout.pictures[slot - 1], b = layout.pictures[slot]
            if slot % 4 == 0 { XCTAssertGreaterThan(b.y, a.y + a.height) } else { XCTAssertEqual(b.y, a.y); XCTAssertGreaterThan(b.x, a.x + a.width) }
        }
    }

    func testPictureSizeKeepsTheSourceAspectRatio() {
        let size = FrameHistorySheet.pictureSize(sourceWidth: 2560, sourceHeight: 1080)
        XCTAssertEqual(size.width, 640)
        XCTAssertEqual(size.height, 270)
        XCTAssertEqual(FrameHistorySheet.pictureSize(sourceWidth: 1920, sourceHeight: 1080, width: 320).height, 180)
        XCTAssertEqual(FrameHistorySheet.pictureSize(sourceWidth: 1000, sourceHeight: 333, width: 100).height % 2, 0)
        let fallback = FrameHistorySheet.pictureSize(sourceWidth: 0, sourceHeight: 0)
        XCTAssertGreaterThan(fallback.width, 0)
        XCTAssertGreaterThan(fallback.height, 0)
    }

    func testFrameHistoryModeStaysCompatibleWithSavedSettings() throws {
        XCTAssertEqual(ProjectionMode.frameHistory.metalMode, .raw)
        XCTAssertEqual(ProjectionMode.perspective.metalMode, .perspective)
        XCTAssertFalse(ProjectionMode.metalModes.contains(.frameHistory))
        XCTAssertEqual(ProjectionMode.metalModes.enumerated().map { $0.element.shaderID == $0.offset }.filter { !$0 }.count, 0)
        var settings = ProjectionSettings()
        settings.mode = .frameHistory
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ProjectionSettings.self, from: data).mode, .frameHistory)
        // Settings saved before the mode existed (including the earlier "grid16" direction view) still load.
        let older = Data(#"{"mode":"grid16"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ProjectionSettings.self, from: older).mode, .grid16)
    }
}
