import Foundation

/// Recording settings that the original 「記録設定」 dialog stores in the card's control sectors.
///
/// The byte layout was established by driving the original application (Wine, writes swallowed) and diffing the sectors it tried to
/// write; see docs/settings-format.md. It is verified for the single-channel Q-01 layout only, so every decoder step is strict and
/// refuses (`BrowserError.unsupported`) anything it does not recognise instead of guessing.
public struct RecordingSettings: Equatable, Sendable {
    public enum Mode: Int, CaseIterable, Sendable {
        case continuousOnly = 0, eventOnly = 1, continuousAndEvent = 2
        public var label: String {
            switch self {
            case .continuousOnly: return "常時録画"
            case .eventOnly: return "イベント記録"
            case .continuousAndEvent: return "常時＋イベント"
            }
        }
    }
    public var mode: Mode = .continuousAndEvent
    public var frameRateIndex = 0
    public var eventWindowIndex = 10
    public var audioEnabled = true
    public var historyHoursIndex = 1
    public var historyDoubleRate = false
    public var overwriteContinuous = true
    public var overwriteEvent = true
    public var overwriteHistory = true
    public var beepEnabled = true
    public var gSensorEnabled = true
    public var multiBatteryConnected = false
    public var easyMode = true
    public var shockSensitivity = 5
    public var accelerationSensitivity = 5
    public var steeringSensitivity = 5
    public var cardID = ""
    /// The card's four-digit password (1000～9999); nil = none. Stored behind the card ID, see `CardPassword`.
    public var password: Int?
    public init() {}

    /// State of a factory-fresh card. NOT what the dialog's 「初期設定に戻す」 produces: see `resettingToDialogDefaults()`.
    public static let factoryDefault = RecordingSettings()
    /// Longest card ID the original dialog accepts (longer text makes it refuse the save).
    public static let maxCardIDLength = RecordingSettingsTables.maxCardIDLength

