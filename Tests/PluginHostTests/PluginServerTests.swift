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
