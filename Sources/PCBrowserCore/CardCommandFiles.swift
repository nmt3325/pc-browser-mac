import Foundation
import Darwin

/// Calendar fields exactly as the original writes them into CONFIG\TIME.INI (the PC's local time, no time zone).
public struct CardLocalTime: Equatable, Sendable {
    public let year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) throws {
        guard (2000...2099).contains(year), (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            throw BrowserError.invalid("日時の指定が範囲外です")
        }
        guard day >= 1, day <= CardLocalTime.daysInMonth(year: year, month: month) else { throw BrowserError.invalid("日付の指定が範囲外です") }
        self.year = year; self.month = month; self.day = day; self.hour = hour; self.minute = minute; self.second = second
    }
    public init(date: Date, timeZone: TimeZone = TimeZone.current) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        try self.init(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0, hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
    }
    static func daysInMonth(year: Int, month: Int) -> Int {
        let lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        return month == 2 && leap ? 29 : lengths[month - 1]
    }
    /// `YYYY.MM.DD;HH:MM:SS`
    public var text: String { String(format: "%04ld.%02ld.%02ld;%02ld:%02ld:%02ld", year, month, day, hour, minute, second) }
}

extension CardLocalTime {
    /// Parses `YYYY.MM.DD;HH:MM:SS`; nil for anything else (including impossible dates).
    public static func parse(_ text: String) -> CardLocalTime? {
        let t = Array(text.utf8)
        guard t.count == 19, t[4] == 0x2E, t[7] == 0x2E, t[10] == 0x3B, t[13] == 0x3A, t[16] == 0x3A else { return nil }
        func number(_ from: Int, _ to: Int) -> Int? {
            var value = 0
            for i in from..<to {
                guard t[i] >= 0x30, t[i] <= 0x39 else { return nil }
                value = value * 10 + Int(t[i] - 0x30)
            }
            return value
        }
        guard let y = number(0, 4), let mo = number(5, 7), let d = number(8, 10), let h = number(11, 13), let mi = number(14, 16), let s = number(17, 19) else { return nil }
        return try? CardLocalTime(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    }
    /// The LOCALTIME line of a TIME.INI file.
    public static func parseIni(_ data: Data) -> CardLocalTime? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // "\r\n" is ONE Character in Swift, so splitting the String by Character would never separate CRLF lines; split the scalars instead.
        for raw in text.components(separatedBy: CharacterSet.newlines) {
            let line = raw.trimmingCharacters(in: CharacterSet.whitespaces)
            if line.uppercased().hasPrefix("LOCALTIME=") { return CardLocalTime.parse(String(line.dropFirst(10))) }
        }
        return nil
    }
}

/// What the card's CONFIG folder holds for the two command files the original's recording-settings dialog manages.
public struct CardCommandState: Equatable, Sendable {
    /// CONFIG\TIME.INI exists (the original opens its date/time row ticked in that case).
    public let timeFileExists: Bool
    /// The LOCALTIME line of that file when it is readable.
    public let time: CardLocalTime?
    /// CONFIG\SELFADJ.INI exists (the original opens its 「設置角度検出を実行」 box ticked in that case).
    public let angleDetectionRequested: Bool
    public init(timeFileExists: Bool, time: CardLocalTime?, angleDetectionRequested: Bool) {
        self.timeFileExists = timeFileExists; self.time = time; self.angleDetectionRequested = angleDetectionRequested
    }
    public static let absent = CardCommandState(timeFileExists: false, time: nil, angleDetectionRequested: false)
}

/// What to do with CONFIG\TIME.INI: leave it alone, write the picker's time into it, or delete it.
public enum CardTimeRequest: Equatable, Sendable {
    case keep
    case set(CardLocalTime)
    case remove
}
/// What to do with CONFIG\SELFADJ.INI: leave it alone, create it (empty), or delete it.
public enum CardAngleRequest: Equatable, Sendable {
    case keep
    case request
    case cancel
}