    /// The dialog disables some controls depending on the mode and stores the forced value; this reproduces that.
    public func normalized() -> RecordingSettings {
        var s = self
        if s.mode == .eventOnly { s.overwriteContinuous = false }
        if s.mode == .continuousOnly { s.overwriteEvent = false; s.eventWindowIndex = 0 }
        if s.easyMode && s.gSensorEnabled {
            s.accelerationSensitivity = s.shockSensitivity
            s.steeringSensitivity = s.shockSensitivity
        }
        if !s.gSensorEnabled {
            // The card keeps no sensitivity while the G sensor is off (all four bytes are zero).
            s.easyMode = false; s.shockSensitivity = 5; s.accelerationSensitivity = 5; s.steeringSensitivity = 5
        }
        return s
    }
    /// What the original's 「初期設定に戻す」 sets (observed with every control changed first): 常時＋イベント, 30コマ/秒, イベント記録時間 10+10秒,
    /// 音声あり, 履歴24時間・標準コマ数, 3つの上書きとビープ音あり, Gセンサーあり・簡単設定・感度5。SDカードID・パスワード・マルチバッテリーは触りません
    /// （日時・設置角度検出のチェックは外れます: `RecordingSettingsDraft.resettingToDialogDefaults()`）。
    /// 工場出荷カードの値（イベント30+30秒・履歴168時間）とはイベント記録時間と履歴記録時間が異なります。
    public func resettingToDialogDefaults() -> RecordingSettings {
        var s = RecordingSettings()
        s.eventWindowIndex = 0
        s.historyHoursIndex = 0
        s.cardID = cardID
        s.password = password
        s.multiBatteryConnected = multiBatteryConnected
        return s
    }
    /// In easy mode the single 感度 slider sets all three values.
    public mutating func setEasySensitivity(_ value: Int) {
        shockSensitivity = value; accelerationSensitivity = value; steeringSensitivity = value
    }
    /// Choosing a mode in the dialog also changes what the other controls offer: event-only recording only offers the five fastest
    /// rates, so the dialog moves a slower selection to 1 frame/s whatever order the two were chosen in.
    public mutating func setMode(_ newMode: Mode) {
        mode = newMode
        let last = RecordingSettingsTables.eventOnlyLastFrameRateIndex
        if newMode == .eventOnly && frameRateIndex > last { frameRateIndex = last }
    }
    public func validate() throws {
        guard (0..<RecordingSettingsTables.frameRates.count).contains(frameRateIndex) else { throw BrowserError.invalid("録画コマ数の指定が範囲外です") }
        if mode == .eventOnly && frameRateIndex > RecordingSettingsTables.eventOnlyLastFrameRateIndex {
            throw BrowserError.invalid("イベント記録のみのときは1コマ/秒より遅い録画コマ数は選べません")
        }
        guard (0..<RecordingSettingsTables.eventWindows.count).contains(eventWindowIndex) else { throw BrowserError.invalid("イベント記録時間の指定が範囲外です") }
        guard (0..<RecordingSettingsTables.historyHours.count).contains(historyHoursIndex) else { throw BrowserError.invalid("履歴記録時間の指定が範囲外です") }
        for v in [shockSensitivity, accelerationSensitivity, steeringSensitivity] where !(1...9).contains(v) {
            throw BrowserError.invalid("感度は1〜9で指定してください")
        }
        if let p = password, !CardPassword.range.contains(p) { throw BrowserError.invalid(CardPassword.Message.outOfRange) }
        guard cardID.utf8.count <= RecordingSettingsTables.maxCardIDLength,
              cardID.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            throw BrowserError.invalid("SDカードIDは半角の英数字・記号で\(RecordingSettingsTables.maxCardIDLength)文字以内にしてください")
        }
    }
    /// Names of the items that differ (used for the confirmation text before writing).
    public func differences(from other: RecordingSettings) -> [String] {
        var d: [String] = []
        if mode != other.mode { d.append("記録モード") }
        if frameRateIndex != other.frameRateIndex { d.append("録画コマ数") }
        if eventWindowIndex != other.eventWindowIndex { d.append("イベント記録時間") }
        if audioEnabled != other.audioEnabled { d.append("音声記録") }
        if historyHoursIndex != other.historyHoursIndex { d.append("履歴記録時間") }
        if historyDoubleRate != other.historyDoubleRate { d.append("履歴記録コマ数") }
        if overwriteContinuous != other.overwriteContinuous { d.append("常時録画の上書き") }
        if overwriteEvent != other.overwriteEvent { d.append("イベント録画の上書き") }
        if overwriteHistory != other.overwriteHistory { d.append("履歴記録の上書き") }
        if beepEnabled != other.beepEnabled { d.append("ビープ音") }
        if gSensorEnabled != other.gSensorEnabled { d.append("Gセンサー記録") }
        if multiBatteryConnected != other.multiBatteryConnected { d.append("マルチバッテリー") }
        if easyMode != other.easyMode { d.append("簡単設定モード") }
        if shockSensitivity != other.shockSensitivity { d.append("衝撃感度") }
        if accelerationSensitivity != other.accelerationSensitivity { d.append("急発進・急ブレーキ感度") }
        if steeringSensitivity != other.steeringSensitivity { d.append("急ハンドル感度") }
        if cardID != other.cardID { d.append("SDカードID") }
        if password != other.password { d.append("パスワード") }
        return d
    }
    /// Changing these rewrites the region table, which is what makes the original ask whether to erase the recordings.
    public func changesLayout(from other: RecordingSettings) -> Bool {
        mode != other.mode || historyHoursIndex != other.historyHoursIndex || historyDoubleRate != other.historyDoubleRate
    }
}

