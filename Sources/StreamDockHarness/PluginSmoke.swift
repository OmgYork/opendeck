// PluginSmoke — M2 插件宿主闭环冒烟(不依赖 app UI)
//
// 真实链路:PluginServer(WS)→ 拉起 node 插件进程 → 注册/willAppear → 插件 setImage/setState/setTitle
// → IconRenderer 渲染 → 设备上屏;物理按键 → keyDown/keyUp → 插件切状态。
// 退出码:0 = 插件成功上屏;2 = 未找到设备;4 = 前置失败(manifest/node);3 = 超时未见图像。

import CoreGraphics
import Foundation
import PluginHost
import StreamDockKit

/// 冒烟装置:单 context 单插件,最小宿主逻辑(完整版在 OpenDeck 的 PluginHostModel)
@MainActor
final class PluginSmokeRig {
    let controller: DeviceController
    let server = PluginServer()
    let manifest: SDManifest
    let pluginRoot: URL
    let action: SDManifest.Action
    let keyIndex: Int
    let contextID = "harness-ctx-1"
    let settings = JSONValue.object([:])

    var port: UInt16 = 0
    var process: PluginProcess?
    var connection: PluginServer.Connection?
    var state = 0
    var lastImage: CGImage?
    var lastTitle: String?
    var gotImage = false
    var gotRender = false // 任何一次成功上屏(setImage 或 manifest 默认图,OBS 用后者)
    var gotGlobalSettings = false
    var gotSyntheticFlip = false
    var physicalKeyEvents = 0

