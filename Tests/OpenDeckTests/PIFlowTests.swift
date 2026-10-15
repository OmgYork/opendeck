import CryptoKit
import Foundation
import PluginHost
import Testing
@testable import OpenDeck

/// PI 全链路集成测试:假插件 + 假 PI 两个 WebSocket 客户端直连 PluginHostModel 的宿主服务,
/// 钉死 PI 路由契约(注册推送/应答寻址/settings 双向/两向透传/断开通知)。
/// 假客户端是 PluginServerTests 迷你 RFC6455 客户端的移植(测试 target 间不共享代码);
/// 假插件 manifest 不带 CodePath → family=.unsupported → ensureRuntime 不拉真 node。
@MainActor
@Suite("PluginHostModel PI 路由(真 socket)")
struct PIFlowTests {
    private static let pluginUUID = "com.test.fake"
    private static let actionUUID = "com.test.fake.action"
    private static let contextID = "ctx-1"
    private static let manifestJSON = #"{"Name":"fake","Version":"1.0","Actions":[{"UUID":"com.test.fake.action","Name":"A1","PropertyInspectorPath":"pi/index.html"}]}"#

    @Test("PI 全链路:注册推送、应答寻址、settings 双向、sendTo 透传、断开通知")
    func piFlow() async throws {
        let sandbox = try makeSandbox()
        let model = PluginHostModel(pluginsRoot: sandbox.plugins, settingsRoot: sandbox.settings)
        model.start()
        try await waitUntil { model.port != 0 }

        // 实例先行:context 归属走 instances 反查路径
        model.syncKey(at: 0, action: .plugin(
            pluginID: Self.pluginUUID, actionUUID: Self.actionUUID, contextID: Self.contextID
        ))

        let plugin = try await FakeClient.connect(port: model.port)
        try plugin.send(#"{"uuid":"com.test.fake","event":"registerPlugin"}"#)
        let pluginBoot = try await plugin.readUntil(contains: "willAppear")
        #expect(pluginBoot.contains { $0.contains("deviceDidConnect") }, "插件注册应答缺 deviceDidConnect,实收 \(pluginBoot)")

        let pi = try await FakeClient.connect(port: model.port)
        try pi.send(#"{"event":"registerPropertyInspector","uuid":"ctx-1"}"#)

        // ① 注册即推 didReceiveSettings(时序硬约束:OBS PI 等首条下行才初始化,否则界面永不显示)
        let piBoot = try await pi.readUntil(contains: "didReceiveSettings")
        #expect(piBoot.contains { $0.contains("ctx-1") }, "PI 注册未收到 didReceiveSettings 推送,实收 \(piBoot)")

        // ② 插件收到 propertyInspectorDidAppear
        let appear = try await plugin.readUntil(contains: "propertyInspectorDidAppear")
        #expect(appear.contains { $0.contains("propertyInspectorDidAppear") }, "实收 \(appear)")

        // ③ PI 的 getGlobalSettings 应答本连接(context 字段是 contextID,归属按注册反查)
        try pi.send(#"{"event":"getGlobalSettings","context":"ctx-1"}"#)
        let global = try await pi.readUntil(contains: "didReceiveGlobalSettings")
        #expect(global.contains { $0.contains(Self.pluginUUID) }, "实收 \(global)")

        // ④ PI setSettings → 插件实时收 didReceiveSettings;⑤ 落盘持久化
        try pi.send(#"{"event":"setSettings","context":"ctx-1","payload":{"k":"v"}}"#)
        let push = try await plugin.readUntil(contains: "didReceiveSettings")
        #expect(push.contains { $0.contains("\"k\"") }, "插件未实时收到 settings 变更,实收 \(push)")
        let persisted = PluginSettingsStore(baseURL: sandbox.settings).document(pluginUUID: Self.pluginUUID)
        #expect(persisted.contexts[Self.contextID]?.settings == .object(["k": .string("v")]),
                "PI 的 setSettings 未落盘:\(persisted.contexts)")

        // ⑥ PI sendToPlugin 原帧透传给插件
        try pi.send(#"{"event":"sendToPlugin","action":"com.test.fake.action","context":"ctx-1","payload":{"x":1}}"#)
        let relayed = try await plugin.readUntil(contains: "sendToPlugin")
        #expect(relayed.contains { $0.contains("sendToPlugin") }, "实收 \(relayed)")

        // ⑦ 插件 sendToPropertyInspector 原帧透传给 PI
        try plugin.send(#"{"event":"sendToPropertyInspector","context":"ctx-1","payload":{"y":2}}"#)
        let toPI = try await pi.readUntil(contains: "sendToPropertyInspector")
        #expect(toPI.contains { $0.contains("sendToPropertyInspector") }, "实收 \(toPI)")

        // ⑧ PI 断开 → 插件收 propertyInspectorDidDisappear
        pi.close()
        let disappear = try await plugin.readUntil(contains: "propertyInspectorDidDisappear")
        #expect(disappear.contains { $0.contains("propertyInspectorDidDisappear") }, "实收 \(disappear)")

        plugin.close()
        model.shutdown()
    }

    /// 草稿态预登记:instances 无此 context 时靠 pendingPI 定归属
    @Test("草稿态 PI 注册:pendingPI 兜底归属")
    @MainActor
    func pendingPIRegistration() async throws {
        let sandbox = try makeSandbox()
        let model = PluginHostModel(pluginsRoot: sandbox.plugins, settingsRoot: sandbox.settings)
        model.start()
        try await waitUntil { model.port != 0 }

        model.registerPendingPI(
            pluginUUID: Self.pluginUUID, actionUUID: Self.actionUUID, contextID: "draft-1"
        )
        let pi = try await FakeClient.connect(port: model.port)
        try pi.send(#"{"event":"registerPropertyInspector","uuid":"draft-1"}"#)
        let piBoot = try await pi.readUntil(contains: "didReceiveSettings")
        #expect(piBoot.contains { $0.contains("draft-1") && $0.contains(Self.actionUUID) },
                "草稿 context 未按预登记归属,实收 \(piBoot)")
        pi.close()

        // 未预登记的 context 注册被拒(无推送)
        let stranger = try await FakeClient.connect(port: model.port)
        try stranger.send(#"{"event":"registerPropertyInspector","uuid":"unknown-ctx"}"#)
        let silence = try await stranger.readUntil(contains: "didReceiveSettings", timeout: 0.8)
        #expect(silence.isEmpty, "未知 context 不应收到任何推送,实收 \(silence)")
        stranger.close()

        model.shutdown()
    }

    // MARK: - 沙盒与等待

    private struct Sandbox {
        let root: URL
        let plugins: URL
        let settings: URL
    }

    private func makeSandbox() throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-pi-\(UUID().uuidString)")
        let plugins = root.appendingPathComponent("plugins")
        let settings = root.appendingPathComponent("pluginSettings")
        let pluginDir = plugins.appendingPathComponent("\(Self.pluginUUID).sdPlugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try Data(Self.manifestJSON.utf8).write(to: pluginDir.appendingPathComponent("manifest.json"))
        return Sandbox(root: root, plugins: plugins, settings: settings)
    }

    private func waitUntil(_ condition: () -> Bool, timeout seconds: Double = 3) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "等待超时")
    }
}

/// 极简 RFC6455 客户端(阻塞 IO 跑在后台线程;SO_RCVTIMEO 防挂死)
private final class FakeClient: @unchecked Sendable {
    let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func connect(port: UInt16) async throws -> FakeClient {
        try await Task.detached(priority: .userInitiated) {
            let fd = Self.rawConnect(port: port)
            guard fd >= 0 else { throw TestSocketError.connectFailed }
            return FakeClient(fd: fd)
        }.value
    }

    enum TestSocketError: Error { case connectFailed }

    private static func rawConnect(port: UInt16) -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return -1 }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            return -1
        }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        guard sendAll(descriptor, Data(request.utf8)) else {
            Darwin.close(descriptor)
            return -1
        }
        var head = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while !head.contains(terminator) {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            head.append(contentsOf: buffer[0..<count])
        }
        return descriptor
    }

    func send(_ text: String) throws {
        let data = Data(text.utf8)
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        var frame = Data([0x81])
        let count = data.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else {
            frame.append(0x80 | 126)
            frame.append(UInt8(count >> 8))
            frame.append(UInt8(count & 0xFF))
        }
        frame.append(contentsOf: mask)
        var payload = data
        for index in 0..<payload.count {
            payload[index] ^= mask[index % 4]
        }
        frame.append(payload)
        let ok = frame.withUnsafeBytes { raw in
            Self.sendAll(fd, Data(raw))
        }
        try #require(ok, "发送失败 errno=\(errno)")
    }

    /// 累积读文本帧直到某帧包含 needle;超时返回已收内容(断言方自行判断)
    func readUntil(contains needle: String, timeout: TimeInterval = 3) async throws -> [String] {
        let collected = try await Task.detached(priority: .userInitiated) { [fd] () -> [String] in
            var texts: [String] = []
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                guard let frame = Self.readFrame(fd: fd),
                      let text = String(data: frame, encoding: .utf8)
                else { continue }
                texts.append(text)
                if text.contains(needle) { return texts }
            }
            return texts
        }.value
        return collected
    }

