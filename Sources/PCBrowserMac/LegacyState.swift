import AppKit
import PCBrowserCore

extension BrowserModel {
    var legacyModel: LegacyModel? { LegacyModelCatalog.model(commandID: legacyModelID) }
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
