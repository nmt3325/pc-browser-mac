import XCTest
@testable import PCBrowserCore

final class LegacyCatalogTests: XCTestCase {
    private func model(_ id: Int) throws -> LegacyModel { try XCTUnwrap(LegacyModelCatalog.model(commandID: id)) }

    func testAllFortyFourOriginalModelsAreUnique() {
        let all = LegacyModelCatalog.all
        XCTAssertEqual(all.count, 44)
        XCTAssertEqual(Set(all.map(\.commandID)).count, 44)
        XCTAssertEqual(Set(all.map(\.name)).count, 44)
        XCTAssertEqual(Set(all.map(\.index)).count, 44)
        XCTAssertEqual(LegacyModelCatalog.families.map { LegacyModelCatalog.models(in: $0).count }, [26, 1, 6, 3, 2, 4, 1, 1])
    }
    func testSpotCheckedModelValuesAndWindowTitle() throws {
        let a = try model(449)
        XCTAssertEqual(a.name, "BU-DRHD640T"); XCTAssertEqual(a.index, 58); XCTAssertEqual(a.capability, 0x14647); XCTAssertEqual(a.family, "BU")
        let q = try model(455)
        XCTAssertEqual(q.name, "Q-04"); XCTAssertEqual(q.index, 64); XCTAssertEqual(q.capability, 0x16cc5)
        XCTAssertEqual(try model(451).windowTitle, "PC Browser[SRZ-01]")
        XCTAssertEqual(try model(426).name, "BU-DRHD635T Ver.2")
        XCTAssertNil(LegacyModelCatalog.model(commandID: 427))
    }
    func testSensorPanelClassFollowsLowTwoCapabilityBits() throws {
        XCTAssertEqual(try model(417).sensorPanelClass, 0)
        XCTAssertEqual(try model(401).sensorPanelClass, 0)
        XCTAssertEqual(try model(400).sensorPanelClass, 1)
        XCTAssertEqual(try model(454).sensorPanelClass, 3)
        XCTAssertEqual(try model(450).sensorPanelClass, 3)
        XCTAssertEqual(LegacyModelCatalog.all.filter { $0.sensorPanelClass == 2 }.count, 0)
        XCTAssertTrue(try model(417).sensorPanelDescription.contains("描画しません"))
    }
    func testKnotConversionAndLegacyMeterTruncation() {
        XCTAssertEqual(SpeedUnit.knots.value(fromKMH: 100), 53.9956803, accuracy: 1e-9)
        XCTAssertEqual(SpeedUnit.knots.legacyMeterValue(fromKMH: 100), 53)
        XCTAssertEqual(SpeedUnit.knots.legacyMeterValue(fromKMH: 1), 0)
        XCTAssertEqual(SpeedUnit.kilometersPerHour.legacyMeterValue(fromKMH: 99.99), 99)
        XCTAssertEqual(SpeedUnit.kilometersPerHour.legacyMeterValue(fromKMH: -5), 0)
        XCTAssertEqual(SpeedUnit.kilometersPerHour.legacyMeterValue(fromKMH: .nan), 0)
        XCTAssertEqual(SpeedUnit.kilometersPerHour.legacyMeterValue(fromKMH: 1e9), 65535)
        XCTAssertEqual(SpeedUnit.kilometersPerHour.text(fromKMH: 36), "36.00 km/h")
        XCTAssertEqual(SpeedUnit.knots.text(fromKMH: 36), "19.44 knot")
    }
    func testGSensorScaleLabelsMatchOriginalPainters() {
        let acceleration = [["1.0", "0.5", "-0.5", "-1.0"], ["2.0", "1.0", "-1.0", "-2.0"], ["3.0", "1.5", "-1.5", "-3.0"], ["4.0", "2.0", "-2.0", "-4.0"]]
        let gyro = [["36", "18", "-18", "-36"], ["72", "36", "-36", "-72"], ["108", "54", "-54", "-108"], ["144", "72", "-72", "-144"]]
        XCTAssertEqual(GSensorScale.allCases.count, 4)
        for (i, scale) in GSensorScale.allCases.enumerated() {
            XCTAssertEqual(scale.accelerationTickLabels, acceleration[i])
            XCTAssertEqual(scale.gyroTickLabels, gyro[i])
            XCTAssertEqual(scale.commandID, 330 + i)
            XCTAssertEqual(GSensorScale(commandID: 330 + i), scale)
        }
        XCTAssertNil(GSensorScale(commandID: 329))
        XCTAssertNil(GSensorScale(commandID: 334))
        XCTAssertEqual(GSensorScale.standard.label, "標準")
    }
    func testCalibrationIsOptionalAndNeverGuessed() throws {
        XCTAssertFalse(SensorCalibration().isCalibrated)
        XCTAssertNil(SensorCalibration().acceleration(raw: 100))
        XCTAssertNil(SensorCalibration(accelerationCountsPerUnit: 0).acceleration(raw: 100))
        XCTAssertNil(SensorCalibration(accelerationCountsPerUnit: -2).acceleration(raw: 100))
        XCTAssertNil(SensorCalibration(accelerationCountsPerUnit: .nan).acceleration(raw: 100))
        XCTAssertEqual(try XCTUnwrap(SensorCalibration(accelerationCountsPerUnit: 8192).acceleration(raw: 4096)), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(SensorCalibration(gyroCountsPerUnit: 131).gyro(raw: -262)), -2, accuracy: 1e-12)
        XCTAssertTrue(SensorCalibration(gyroCountsPerUnit: 131).isCalibrated)
        let stored = SensorCalibration(accelerationCountsPerUnit: 4096, gyroCountsPerUnit: nil)
        XCTAssertEqual(try JSONDecoder().decode(SensorCalibration.self, from: JSONEncoder().encode(stored)), stored)
    }
    func testHelpLinksAreTheOriginalUrls() {
        XCTAssertEqual(LegacyLinks.url(commandID: 391)?.absoluteString, "http://www.yupiteru.co.jp/")
        XCTAssertEqual(LegacyLinks.url(commandID: 392)?.absoluteString, "https://www.google.com/help/terms_maps.html?hl=en")
        XCTAssertEqual(LegacyLinks.url(commandID: 393)?.absoluteString, "https://www.google.com/intl/ALL/policies/privacy/index.html")
        XCTAssertNil(LegacyLinks.url(commandID: 390))
    }

