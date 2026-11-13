import SwiftUI
import PCBrowserCore

struct LegacyInventoryView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("原版メニュー対応表").font(.title2); Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(summaryLine).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(LegacyMenuInventory.groups, id: \.self) { group in
                    Section(group) {
                        ForEach(LegacyMenuInventory.commands(in: group)) { command in row(command) }
                    }
                }
            }
        }.padding(20).frame(width: 860, height: 660)
    }
    private var summaryLine: String {
        var parts: [String] = []
        for status in LegacyCommandStatus.allCases {
            let n = LegacyMenuInventory.count(status)
            if n > 0 { parts.append("\(status.displayName) \(n)") }
        }
        return parts.joined(separator: " · ") + " / 合計 \(LegacyMenuInventory.all.count)"
    }
    private func row(_ c: LegacyCommand) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(c.id)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text((c.path + [c.label]).joined(separator: " ▸ ")).font(.callout)
                Text(c.macEquivalent).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(c.reason).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(c.status.displayName).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                .background(color(c.status).opacity(0.18), in: Capsule())
        }.padding(.vertical, 2)
    }
    private func color(_ status: LegacyCommandStatus) -> Color {
        switch status {
        case .implemented: return .green
        case .partial: return .orange
        case .blocked, .refusedByPolicy: return .red
        default: return .gray
        }
    }
}
