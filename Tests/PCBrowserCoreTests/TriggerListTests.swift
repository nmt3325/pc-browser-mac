import XCTest
@testable import PCBrowserCore

final class TriggerListTests: XCTestCase {
    private let helper = LegacyReportTests()

    func testOnlyFramesWithTriggerFieldsAreListed() throws {
        let recording = try helper.recording("e", helper.eventFrames())
        let entries = TriggerList.entries(recording)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].text, "2026/11/11 20:25:04(衝撃)")
        XCTAssertEqual(entries[0].packetIndex, 5)
        XCTAssertEqual(entries[0].types, ["衝撃"])
    }

    func testSeveralTriggersAndTypeNames() throws {
        var frames = helper.eventFrames()
        frames[6].flags = 4; frames[6].mask = 0
        frames[7].flags = 1; frames[7].mask = 0x1 | 0x40
        let entries = TriggerList.entries(try helper.recording("e", frames))
        XCTAssertEqual(entries.map(\.packetIndex), [5, 6, 7])
        XCTAssertEqual(entries[1].label, "ワンタッチ")
        XCTAssertEqual(entries[1].types, ["ワンタッチ"])
        XCTAssertEqual(entries[2].types, ["衝撃", "急ブレーキ"])
        XCTAssertEqual(entries[2].label, "衝撃, など")
        XCTAssertEqual(TriggerList.types(of: EventTrigger.Sample(flags: 1, mask: 0)), ["イベント"])
    }

    func testPresentTypesFollowTheOriginalOrderAndFilterByType() throws {
        var frames = helper.eventFrames()
        frames[6].flags = 1; frames[6].mask = 0x40
        frames[7].flags = 1; frames[7].mask = 0x4
        let entries = TriggerList.entries(try helper.recording("e", frames))
        XCTAssertEqual(TriggerList.presentTypes(entries), ["衝撃", "急ハンドル", "急ブレーキ"])
        XCTAssertEqual(TriggerList.filter(entries, selected: nil).count, 3)
        XCTAssertEqual(TriggerList.filter(entries, selected: ["急ブレーキ"]).map(\.packetIndex), [6])
        XCTAssertEqual(TriggerList.filter(entries, selected: ["衝撃", "急ハンドル"]).map(\.packetIndex), [5, 7])
        XCTAssertTrue(TriggerList.filter(entries, selected: []).isEmpty)
    }

    func testAllTypesListEveryNamedCauseOnce() {
        XCTAssertEqual(TriggerList.allTypes.count, 21)
        XCTAssertEqual(Set(TriggerList.allTypes).count, 21)
        XCTAssertEqual(TriggerList.allTypes.first, "衝撃")
        XCTAssertEqual(TriggerList.allTypes.last, "イベント")
    }
}