public enum RecordingSettingsTables {
    public struct FrameRate: Equatable, Sendable {
        public let label: String
        public let unit: UInt8, count: UInt8, parameter: UInt16
    }
    /// 録画コマ数 (dialog list order). unit 1 = per second, 2 = per minute, 3 = per hour.
    public static let frameRates: [FrameRate] = [
        FrameRate(label: "30コマ/秒", unit: 1, count: 30, parameter: 10000),
        FrameRate(label: "15コマ/秒", unit: 1, count: 15, parameter: 11000),
        FrameRate(label: "10コマ/秒", unit: 1, count: 10, parameter: 12000),
        FrameRate(label: "5コマ/秒", unit: 1, count: 5, parameter: 12000),
        FrameRate(label: "1コマ/秒", unit: 1, count: 1, parameter: 14000),
        FrameRate(label: "2コマ/分", unit: 2, count: 2, parameter: 14000),
        FrameRate(label: "1コマ/分", unit: 2, count: 1, parameter: 14000),
        FrameRate(label: "12コマ/時", unit: 3, count: 12, parameter: 14000),
        FrameRate(label: "6コマ/時", unit: 3, count: 6, parameter: 14000)]
    /// The two event records follow the continuous rate down to 1 frame/s and stay at 1 frame/s for the slower rates.
    public static func eventRate(frameRateIndex: Int) -> FrameRate {
        let r = frameRates[frameRateIndex]
        return r.unit == 1 ? r : frameRates[4]
    }
    public struct EventWindow: Equatable, Sendable {
        public let preSeconds: Int, postSeconds: Int
        public var label: String { "トリガー前\(preSeconds)秒＋後\(postSeconds)秒" }
    }
    /// イベント記録時間 (dialog list order).
    public static let eventWindows: [EventWindow] = [
        EventWindow(preSeconds: 10, postSeconds: 10), EventWindow(preSeconds: 12, postSeconds: 8), EventWindow(preSeconds: 15, postSeconds: 5),
        EventWindow(preSeconds: 18, postSeconds: 12), EventWindow(preSeconds: 20, postSeconds: 10), EventWindow(preSeconds: 20, postSeconds: 20),
        EventWindow(preSeconds: 25, postSeconds: 15), EventWindow(preSeconds: 30, postSeconds: 10), EventWindow(preSeconds: 30, postSeconds: 20),
        EventWindow(preSeconds: 25, postSeconds: 25), EventWindow(preSeconds: 30, postSeconds: 30)]
    /// Event-only recording offers the five fastest rates (30, 15, 10, 5 and 1 frame/s) only.
    public static let eventOnlyLastFrameRateIndex = 4
    public static func availableFrameRateIndices(for mode: RecordingSettings.Mode) -> [Int] {
        let count = mode == .eventOnly ? eventOnlyLastFrameRateIndex + 1 : frameRates.count
        return Array(0..<count)
    }
    public static let historyHours = [24, 168, 480]
    /// One journal sector holds two 256-byte records, i.e. 1800 sectors per hour at one record per second.
    public static let historySectorsPerHour = 1800
    /// The original dialog writes IDs of up to 24 characters and refuses longer text without writing anything.
    public static let maxCardIDLength = 24
}

/// Six little-endian words of the control sector that delimit the normal, event and journal regions.
public struct RecordingRegionTable: Equatable, Sendable {
    public var normalStart: UInt32, normalEnd: UInt32
    public var eventStart: UInt32, eventEnd: UInt32
    public var journalStart: UInt32, journalEnd: UInt32
    public static let offset = 0x1BE
    public init(normalStart: UInt32, normalEnd: UInt32, eventStart: UInt32, eventEnd: UInt32, journalStart: UInt32, journalEnd: UInt32) {
        self.normalStart = normalStart; self.normalEnd = normalEnd; self.eventStart = eventStart; self.eventEnd = eventEnd
        self.journalStart = journalStart; self.journalEnd = journalEnd
    }
    init(sector s: [UInt8]) {
        var words = [UInt32](repeating: 0, count: 6)
        for i in 0..<6 {
            var v: UInt32 = 0
            for b in 0..<4 { v |= UInt32(s[RecordingRegionTable.offset + i * 4 + b]) << UInt32(b * 8) }
            words[i] = v
        }
        self.init(normalStart: words[0], normalEnd: words[1], eventStart: words[2], eventEnd: words[3], journalStart: words[4], journalEnd: words[5])
    }
    func write(into s: inout [UInt8]) {
        let words = [normalStart, normalEnd, eventStart, eventEnd, journalStart, journalEnd]
        for (i, w) in words.enumerated() { for b in 0..<4 { s[RecordingRegionTable.offset + i * 4 + b] = UInt8(truncatingIfNeeded: w >> UInt32(b * 8)) } }
    }
    /// First sector that holds recordings, whichever region(s) exist.
    public var firstRecordSector: UInt32 { normalStart != 0 ? normalStart : eventStart }