    func testInventoryIdsAreUniqueAndEveryEntryExplainsItself() {
        let all = LegacyMenuInventory.all
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertTrue(all.allSatisfy { !$0.reason.isEmpty && !$0.macEquivalent.isEmpty && !$0.label.isEmpty })
    }
    func testMenuBarStructureMatchesOriginalResources() throws {
        XCTAssertEqual(LegacyMenuInventory.menuBarGroups.map { LegacyMenuInventory.commands(in: $0).count }, [8, 15, 10, 56, 4])
        let open = try XCTUnwrap(LegacyMenuInventory.command(id: 300))
        XCTAssertEqual(open.group, "ファイル"); XCTAssertEqual(open.key, "o"); XCTAssertEqual(open.handler, 0x426260)
        XCTAssertEqual(LegacyMenuInventory.command(id: 301)?.path, ["読み込み"])
        XCTAssertEqual(LegacyMenuInventory.command(id: 331)?.path, ["加速度センサースケール"])
        XCTAssertEqual(LegacyMenuInventory.command(id: 345)?.label, "180°VRパノラマ表示")
        XCTAssertEqual(LegacyMenuInventory.command(id: 381)?.label, "車速パルス")
        XCTAssertEqual(LegacyMenuInventory.command(id: 392)?.label, "Google Maps/Google Earth追加利用規約")
        XCTAssertTrue(try XCTUnwrap(LegacyMenuInventory.command(id: 307)).separatorBefore)
        for group in LegacyMenuInventory.menuBarGroups {
            XCTAssertTrue(LegacyMenuInventory.commands(in: group).allSatisfy { $0.handler != 0 }, group)
        }
    }
    func testInventoryAgreesWithModelCatalog() throws {
        for m in LegacyModelCatalog.all {
            let entry = try XCTUnwrap(LegacyMenuInventory.command(id: m.commandID))
            XCTAssertEqual(entry.label, m.name)
            XCTAssertEqual(entry.group, "ツール")
            XCTAssertEqual(entry.path, ["機種選択", m.family])
            XCTAssertEqual(entry.status, .partial)
        }
    }
    func testBlockedAndPolicyItemsAreNeverPresentedAsPorted() {
        for id in [312, 313, 381] { XCTAssertEqual(LegacyMenuInventory.command(id: id)?.status, .blocked, "\(id)") }
        XCTAssertEqual(LegacyMenuInventory.command(id: 370)?.status, .refusedByPolicy)
        XCTAssertEqual(LegacyMenuInventory.command(id: 1071)?.status, .noHandler)
        XCTAssertEqual(LegacyMenuInventory.commands(in: "未使用アクセラレーター").count, 13)
    }
    /// 301-303 were "blocked" while the three lists were unknown. They are now read from the region table, so the commands select a list
    /// and the inventory describes them as partially ported (verified on one card, other models unverified).
    func testLoadCommandsSelectTheThreeRecordLists() {
        XCTAssertEqual(RecordListKind(commandID: 301), .event)
        XCTAssertEqual(RecordListKind(commandID: 302), .continuous)
        XCTAssertEqual(RecordListKind(commandID: 303), .history)
        XCTAssertNil(RecordListKind(commandID: 300)); XCTAssertNil(RecordListKind(commandID: 304))
        for kind in RecordListKind.allCases {
            XCTAssertEqual(RecordListKind(commandID: kind.commandID), kind)
            XCTAssertEqual(LegacyMenuInventory.command(id: kind.commandID)?.label, kind.title)
            XCTAssertEqual(LegacyMenuInventory.command(id: kind.commandID)?.status, .partial)
        }
    }
    func testSummaryIsConsistentJSON() throws {
        let summary = LegacyMenuInventory.summary()
        XCTAssertTrue(JSONSerialization.isValidJSONObject(summary))
        XCTAssertEqual(summary["commands"] as? Int, LegacyMenuInventory.all.count)
        XCTAssertEqual(summary["models"] as? Int, 44)
        let statuses = try XCTUnwrap(summary["statuses"] as? [String: Int])
        XCTAssertEqual(statuses.values.reduce(0, +), LegacyMenuInventory.all.count)
        XCTAssertEqual((summary["entries"] as? [[String: Any]])?.count, LegacyMenuInventory.all.count)
    }
}

