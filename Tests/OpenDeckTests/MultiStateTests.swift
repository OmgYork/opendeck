import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PluginHost
import StreamDockKit
import Testing
@testable import OpenDeck

/// 多状态图标集成测试:假插件(真 WebSocket 客户端)+ 真 PluginHostModel,
/// 钉死 keyUp 自动轮换 / DisableAutomaticStates 豁免 / 按 state 渲染 manifest 默认图 /
/// state 持久化与重启回放(注册重放路径)。
/// FakeClient 为 PIFlowTests 同款迷你 RFC6455 客户端的移植(测试文件间不共享代码)。
@MainActor
@Suite("PluginHostModel 多状态(真 socket)")
struct MultiStateTests {
    private static let pluginUUID = "com.test.multistate"
    private static let actionUUID = "com.test.multistate.action"
    private static let contextID = "ctx-ms"

    /// 两态 manifest;DisableAutomaticStates 按用例注入
    private static func manifestJSON(disableAutomaticStates: Bool) -> String {
        let disable = disableAutomaticStates ? #","DisableAutomaticStates":true"# : ""
        return """
        {"Name":"ms","Version":"1.0","Actions":[{"UUID":"\(actionUUID)","Name":"A","States":[{"Image":"images/off"},{"Image":"images/on"}]\(disable)}]}
        """
    }

    // MARK: - 用例

