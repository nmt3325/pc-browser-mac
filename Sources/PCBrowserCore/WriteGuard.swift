import Foundation

/// Output-path policy. PC Browser Mac never writes to an original card or image:
/// every export must create a NEW file that is not an input or inside an input.
public enum WriteGuard {
    public enum Decision: Equatable, Sendable {
        case allowed
        case refused(String)
        public var isAllowed: Bool { if case .allowed = self { return true } else { return false } }
        public var reason: String? { if case .refused(let reason) = self { return reason } else { return nil } }
    }

    public static func checkNewOutput(_ destination: URL, protecting sources: [URL] = []) -> Decision {
        guard destination.isFileURL else { return .refused("書き出し先はローカルのファイルを指定してください") }
        let path = destination.standardizedFileURL.path
        guard !path.isEmpty, path != "/" else { return .refused("書き出し先が不正です") }
        if isDevicePath(path) { return .refused("デバイスファイルへは書き出しません（SDカード・ディスクを保護しています）") }
        let fm = FileManager.default
        // attributesOfItem does not follow symbolic links, so a dangling link also counts as existing.
        if (try? fm.attributesOfItem(atPath: path)) != nil { return .refused("既存ファイルには上書きしません。新しい出力名を選んでください") }
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .refused("保存先のフォルダーが存在しません") }
        let resolved = parent.resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent).standardizedFileURL.path
        if isDevicePath(resolved) { return .refused("デバイスファイルへは書き出しません（SDカード・ディスクを保護しています）") }
        for source in sources {
            let protected = source.resolvingSymlinksInPath().standardizedFileURL.path
            if resolved == protected || resolved.hasPrefix(protected.hasSuffix("/") ? protected : protected + "/") {
                return .refused("入力元（読み取り専用）と同じ場所、または入力元の内部には書き出せません")
            }
        }
        return .allowed
    }

    /// The policy for an output folder that an export may still have to create: never a device, never an input or inside one.
    /// Nothing is created here.
    public static func checkOutputFolder(_ folder: URL, protecting sources: [URL] = []) -> Decision {
        guard folder.isFileURL else { return .refused("書き出し先はローカルのフォルダーを指定してください") }
        let standard = folder.standardizedFileURL
        guard !standard.path.isEmpty, standard.path != "/" else { return .refused("書き出し先が不正です") }
        if isDevicePath(standard.path) { return .refused("デバイスファイルへは書き出しません（SDカード・ディスクを保護しています）") }
        let fm = FileManager.default
        var existing = standard
        var missing: [String] = []
        while !fm.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: existing.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .refused("保存先のフォルダーを作成できません（途中にファイルがあります）") }
        var resolved = existing.resolvingSymlinksInPath()
        for part in missing { resolved.appendPathComponent(part) }
        let resolvedPath = resolved.standardizedFileURL.path
        if isDevicePath(resolvedPath) { return .refused("デバイスファイルへは書き出しません（SDカード・ディスクを保護しています）") }
        for source in sources {
            let protected = source.resolvingSymlinksInPath().standardizedFileURL.path
            if resolvedPath == protected || resolvedPath.hasPrefix(protected.hasSuffix("/") ? protected : protected + "/") {
                return .refused("入力元（読み取り専用）と同じ場所、または入力元の内部には書き出せません")
            }
        }
        return .allowed
    }

    private static func isDevicePath(_ path: String) -> Bool { path == "/dev" || path.hasPrefix("/dev/") }
}

/// Operations of the original application that modify an original card. They are
/// deliberately never implemented; the app explains why instead of guessing.
public enum DestructiveOperation: String, CaseIterable, Sendable {
    case formatCard, initializeCard, eraseRecordings, setPassword, removePassword, updateFirmware, writeCardSettings
    public var originalFeature: String {
        switch self {
        case .formatCard: return "SDカードフォーマット（原版ハンドラ0x437bb0）"
        case .initializeCard: return "カード初期化"
        case .eraseRecordings: return "録画消去（原版ダイアログ121）"
        case .setPassword: return "パスワード設定（原版ダイアログ106）"
        case .removePassword: return "パスワード解除（原版ダイアログ106）"
        case .updateFirmware: return "ファームウェア更新"
        case .writeCardSettings: return "録画設定のカードへの書き戻し（原版ダイアログ130–139）"
        }
    }
    public var refusalReason: String {
        switch self {
        case .formatCard, .initializeCard:
            return "原本のSDカードを消去する操作です。カード形式・機種別手順の検証と機種ごとの承認がないため、この版では実装しません。"
        case .eraseRecordings:
            return "循環更新と管理領域の更新規則が未解析のため、原本の録画は削除しません。"
        case .setPassword, .removePassword:
            return "パスワードの保存形式・鍵導出が未解析で、誤った書き込みはカードを読み出せなくするおそれがあるため実装しません。"
        case .updateFirmware:
            return "機器ごとの更新手順と署名の確認ができず、失敗すると機器が使えなくなるおそれがあるため実装しません。"
        case .writeCardSettings:
            return "原本のカード・マウント中のSDカード・読み込んだIMGには書き込みません。録画設定の変更は、記録設定シートが作る新しいIMGコピーにだけ書き出します。"
        }
    }
    public var decision: WriteGuard.Decision { .refused(refusalReason) }
}