/// Command files that the original's 「日時設定」 and 「設置角度検出」 options leave in (or remove from) the card's CONFIG folder.
/// Observed on the original: ticking 「日時設定: 設定する」 makes Save write TIME.INI with the picker's time, un-ticking it when the file
/// exists deletes it; 「設置角度検出を実行」 creates an empty SELFADJ.INI, un-ticking deletes it. The recorder reads them at the next power-on;
/// their effect on a real recorder could not be verified here, only the files the original produces.
public enum CardCommandFile: Equatable, Sendable {
    case writeTime(CardLocalTime)
    case removeTime
    case requestAngleDetection
    case cancelAngleDetection
    public static let directoryName = "CONFIG"
    public var fileName: String {
        switch self {
        case .writeTime, .removeTime: return "TIME.INI"
        case .requestAngleDetection, .cancelAngleDetection: return "SELFADJ.INI"
        }
    }
    public var path: String { CardCommandFile.directoryName + "/" + fileName }
    /// 8.3 directory-entry name (11 bytes, space padded).
    var shortName: [UInt8] {
        switch self {
        case .writeTime, .removeTime: return Array("TIME    INI".utf8)
        case .requestAngleDetection, .cancelAngleDetection: return Array("SELFADJ INI".utf8)
        }
    }
    /// `[SET]`, CR LF, `LOCALTIME=YYYY.MM.DD;HH:MM:SS` without a trailing newline (36 bytes); SELFADJ.INI is created empty; nil for removals.
    public var contents: Data? {
        switch self {
        case .writeTime(let t): return Data(("[SET]\r\nLOCALTIME=" + t.text).utf8)
        case .requestAngleDetection: return Data()
        case .removeTime, .cancelAngleDetection: return nil
        }
    }
    public var isRemoval: Bool { contents == nil }
    /// Stable machine-readable name used by the command-line report.
    public var action: String {
        switch self {
        case .writeTime: return "writeTime"
        case .removeTime: return "removeTime"
        case .requestAngleDetection: return "requestAngleDetection"
        case .cancelAngleDetection: return "cancelAngleDetection"
        }
    }
    /// What has to happen to turn `state` into the requested one. A time file that already holds the requested time is not rewritten
    /// (the original rewrites it with identical content, which leaves the same logical result).
    public static func actions(from state: CardCommandState, time: CardTimeRequest, angle: CardAngleRequest) -> [CardCommandFile] {
        var result: [CardCommandFile] = []
        switch time {
        case .keep: break
        case .set(let t): if !(state.timeFileExists && state.time == t) { result.append(.writeTime(t)) }
        case .remove: if state.timeFileExists { result.append(.removeTime) }
        }
        switch angle {
        case .keep: break
        case .request: if !state.angleDetectionRequested { result.append(.requestAngleDetection) }
        case .cancel: if state.angleDetectionRequested { result.append(.cancelAngleDetection) }
        }
        return result
    }
}

protocol Fat16Storage: AnyObject {
    func read(at offset: UInt64, count: Int) throws -> Data
    func write(_ data: Data, at offset: UInt64) throws
}

final class FileFat16Storage: Fat16Storage {
    private let fd: Int32
    init(fd: Int32) { self.fd = fd }
    func read(at offset: UInt64, count: Int) throws -> Data { try RecordingSettingsStore.preadExactly(fd: fd, offset: offset, count: count) }
    func write(_ data: Data, at offset: UInt64) throws { try RecordingSettingsStore.pwriteAll(fd: fd, data: data, offset: offset) }
}

/// Minimal FAT16 writer that can create or replace one small file inside the root-level CONFIG folder of a card IMAGE COPY.
/// It refuses anything it does not fully understand (FAT12/FAT32, mismatching FAT copies, damaged chains, read-only targets, a full folder).
final class Fat16Volume {
    enum Directory { case root, cluster(UInt16) }
    struct Slot { let offset: UInt64; let entry: Data }

    let storage: Fat16Storage
    let partitionEnd: UInt64
    let fatStart: UInt64, fatBytes: Int, fatCount: Int
    let rootStart: UInt64, rootBytes: Int
    let dataStart: UInt64, bytesPerCluster: Int, clusterCount: Int
    private(set) var fat: [UInt16]
    private var fatRaw: Data

