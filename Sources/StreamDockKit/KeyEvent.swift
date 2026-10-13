import Foundation

/// 面板按键事件。坐标以 293S 网格为准:row 0-2,column 0-5(第 5 列为右侧软键)。
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