    /// The table the original dialog computes. The journal keeps its last sector; its size follows the history settings, the event region
    /// ends just before it, and in 常時＋イベント mode the normal region takes 71 % of the space below the journal in 12-sector units.
    public static func standard(mode: RecordingSettings.Mode, historyHoursIndex: Int, doubleRate: Bool,
                                firstRecordSector first: UInt32, journalEnd: UInt32) -> RecordingRegionTable? {
        guard (0..<RecordingSettingsTables.historyHours.count).contains(historyHoursIndex) else { return nil }
        let hours = UInt64(RecordingSettingsTables.historyHours[historyHoursIndex])
        let sectors = hours * UInt64(RecordingSettingsTables.historySectorsPerHour) * (doubleRate ? 2 : 1)
        let last = UInt64(journalEnd)
        guard sectors <= last, first != 0, last - sectors + 1 > UInt64(first) + 24 else { return nil }
        let js = last - sectors + 1, before = js - 1
        func u(_ v: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: v) }
        switch mode {
        case .continuousAndEvent:
            let ne = js * 71 / 1200 * 12
            guard ne > UInt64(first), ne < before else { return nil }
            return RecordingRegionTable(normalStart: first, normalEnd: u(ne), eventStart: u(ne + 1), eventEnd: u(before), journalStart: u(js), journalEnd: journalEnd)
        case .eventOnly:
            return RecordingRegionTable(normalStart: 0, normalEnd: 0, eventStart: first, eventEnd: u(before), journalStart: u(js), journalEnd: journalEnd)
        case .continuousOnly:
            return RecordingRegionTable(normalStart: first, normalEnd: u(before), eventStart: 0, eventEnd: 0, journalStart: u(js), journalEnd: journalEnd)
        }
    }
}

public struct RecordingSettingsSnapshot: Equatable, Sendable {
    public let settings: RecordingSettings
    public let regions: RecordingRegionTable
    /// True when the region table is exactly what the original computes for these settings; layout changes are only offered then.
    public let regionsAreStandard: Bool
    public let generation: UInt32
}
public struct RecordingSettingsEdit: Equatable, Sendable {
    public let settings: RecordingSettings
    public let control: Data
    public let channel: Data
    public let layoutChanged: Bool
    public let changes: [String]
}

public enum RecordingSettingsCodec {
    static let marker: [UInt8] = Array("YP_FORMAT_1.01__\0".utf8)
    enum Offset {
        static let generation = 0x00, checksum = 0x12, channelCount = 0x14
        static let records = 0x21, recordSize = 8, recordBlockStart = 0x20, recordBlockEnd = 0x39
        static let overwriteContinuous = 0x3A, overwriteEvent = 0x3B, overwriteHistory = 0x3C
        static let recordMode = 0x3E, audio = 0x3F
        static let gSensor = 0x46, easy = 0x47, shock = 0x48, acceleration = 0x49, steering = 0x4A
        static let beep = 0x50, batteryA = 0x54, cardID = 0x66, cardIDEnd = 0x88, historyRate = 0x90, batteryB = 0x97
        /// Password flag and word follow the card ID text (CardPassword); the five bytes up to the history-rate byte stay zero.
        static let passwordFlag = CardPassword.flagOffset, passwordEnd = 0x8B, reservedEnd = 0x90
        static let generationCounters = [0x1E0, 0x1E4, 0x1E8], generationTail = 0x1FF
    }

    /// 2 × (sum of every control-sector byte except the checksum itself + sum of the channel sector(s)), modulo 65536.
    public static func checksum(control: [UInt8], channels: [[UInt8]]) -> UInt16 {
        var sum: UInt32 = 0
        for (i, b) in control.enumerated() where i != Offset.checksum && i != Offset.checksum + 1 { sum &+= UInt32(b) }
        for channel in channels { for b in channel { sum &+= UInt32(b) } }
        return UInt16(truncatingIfNeeded: sum &* 2)
    }