    init(controller: DeviceController, manifest: SDManifest, pluginRoot: URL, keyIndex: Int) throws {
        self.controller = controller
        self.manifest = manifest
        self.pluginRoot = pluginRoot
        self.keyIndex = keyIndex
        guard let action = manifest.keypadActions.first else {
            throw NSError(domain: "PluginSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "manifest 无 Keypad 型 action"])
        }
        self.action = action
    }

    var keySize: Int { StreamDock293S.keySize(column: keyIndex % StreamDock293S.columns) }

    func start(nodeURL: URL) {
        server.onReady = { [weak self] port in
            Task { @MainActor in self?.spawn(nodeURL: nodeURL, port: port) }
        }
        server.onOpen = { [weak self] connection in
            Task { @MainActor in
                print("🔌 插件已连接")
                self?.connection = connection
            }
        }
        server.onMessage = { [weak self] connection, data in
            Task { @MainActor in self?.handle(connection: connection, data: data) }
        }
        server.onClose = { [weak self] connection in
            Task { @MainActor in
                if self?.connection?.id == connection.id {
                    print("🔌 插件连接断开")
                    self?.connection = nil
                }
            }
        }
        server.onError = { message in
            Task { @MainActor in print("⚠️  server: \(message)") }
        }
        server.start()
    }

    func spawn(nodeURL: URL, port: UInt16) {
        self.port = port
        guard let entry = manifest.entryPathMac else {
            print("❌ manifest 无 CodePathMac/CodePath")
            exit(4)
        }
        let info = SDProtocol.registrationInfo(
            pluginUUID: manifest.pluginUUID,
            pluginVersion: manifest.version,
            device: .streamDock293V3
        )
        let infoJSON = String(data: SDProtocol.encode(info), encoding: .utf8) ?? "{}"
        let process = PluginProcess(
            pluginUUID: manifest.pluginUUID,
            nodeURL: nodeURL,
            entryURL: pluginRoot.appendingPathComponent(entry),
            workingDirectory: pluginRoot,
            port: port,
            infoJSON: infoJSON
        )
        process.onExit = { _, code, stderrTail in
            Task { @MainActor in
                print("❌ 插件进程退出 code=\(code)")
                if !stderrTail.isEmpty {
                    print("   stderr 尾部: \(stderrTail.suffix(600))")
                }
            }
        }
        process.onSpawnError = { message in
            Task { @MainActor in print("❌ \(message)") }
        }
        self.process = process
        process.start()
        print("🚀 已拉起 \(nodeURL.lastPathComponent) → \(manifest.pluginUUID) @:\(port)")
    }

    func handle(connection: PluginServer.Connection, data: Data) {
        guard let message = SDProtocol.parse(data) else {
            print("⬇️  非 JSON 帧(\(data.count)B)")
            return
        }
        print("⬇️  \(messageSummary(message))")

        switch message {
        case .registered:
            // 注册即发:可见实例 willAppear + 设备在线通知
            send(SDProtocol.willAppear(
                action: action.uuid, context: contextID, device: .streamDock293V3,
                settings: settings, row: keyIndex / 5, column: keyIndex % 5, state: state
            ))
            send(SDProtocol.deviceDidConnect(.streamDock293V3))
        case .getGlobalSettings:
            // OBS 插件同款硬需求:必须应答,否则其全局设置为空
            send(SDProtocol.didReceiveGlobalSettings(pluginUUID: manifest.pluginUUID, settings: .object([:])))
            gotGlobalSettings = true
        case .getSettings:
            send(SDProtocol.didReceiveSettings(
                action: action.uuid, context: contextID,
                settings: settings, row: keyIndex / 5, column: keyIndex % 5
            ))
        case .setImage(_, let image, _, _):
            guard let cgImage = PluginImageDecoder.decodeCGImage(from: image) else {
                print("⚠️  setImage 解码失败(SVG 或坏数据),回退默认图")
                redraw()
                return
            }
            lastImage = cgImage
            gotImage = true
            redraw()
        case .setTitle(_, let title, _, _):
            lastTitle = title?.replacingOccurrences(of: "\n", with: " ") // M2 已知限制:多行折叠
            redraw()
        case .setState(_, let newState):
            state = newState
            lastImage = nil // state 切换后回到 manifest 默认图
            redraw()
        default:
            break
        }
    }

    /// 重渲染当前键面:插件图 > manifest 默认图;标题叠加;预旋转后上屏(缓存于 DeviceController)
    func redraw() {
        let row = keyIndex / StreamDock293S.columns
        let column = keyIndex % StreamDock293S.columns
        let image: CGImage?
        if let lastImage {
            image = IconRenderer.render(size: keySize, backgroundColorHex: "#2E3440",
                                        title: lastTitle, baseImage: lastImage)
        } else {
            let manifestPath = state < action.stateImages.count ? action.stateImages[state] : nil
            let iconURL = SDManifest.resolveImageURL(pluginRoot: pluginRoot, manifestPath: manifestPath)
            image = IconRenderer.render(size: keySize, backgroundColorHex: "#2E3440",
                                        title: lastTitle, iconPath: iconURL?.path)
        }
        guard let image else {
            print("⚠️  渲染失败 r\(row)c\(column)")
            return
        }
        gotRender = true
        controller.drawKey(row: row, column: column, image: image)
    }

    func handleKeyEvent(_ event: KeyEvent) {
        let index = event.row * StreamDock293S.columns + event.column
        guard index == keyIndex, connection != nil else { return }
        if event.phase == .down {
            physicalKeyEvents += 1
        }
        switch event.phase {
        case .down:
            send(SDProtocol.keyDown(action: action.uuid, context: contextID, device: .streamDock293V3,
                                    settings: settings, row: event.row, column: event.column, state: state))
        case .up:
            send(SDProtocol.keyUp(action: action.uuid, context: contextID, device: .streamDock293V3,
                                  settings: settings, row: event.row, column: event.column, state: state))
            // 未禁用自动状态的 action:宿主代为轮换(Elgato 行为),OBS 类已禁用不受影响
            if !action.disableAutomaticStates && action.stateCount > 1 {
                state = (state + 1) % action.stateCount
                lastImage = nil
                redraw()
            }
        }
    }

    func send(_ event: JSONValue) {
        guard let connection else { return }
        server.send(SDProtocol.encode(event), to: connection)
    }

    func shutdown() {
        if let process {
            let tail = process.diagnosticTail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                print("📋 插件诊断尾部:\n\(tail.suffix(1200))")
            }
        }
        process?.terminate()
        server.stop()
    }

