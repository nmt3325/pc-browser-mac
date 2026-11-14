import Foundation

/// The four-digit card password of the original application (its dialog 106 and the 「パスワード」 box of 記録設定).
///
/// Everything here was established by driving the original (Wine, writes swallowed): the control sector keeps a flag byte at +0x88
/// (0 = no password, 1 = password) followed by the little-endian word `3 × password + 1639`; the original asks for the password
/// when it loads such a card and refuses to load it on a wrong or cancelled entry. The password is only a gate in the application
/// (the recordings themselves are not encrypted), which is why the layout was verifiable from the control sector alone.
/// Only the Q-01 family (dialog class 81) was observed, so the gate and the stored form are applied to that family only.
public enum CardPassword {
    public static let range = 1000...9999
    /// The edit box accepts at most four characters.
    public static let maxLength = 4
    public static let flagOffset = 0x88
    public static let wordOffset = 0x89
    static let multiplier = 3, bias = 1639

    /// Texts of the original's message boxes (kept verbatim).
    public enum Message {
        public static let wrong = "パスワードが間違っています。"
        public static let outOfRange = "パスワードは1000～9999の範囲で入力してください。"
        public static let tooLong = "4 文字以内で入力してください。"
        public static let prompt = "SDカードのパスワードを入力してください。"
        public static let reenter = "パスワードが変更されています。\n確認のためもう一度パスワードを入力してください。"
        public static let confirmClear = "パスワードがクリアされます。\nよろしいですか？"
    }

    /// The 16-bit value stored behind the flag byte.
    public static func storedWord(for password: Int) -> UInt16 { UInt16(truncatingIfNeeded: password * multiplier + bias) }

    /// Reads the stored form. nil = no password. Every pattern the original does not write is refused rather than guessed.
    public static func decode(flag: UInt8, word: UInt16) throws -> Int? {
        switch flag {
        case 0:
            guard word == 0 else { throw BrowserError.unsupported("パスワード未設定のカードにパスワード値が残っています") }
            return nil
        case 1:
            let raw = Int(word) - bias
            guard raw >= 0, raw % multiplier == 0, range.contains(raw / multiplier) else {
                throw BrowserError.unsupported("パスワードの保存形式を認識できません")
            }
            return raw / multiplier
        default:
            throw BrowserError.unsupported("パスワードの保存形式を認識できません")
        }
    }
    /// The three bytes (flag, word low, word high) the original stores.
    public static func encode(_ password: Int?) -> [UInt8] {
        guard let p = password else { return [0, 0, 0] }
        let w = storedWord(for: p)
        return [1, UInt8(w & 0xFF), UInt8(w >> 8)]
    }

    /// What the edit box holds, judged the way the original judges it when 「SDカードへ保存」 is pressed.
    public enum Entry: Equatable, Sendable {
        /// Empty box: no password.
        case none
        case password(Int)
        /// More than four characters (the original's MFC length check).
        case tooLong
        /// Not a number in 1000～9999 (letters, 3-digit values, 0999 …).
        case outOfRange
        public var message: String? {
            switch self {
            case .none, .password: return nil
            case .tooLong: return Message.tooLong
            case .outOfRange: return Message.outOfRange
            }
        }
        /// The number when the box holds a valid password, else nil.
        public var value: Int? { if case .password(let p) = self { return p } else { return nil } }
    }
    public static func parse(_ text: String) -> Entry {
        if text.isEmpty { return .none }
        if text.count > maxLength { return .tooLong }
        guard text.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let value = Int(text), range.contains(value) else { return .outOfRange }
        return .password(value)
    }

    /// What the original asks for after the password box was edited and before it offers to save.
    public enum Change: Equatable, Sendable {
        case none
        /// A password was set or changed: it must be typed again, a mismatch aborts with 「パスワードが間違っています。」.
        case reenter(Int)
        /// The password was emptied: 「パスワードがクリアされます。 よろしいですか？」.
        case confirmClear
        public static func required(old: Int?, new: Int?) -> Change {
            switch (old, new) {
            case (nil, nil): return .none
            case (let o?, let n?) where o == n: return .none
            case (_, let n?): return .reenter(n)
            case (_?, nil): return .confirmClear
            }
        }
    }
    /// True when the typed confirmation names the same password.
    public static func confirms(_ typed: String, expected: Int) -> Bool { parse(typed) == .password(expected) }
    /// True when an entry at the card's load prompt unlocks it.
    public static func unlocks(_ typed: String, stored: Int) -> Bool { confirms(typed, expected: stored) }

    /// The password a control sector asks for when the card is opened; nil when it has none, is not a Q-01-family card or is not understood.
    public static func required(controlSector sector: Data) -> Int? {
        guard sector.count == 512, let model = DeviceModelTable.identify(controlSector: sector), model.dialogClass == 81 else { return nil }
        let base = sector.startIndex
        let word = UInt16(sector[base + wordOffset]) | UInt16(sector[base + wordOffset + 1]) << 8
        guard let decoded = try? decode(flag: sector[base + flagOffset], word: word) else { return nil }
        return decoded
    }
    /// Looks the control sector up like the catalog does and reads only that sector.
    public static func required(in source: any ByteSource) -> Int? {
        guard let header = try? ControlHeader.locate(in: source), let sector = try? source.read(at: header.sector * 512, count: 512) else { return nil }
        return required(controlSector: sector)
    }
}
