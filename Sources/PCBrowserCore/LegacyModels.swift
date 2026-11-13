import Foundation

/// One entry of the original application's "機種選択" menu (command IDs 400–455).
/// `index` and `capability` are the two values the original stores in its main
/// window object when a model is chosen (static analysis of the 1.9.60.0 menu
/// handlers). Their remaining bits are intentionally not interpreted here.
public struct LegacyModel: Sendable, Equatable, Identifiable {
    public let commandID: Int
    public let name: String
    public let family: String
    public let index: Int
    public let capability: Int
    public var id: Int { commandID }
    public var windowTitle: String { "PC Browser[\(name)]" }
    /// The original's G-scale handlers pick a sensor painter from `capability & 3`:
    /// 0 = background only (no sensor panel), 1 = standard panel, 3 = extended panel.
    public var sensorPanelClass: Int { capability & 3 }
    public var sensorPanelDescription: String {
        switch sensorPanelClass {
        case 0: return "原版はこの機種でセンサーパネルを描画しません"
        case 1: return "標準センサーパネル"
        case 3: return "拡張センサーパネル"
        default: return "未分類のセンサーパネル"
        }
    }
}

public enum LegacyModelCatalog {
    /// Sub-menu order of the original "機種選択" menu.
    public static let families = ["BU", "SN", "FDR", "FA", "BDR", "Q", "S", "SRZ"]
    /// All 44 models in the original menu order.
    public static let all: [LegacyModel] = {
        var rows: [LegacyModel] = []
        func m(_ family: String, _ id: Int, _ name: String, _ index: Int, _ capability: Int) {
            rows.append(LegacyModel(commandID: id, name: name, family: family, index: index, capability: capability))
        }
        m("BU", 402, "BU-DRR403", 17, 0x445)
        m("BU", 403, "BU-DRR603T", 18, 0x645)
        m("BU", 404, "BU-DRHD320", 19, 0x4441)
        m("BU", 405, "BU-DRHD421", 20, 0x4445)
        m("BU", 406, "BU-DRHD620T", 21, 0x464d)
        m("BU", 411, "BU-DRB300", 5, 0x501)
        m("BU", 412, "BU-DRR401", 6, 0x505)
        m("BU", 413, "BU-DRR600T", 7, 0x705)
        m("BU", 414, "BU-DRR610T", 8, 0x70d)
        m("BU", 415, "BU-DRHD4", 13, 0x545)
        m("BU", 416, "BU-DRHD6T", 14, 0x745)
        m("BU", 407, "BU-DRB305", 23, 0x441)
        m("BU", 408, "BU-DRR405", 24, 0x445)
        m("BU", 409, "BU-DRR605T", 25, 0x645)
        m("BU", 410, "BU-DRR615T", 26, 0x64d)
        m("BU", 418, "BU-DRHD330", 27, 0x4441)
        m("BU", 419, "BU-DRHD431", 28, 0x4445)
        m("BU", 420, "BU-DRHD630T", 29, 0x14645)
        m("BU", 421, "BU-DRHD635T", 30, 0x464d)
        m("BU", 445, "BU-DRHD330 Ver.2", 54, 0x4441)
        m("BU", 446, "BU-DRHD431 Ver.2", 55, 0x4445)
        m("BU", 447, "BU-DRHD630T Ver.2", 56, 0x14645)
        m("BU", 426, "BU-DRHD635T Ver.2", 38, 0x464d)
        m("BU", 438, "BU-SV750LTE", 51, 0x74c5)
        m("BU", 449, "BU-DRHD640T", 58, 0x14647)
        m("BU", 450, "BU-DRHD645T", 59, 0x464f)
        m("SN", 435, "SN-HQ90d", 43, 0x74c5)
        m("FDR", 422, "FDR-800", 31, 0x5a53)
        m("FDR", 425, "FDR-810", 34, 0x5a53)
        m("FDR", 443, "FDR-820", 52, 0x5adb)
        m("FDR", 444, "FDR-900", 53, 0x5adb)
        m("FDR", 453, "FDR-820 m2", 62, 0x5adb)
        m("FDR", 454, "FDR-820AI", 63, 0x5adb)
        m("FA", 417, "FA1001", 22, 0x840)
        m("FA", 423, "FA1002", 32, 0x840)
        m("FA", 424, "FA2001", 33, 0x840)
        m("BDR", 400, "BDR-1", 15, 0x245)
        m("BDR", 401, "BDR-S1", 16, 0x40)
        m("Q", 428, "Q-01", 35, 0x6445)
        m("Q", 429, "Q-02", 45, 0x64c5)
        m("Q", 442, "Q-03", 49, 0x164c5)
        m("Q", 455, "Q-04", 64, 0x16cc5)
        m("S", 441, "S20", 48, 0x64c5)
        m("SRZ", 451, "SRZ-01", 60, 0x16cc5)
        return rows
    }()
    public static func models(in family: String) -> [LegacyModel] { all.filter { $0.family == family } }
    public static func model(commandID: Int) -> LegacyModel? { all.first { $0.commandID == commandID } }
}
