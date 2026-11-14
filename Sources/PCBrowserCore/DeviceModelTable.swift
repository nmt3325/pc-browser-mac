import Foundation

/// One entry of the original application's 使用機種 list.
///
/// `index` is the list position, `code` the model byte the recorder writes at offset 0x1DC of its control
/// sector, and `dialogClass` the template family the original opens for the recording-settings dialog
/// (models of one class share one dialog layout; the number is the original's internal resource class).
/// All three were read from the original application: the list from its model table, the code by editing the
/// control sector of a copy of a card and watching the window title and settings dialog it chose.
public struct DeviceModel: Sendable, Equatable, Identifiable {
    public let index: Int
    public let name: String
    public let code: UInt8
    public let dialogClass: Int
    public var id: Int { index }
    /// Title the original shows once this model is selected.
    public var windowTitle: String { "PC Browser[\(name)]" }
    /// Settings-dialog size in pixels at 96 dpi (width, height) measured for this class in the original.
    public var settingsDialogSize: (width: Int, height: Int)? { DeviceModelTable.dialogSizes[dialogClass] }
}

public enum DeviceModelTable {
    /// Offset of the model byte inside the control sector.
    public static let codeOffset = 0x1DC

    /// Settings-dialog sizes (width, height) by dialog class.
    public static let dialogSizes: [Int: (width: Int, height: Int)] = [
        78: (1104, 917), 80: (1079, 1009), 81: (1079, 901),
        123: (1104, 1100), 127: (1079, 1119), 147: (1482, 1056),
    ]

    /// The 37 models of the original in list order.
    public static let all: [DeviceModel] = {
        let rows: [(String, UInt8, Int)] = [
            ("BDR-1", 0x00, 80), ("BDR-S1", 0x01, 80), ("BU-DRR403", 0x02, 80), ("BU-DRR603T", 0x03, 80),
            ("BU-DRHD320", 0x04, 127), ("BU-DRHD421", 0x05, 127), ("BU-DRHD620T", 0x06, 127), ("BU-DRB305", 0x08, 80),
            ("BU-DRR405", 0x09, 80), ("BU-DRR605T", 0x0A, 80), ("BU-DRR615T", 0x0B, 80), ("FA1001", 0x07, 80),
            ("FDR-800", 0x10, 127), ("BU-DRHD330", 0x0C, 127), ("BU-DRHD431", 0x0D, 127), ("BU-DRHD630T", 0x0E, 127),
            ("BU-DRHD635T", 0x0F, 127), ("FA1002", 0x11, 80), ("FA2001", 0x12, 80), ("FDR-810", 0x13, 127),
            ("Q-01", 0x14, 81), ("Q-02", 0x1E, 81), ("SN-HQ90d", 0x1C, 78), ("S20", 0x21, 123),
            ("Q-03", 0x23, 81), ("BU-DRHD330 Ver.2", 0x26, 127), ("BU-DRHD431 Ver.2", 0x27, 127),
            ("BU-DRHD630T Ver.2", 0x28, 127), ("BU-DRHD635T Ver.2", 0x17, 127), ("FDR-820", 0x24, 147),
            ("FDR-900", 0x29, 147), ("BU-DRHD640T", 0x2B, 127), ("BU-DRHD645T", 0x2C, 127), ("SRZ-01", 0x2D, 81),
            ("FDR-820 m2", 0x2E, 147), ("FDR-820AI", 0x2F, 147), ("Q-04", 0x30, 81),
        ]
        return rows.enumerated().map { DeviceModel(index: $0.offset, name: $0.element.0, code: $0.element.1, dialogClass: $0.element.2) }
    }()

    public static func model(code: UInt8) -> DeviceModel? { all.first { $0.code == code } }
    public static func model(named name: String) -> DeviceModel? { all.first { $0.name == name } }
    public static func models(dialogClass: Int) -> [DeviceModel] { all.filter { $0.dialogClass == dialogClass } }

    /// The model named by a control sector. Unknown codes and short sectors return nil.
    public static func identify(controlSector: Data) -> DeviceModel? {
        guard controlSector.count > codeOffset else { return nil }
        return model(code: controlSector[controlSector.startIndex + codeOffset])
    }

    /// The model the card says it was recorded by. Partial copies without the control sector return nil.
    public static func identify(from source: any ByteSource, control: ControlHeader) -> DeviceModel? {
        guard let sector = try? source.read(at: control.sector * 512, count: 512) else { return nil }
        return identify(controlSector: sector)
    }

    /// The menu entry (機種選択) that corresponds to a list model; the menu uses the same names.
    public static func menuModel(for model: DeviceModel) -> LegacyModel? {
        LegacyModelCatalog.all.first { $0.name == model.name }
    }
}
