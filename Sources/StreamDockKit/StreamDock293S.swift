import Foundation

/// Stream Dock 293V3(旧平台)协议常量与纯函数。
/// 全部为无副作用计算,是单测的黄金标准;字节布局见 mirabox/HANDOFF.md §1.2。
///
/// 型号勘误(2026-10-13):本机设备 USB 0x6603:0x1005 在社区支持模块中明确定义为
/// **293V3 = 5×3 = 15 键、键位 id 顺序排列、无软键列**(此前误按 HSV-293S 六列蛇形布局实现,
/// 那条记录本身带 TODO: verify these 存疑标记;官方 app 报 6×3 属异常值)。
public enum StreamDock293S {
    public static let rows = 3
    public static let columns = 5
    public static let packetSize = 1024
    /// 单键 JPEG 上限(设备端硬限制)
    public static let maxKeyJPEGBytes = 10_240
    /// 心跳周期,必须 <8s 否则设备自行重启
    public static let heartbeatInterval: TimeInterval = 7

    /// 显示校正:实测设备以 **180° 旋转**显示图像(与社区模块 iconRotation:180 一致)。
    /// 勘误过程:数字多为竖向对称字形,曾误判为水平镜像;非对称图片揭示真相(2026-10-13)
    public static let displayRotationDegrees = 180

    static let cmdPrefix: [UInt8] = [0x43, 0x52, 0x54, 0x00, 0x00] // "CRT\0\0"

    /// 键位映射:[逻辑行][列] → 固件 id,用于**绘制**(BAT 命令)。
    /// 绘制空间自底行起算(实拍解码:0x0b=物理左上,0x01=物理左下)
    static let keyIds: [[UInt8]] = [
        [0x0b, 0x0c, 0x0d, 0x0e, 0x0f], // 物理顶行
        [0x06, 0x07, 0x08, 0x09, 0x0a], // 物理中行
        [0x01, 0x02, 0x03, 0x04, 0x05], // 物理底行
    ]

    /// 键位映射,用于**输入报告解析**。
    /// ⚠️ 固件的绘制与输入是两套编号空间(2026-10-13 按压实测):输入自顶行起算
    /// (按物理左上报 0x01),与绘制空间在顶/底两行恰好对调,中行重合——勿合并为一张表
    static let inputKeyIds: [[UInt8]] = [
        [0x01, 0x02, 0x03, 0x04, 0x05], // 物理顶行
        [0x06, 0x07, 0x08, 0x09, 0x0a], // 物理中行
        [0x0b, 0x0c, 0x0d, 0x0e, 0x0f], // 物理底行
    ]

    /// 已知 USB 身份:293V3 两批次(社区模块 293V3.ts),打包为 vid<<16|pid
    static let knownUSBIds: Set<UInt32> = [
        0x6603_1005, // 本机实测
        0x6603_1006,
    ]

    public static func isKnownUSBId(vendorId: Int, productId: Int) -> Bool {
        let packed = UInt32(bitPattern: Int32(truncatingIfNeeded: vendorId << 16 | productId))
        return knownUSBIds.contains(packed)
    }

    public static func keyId(row: Int, column: Int) -> UInt8? {
        guard rowIds(indicesValid: row, column) else { return nil }
        return keyIds[row][column]
    }

    static func rowIds(indicesValid row: Int, _ column: Int) -> Bool {
        (0..<rows).contains(row) && (0..<columns).contains(column)
    }

    public static func position(of keyId: UInt8) -> (row: Int, column: Int)? {
        for (r, row) in keyIds.enumerated() {
            if let c = row.firstIndex(of: keyId) { return (r, c) }
        }
        return nil
    }

    /// 键面分辨率:全部主键 100×100
    public static func keySize(column: Int) -> Int {
        _ = column
        return 100
    }

    // MARK: - 命令构造(纯函数)

    /// 命令包:CRT 前缀 + 命令,补零到 packetSize
    public static func commandPacket(_ cmd: [UInt8]) -> [UInt8] {
        var packet = cmdPrefix + cmd
        if packet.count < packetSize {
            packet.append(contentsOf: [UInt8](repeating: 0, count: packetSize - packet.count))
        }
        return [UInt8](packet.prefix(packetSize))
    }

    static let heartbeatCommand: [UInt8] = [0x43, 0x4f, 0x4e, 0x4e, 0x45, 0x43, 0x54] // "CONNECT"
    static let wakeCommand: [UInt8] = [0x44, 0x49, 0x53] // "DIS"
    static let refreshCommand: [UInt8] = [0x53, 0x54, 0x50] // "STP"
    static let clearPanelCommand: [UInt8] = [0x43, 0x4c, 0x45, 0x00, 0x00, 0x00, 0xff] // "CLE…0xff"
    static let closeCommand: [UInt8] = [0x43, 0x4c, 0x45, 0x00, 0x00, 0x44, 0x43] // "CLE…"DC""

    static func brightnessCommand(_ byte: UInt8) -> [UInt8] {
        [0x4c, 0x49, 0x47, 0x00, 0x00, byte] // "LIG"
    }

    /// 画键头:"BAT" + JPEG 长度(u32 大端) + 键 id
    static func imageHeaderCommand(jpegSize: Int, keyId: UInt8) -> [UInt8] {
        [0x42, 0x41, 0x54,
         UInt8((jpegSize >> 24) & 0xff), UInt8((jpegSize >> 16) & 0xff),
         UInt8((jpegSize >> 8) & 0xff), UInt8(jpegSize & 0xff),
         keyId]
    }

    /// JPEG 数据块切分:每块补零到 packetSize,不带 CRT 前缀
    public static func imageChunks(_ jpeg: Data) -> [[UInt8]] {
        let bytes = [UInt8](jpeg)
        guard !bytes.isEmpty else { return [] }
        var chunks: [[UInt8]] = []
        var start = 0
        while start < bytes.count {
            let end = min(start + packetSize, bytes.count)
            var chunk = [UInt8](bytes[start..<end])
            if chunk.count < packetSize {
                chunk.append(contentsOf: [UInt8](repeating: 0, count: packetSize - chunk.count))
            }
            chunks.append(chunk)
            start = end
        }
        return chunks
    }

    /// 亮度伽马:b = (v/100)^0.75 × 100(与官方/社区实现一致)
    public static func brightnessByte(percent: Int) -> UInt8 {
        let clamped = max(0, min(100, percent))
        return UInt8((pow(Double(clamped) / 100, 0.75) * 100).rounded())
    }

    /// 输入报告键 id → 物理位置(走输入键位空间,勿用绘制表)
    public static func inputPosition(of keyId: UInt8) -> (row: Int, column: Int)? {
        for (r, row) in inputKeyIds.enumerated() {
            if let c = row.firstIndex(of: keyId) { return (r, c) }
        }
        return nil
    }

    /// 输入报告解析:report[9]=键 id,report[10]=0 抬起/非 0 按下
    public static func parseKeyEvent(fromReport report: [UInt8]) -> KeyEvent? {
        guard report.count >= 11 else { return nil }
        let key = report[9]
        let phase: KeyEvent.Phase = report[10] == 0 ? .up : .down
        guard let pos = inputPosition(of: key) else { return nil }
        return KeyEvent(row: pos.row, column: pos.column, phase: phase)
    }
}
