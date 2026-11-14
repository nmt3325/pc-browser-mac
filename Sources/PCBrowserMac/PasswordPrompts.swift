import AppKit
import PCBrowserCore

/// The small modal boxes of the original's password handling (dialog 106 and the 「パスワード」 / エラー message boxes) and of 録画データ削除.
@MainActor
enum PasswordPrompts {
    /// A message, one masked edit box, OK / キャンセル. nil = cancelled.
    static func ask(message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "パスワード"
        alert.informativeText = message
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
    /// A question with はい / いいえ (はい is the default button).
    static func confirm(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "はい")
        alert.addButton(withTitle: "いいえ")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// A message with OK / キャンセル (OK is the default button): the first confirmation of 録画データ削除 / 記録設定データ初期化.
    static func proceed(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }
    static func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "エラー"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