    init(storage: Fat16Storage, diskBytes: UInt64) throws {
        self.storage = storage
        let partitions = try PartitionTable.parse(try storage.read(at: 0, count: 512), diskBytes: diskBytes)
        guard let part = partitions.first(where: { [0x04, 0x06, 0x0E].contains($0.type) }) else { throw BrowserError.unsupported("FAT16の設定領域がありません") }
        let boot = Bytes(try storage.read(at: part.start, count: 512))
        let bytesPerSector = Int(try boot.le16(11)), perCluster = Int(try boot.u8(13)), reserved = Int(try boot.le16(14)), fats = Int(try boot.u8(16))
        let rootEntries = Int(try boot.le16(17)), fatSectors = Int(try boot.le16(22))
        var total = Int(try boot.le16(19))
        if total == 0 { total = Int(try boot.le32(32)) }
        guard bytesPerSector == 512, [1, 2, 4, 8, 16, 32, 64, 128].contains(perCluster), (1...2).contains(fats), rootEntries > 0, rootEntries % 16 == 0,
              rootEntries <= 4096, reserved > 0, fatSectors > 0, total > 0, try boot.le16(510) == 0xAA55 else {
            throw BrowserError.unsupported("未対応のFAT16レイアウトです")
        }
        let rootSectors = rootEntries / 16
        let metadata = reserved + fats * fatSectors + rootSectors
        guard total > metadata, UInt64(total) * 512 <= part.end - part.start else { throw BrowserError.invalid("FAT16の管理領域がパーティションを超えています") }
        let clusters = (total - metadata) / perCluster
        guard clusters >= 4085, clusters < 65525, fatSectors * 256 >= clusters + 2 else { throw BrowserError.unsupported("FAT16以外の形式、またはFATの大きさが不正です") }
        self.partitionEnd = part.end
        self.fatStart = part.start + UInt64(reserved * 512)
        self.fatBytes = fatSectors * 512
        self.fatCount = fats
        self.rootStart = fatStart + UInt64(fats * fatBytes)
        self.rootBytes = rootSectors * 512
        self.dataStart = rootStart + UInt64(rootBytes)
        self.bytesPerCluster = perCluster * 512
        self.clusterCount = clusters
        let raw = try storage.read(at: fatStart, count: fatBytes)
        if fats == 2 {
            let second = try storage.read(at: fatStart + UInt64(fatBytes), count: fatBytes)
            guard second == raw else { throw BrowserError.unsupported("2面のFATが一致しないため書き込みません") }
        }
        self.fatRaw = Data(raw)
        var table = [UInt16](repeating: 0, count: raw.count / 2)
        let b = Bytes(raw)
        for i in 0..<table.count { table[i] = try b.le16(i * 2) }
        self.fat = table
    }

    private func clusterOffset(_ n: UInt16) -> UInt64 { dataStart + UInt64(Int(n) - 2) * UInt64(bytesPerCluster) }
    private func isDataCluster(_ n: UInt16) -> Bool { n >= 2 && Int(n) < clusterCount + 2 }

    func chain(from first: UInt16) throws -> [UInt16] {
        var result: [UInt16] = []
        var n = first
        var seen = Set<UInt16>()
        while n >= 2 && n < 0xFFF8 {
            guard isDataCluster(n), !seen.contains(n) else { throw BrowserError.invalid("FATチェーンが壊れています") }
            seen.insert(n); result.append(n)
            guard result.count <= clusterCount else { throw BrowserError.invalid("FATチェーンが長すぎます") }
            n = fat[Int(n)]
        }
        guard n >= 0xFFF8 || first < 2 else { throw BrowserError.invalid("FATチェーンが途中で切れています") }
        return result
    }

    /// Offsets of every 32-byte slot of a directory, in order.
    private func slots(of directory: Directory) throws -> [Slot] {
        var regions: [(UInt64, Int)] = []
        switch directory {
        case .root: regions = [(rootStart, rootBytes)]
        case .cluster(let first):
            for c in try chain(from: first) { regions.append((clusterOffset(c), bytesPerCluster)) }
        }
        var result: [Slot] = []
        for (start, length) in regions {
            let data = try storage.read(at: start, count: length)
            var i = 0
            while i + 32 <= length { result.append(Slot(offset: start + UInt64(i), entry: data.subdata(in: i..<(i + 32)))); i += 32 }
        }
        return result
    }

    private func find(_ name: [UInt8], in directory: Directory) throws -> Slot? {
        for slot in try slots(of: directory) {
            let first = slot.entry[slot.entry.startIndex]
            if first == 0 { return nil }
            if first == 0xE5 { continue }
            let attribute = slot.entry[slot.entry.startIndex + 11]
            if attribute == 0x0F || attribute & 0x08 != 0 { continue }
            if Array(slot.entry.prefix(11)) == name { return slot }
        }
        return nil
    }

