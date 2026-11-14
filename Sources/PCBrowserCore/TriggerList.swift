import Foundation

/// One line of the original player's トリガリスト: a frame whose header names a trigger, shown as `yyyy/MM/dd HH:mm:ss(label)`.
public struct TriggerListEntry: Sendable, Equatable, Identifiable {
    public var id: Int { packetIndex }
    /// Index into `Recording.packets`; selecting the line seeks there.
    public let packetIndex: Int
    public let clock: CardTimestamp?
    public let label: String
    /// Names of every cause bit of the record (the unit of the trigger-type filter).
    public let types: [String]
    public var text: String { LegacyReport.dateTimeText(clock) + "(" + label + ")" }
}

public enum TriggerList {
    /// Every trigger type the original's filter dialog can show, in the order the original tests the cause bits, then the
    /// generic event.
    public static let allTypes: [String] = EventTrigger.names.map(\.text) + ["イベント"]

    /// The cause names of one trigger record: all set cause bits; one-touch for a cause-less record with flag bit 2;
    /// otherwise the generic event.
    public static func types(of sample: EventTrigger.Sample) -> [String] {
        let named = EventTrigger.names.filter { sample.mask & $0.mask != 0 }.map(\.text)
        if !named.isEmpty { return named }
        return sample.flags & 4 != 0 ? ["ワンタッチ"] : ["イベント"]
    }

    /// The trigger frames of a loaded recording in time order.
    public static func entries(_ recording: Recording) -> [TriggerListEntry] {
        var result: [TriggerListEntry] = []
        for (index, packet) in recording.packets.enumerated() {
            let t = packet.telemetry
            guard !t.trigger.isEmpty else { continue }
            result.append(TriggerListEntry(packetIndex: index, clock: t.clock, label: EventTrigger.label([t.trigger]), types: types(of: t.trigger)))
        }
        return result
    }

    /// The types that occur in the entries, in `allTypes` order.
    public static func presentTypes(_ entries: [TriggerListEntry]) -> [String] {
        let present = Set(entries.flatMap(\.types))
        return allTypes.filter { present.contains($0) }
    }

    /// Entries with at least one selected type. `nil` selects everything.
    public static func filter(_ entries: [TriggerListEntry], selected: Set<String>?) -> [TriggerListEntry] {
        guard let selected else { return entries }
        return entries.filter { !selected.isDisjoint(with: $0.types) }
    }
}