    struct Record { var parameter: UInt16, unit: UInt8, count: UInt8, window: UInt16 }
    static func record(_ s: [UInt8], _ index: Int) -> Record? {
        let o = Offset.records + index * Offset.recordSize
        guard s[o] == 0x0B, s[o + 5] == 0 else { return nil }
        return Record(parameter: UInt16(s[o + 1]) | UInt16(s[o + 2]) << 8, unit: s[o + 3], count: s[o + 4], window: UInt16(s[o + 6]) | UInt16(s[o + 7]) << 8)
    }
    static func put(_ r: Record, _ index: Int, into s: inout [UInt8]) {
        let o = Offset.records + index * Offset.recordSize
        s[o] = 0x0B; s[o + 1] = UInt8(r.parameter & 0xFF); s[o + 2] = UInt8(r.parameter >> 8); s[o + 3] = r.unit; s[o + 4] = r.count; s[o + 5] = 0
        s[o + 6] = UInt8(r.window & 0xFF); s[o + 7] = UInt8(r.window >> 8)
    }
    static func effectiveRate(_ r: Record) -> Int { r.unit == 1 ? Int(r.count) : 1 }
    static func counter(_ s: [UInt8], _ o: Int) -> UInt32 {
        var v: UInt32 = 0
        for b in 0..<4 { v |= UInt32(s[o + b]) << UInt32(b * 8) }
        return v
    }
    static func setCounter(_ v: UInt32, _ o: Int, into s: inout [UInt8]) { for b in 0..<4 { s[o + b] = UInt8(truncatingIfNeeded: v >> UInt32(b * 8)) } }