    private func messageSummary(_ message: PluginInbound) -> String {
        switch message {
        case .registered(let uuid): return "registered \(uuid)"
        case .registeredPI(let uuid): return "registeredPI ctx=\(uuid.prefix(12))"
        case .setImage(let context, let image, let state, let target):
            let preview = image.map { $0.isEmpty ? "<空串=恢复默认>" : "<\($0.prefix(28))…>" } ?? "<缺失>"
            return "setImage ctx=\(context.prefix(12)) image=\(preview) state=\(state.map(String.init) ?? "-") target=\(target)"
        case .setTitle(let context, let title, _, _): return "setTitle ctx=\(context.prefix(12)) title=\(title ?? "-")"
        case .setState(let context, let state): return "setState ctx=\(context.prefix(12)) state=\(state)"
        case .setSettings(let context, let settings): return "setSettings ctx=\(context.prefix(12)) \(settings)"
        case .getSettings(let context): return "getSettings ctx=\(context.prefix(12))"
        case .setGlobalSettings(let uuid, _): return "setGlobalSettings \(uuid.prefix(16))"
        case .getGlobalSettings(let uuid): return "getGlobalSettings \(uuid.prefix(16))"
        case .sendToPlugin(let action, let context, _): return "sendToPlugin action=\(action ?? "-") ctx=\(context?.prefix(12) ?? "-")"
        case .sendToPropertyInspector(let context, _): return "sendToPropertyInspector ctx=\(context?.prefix(12) ?? "-")"
        case .showOk: return "showOk"
        case .showAlert: return "showAlert"
        case .openURL(let url): return "openUrl \(url)"
        case .logMessage(let text): return "logMessage \(text)"
        case .unhandled(let event): return "unhandled \(event)(吞掉)"
        }
    }
}

/// 冒烟主流程;返回退出码(见文件头)
@MainActor
func runPluginSmoke(pluginDirectory: URL, nodeOverride: URL?, keyIndex: Int, listenSeconds: TimeInterval, controller: DeviceController) -> Int32 {
    guard let manifest = try? SDManifest.load(fromDirectory: pluginDirectory) else {
        print("❌ manifest 读取失败:\(pluginDirectory.path)")
        return 4
    }
    guard let rig = try? PluginSmokeRig(controller: controller, manifest: manifest, pluginRoot: pluginDirectory, keyIndex: keyIndex) else {
        print("❌ manifest 无可用 action")
        return 4
    }
    guard let nodeURL = nodeOverride ?? NodeLocator.locate() else {
        print("❌ 未找到 node(官方 app 未装且系统无 node)")
        return 4
    }
    print("🧪 插件冒烟:\(manifest.name) v\(manifest.version),node=\(nodeURL.path),验证键 index=\(keyIndex)")

    rig.start(nodeURL: nodeURL)
    controller.onKeyEvent = { event in
        Task { @MainActor in rig.handleKeyEvent(event) }
    }

    print("—— 监听 \(Int(listenSeconds)) 秒:3 秒后自动合成一次按键(协议闭环自证),期间手动按压验证键(编号 \(keyIndex + 1))可叠加物理验证 ——")
    let start = Date()
    let deadline = start.addingTimeInterval(listenSeconds)
    var syntheticFired = false
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        // 合成按键:走与物理事件完全相同的分发路径,无人值守也能验证 keyDown→setState 闭环
        if !syntheticFired, rig.gotRender, Date().timeIntervalSince(start) > 3 {
            syntheticFired = true
            let row = rig.keyIndex / StreamDock293S.columns
            let column = rig.keyIndex % StreamDock293S.columns
            let before = rig.state
            rig.handleKeyEvent(KeyEvent(row: row, column: column, phase: .down))
            rig.handleKeyEvent(KeyEvent(row: row, column: column, phase: .up))
            rig.gotSyntheticFlip = rig.state != before
            print("🧪 合成按键:state \(before) → \(rig.state),flip=\(rig.gotSyntheticFlip)")
        }
    }
    rig.shutdown()

    if rig.gotRender {
        print("✅ 插件图像已上屏(setImage \(rig.gotImage ? "有" : "无,走 manifest 默认图"),合成按键 flip=\(rig.gotSyntheticFlip),物理按压 \(rig.physicalKeyEvents) 次)")
        return 0
    }
    print("⚠️  监听窗口内未见任何上屏(退出码 3)")
    return 3
}