final class WriteGuardTests: XCTestCase {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("writeguard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testNewFileInExistingFolderIsAllowed() throws {
        let d = try temp()
        XCTAssertEqual(WriteGuard.checkNewOutput(d.appendingPathComponent("out.mp4")), .allowed)
        XCTAssertTrue(WriteGuard.checkNewOutput(d.appendingPathComponent("out.mp4")).isAllowed)
    }
    func testExistingFileAndDanglingSymlinkAreRefused() throws {
        let d = try temp(), f = d.appendingPathComponent("a.png")
        try Data([1]).write(to: f)
        XCTAssertNotEqual(WriteGuard.checkNewOutput(f), .allowed)
        let link = d.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: d.appendingPathComponent("missing-target"))
        XCTAssertNotEqual(WriteGuard.checkNewOutput(link), .allowed)
        XCTAssertEqual(try Data(contentsOf: f), Data([1]))
    }
    func testMissingFolderAndNonFileURLAreRefused() throws {
        let d = try temp()
        XCTAssertNotEqual(WriteGuard.checkNewOutput(d.appendingPathComponent("nope/out.png")), .allowed)
        XCTAssertNotEqual(WriteGuard.checkNewOutput(URL(string: "https://example.invalid/out.png")!), .allowed)
        XCTAssertNotNil(WriteGuard.checkNewOutput(d.appendingPathComponent("nope/out.png")).reason)
    }
    func testOutputFolderMayBeMissingButNeverAnInputOrADevice() throws {
        let d = try temp(), card = d.appendingPathComponent("card", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        XCTAssertEqual(WriteGuard.checkOutputFolder(d.appendingPathComponent("a/b/c", isDirectory: true)), .allowed)
        XCTAssertEqual(WriteGuard.checkOutputFolder(d, protecting: [card]), .allowed)
        XCTAssertNotEqual(WriteGuard.checkOutputFolder(card, protecting: [card]), .allowed)
        XCTAssertNotEqual(WriteGuard.checkOutputFolder(card.appendingPathComponent("new/sub", isDirectory: true), protecting: [card]), .allowed)
        let alias = d.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: card)
        XCTAssertNotEqual(WriteGuard.checkOutputFolder(alias.appendingPathComponent("new", isDirectory: true), protecting: [card]), .allowed)
        let file = d.appendingPathComponent("plain.txt")
        try Data([1]).write(to: file)
        XCTAssertNotEqual(WriteGuard.checkOutputFolder(file.appendingPathComponent("sub", isDirectory: true)), .allowed)
        XCTAssertNotEqual(WriteGuard.checkOutputFolder(URL(fileURLWithPath: "/dev/rdisk99/x")), .allowed)
        XCTAssertNotEqual(WriteGuard.checkOutputFolder(URL(string: "https://example.invalid/x")!), .allowed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent("a").path), "the check must not create anything")
    }
    func testDevicePathsAreRefused() {
        XCTAssertNotEqual(WriteGuard.checkNewOutput(URL(fileURLWithPath: "/dev/rdisk99")), .allowed)
        XCTAssertNotEqual(WriteGuard.checkNewOutput(URL(fileURLWithPath: "/dev/null")), .allowed)
    }
    func testInputsAndTheirInsidesAreRefused() throws {
        let d = try temp(), card = d.appendingPathComponent("card.img")
        try Data([0]).write(to: card)
        XCTAssertNotEqual(WriteGuard.checkNewOutput(card, protecting: [card]), .allowed)
        let package = d.appendingPathComponent("x.pcbbackup", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        XCTAssertNotEqual(WriteGuard.checkNewOutput(package.appendingPathComponent("new.bin"), protecting: [package]), .allowed)
        let alias = d.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: package)
        XCTAssertNotEqual(WriteGuard.checkNewOutput(alias.appendingPathComponent("new.bin"), protecting: [package]), .allowed)
        XCTAssertEqual(WriteGuard.checkNewOutput(d.appendingPathComponent("other.bin"), protecting: [package, card]), .allowed)
    }
    func testEveryDestructiveOperationIsRefusedWithAReason() {
        XCTAssertEqual(DestructiveOperation.allCases.count, 7)
        for operation in DestructiveOperation.allCases {
            XCTAssertFalse(operation.decision.isAllowed, operation.rawValue)
            XCTAssertFalse((operation.decision.reason ?? "").isEmpty)
            XCTAssertFalse(operation.originalFeature.isEmpty)
        }
    }
}
