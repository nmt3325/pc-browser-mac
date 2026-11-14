import SwiftUI
import PCBrowserCore

/// トリガリスト of the original player: one line `yyyy/MM/dd HH:mm:ss(label)` per frame that names a trigger; choosing a line
/// jumps to that frame. トリガ種類選択 narrows the lines to the chosen cause types.
struct TriggerListPanel: View {
    @ObservedObject var model: BrowserModel
    @State private var entries: [TriggerListEntry] = []
    @State private var showTypes = false

    private var visible: [TriggerListEntry] { TriggerList.filter(entries, selected: model.triggerTypeSelection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(visible.count)件").monospacedDigit().foregroundStyle(.secondary)
                if model.triggerTypeSelection != nil { Text("（種類を絞り込み中）").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("トリガ種類選択…") { showTypes = true }.disabled(entries.isEmpty)
            }
            if visible.isEmpty {
                Text(entries.isEmpty ? "この録画のフレーム情報にはトリガがありません" : "選択した種類のトリガはありません").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                List(visible) { entry in
                    Button { model.seekToFrame(entry.packetIndex) } label: {
                        Text(entry.text).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .task(id: model.recording?.id) {
            guard let recording = model.recording else { entries = []; return }
            entries = await Task.detached(priority: .utility) { TriggerList.entries(recording) }.value
        }
        .sheet(isPresented: $showTypes) { TriggerTypeSheet(model: model, entries: entries) }
    }
}

/// トリガ種類選択: the cause types that occur in the recording as a checklist.
/// 並び替え toggles between the original's order and alphabetical order (what the original's button sorts is unverified).
struct TriggerTypeSheet: View {
    @ObservedObject var model: BrowserModel
    let entries: [TriggerListEntry]
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var alphabetical = false

    private var types: [String] {
        let present = TriggerList.presentTypes(entries)
        return alphabetical ? present.sorted() : present
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("トリガ種類選択").font(.headline)
            Text("表示するトリガ種類を選択してください")
            List(types, id: \.self) { type in
                Toggle(type, isOn: Binding(get: { chosen.contains(type) }, set: { on in if on { chosen.insert(type) } else { chosen.remove(type) } }))
            }.frame(height: 220)
            HStack {
                Button("全て選択する") { chosen = Set(types) }
                Button("全て解除する") { chosen = [] }
                Button("並び替え") { alphabetical.toggle() }
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("表示") { model.triggerTypeSelection = chosen.count == types.count ? nil : chosen; dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 460)
        .onAppear { chosen = model.triggerTypeSelection ?? Set(TriggerList.presentTypes(entries)) }
    }
}
