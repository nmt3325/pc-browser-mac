import Foundation
import Darwin
import PCRawIO
import PCBrowserCore

struct ExternalDisk: Sendable {
    let bsd: String
    let name: String
    let bytes: UInt64
}
enum SDCardAccess {
    private static func diskutil(_ arguments: [String]) throws -> [String: Any] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil"); p.arguments = arguments
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0, let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw BrowserError.io("外部ディスクの一覧を取得できません") }
        return result
    }
    /// Reads device descriptions only. No card contents are read by enumeration.
    static func list() throws -> [ExternalDisk] {
        let plist = try diskutil(["list", "-plist", "external", "physical"])
        let roots = plist["AllDisksAndPartitions"] as? [[String: Any]] ?? []
        var disks: [ExternalDisk] = []
        for root in roots {
            guard let bsd = root["DeviceIdentifier"] as? String, bsd.range(of: "^disk[0-9]{1,4}$", options: .regularExpression) != nil else { continue }
            let info = try diskutil(["info", "-plist", bsd])
            guard info["Internal"] as? Bool == false, info["Whole"] as? Bool == true,
                  let n = info["TotalSize"] as? NSNumber, n.uint64Value > 0 else { continue }
            disks.append(ExternalDisk(bsd: bsd, name: info["MediaName"] as? String ?? bsd, bytes: n.uint64Value))
        }
        return disks
    }
    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func open(_ disk: ExternalDisk, helper: URL) throws -> FileByteSource {
        guard disk.bsd.range(of: "^disk[0-9]{1,4}$", options: .regularExpression) != nil else { throw BrowserError.invalid("外部ディスクの名前が不正です") }
        let dir = URL(fileURLWithPath: "/tmp/pcb-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appendingPathComponent("read.sock").path
        let listener = pc_create_listener(socket)
        guard listener >= 0 else { throw BrowserError.io("読み取り専用ヘルパーの通信を準備できません") }
        defer { close(listener) }
        let command = [helper.path, "--device", disk.bsd, "--socket", socket, "--uid", String(getuid())].map(shellQuote).joined(separator: " ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        var descriptor: Int32 = -1
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            descriptor = pc_receive_readonly_fd(listener, "/dev/r" + disk.bsd, 1000)
            if descriptor >= 0 { break }
            if !process.isRunning { break }
        }
        if descriptor < 0 {
            if process.isRunning { process.terminate() }; process.waitUntilExit()
            throw BrowserError.io("SDカードへの読み取りアクセスが許可されなかったか、接続を確認できませんでした")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { close(descriptor); throw BrowserError.io("読み取りヘルパーが正常に終了しませんでした") }
        let bytes = pc_device_size(descriptor)
        guard bytes == disk.bytes, bytes > 0 else { close(descriptor); throw BrowserError.invalid("SDカードの容量が変わりました。選択し直してください") }
        return try FileByteSource(readonlyDescriptor: descriptor, byteCount: bytes, alignedDevice: true)
    }
}
