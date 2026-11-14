import SwiftUI
import AppKit
import PCBrowserCore

/// ログデータ変換 of the original (GPSログ／Earth): the folder and file name, the points (density), the route (width, colour,
/// transparency), Google Earth Pro起動 and スタート. The whole 履歴記録 journal is converted whatever rows are selected in the list, and
/// the settings start from the original's defaults at every opening (docs/kml-export.md). Only new files are written, never onto
/// the card that is being read.
struct LogConversionView: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var options = JournalKMLOptions()
    @State private var folderPath = ReportFiles.defaultFolder.path
    @State private var fileName = ""
    @State private var colour = Color.black
    @State private var kml: JournalKML?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(JournalKML.title).font(.system(size: 18, weight: .bold))
            GroupBox("GPSログ／Earth") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("保存する場所")
                        HStack { TextField("", text: $folderPath).textFieldStyle(.roundedBorder); Button("参照") { chooseFolder() } }
                    }
                    GridRow {
                        Text("ファイル名")
                        HStack { TextField("", text: $fileName).textFieldStyle(.roundedBorder); Text(".kml").foregroundStyle(.secondary) }
                    }
                    Divider().gridCellColumns(2)
                    GridRow {
                        Toggle("ポイント", isOn: $options.showPoints)
                        HStack(spacing: 8) { Text("間隔"); SpinField(value: $options.density, range: JournalKMLOptions.densityRange); Text("件ごと").foregroundStyle(.secondary) }
                            .disabled(!options.showPoints)
                    }
                    GridRow {
                        Toggle("ルート", isOn: $options.showRoute)
                        HStack(spacing: 12) {
                            Text("幅"); SpinField(value: $options.width, range: JournalKMLOptions.widthRange)
                            Text("色"); ColorPicker("", selection: $colour, supportsOpacity: false).labelsHidden()
                            Text("透明度"); SpinField(value: $options.alpha, range: JournalKMLOptions.alphaRange)
                        }.disabled(!options.showRoute)
                    }
                    Divider().gridCellColumns(2)
                    GridRow {
                        Toggle("Google Earth Pro起動", isOn: $options.launchEarth).gridCellColumns(2)
                    }
                }.padding(10)
            }
            if let kml {
                Text("履歴記録の全\(kml.entryCount)件を書き出します（一覧で選んだ行には関係しません）。元データは読み取り専用で、既存のファイルは上書きしません。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("履歴記録が読み込まれていません").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("スタート") { start() }.keyboardShortcut(.defaultAction).disabled(kml == nil || model.busy)
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 600)
        .onAppear {
            guard kml == nil, let log = model.historyLog else { return }
            kml = JournalKML(log: log)
            fileName = kml?.defaultStem ?? ""
            // Starting another application is the user's decision here as everywhere in this app: the preference decides the initial state.
            options.launchEarth = model.openEarthAfterExport
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "保存する場所"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }

    private func rgb(of colour: Color) -> UInt32 {
        let c = NSColor(colour).usingColorSpace(.sRGB) ?? .black
        func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }

    private func start() {
        guard let kml else { return }
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            model.errorMessage = "ファイル名を確認してください（空欄、/ と : は使えません）"
            return
        }
        let file = name.lowercased().hasSuffix(".kml") ? name : name + ".kml"
        let folder = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
        if let reason = ReportFiles.refusal(names: [file], folder: folder, protecting: [model.sourceURL].compactMap { $0 }) {
            model.errorMessage = reason
            return
        }
        var chosen = options
        chosen.rgb = rgb(of: colour)
        dismiss()
        model.convertJournal(kml, options: chosen.clamped, folder: folder, fileName: file)
    }
}

/// An edit box with a spin button whose value stays inside `range`.
private struct SpinField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 2) {
            TextField("", value: $value, format: .number)
                .multilineTextAlignment(.trailing).frame(width: 46)
                .onChange(of: value) { _, new in
                    let inside = min(max(new, range.lowerBound), range.upperBound)
                    if inside != new { value = inside }
                }
            Stepper("", value: $value, in: range).labelsHidden()
        }
    }
}

extension BrowserModel {
    /// Writes the Google Earth file of the journal into a new file (progress and キャンセル as for every export), then reports
    /// 完了しました like the original and opens Google Earth when asked to.
    func convertJournal(_ kml: JournalKML, options: JournalKMLOptions, folder: URL, fileName: String) {
        let protected = [sourceURL].compactMap { $0 }
        let target = folder.appendingPathComponent(fileName)
        performExport(JournalKML.title) { flag, progress in
            if let reason = ReportFiles.refusal(names: [fileName], folder: folder, protecting: protected) { throw BrowserError.invalid(reason) }
            let data = try kml.data(options: options, cancelled: { flag.cancelled })
            progress(0.9)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: target, options: .withoutOverwriting)
            progress(1)
            await MainActor.run { self.finishLogConversion(target, launchEarth: options.launchEarth) }
        }
    }

    func finishLogConversion(_ url: URL, launchEarth: Bool) {
        let done = NSAlert()
        done.messageText = JournalKML.title
        done.informativeText = JournalKML.completionText
        done.addButton(withTitle: "OK")
        done.runModal()
        if launchEarth { openKMLInEarth(url) }
    }
}
