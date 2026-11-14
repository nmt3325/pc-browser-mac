import XCTest
@testable import PCBrowserCore

final class DeviceModelTableTests: XCTestCase {
    func testTableHasThirtySevenModelsWithUniqueCodesAndNames() {
        let all = DeviceModelTable.all
        XCTAssertEqual(all.count, 37)
        XCTAssertEqual(Set(all.map(\.code)).count, 37)
        XCTAssertEqual(Set(all.map(\.name)).count, 37)
        XCTAssertEqual(all.map(\.index), Array(0..<37))
    }

    func testEveryListModelHasAMenuEntryOfTheSameName() {
        for model in DeviceModelTable.all {
            let menu = DeviceModelTable.menuModel(for: model)
            XCTAssertNotNil(menu, model.name)
            XCTAssertEqual(menu?.windowTitle, model.windowTitle)
        }
    }

    func testKnownCodes() {
        XCTAssertEqual(DeviceModelTable.model(code: 0x14)?.name, "Q-01")
        XCTAssertEqual(DeviceModelTable.model(code: 0x14)?.windowTitle, "PC Browser[Q-01]")
        XCTAssertEqual(DeviceModelTable.model(code: 0x00)?.name, "BDR-1")
        XCTAssertEqual(DeviceModelTable.model(code: 0x30)?.name, "Q-04")
        XCTAssertEqual(DeviceModelTable.model(code: 0x2F)?.name, "FDR-820AI")
        XCTAssertEqual(DeviceModelTable.model(code: 0x17)?.name, "BU-DRHD635T Ver.2")
        XCTAssertEqual(DeviceModelTable.model(code: 0x07)?.name, "FA1001")
        XCTAssertNil(DeviceModelTable.model(code: 0x22))
        XCTAssertNil(DeviceModelTable.model(code: 0xFF))
    }

    func testDialogClassesGroupModels() {
        XCTAssertEqual(DeviceModelTable.models(dialogClass: 147).map(\.name), ["FDR-820", "FDR-900", "FDR-820 m2", "FDR-820AI"])
        XCTAssertEqual(DeviceModelTable.models(dialogClass: 81).map(\.name), ["Q-01", "Q-02", "Q-03", "SRZ-01", "Q-04"])
        XCTAssertEqual(DeviceModelTable.models(dialogClass: 78).map(\.name), ["SN-HQ90d"])
        XCTAssertEqual(DeviceModelTable.models(dialogClass: 123).map(\.name), ["S20"])
        XCTAssertEqual(DeviceModelTable.models(dialogClass: 80).count, 11)
        XCTAssertEqual(DeviceModelTable.models(dialogClass: 127).count, 15)
        XCTAssertEqual(Set(DeviceModelTable.all.map(\.dialogClass)), Set(DeviceModelTable.dialogSizes.keys))
        let size = DeviceModelTable.model(code: 0x29)?.settingsDialogSize
        XCTAssertEqual(size?.width, 1482)
        XCTAssertEqual(size?.height, 1056)
    }

    func testIdentifyReadsByteOneDCOfTheControlSector() {
        var sector = Data(count: 512)
        sector[0x1DC] = 0x24
        XCTAssertEqual(DeviceModelTable.identify(controlSector: sector)?.name, "FDR-820")
        sector[0x1DC] = 0x99
        XCTAssertNil(DeviceModelTable.identify(controlSector: sector))
        XCTAssertNil(DeviceModelTable.identify(controlSector: Data(count: 0x1DC)))
        XCTAssertEqual(DeviceModelTable.identify(controlSector: Data(count: 512))?.name, "BDR-1", "code 0 is a model, not an absent value")
    }

    func testIdentifyFromAnImage() throws {
        var image = CatalogTests().fixture([CatalogTests.Spec(record: 20, root: 20, start: true)])
        let index = try CatalogScanner.scan(MemorySource(image))
        image[Int(index.control.sector) * 512 + 0x1DC] = 0x2C
        XCTAssertEqual(DeviceModelTable.identify(from: MemorySource(image), control: index.control)?.name, "BU-DRHD645T")
        XCTAssertNil(DeviceModelTable.identify(from: MemorySource(image.prefix(Int(index.control.sector) * 512 + 100)), control: index.control), "a truncated copy has no model byte")
    }
}