    private func clusterOfEntry(_ entry: Data) throws -> UInt16 {
        let b = Bytes(entry)
        guard try b.le16(20) == 0 else { throw BrowserError.unsupported("FAT32形式のクラスター番号は扱えません") }
        return try b.le16(26)
    }

    private func configDirectory() throws -> Directory {
        guard let slot = try find(Array("CONFIG     ".utf8), in: .root), slot.entry[slot.entry.startIndex + 11] & 0x10 != 0 else {
            throw BrowserError.unsupported("カード内にCONFIGフォルダーがありません")
        }
        let first = try clusterOfEntry(slot.entry)
        guard isDataCluster(first) else { throw BrowserError.invalid("CONFIGフォルダーの位置が不正です") }
        return .cluster(first)
    }

    /// File contents (exactly `size` bytes) of CONFIG/<name>, or nil when the file does not exist.
    func readConfigFile(_ name: [UInt8]) throws -> Data? {
        guard let slot = try find(name, in: try configDirectory()) else { return nil }
        let b = Bytes(slot.entry)
        let size = Int(try b.le32(28)), first = try clusterOfEntry(slot.entry)
        if size == 0 { return Data() }
        var out = Data()
        for c in try chain(from: first) { out.append(try storage.read(at: clusterOffset(c), count: bytesPerCluster)) }
        guard out.count >= size else { throw BrowserError.truncated("ファイルの長さがFATチェーンより長くなっています") }
        return out.prefix(size)
    }

    private static func fatTime(_ date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max((c.year ?? 1980) - 1980, 0), 127)
        let hour = c.hour ?? 0, minute = c.minute ?? 0, second = c.second ?? 0
        let month = c.month ?? 1, dayOfMonth = c.day ?? 1
        let time = (hour << 11) | (minute << 5) | (second / 2)
        let day = (year << 9) | (month << 5) | dayOfMonth
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: day))
    }

    /// Writes only the FAT sectors that changed, to every FAT copy, and remembers the new table.
    private func commitFAT(_ table: [UInt16]) throws {
        var raw = fatRaw
        for (i, value) in table.enumerated() where value != fat[i] {
            raw[i * 2] = UInt8(value & 0xFF); raw[i * 2 + 1] = UInt8(value >> 8)
        }
        var sector = 0
        while sector * 512 < fatBytes {
            let range = (sector * 512)..<((sector + 1) * 512)
            if raw.subdata(in: range) != fatRaw.subdata(in: range) {
                for copy in 0..<fatCount { try storage.write(raw.subdata(in: range), at: fatStart + UInt64(copy * fatBytes + sector * 512)) }
            }
            sector += 1
        }
        fat = table; fatRaw = raw
    }

    /// Removes CONFIG/<name>: the directory entry is marked deleted first, then its clusters are freed in every FAT copy
    /// (a crash in between leaves unreferenced clusters, never a dangling entry). Returns false when the file does not exist.
    @discardableResult
    func deleteConfigFile(_ name: [UInt8]) throws -> Bool {
        let directory = try configDirectory()
        guard let slot = try find(name, in: directory) else { return false }
        let attribute = slot.entry[slot.entry.startIndex + 11]
        guard attribute & 0x1F == 0 else { throw BrowserError.unsupported("既存のファイルが読み取り専用・隠し・システム属性またはフォルダーです") }
        var table = fat
        for c in try chain(from: try clusterOfEntry(slot.entry)) { table[Int(c)] = 0 }
        var entry = [UInt8](slot.entry)
        entry[0] = 0xE5
        try storage.write(Data(entry), at: slot.offset)
        try commitFAT(table)
        return true
    }

    /// Creates CONFIG/<name> or replaces its contents (the original uses CREATE_ALWAYS). Data first, then the FAT copies, then the directory entry.
    func writeConfigFile(_ name: [UInt8], contents: Data, now: Date) throws {
        let directory = try configDirectory()
        let existing = try find(name, in: directory)
        if let slot = existing {
            let attribute = slot.entry[slot.entry.startIndex + 11]
            guard attribute & 0x1F == 0 else { throw BrowserError.unsupported("既存のファイルが読み取り専用・隠し・システム属性またはフォルダーです") }
        }
        var table = fat
        if let slot = existing {
            for c in try chain(from: try clusterOfEntry(slot.entry)) { table[Int(c)] = 0 }
        }
        let needed = (contents.count + bytesPerCluster - 1) / bytesPerCluster
        var chosen: [UInt16] = []
        var candidate = 2
        while chosen.count < needed && candidate < clusterCount + 2 {
            if table[candidate] == 0 { chosen.append(UInt16(candidate)) }
            candidate += 1
        }
        guard chosen.count == needed else { throw BrowserError.io("カード内の空き容量が足りません") }
        for (i, c) in chosen.enumerated() { table[Int(c)] = i + 1 < chosen.count ? chosen[i + 1] : 0xFFFF }

        // Directory slot (found before anything is written so that a full folder leaves the image untouched).
        var target: Slot? = existing
        if target == nil {
            for slot in try slots(of: directory) {
                let first = slot.entry[slot.entry.startIndex]
                if first == 0 || first == 0xE5 { target = slot; break }
            }
        }
        guard let slot = target else { throw BrowserError.unsupported("CONFIGフォルダーに空きがありません") }

        for (i, c) in chosen.enumerated() {
            var block = Data(count: bytesPerCluster)
            let start = i * bytesPerCluster
            let end = min(contents.count, start + bytesPerCluster)
            if start < end { block.replaceSubrange(0..<(end - start), with: contents.subdata(in: (contents.startIndex + start)..<(contents.startIndex + end))) }
            try storage.write(block, at: clusterOffset(c))
        }
        try commitFAT(table)

        var entry = [UInt8](slot.entry)
        let (time, day) = Fat16Volume.fatTime(now)
        func put16(_ v: UInt16, _ o: Int) { entry[o] = UInt8(v & 0xFF); entry[o + 1] = UInt8(v >> 8) }
        if existing == nil {
            entry = [UInt8](repeating: 0, count: 32)
            for i in 0..<11 { entry[i] = name[i] }
            entry[11] = 0x20
            put16(time, 14); put16(day, 16)
        }
        put16(day, 18); put16(0, 20); put16(time, 22); put16(day, 24)
        put16(chosen.first ?? 0, 26)
        let size = UInt32(contents.count)
        for i in 0..<4 { entry[28 + i] = UInt8(truncatingIfNeeded: size >> UInt32(i * 8)) }
        try storage.write(Data(entry), at: slot.offset)
    }
}