    @Test("keyUp 自动轮换:0→1→回绕 0(宿主代管,无下行帧)")
    func autoCycle() async throws {
        let sandbox = try makeSandbox(disableAutomaticStates: false)
        let model = PluginHostModel(pluginsRoot: sandbox.plugins, settingsRoot: sandbox.settings)
        var logs: [String] = []
        model.hooks.log = { logs.append($0) }
        model.start()
        try await waitUntil { model.port != 0 }
        model.syncKey(at: 0, action: .plugin(
            pluginID: Self.pluginUUID, actionUUID: Self.actionUUID, contextID: Self.contextID
        ))

        let plugin = try await FakeClient.connect(port: model.port)
        try plugin.send(#"{"uuid":"com.test.multistate","event":"registerPlugin"}"#)
        let boot = await plugin.readUntil(contains: "willAppear")
        if boot.isEmpty {
            Issue.record("已装:\(model.installedPlugins.map(\.manifest.pluginUUID)) 坏:\(model.brokenPlugins) 日志:\(logs.joined(separator: " || "))")
        }
        #expect(boot.contains { $0.contains(#""state":0"#) }, "注册重放 willAppear 应带初始态 0,实收 \(boot)")

        model.handleKey(index: 0, phase: .up)
        #expect(persistedState(sandbox, contextID: Self.contextID) == 1, "keyUp 后应轮换到 1")
        model.handleKey(index: 0, phase: .up)
        #expect(persistedState(sandbox, contextID: Self.contextID) == 0, "尾态应回绕到 0")

        plugin.close()
        model.shutdown()
    }

    @Test("DisableAutomaticStates 豁免:keyUp 不轮换")
    func disableExemption() async throws {
        let sandbox = try makeSandbox(disableAutomaticStates: true)
        let model = PluginHostModel(pluginsRoot: sandbox.plugins, settingsRoot: sandbox.settings)
        model.start()
        try await waitUntil { model.port != 0 }
        model.syncKey(at: 0, action: .plugin(
            pluginID: Self.pluginUUID, actionUUID: Self.actionUUID, contextID: Self.contextID
        ))
        let plugin = try await FakeClient.connect(port: model.port)
        try plugin.send(#"{"uuid":"com.test.multistate","event":"registerPlugin"}"#)
        _ = await plugin.readUntil(contains: "willAppear")

        model.handleKey(index: 0, phase: .up)
        #expect(persistedState(sandbox, contextID: Self.contextID) == nil, "禁用自动状态的 action 不应被宿主轮换(无状态写)")

        plugin.close()
        model.shutdown()
    }

    @Test("单态动作:keyUp 不产生状态写")
    func singleStateNoCycle() async throws {
        let sandbox = try makeSandbox(disableAutomaticStates: false, singleState: true)
        let model = PluginHostModel(pluginsRoot: sandbox.plugins, settingsRoot: sandbox.settings)
        model.start()
        try await waitUntil { model.port != 0 }
        model.syncKey(at: 0, action: .plugin(
            pluginID: Self.pluginUUID, actionUUID: Self.actionUUID, contextID: Self.contextID
        ))
        let plugin = try await FakeClient.connect(port: model.port)
        try plugin.send(#"{"uuid":"com.test.multistate","event":"registerPlugin"}"#)
        _ = await plugin.readUntil(contains: "willAppear")

        model.handleKey(index: 0, phase: .up)
        #expect(persistedState(sandbox, contextID: Self.contextID) == nil, "单态动作不应写状态")

        plugin.close()
        model.shutdown()
    }

    @Test("按态选图:syncKey 上屏初始默认图,轮换后产物随 state 变化")
    func stateImageSelection() async throws {
        let sandbox = try makeSandbox(disableAutomaticStates: false)
        let model = PluginHostModel(pluginsRoot: sandbox.plugins, settingsRoot: sandbox.settings)
        var drawn: [CGImage] = []
        model.hooks.draw = { _, image in drawn.append(image) }
        model.start()
        try await waitUntil { model.port != 0 }

        // 上屏即显当前态默认图(此前瓷贴会一直贴到插件首次 setImage 为止)
        model.syncKey(at: 0, action: .plugin(
            pluginID: Self.pluginUUID, actionUUID: Self.actionUUID, contextID: Self.contextID
        ))
        try await waitUntil { !drawn.isEmpty }
        #expect(drawn.count == 1, "syncKey 应渲染一次当前态默认图,实绘 \(drawn.count) 次")
        let initial = try PNGEncoder.encode(try #require(drawn.first))

        let plugin = try await FakeClient.connect(port: model.port)
        try plugin.send(#"{"uuid":"com.test.multistate","event":"registerPlugin"}"#)
        _ = await plugin.readUntil(contains: "willAppear")

        model.handleKey(index: 0, phase: .up) // → state 1
        try await waitUntil { drawn.count >= 2 }
        let cycled = try PNGEncoder.encode(try #require(drawn.last))

        #expect(initial != cycled, "state 0/1 应选出不同 manifest 默认图(off/on),渲染产物不应相同")

        plugin.close()
        model.shutdown()
    }

    @Test("state 持久化回放:新模型注册重放 willAppear 带上次状态")
    func stateReplayAfterRestart() async throws {
        let sandbox = try makeSandbox(disableAutomaticStates: false)
        let model = PluginHostModel(pluginsRoot: sandbox.plugins, settingsRoot: sandbox.settings)
        model.start()
        try await waitUntil { model.port != 0 }
        model.syncKey(at: 0, action: .plugin(
            pluginID: Self.pluginUUID, actionUUID: Self.actionUUID, contextID: Self.contextID
        ))
        let first = try await FakeClient.connect(port: model.port)
        try first.send(#"{"uuid":"com.test.multistate","event":"registerPlugin"}"#)
        _ = await first.readUntil(contains: "willAppear")
        model.handleKey(index: 0, phase: .up) // → 1
        #expect(persistedState(sandbox, contextID: Self.contextID) == 1)
        first.close()
        model.shutdown()

        // 模拟重启:新模型(同盘)+ 新注册 → 重放 willAppear 必须带上 state 1
        let revived = PluginHostModel(pluginsRoot: sandbox.plugins, settingsRoot: sandbox.settings)
        revived.start()
        try await waitUntil { revived.port != 0 }
        revived.syncKey(at: 0, action: .plugin(
            pluginID: Self.pluginUUID, actionUUID: Self.actionUUID, contextID: Self.contextID
        ))
        let second = try await FakeClient.connect(port: revived.port)
        try second.send(#"{"uuid":"com.test.multistate","event":"registerPlugin"}"#)
        let replayed = await second.readUntil(contains: "willAppear")
        #expect(replayed.contains { $0.contains(#""state":1"#) }, "重启回放应携带上次状态 1,实收 \(replayed)")

        second.close()
        revived.shutdown()
    }

    @Test("manifest 声明 ActivateAppBundleID:抬起沿触发激活钩子,按下沿不触发")
    func pressActivatesDeclaredApp() async throws {
        let sandbox = try makeSandbox(disableAutomaticStates: false, singleState: true,
                                      activateBundleID: "dev.zcode.app")
        let model = PluginHostModel(pluginsRoot: sandbox.plugins, settingsRoot: sandbox.settings)
        var activated: [String] = []
        model.hooks.activateApp = { activated.append($0) }
        model.start()
        try await waitUntil { model.port != 0 }
        model.syncKey(at: 0, action: .plugin(
            pluginID: Self.pluginUUID, actionUUID: Self.actionUUID, contextID: Self.contextID
        ))
        let plugin = try await FakeClient.connect(port: model.port)
        try plugin.send(#"{"uuid":"com.test.multistate","event":"registerPlugin"}"#)
        _ = await plugin.readUntil(contains: "willAppear")

        model.handleKey(index: 0, phase: .down)
        #expect(activated.isEmpty, "按下沿只转发插件,不应触发激活")
        model.handleKey(index: 0, phase: .up)
        #expect(activated == ["dev.zcode.app"], "抬起沿应按 manifest 声明激活,实收 \(activated)")

        plugin.close()
        model.shutdown()
    }

    @Test("未声明 ActivateAppBundleID:keyUp 不触发激活钩子")
    func pressWithoutDeclarationNoActivate() async throws {
        let sandbox = try makeSandbox(disableAutomaticStates: false, singleState: true)
        let model = PluginHostModel(pluginsRoot: sandbox.plugins, settingsRoot: sandbox.settings)
        var activated: [String] = []
        model.hooks.activateApp = { activated.append($0) }
        model.start()
        try await waitUntil { model.port != 0 }
        model.syncKey(at: 0, action: .plugin(
            pluginID: Self.pluginUUID, actionUUID: Self.actionUUID, contextID: Self.contextID
        ))
        let plugin = try await FakeClient.connect(port: model.port)
        try plugin.send(#"{"uuid":"com.test.multistate","event":"registerPlugin"}"#)
        _ = await plugin.readUntil(contains: "willAppear")

        model.handleKey(index: 0, phase: .up)
        #expect(activated.isEmpty, "未声明的 action 不应触发激活")

        plugin.close()
        model.shutdown()
    }

    // MARK: - 沙盒与辅助

    private struct Sandbox {
        let root: URL
        let plugins: URL
        let settings: URL
    }

    /// 两态红绿 PNG(off/on)写入 images/,distinct 保证按态选图可断言
    private func makeSandbox(disableAutomaticStates: Bool, singleState: Bool = false,
                             activateBundleID: String? = nil) throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-ms-\(UUID().uuidString)")
        let plugins = root.appendingPathComponent("plugins")
        let settings = root.appendingPathComponent("pluginSettings")
        let pluginDir = plugins.appendingPathComponent("\(Self.pluginUUID).sdPlugin")
        let images = pluginDir.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let states = singleState ? [] : [#"{"Image":"images/off"}"#, #"{"Image":"images/on"}"#]
        let statesField = states.isEmpty ? "" : #","States":["# + states.joined(separator: ",") + #"]"#
        let activateField = activateBundleID.map { #","ActivateAppBundleID":"\#($0)""# } ?? ""
        let manifest = #"{"Name":"ms","Version":"1.0","Actions":[{"UUID":"\#(Self.actionUUID)","Name":"A"\#(statesField)\#(activateField)\#(disableAutomaticStates ? #","DisableAutomaticStates":true"# : "")}]}"#
        try Data(manifest.utf8).write(to: pluginDir.appendingPathComponent("manifest.json"))
        try PNGEncoder.solid(width: 16, height: 16, red: 0xDE, green: 0x3B, blue: 0x3B)
            .write(to: images.appendingPathComponent("off.png"))
        try PNGEncoder.solid(width: 16, height: 16, red: 0x3F, green: 0xB9, blue: 0x50)
            .write(to: images.appendingPathComponent("on.png"))
        return Sandbox(root: root, plugins: plugins, settings: settings)
    }

    private func persistedState(_ sandbox: Sandbox, contextID: String) -> Int? {
        PluginSettingsStore(baseURL: sandbox.settings)
            .load(pluginUUID: Self.pluginUUID).contexts[contextID]?.state
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

/// 纯色 PNG 生成(ImageIO)与 PNG 字节编码(产物差异断言用)
private enum PNGEncoder {
    static func solid(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> Data {
        let out = NSMutableData()
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)
        else { return Data() }
        ctx.setFillColor(CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                                 blue: CGFloat(blue) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { return Data() }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    enum PNGError: Error { case destinationCreationFailed }

    static func encode(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else {
            throw PNGError.destinationCreationFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

/// 极简 RFC6455 客户端(PIFlowTests 同款移植;阻塞 IO 跑后台线程,SO_RCVTIMEO 防挂死)
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

    func readUntil(contains needle: String, timeout: TimeInterval = 3) async -> [String] {
        let collected = await Task.detached(priority: .userInitiated) { [fd] () -> [String] in
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
            guard count > 0 else { return false }
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

// MARK: - §6.26 深度审计轮新增闸门

extension MultiStateTests {
    /// 插件/PI 发负值 setState:钳回 0 并持久化;旧实现负值沿「负下标订阅 manifest 数组」
    /// 崩溃且随持久化形成启动即崩死循环
    @Test("setState 负值:钳到 0,不崩宿主,持久化生效")
    func negativeStateClampsToZero() async throws {
        let sandbox = try makeSandbox(disableAutomaticStates: false)
        let model = PluginHostModel(pluginsRoot: sandbox.plugins, settingsRoot: sandbox.settings)
        model.start()
        try await waitUntil { model.port != 0 }
        model.syncKey(at: 0, action: .plugin(
            pluginID: Self.pluginUUID, actionUUID: Self.actionUUID, contextID: Self.contextID
        ))
        let plugin = try await FakeClient.connect(port: model.port)
        try plugin.send(#"{"uuid":"com.test.multistate","event":"registerPlugin"}"#)
        _ = await plugin.readUntil(contains: "willAppear")

        try plugin.send(#"{"event":"setState","context":"ctx-ms","payload":{"state":-5}}"#)
        try await waitUntil { persistedState(sandbox, contextID: Self.contextID) == 0 }
        #expect(persistedState(sandbox, contextID: Self.contextID) == 0)

        // 钳制后实例仍在(宿主没死):再发合法值照常轮换
        try plugin.send(#"{"event":"setState","context":"ctx-ms","payload":{"state":1}}"#)
        try await waitUntil { persistedState(sandbox, contextID: Self.contextID) == 1 }

        plugin.close()
        model.shutdown()
    }
}

// MARK: - §6.27 性能收尾轮新增闸门

extension MultiStateTests {
    /// 零实例回收 + 重进页重生:HTML 插件最后一个实例摘除 → webview 回收(日志可证);
    /// 重新分配键位 → 运行时重建(已拉起日志第二次出现)。node 家族不回收(常驻语义)
    @Test("HTML 运行时零实例回收,重新分配重生")
    func zeroInstanceTeardownAndRespawn() async throws {
        let sandbox = try makeSandboxHTMLPlugin()
        let model = PluginHostModel(pluginsRoot: sandbox.plugins, settingsRoot: sandbox.settings)
        var logs: [String] = []
        model.hooks.log = { logs.append($0) }
        model.start()
        try await waitUntil { model.port != 0 }

        model.syncKey(at: 0, action: .plugin(
            pluginID: Self.pluginUUID, actionUUID: Self.actionUUID, contextID: Self.contextID
        ))
        try await waitUntil { logs.contains { $0.contains("已拉起 HTML 插件页") } }

        // 摘除唯一实例:webview 应回收
        model.syncKey(at: 0, action: nil)
        try await waitUntil { logs.contains { $0.contains("回收 HTML 运行时") } }

        // 重新分配:运行时重建(第二次「已拉起」)
        model.syncKey(at: 0, action: .plugin(
            pluginID: Self.pluginUUID, actionUUID: Self.actionUUID, contextID: Self.contextID
        ))
        try await waitUntil {
            logs.filter { $0.contains("已拉起 HTML 插件页") }.count >= 2
        }
        model.shutdown()
    }

    /// HTML 家族沙盒(CodePath=index.html;不真加载页面,只验运行时生命周期与日志)
    private func makeSandboxHTMLPlugin() throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-html-\(UUID().uuidString)")
        let plugins = root.appendingPathComponent("plugins")
        let settings = root.appendingPathComponent("pluginSettings")
        let pluginDir = plugins.appendingPathComponent("\(Self.pluginUUID).sdPlugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifest = #"{"Name":"html","Version":"1.0","CodePath":"index.html","Actions":[{"UUID":"\#(Self.actionUUID)","Name":"A"}]}"#
        try Data(manifest.utf8).write(to: pluginDir.appendingPathComponent("manifest.json"))
        try Data("<html></html>".utf8).write(to: pluginDir.appendingPathComponent("index.html"))
        return Sandbox(root: root, plugins: plugins, settings: settings)
    }
}
