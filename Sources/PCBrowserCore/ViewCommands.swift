import Foundation

/// Pointer modes of the original picture window. The raw values are the numbers the original stores
/// in its mouse-mode byte (502 範囲拡大 → 1, 503 移動 → 2, 504 回転 → 3, 512 → 6, 513 → 7).
/// 4 is the value the original writes after view changes; it has no menu item (plain drag).
public enum ViewMouseMode: Int, Sendable, CaseIterable {
    case areaZoom = 1, move = 2, rotate = 3, standard = 4, lensMove = 6, lensSize = 7
}

/// Operations behind the original right-click menus of the picture windows.
public enum ViewCommandKind: String, Sendable, CaseIterable {
    case reset, areaZoom, move, rotateDrag
    case flipHorizontal, flipVertical, flipFrontBack
    case zoomIn, zoomOut
    case rotateClockwise, rotateCounterClockwise
    case lensMove, lensSize, lensReset
    case night, detachWindow, closeWindow

    /// Mouse mode selected by the command, if it only selects a mode.
    public var mouseMode: ViewMouseMode? {
        switch self {
        case .areaZoom: return .areaZoom
        case .move: return .move
        case .rotateDrag: return .rotate
        case .lensMove: return .lensMove
        case .lensSize: return .lensSize
        default: return nil
        }
    }
}

public enum ViewCommands {
    /// Maps original command IDs to operations. Single-screen items are 501–517; the multi-camera tile
    /// menus repeat the same operations as 521–530 (IDs differ, behaviour is the same); 2 closes a detached window.
    public static func kind(commandID id: Int) -> ViewCommandKind? {
        switch id {
        case 501, 521: return .reset
        case 502, 522: return .areaZoom
        case 503, 523: return .move
        case 504, 524: return .rotateDrag
        case 505, 525: return .flipHorizontal
        case 506, 526: return .flipVertical
        case 507: return .flipFrontBack
        case 508, 527: return .zoomIn
        case 509, 528: return .zoomOut
        case 510, 529: return .rotateClockwise
        case 511, 530: return .rotateCounterClockwise
        case 512: return .lensMove
        case 513: return .lensSize
        case 514: return .lensReset
        case 516: return .detachWindow
        case 517: return .night
        case 2: return .closeWindow
        default: return nil
        }
    }

    /// Display-mode commands of the tile / detached-window menus (555–559); 560 (180° VR) is separate.
    public static func displayMode(commandID id: Int) -> ProjectionMode? {
        switch id {
        case 555: return .raw
        case 556: return .perspective
        case 557: return .panorama
        case 558: return .ring
        case 559: return .dome
        default: return nil
        }
    }

    /// Playback commands of the detached-window menu (570–576) are the same as 350–356 in the menu bar.
    public static func playbackCommandID(forDetached id: Int) -> Int? { (570...576).contains(id) ? id - 220 : nil }
}