    public static func decode(control: Data, channel: Data) throws -> RecordingSettingsSnapshot {
        guard control.count == 512, channel.count == 512 else { throw BrowserError.invalid("管理セクターは512バイトである必要があります") }
        let c = [UInt8](control), ch = [UInt8](channel)
        guard Array(c[1..<18]) == marker, Array(c[0x1EC..<0x1FD]) == marker else { throw BrowserError.unsupported("管理領域の識別子が一致しません") }
        guard c[Offset.channelCount] == 1 else { throw BrowserError.unsupported("録画設定の編集は単一チャンネルのカードのみ検証済みです") }
        let stored = UInt16(c[Offset.checksum]) | UInt16(c[Offset.checksum + 1]) << 8
        guard stored == checksum(control: c, channels: [ch]) else { throw BrowserError.unsupported("管理領域のチェックサムが一致しません（この版が検証した形式ではありません）") }
        guard Array(ch[Offset.recordBlockStart..<Offset.recordBlockEnd]) == Array(c[Offset.recordBlockStart..<Offset.recordBlockEnd]) else {
            throw BrowserError.unsupported("チャンネル設定セクターが管理領域と一致しません")
        }
        var s = RecordingSettings()
        guard let normal = record(c, 0), let pre = record(c, 1), let post = record(c, 2), normal.window == 0 else { throw BrowserError.unsupported("録画レコード形式を認識できません") }
        guard let rate = RecordingSettingsTables.frameRates.firstIndex(where: { $0.unit == normal.unit && $0.count == normal.count && $0.parameter == normal.parameter }) else {
            throw BrowserError.unsupported("未知の録画コマ数です")
        }
        s.frameRateIndex = rate
        let event = RecordingSettingsTables.eventRate(frameRateIndex: rate)
        for r in [pre, post] where r.unit != event.unit || r.count != event.count || r.parameter != event.parameter { throw BrowserError.unsupported("イベントレコードの録画コマ数が想定と異なります") }
        let eff = effectiveRate(pre)
        guard eff > 0, Int(pre.window) % eff == 0, Int(post.window) % eff == 0 else { throw BrowserError.unsupported("イベント記録時間を認識できません") }
        let window = RecordingSettingsTables.EventWindow(preSeconds: Int(pre.window) / eff, postSeconds: Int(post.window) / eff)
        guard let windowIndex = RecordingSettingsTables.eventWindows.firstIndex(of: window) else { throw BrowserError.unsupported("未知のイベント記録時間です") }
        s.eventWindowIndex = windowIndex
        switch c[Offset.recordMode] {
        case 3: s.mode = .continuousAndEvent
        case 2: s.mode = .eventOnly
        case 1: s.mode = .continuousOnly
        default: throw BrowserError.unsupported("未知の記録モードです")
        }
        func flag(_ o: Int, on: UInt8, off: UInt8) throws -> Bool {
            if c[o] == on { return true }
            if c[o] == off { return false }
            throw BrowserError.unsupported(String(format: "管理領域の設定値を認識できません（+0x%02lX）", o))
        }
        s.overwriteContinuous = try flag(Offset.overwriteContinuous, on: 2, off: 1)
        s.overwriteEvent = try flag(Offset.overwriteEvent, on: 2, off: 1)
        s.overwriteHistory = try flag(Offset.overwriteHistory, on: 2, off: 1)
        s.audioEnabled = try flag(Offset.audio, on: 1, off: 2)
        s.beepEnabled = try flag(Offset.beep, on: 3, off: 0)
        s.historyDoubleRate = try flag(Offset.historyRate, on: 1, off: 0)
        s.gSensorEnabled = try flag(Offset.gSensor, on: 5, off: 4)
        if s.gSensorEnabled {
            s.easyMode = try flag(Offset.easy, on: 2, off: 1)
            let values = [c[Offset.shock], c[Offset.acceleration], c[Offset.steering]]
            guard values.allSatisfy({ (1...9).contains($0) }) else { throw BrowserError.unsupported("感度の値が範囲外です") }
            s.shockSensitivity = Int(values[0]); s.accelerationSensitivity = Int(values[1]); s.steeringSensitivity = Int(values[2])
        } else {
            guard c[Offset.easy] == 0, c[Offset.shock] == 0, c[Offset.acceleration] == 0, c[Offset.steering] == 0 else { throw BrowserError.unsupported("Gセンサー無効時の感度値が想定と異なります") }
            s.easyMode = false
        }
        switch (c[Offset.batteryA], c[Offset.batteryB]) {
        case (0, 0): s.multiBatteryConnected = false
        case (1, 2): s.multiBatteryConnected = true
        default: throw BrowserError.unsupported("マルチバッテリー設定を認識できません")
        }
        let idBytes = Array(c[Offset.cardID..<Offset.cardIDEnd])
        let text = idBytes.prefix(while: { $0 != 0 })
        guard idBytes.dropFirst(text.count).allSatisfy({ $0 == 0 }), text.allSatisfy({ (0x21...0x7E).contains($0) }) else { throw BrowserError.unsupported("SDカードIDの形式を認識できません") }
        s.cardID = String(decoding: text, as: UTF8.self)
        let passwordWord = UInt16(c[CardPassword.wordOffset]) | UInt16(c[CardPassword.wordOffset + 1]) << 8
        s.password = try CardPassword.decode(flag: c[Offset.passwordFlag], word: passwordWord)
        guard c[Offset.passwordEnd..<Offset.reservedEnd].allSatisfy({ $0 == 0 }) else { throw BrowserError.unsupported("パスワード領域の後ろに想定外の値があります") }

        let regions = RecordingRegionTable(sector: c)
        let sectors = Int64(regions.journalEnd) - Int64(regions.journalStart) + 1
        let perHour = Int64(RecordingSettingsTables.historySectorsPerHour) * (s.historyDoubleRate ? 2 : 1)
        var standard = false
        if let index = RecordingSettingsTables.historyHours.firstIndex(where: { Int64($0) * perHour == sectors }) {
            s.historyHoursIndex = index
            standard = RecordingRegionTable.standard(mode: s.mode, historyHoursIndex: index, doubleRate: s.historyDoubleRate,
                                                     firstRecordSector: regions.firstRecordSector, journalEnd: regions.journalEnd) == regions
        }
        let generation = counter(c, Offset.generationCounters[0])
        return RecordingSettingsSnapshot(settings: s, regions: regions, regionsAreStandard: standard, generation: generation)
    }