    func close() {
        Darwin.close(fd)
    }

    // MARK: - 帧读写(服务端下行帧不带掩码)

    private static func readFrame(fd: Int32) -> Data? {
        var header = [UInt8](repeating: 0, count: 2)
        guard readFully(fd, &header) else { return nil }
        var length = Int(header[1] & 0x7F)
        if length == 126 {
            var ext = [UInt8](repeating: 0, count: 2)
            guard readFully(fd, &ext) else { return nil }
            length = Int(ext[0]) << 8 | Int(ext[1])
        } else if length == 127 {
            var ext = [UInt8](repeating: 0, count: 8)
            guard readFully(fd, &ext) else { return nil }
            length = ext.reduce(0) { $0 << 8 | Int($1) }
        }
        guard length > 0 else { return Data() }
        var payload = [UInt8](repeating: 0, count: length)
        guard readFully(fd, &payload) else { return nil }
        return Data(payload)
    }

    private static func readFully(_ fd: Int32, _ buffer: inout [UInt8]) -> Bool {
        var received = 0
        let total = buffer.count
        while received < total {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress!.advanced(by: received), total - received)
            }
            guard count > 0 else { return false } // 超时(SO_RCVTIMEO)或对端关闭
            received += count
        }
        return true
    }

    private static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
    }
}
