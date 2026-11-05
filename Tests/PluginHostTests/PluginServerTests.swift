import CryptoKit
import Foundation
import os
import Testing

@testable import PluginHost

@Suite("PluginServer(真 socket)")
struct PluginServerTests {
    @Test("升级握手 + 客户端掩码帧接收 + 服务端帧下发")
    func handshakeEcho() async throws {
        let server = PluginServer()
        final class Box: @unchecked Sendable {  // 状态由 OSAllocatedUnfairLock 守卫
            var received: [Data] = []
            var opened = false
            var closed = false
        }
        let box = OSAllocatedUnfairLock(initialState: Box())
        server.onMessage = { _, data in
            box.withLock { $0.received.append(data) }
        }
        server.onOpen = { _ in box.withLock { $0.opened = true } }
        server.onClose = { _ in box.withLock { $0.closed = true } }
        server.onError = { message in Issue.record("server error: \(message)") }

        server.start()
        for _ in 0..<150 where server.port == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(server.port != 0, "监听未就绪")

        let client = try await connectAndHandshake(port: server.port)
        try sendMaskedText(client, "你好 opendeck")

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let done = box.withLock { $0.received.contains { String(data: $0, encoding: .utf8) == "你好 opendeck" } }
            if done { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let (opened, messages) = box.withLock { ($0.opened, $0.received) }
        #expect(opened, "onOpen 未触发")
        #expect(messages.contains { String(data: $0, encoding: .utf8) == "你好 opendeck" },
                "未收到客户端文本帧,实收 \(messages.count) 条")

        server.stop()
        Darwin.close(client)
    }

    @Test("64 位超长帧头:熔断断连,不崩宿主进程")
    func maliciousFrameLengthBreaksConnectionNotProcess() async throws {
        let server = PluginServer()
        final class Box: @unchecked Sendable {
            var closed = false
        }
        let box = OSAllocatedUnfairLock(initialState: Box())
        server.onClose = { _ in box.withLock { $0.closed = true } }
        server.onError = { message in Issue.record("server error: \(message)") }

        server.start()
        for _ in 0..<150 where server.port == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(server.port != 0, "监听未就绪")

        let client = try await connectAndHandshake(port: server.port)
        // 恶意帧:text + masked + len=127,后随 8 字节 0xFF(2^64-1,普通 << 会整型溢出 trap)
        try sendAll(client, Data([0x81, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))

        // 能走到这里本身就证明没 trap;再等熔断把连接摘掉
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if box.withLock({ $0.closed }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(box.withLock { $0.closed }, "超长帧头应熔断断连(onClose 未触发)")

        server.stop()
        Darwin.close(client)
    }

    // MARK: - 极简 RFC6455 客户端(测试专用)

    private func connectAndHandshake(port: UInt16) async throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(connectResult == 0, "connect 失败 errno=\(errno)")

        // 收发超时,防止测试挂死
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try sendAll(descriptor, Data(request.utf8))

        var head = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while !head.contains(terminator) {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &buffer, buffer.count)
            try #require(count > 0, "握手读取失败")
            head.append(contentsOf: buffer[0..<count])
        }
        let headerText = String(data: head, encoding: .utf8) ?? ""
        #expect(headerText.contains("101"), "应答非 101:\(headerText.prefix(120))")
        let expectedAccept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        #expect(headerText.contains(expectedAccept), "Sec-WebSocket-Accept 不匹配")
        return descriptor
    }

    private func sendMaskedText(_ descriptor: Int32, _ text: String) throws {
        var payload = Data(text.utf8)
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        var frame = Data([0x81, 0x80 | UInt8(payload.count)])
        frame.append(contentsOf: mask)
        for index in 0..<payload.count {
            payload[index] ^= mask[index % 4]
        }
        frame.append(payload)
        try sendAll(descriptor, frame)
    }

    private func sendAll(_ descriptor: Int32, _ data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { rawBuffer in
                write(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            try #require(written > 0, "write 失败 errno=\(errno)")
            remaining.removeFirst(written)
        }
    }
}

// MARK: - §6.26 深度审计轮新增闸门

extension PluginServerTests {
    /// 握手前的无界 inbox:header 永不来齐的连接在 64KB 专用上限处熔断。
    /// 旧实现提前 return 跳过了握手后的 32MB 检查,本地进程可无界吃内存 + O(n²) 扫描
    @Test("握手前 inbox 上限:不发 terminato 的洪水连接被断开")
    func preHandshakeFloodBreaksConnection() async throws {
        let server = PluginServer()
        final class Box: @unchecked Sendable {
            var closed = false
        }
        let box = OSAllocatedUnfairLock(initialState: Box())
        server.onClose = { _ in box.withLock { $0.closed = true } }
        server.onError = { _ in } // 熔断本身会报非法升级请求,不按错误断言

        server.start()
        for _ in 0..<150 where server.port == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(server.port != 0, "监听未就绪")

        // 裸 socket,不发升级头,只灌无 terminator 的字节
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = server.port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr>.size))
            }
        }
        try #require(connectResult == 0)
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        try sendAll(descriptor, Data(repeating: UInt8(ascii: "A"), count: 80 * 1024))

        // 服务端熔断 → close → 读到 EOF(0)或 ECONNRESET
        var sawClose = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { sawClose = true; break }
            try sendAll(descriptor, Data(repeating: UInt8(ascii: "A"), count: 16 * 1024))
            if box.withLock({ $0.closed }) { sawClose = true; break }
        }
        #expect(sawClose || box.withLock({ $0.closed }), "洪水连接应被服务端熔断")
        Darwin.close(descriptor)
        server.stop()
    }
}

// MARK: - §6.27 性能收尾轮新增闸门

extension PluginServerTests {
    /// 管线化洪灌:单次 drain 上限 256 帧,超出部分重排队消化——
    /// 全部帧必须最终到达(节流不得丢帧),且连接保持可用
    @Test("入站洪泛节流:1000 条管线化帧全部送达,连接不断")
    func pipelinedFloodThrottledButComplete() async throws {
        let server = PluginServer()
        final class Box: @unchecked Sendable {
            var received = 0
            var closed = false
        }
        let box = OSAllocatedUnfairLock(initialState: Box())
        server.onMessage = { _, _ in box.withLock { $0.received += 1 } }
        server.onClose = { _ in box.withLock { $0.closed = true } }
        server.onError = { message in Issue.record("server error: \(message)") }

        server.start()
        for _ in 0..<150 where server.port == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(server.port != 0, "监听未就绪")

        let client = try await connectAndHandshake(port: server.port)
        let total = 1000
        for index in 0..<total {
            try sendMaskedText(client, "f\(index)")
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if box.withLock({ $0.received }) >= total { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let (received, closed) = box.withLock { ($0.received, $0.closed) }
        #expect(received == total, "洪灌帧不得丢失:实收 \(received)/\(total)")
        #expect(!closed, "节流是让出而非断连")

        Darwin.close(client)
        server.stop()
    }
}