    /// Read-modify-write: only the modelled fields change; every other byte of both sectors is kept.
    public static func apply(_ requested: RecordingSettings, control: Data, channel: Data) throws -> RecordingSettingsEdit {
        let old = try decode(control: control, channel: channel)
        let s = requested.normalized()
        try s.validate()
        var c = [UInt8](control), ch = [UInt8](channel)
        let rate = RecordingSettingsTables.frameRates[s.frameRateIndex], event = RecordingSettingsTables.eventRate(frameRateIndex: s.frameRateIndex)
        let window = RecordingSettingsTables.eventWindows[s.eventWindowIndex]
        let eventRecord = Record(parameter: event.parameter, unit: event.unit, count: event.count, window: 0)
        let eff = effectiveRate(eventRecord)
        put(Record(parameter: rate.parameter, unit: rate.unit, count: rate.count, window: 0), 0, into: &c)
        var pre = eventRecord, post = eventRecord
        pre.window = UInt16(window.preSeconds * eff); post.window = UInt16(window.postSeconds * eff)
        put(pre, 1, into: &c); put(post, 2, into: &c)
        c[Offset.overwriteContinuous] = s.overwriteContinuous ? 2 : 1
        c[Offset.overwriteEvent] = s.overwriteEvent ? 2 : 1
        c[Offset.overwriteHistory] = s.overwriteHistory ? 2 : 1
        switch s.mode {
        case .continuousAndEvent: c[Offset.recordMode] = 3
        case .eventOnly: c[Offset.recordMode] = 2
        case .continuousOnly: c[Offset.recordMode] = 1
        }
        c[Offset.audio] = s.audioEnabled ? 1 : 2
        c[Offset.beep] = s.beepEnabled ? 3 : 0
        c[Offset.historyRate] = s.historyDoubleRate ? 1 : 0
        if s.gSensorEnabled {
            c[Offset.gSensor] = 5; c[Offset.easy] = s.easyMode ? 2 : 1
            c[Offset.shock] = UInt8(s.shockSensitivity); c[Offset.acceleration] = UInt8(s.accelerationSensitivity); c[Offset.steering] = UInt8(s.steeringSensitivity)
        } else {
            c[Offset.gSensor] = 4; c[Offset.easy] = 0; c[Offset.shock] = 0; c[Offset.acceleration] = 0; c[Offset.steering] = 0
        }
        c[Offset.batteryA] = s.multiBatteryConnected ? 1 : 0
        c[Offset.batteryB] = s.multiBatteryConnected ? 2 : 0
        let id = Array(s.cardID.utf8)
        for i in Offset.cardID..<Offset.reservedEnd { c[i] = i < Offset.cardIDEnd && i - Offset.cardID < id.count ? id[i - Offset.cardID] : 0 }
        for (k, b) in CardPassword.encode(s.password).enumerated() { c[Offset.passwordFlag + k] = b }
        let layoutChanged = s.changesLayout(from: old.settings)
        if layoutChanged {
            guard old.regionsAreStandard else { throw BrowserError.unsupported("領域表がこの版の既知の計算式と一致しないため、記録モード・履歴の変更は書き込めません") }
            guard let table = RecordingRegionTable.standard(mode: s.mode, historyHoursIndex: s.historyHoursIndex, doubleRate: s.historyDoubleRate,
                                                            firstRecordSector: old.regions.firstRecordSector, journalEnd: old.regions.journalEnd) else {
                throw BrowserError.invalid("この容量では指定した記録モード・履歴時間の領域を確保できません")
            }
            table.write(into: &c)
            let next = generationAfterLayoutChange(old.generation)
            c[Offset.generation] = UInt8(truncatingIfNeeded: next); c[Offset.generationTail] = UInt8(truncatingIfNeeded: next)
            for o in Offset.generationCounters { setCounter(next, o, into: &c) }
        }
        for i in Offset.recordBlockStart..<Offset.recordBlockEnd { ch[i] = c[i] }
        let sum = checksum(control: c, channels: [ch])
        c[Offset.checksum] = UInt8(sum & 0xFF); c[Offset.checksum + 1] = UInt8(sum >> 8)
        return RecordingSettingsEdit(settings: s, control: Data(c), channel: Data(ch), layoutChanged: layoutChanged, changes: s.differences(from: old.settings))
    }

    /// A layout-changing save of the original raises a card that still has the factory value 1 to 2 and leaves any other value alone
    /// (observed with starting values 1, 2 and 5; saves that do not change the layout never touch it).
    static func generationAfterLayoutChange(_ old: UInt32) -> UInt32 { old < 2 ? 2 : old }
}
