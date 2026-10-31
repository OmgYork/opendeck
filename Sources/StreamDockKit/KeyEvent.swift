import Foundation

/// 面板按键事件。坐标以 293V3 网格为准:row 0-2,column 0-4(5×3 = 15 键,无软键列)。
/// 六列/软键是 HSV-293S 的旧设计,本机设备不是那个型号——勘误依据见 StreamDock293S 的类型注释。
public struct KeyEvent: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case down
        case up
    }

    public let row: Int
    public let column: Int
    public let phase: Phase

    public init(row: Int, column: Int, phase: Phase) {
        self.row = row
        self.column = column
        self.phase = phase
    }
}

/// 设备连接状态(热插拔自动迁移)
public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case running
}
