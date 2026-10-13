import Foundation
import Testing

@testable import StreamDockKit

/// 协议纯函数黄金测试:字节布局全部对照 mirabox/HANDOFF.md §1.2
@Suite("StreamDock293S 协议")
struct StreamDock293STests {
    @Test("顺序键位映射:15 键双向一致")
    func keyMapRoundTrip() {
        var seen = Set<UInt8>()
        for row in 0..<StreamDock293S.rows {
            for column in 0..<StreamDock293S.columns {
                guard let id = StreamDock293S.keyId(row: row, column: column) else {
                    Issue.record("r\(row)c\(column) 无键 id")
                    continue
                }
                seen.insert(id)
                let back = StreamDock293S.position(of: id)
                #expect(back?.row == row)
                #expect(back?.column == column)
            }
        }
        #expect(seen.count == 15)
    }

    @Test("键位表内容与实拍解码一致:固件 id 自底行起算")
    func keyMapGolden() {
        #expect(StreamDock293S.keyId(row: 0, column: 0) == 0x0b) // 物理顶行左 1
        #expect(StreamDock293S.keyId(row: 0, column: 4) == 0x0f)
        #expect(StreamDock293S.keyId(row: 1, column: 0) == 0x06)
        #expect(StreamDock293S.keyId(row: 2, column: 4) == 0x05) // 物理底行右 1
        #expect(StreamDock293S.keyId(row: 3, column: 0) == nil)
        #expect(StreamDock293S.keyId(row: 0, column: 5) == nil) // 无软键列
    }

    @Test("命令包:CRT 前缀+补零到 1024")
    func commandPacketFormat() {
        let packet = StreamDock293S.commandPacket(StreamDock293S.heartbeatCommand)
        #expect(packet.count == 1024)
        #expect(Array(packet.prefix(5)) == [0x43, 0x52, 0x54, 0x00, 0x00])
        // "CONNECT" 紧跟前缀
        #expect(Array(packet[5..<12]) == [0x43, 0x4f, 0x4e, 0x4e, 0x45, 0x43, 0x54])
        // 其余补零
        #expect(packet[12...].allSatisfy { $0 == 0 })
    }

    @Test("BAT 画键头:命令+大端长度+键 id")
    func imageHeader() {
        let header = StreamDock293S.imageHeaderCommand(jpegSize: 0x0000_1234, keyId: 0x0d)
        #expect(header == [0x42, 0x41, 0x54, 0x00, 0x00, 0x12, 0x34, 0x0d])
    }

    @Test("图像分块:补零、无前缀、块数正确")
    func imageChunking() {
        let small = Data(repeating: 0xAB, count: 100)
        let one = StreamDock293S.imageChunks(small)
        #expect(one.count == 1)
        #expect(one[0].count == 1024)
        #expect(one[0][0] == 0xAB)
        #expect(one[0][100...].allSatisfy { $0 == 0 })

        let big = Data(repeating: 0xCD, count: 2500)
        let three = StreamDock293S.imageChunks(big)
        #expect(three.count == 3)
        #expect(three[0].count == 1024 && three[1].count == 1024)
        #expect(three[2].count == 1024)
        #expect(three[2][452...].allSatisfy { $0 == 0 })
    }

    @Test("亮度伽马:b=(v/100)^0.75×100")
    func brightness() {
        #expect(StreamDock293S.brightnessByte(percent: 100) == 100)
        #expect(StreamDock293S.brightnessByte(percent: 0) == 0)
        #expect(StreamDock293S.brightnessByte(percent: 50) == 59)
        #expect(StreamDock293S.brightnessByte(percent: 120) == 100)
    }

    @Test("输入报告解析:键 id/相位/短报告")
    func parseKeyEvents() {
        var report = [UInt8](repeating: 0, count: 32)
        report[9] = 0x01
        report[10] = 1
        #expect(StreamDock293S.parseKeyEvent(fromReport: report) == KeyEvent(row: 2, column: 0, phase: .down))

        report[10] = 0
        #expect(StreamDock293S.parseKeyEvent(fromReport: report) == KeyEvent(row: 2, column: 0, phase: .up))

        report[9] = 0x0f
        report[10] = 1
        #expect(StreamDock293S.parseKeyEvent(fromReport: report) == KeyEvent(row: 0, column: 4, phase: .down))

        #expect(StreamDock293S.parseKeyEvent(fromReport: [UInt8](repeating: 0, count: 10)) == nil)

        // 0x10-0x12 在 293V3 上不存在(此前误标为软键)
        report[9] = 0x10
        #expect(StreamDock293S.parseKeyEvent(fromReport: report) == nil)

        report[9] = 0x99
        #expect(StreamDock293S.parseKeyEvent(fromReport: report) == nil)
    }

    @Test("USB 身份识别:293V3 两批次")
    func usbIds() {
        #expect(StreamDock293S.isKnownUSBId(vendorId: 0x6603, productId: 0x1005))
        #expect(StreamDock293S.isKnownUSBId(vendorId: 0x6603, productId: 0x1006))
        #expect(!StreamDock293S.isKnownUSBId(vendorId: 0x0fd9, productId: 0x006c)) // Elgato,应拒绝
    }
}
