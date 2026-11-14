import AppKit
import PCBrowserCore

extension BrowserModel {
    var legacyModel: LegacyModel? { LegacyModelCatalog.model(commandID: legacyModelID) }
    /// 表示 ▸ 画面表示 ▸ 16分割表示 exists only for the FDR capability class of the selected model (as in the original).
    var frameHistoryAvailable: Bool { legacyModel?.supportsFrameHistorySheet ?? false }
    /// 16分割表示 (the sixteen most recent frames). The single-screen mode in use is remembered for 1画面表示.
    func showFrameHistory() {
        guard frameHistoryAvailable, projection.mode != .frameHistory else { return }
        modeBeforeFrameHistory = projection.mode
        projection.mode = .frameHistory
    }
    /// 1画面表示: leaves 16分割表示 (back to the previous single screen) and the Mac-only multi-picture views.
    func showSingleScreen() {
        switch projection.mode {
        case .frameHistory: projection.mode = modeBeforeFrameHistory
        case .frontRear, .quad, .grid16: projection.mode = .perspective
        default: break
        }
    }
    /// A model without the 16分割 screen cannot keep it.
    func leaveFrameHistoryIfUnavailable() {
        if projection.mode == .frameHistory, !frameHistoryAvailable { projection.mode = modeBeforeFrameHistory }
    }
    var windowTitle: String { legacyModel.map { $0.windowTitle + " — Mac 読み取り専用" } ?? "PC Browser Mac — 読み取り専用" }
    func saveLegacyPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(legacyModelID, forKey: "pcbrowser.legacyModel")
        defaults.set(speedUnit.rawValue, forKey: "pcbrowser.speedUnit")
        defaults.set(sensorScale.rawValue, forKey: "pcbrowser.sensorScale")
        defaults.set(showMap, forKey: "pcbrowser.showMap")
        if let data = try? JSONEncoder().encode(sensorCalibration) { defaults.set(data, forKey: "pcbrowser.sensorCalibration") }
    }
    /// Menu-style playback: start (or restart) at a fixed rate in one direction.
    /// `playbackRate`'s observer pauses on change, so the rate is set first.
    func play(rate: Double, backwards: Bool) {
        if playbackRate != rate { playbackRate = rate }
        if playing && reverse == backwards { return }
        togglePlay(backwards: backwards)
    }
    func speedText(_ kmh: Double?) -> String { kmh.map { speedUnit.text(fromKMH: $0) } ?? "—" }
}