/// Read-only view of a byte source for `Fat16Volume` (writes are refused).
final class ReadOnlyFat16Storage: Fat16Storage {
    private let source: any ByteSource
    init(source: any ByteSource) { self.source = source }
    func read(at offset: UInt64, count: Int) throws -> Data { try source.read(at: offset, count: count) }
    func write(_ data: Data, at offset: UInt64) throws { throw BrowserError.unsupported("読み取り専用のため書き込めません") }
}

public enum CardCommandFiles {
    /// The state of the two command files on a card, read without writing anything. Throws when the card has no FAT16 volume (with a
    /// CONFIG folder) that this reader fully understands.
    public static func read(_ source: any ByteSource) throws -> CardCommandState {
        let volume = try Fat16Volume(storage: ReadOnlyFat16Storage(source: source), diskBytes: source.byteCount)
        let time = try volume.readConfigFile(Array("TIME    INI".utf8))
        let angle = try volume.readConfigFile(Array("SELFADJ INI".utf8))
        return CardCommandState(timeFileExists: time != nil, time: time.flatMap { CardLocalTime.parseIni($0) }, angleDetectionRequested: angle != nil)
    }

    /// Applies every action to the FAT16 volume of `storage` and checks each result by reading it back. Used on image copies only.
    static func write(_ files: [CardCommandFile], to storage: Fat16Storage, diskBytes: UInt64, now: Date) throws {
        guard Set(files.map { $0.fileName }).count == files.count else { throw BrowserError.invalid("同じコマンドファイルに対する指定が重複しています") }
        let volume = try Fat16Volume(storage: storage, diskBytes: diskBytes)
        for file in files {
            if let contents = file.contents {
                try volume.writeConfigFile(file.shortName, contents: contents, now: now)
            } else {
                try volume.deleteConfigFile(file.shortName)
            }
        }
        let check = try Fat16Volume(storage: storage, diskBytes: diskBytes)
        for file in files {
            let back = try check.readConfigFile(file.shortName)
            if let contents = file.contents {
                guard let data = back, data == contents else { throw BrowserError.io("コマンドファイル\(file.path)の読み戻し検証に失敗しました") }
            } else {
                guard back == nil else { throw BrowserError.io("コマンドファイル\(file.path)の削除を確認できません") }
            }
        }
    }
}
