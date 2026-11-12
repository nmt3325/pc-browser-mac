import Foundation
public struct SettingItem:Identifiable,Sendable {
    public var id:String {section+"/"+key};public let section:String;public let key:String;public let value:String
    public var isSensitive:Bool {["PASSWORD","SDID","SERIAL","SSID","AUTH"].contains{key.uppercased().contains($0)}}
    public var displayValue:String {isSensitive ? "••••（非表示）" : value}
}
public enum INIParser {
    public static func parse(_ text:String)->[SettingItem] {
        var section="設定",items:[SettingItem]=[]
        for raw in text.components(separatedBy:.newlines) {
            let s=raw.trimmingCharacters(in:.whitespacesAndNewlines)
            if s.isEmpty||s.hasPrefix(";")||s.hasPrefix("#"){continue}
            if s.hasPrefix("["),s.hasSuffix("]"){section=String(s.dropFirst().dropLast());continue}
            guard let p=s.firstIndex(of:"=") else {continue}
            let key=String(s[..<p]).trimmingCharacters(in:.whitespaces)
            let value=String(s[s.index(after:p)...]).trimmingCharacters(in:.whitespaces)
            if !key.isEmpty {items.append(.init(section:section,key:key,value:value))}
        }
        return items
    }
    public static func decode(_ data:Data)->String {
        if data.starts(with:[0xff,0xfe]),let s=String(data:data,encoding:.utf16LittleEndian){return s}
        return String(data:data,encoding:.utf8) ?? String(data:data,encoding:.shiftJIS) ?? String(decoding:data,as:UTF8.self)
    }
}
