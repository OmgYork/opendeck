import AppKit
import CoreGraphics
import ImageIO
import Observation
import PluginHost
import StreamDockKit

/// 插件宿主协调器:把按键事件/键位配置翻译成 Elgato SD SDK v2 协议,
/// 把插件推来的图像/状态渲染回设备。单 context = 一颗键上的一个插件动作实例。
/// 生命周期:进程按需拉起(首个实例出现时),退出时统一收割;崩溃自动重启(有界)。
@MainActor
@Observable
final class PluginHostModel {
    /// 上层(AppModel)注入的输出钩子
    struct Hooks {
        var draw: (Int, CGImage) -> Void = { _, _ in }
        var backgroundColor: (Int) -> String = { _ in "#3B4252" }
        var open: (URL) -> Void = { _ in }
        var log: (String) -> Void = { _ in }
    }

    @ObservationIgnored var hooks = Hooks()

    /// 已安装插件(UI 动作选择器与插件管理器共用)
    private(set) var installedPlugins: [InstalledPlugin] = []
    private(set) var brokenPlugins: [String] = []
    /// WS 服务端口(0 = 未就绪)
    private(set) var port: UInt16 = 0

    private let server = PluginServer()
    private let registry = PluginRegistry(pluginsRoot: PluginRegistry.defaultRoot())
    private let settingsStore = PluginSettingsStore(
        baseURL: PluginRegistry.defaultRoot().deletingLastPathComponent().appendingPathComponent("pluginSettings")
    )

    // MARK: 运行时状态

    /// 引用类型:消息处理中原地变更状态/图像,mutations 直写字典持有的实例
    private final class Instance {
        let contextID: String
        let pluginUUID: String
        let actionUUID: String
        let keyIndex: Int
        /// 当前状态(多状态 action 的下标;持久化于 pluginSettings,跨重启稳定)
        var state: Int = 0
        /// setImage 未指定 state = 作用于所有状态
        var allStateImage: CGImage?
        var stateImages: [Int: CGImage] = [:]
        var title: String?

        init(contextID: String, pluginUUID: String, actionUUID: String, keyIndex: Int, state: Int) {
            self.contextID = contextID
            self.pluginUUID = pluginUUID
            self.actionUUID = actionUUID
            self.keyIndex = keyIndex
            self.state = state
        }
    }

    private final class Runtime {
        let manifest: SDManifest
        let directoryURL: URL
        var process: PluginProcess?
        var connection: PluginServer.Connection?
        var registered = false
        var respawnAttempts = 0
        var wantsSpawn = false

        init(manifest: SDManifest, directoryURL: URL) {
            self.manifest = manifest
            self.directoryURL = directoryURL
        }

        var actionFor: [SDManifest.Action] { manifest.keypadActions }
        func action(uuid: String) -> SDManifest.Action? { manifest.keypadActions.first { $0.uuid == uuid } }
    }

    private var runtimes: [String: Runtime] = [:]
    private var instances: [String: Instance] = [:]
    private var pluginByConnection: [UUID: String] = [:]
    private var serverStarted = false
    /// settings 文档缓存:OBS 等插件高频 setGlobalSettings,无变化不落盘
    private var settingsCache: [String: PluginSettingsDocument] = [:]

    init() {}

    // MARK: - 生命周期

    func start() {
        guard !serverStarted else { return }
        serverStarted = true

        server.onReady = { [weak self] port in
            Task { @MainActor in
                guard let self else { return }
                self.port = port
                self.hooks.log("插件宿主 WebSocket 就绪 @:\(port)")
                for runtime in self.runtimes.values where runtime.wantsSpawn {
                    self.spawn(runtime)
                }
            }
        }
        server.onOpen = { [weak self] connection in
            Task { @MainActor in
                self?.pluginByConnection[connection.id] = nil // 等注册包归属
            }
        }
        server.onMessage = { [weak self] connection, data in
            Task { @MainActor in
                self?.handleMessage(connection: connection, data: data)
            }
        }
        server.onClose = { [weak self] connection in
            Task { @MainActor in
                self?.handleDisconnect(connection)
            }
        }
        server.onError = { [weak self] message in
            Task { @MainActor in self?.hooks.log("插件宿主: \(message)") }
        }
        server.start()
        reloadInstalledPlugins()
    }

    /// 退出收割:停监听 + SIGTERM 全部 node(有宽限)
    func shutdown() {
        for runtime in runtimes.values {
            runtime.process?.terminate()
            runtime.process = nil
            runtime.connection = nil
            runtime.registered = false
        }
        server.stop()
        serverStarted = false
        port = 0
    }

    /// 重新扫描插件库(安装/卸载后调用)
    func reloadInstalledPlugins() {
        let result = registry.installedPlugins()
        installedPlugins = result.plugins
        brokenPlugins = result.broken
    }

    // MARK: - 键位同步(AppModel.applyKey 在启动/编辑/整页刷新时逐键调用)

    func syncKey(at index: Int, action: KeyAction?) {
        let existing = instances.values.first { $0.keyIndex == index }

        guard case .plugin(let pluginID, let actionUUID, let contextID) = action else {
            if let existing {
                sendWillDisappear(existing)
                instances.removeValue(forKey: existing.contextID)
            }
            return
        }

        if let existing, existing.contextID == contextID {
            return // 未变化
        }
        if let existing {
            sendWillDisappear(existing) // 换了插件/动作:旧实例退场
            instances.removeValue(forKey: existing.contextID)
        }

        guard let runtime = ensureRuntime(pluginUUID: pluginID) else {
            hooks.log("插件未安装,动作暂不生效:\(pluginID)")
            return
        }
        let record = document(pluginUUID: pluginID).contexts[contextID] ?? PluginContextRecord()
        instances[contextID] = Instance(
            contextID: contextID,
            pluginUUID: pluginID,
            actionUUID: actionUUID,
            keyIndex: index,
            state: record.state
        )
        if runtime.registered {
            sendWillAppear(instances[contextID]!, runtime: runtime)
        }
    }

    // MARK: - 按键事件(AppModel.onKeyEvent 分流;按下抬起两沿都要)

    func handleKey(index: Int, phase: KeyEvent.Phase) {
        guard let instance = instances.values.first(where: { $0.keyIndex == index }),
              let runtime = runtimes[instance.pluginUUID],
              runtime.registered
        else { return }

        let device = SDProtocol.Device.streamDock293V3
        let settings = currentSettings(instance)
        let row = index / StreamDock293S.columns
        let column = index % StreamDock293S.columns
        switch phase {
        case .down:
            send(SDProtocol.keyDown(action: instance.actionUUID, context: instance.contextID,
                                    device: device, settings: settings, row: row, column: column,
                                    state: instance.state), runtime: runtime)
        case .up:
            send(SDProtocol.keyUp(action: instance.actionUUID, context: instance.contextID,
                                  device: device, settings: settings, row: row, column: column,
                                  state: instance.state), runtime: runtime)
            // 未禁用自动状态的 action:宿主代为轮换(Elgato 行为;OBS 全系已禁用,不受影响)
            if let manifestAction = runtime.action(uuid: instance.actionUUID),
               !manifestAction.disableAutomaticStates, manifestAction.stateCount > 1 {
                let next = (instance.state + 1) % manifestAction.stateCount
                setState(instance, next)
            }
        }
    }

    // MARK: - 协议消息

    private func handleMessage(connection: PluginServer.Connection, data: Data) {
        #if DEBUG
        if let raw = try? JSONSerialization.jsonObject(with: data),
           let obj = raw as? [String: Any], let ev = obj["event"] as? String {
            let stateValue = (obj["payload"] as? [String: Any])?["state"].map { "\($0)" } ?? "-"
            print("📥 \(ev) state=\(stateValue) ctx=\(obj["context"] ?? "?")")
        }
        #endif
        // 注册包必须先行处理:它建立连接→插件的归属关系,路由守卫在其后才成立
        if let first = SDProtocol.parse(data), case .registered(let uuid) = first {
            pluginByConnection[connection.id] = uuid
            guard let runtime = runtimes[uuid] else {
                hooks.log("未知插件注册(未配置):\(uuid)")
                return
            }
            runtime.connection = connection
            runtime.registered = true
            runtime.respawnAttempts = 0
            hooks.log("插件已注册:\(uuid)")
            send(SDProtocol.deviceDidConnect(.streamDock293V3), runtime: runtime)
            for instance in instances.values where instance.pluginUUID == uuid {
                sendWillAppear(instance, runtime: runtime)
            }
            return
        }

        guard let pluginUUID = pluginByConnection[connection.id],
              let runtime = runtimes[pluginUUID]
        else { return } // 未注册的连接不发业务消息

        switch SDProtocol.parse(data) {
        case .registered:
            break // 已由上方注册分支处理

        case .setImage(let context, let image, let state, let target):
            guard let instance = self.instance(context: context) else { return }
            guard target != 2 else { return } // 纯软件图,M2 不维护软件预览
            if image?.isEmpty ?? true {
                // 空串 = 恢复 manifest 默认图
                if let state {
                    instance.stateImages[state] = nil
                } else {
                    instance.allStateImage = nil
                }
            } else if let cgImage = PluginImageDecoder.decodeCGImage(from: image) {
                if let state {
                    instance.stateImages[state] = cgImage
                } else {
                    instance.allStateImage = cgImage
                }
            } else {
                hooks.log("setImage 解码失败(SVG 或坏数据),回退默认图")
            }
            redraw(instance)

        case .setTitle(let context, let title, _, _):
            guard let instance = self.instance(context: context) else { return }
            // M2 已知限制:多行标题折叠为单行
            instance.title = title?.replacingOccurrences(of: "\n", with: " ")
            redraw(instance)

        case .setState(let context, let state):
            guard let instance = self.instance(context: context) else { return }
            setState(instance, state)

        case .setSettings(let context, let settings):
            guard let instance = self.instance(context: context) else { return }
            var document = document(pluginUUID: instance.pluginUUID)
            document.contexts[instance.contextID, default: PluginContextRecord()].settings = settings
            saveDocument(document, pluginUUID: instance.pluginUUID)

        case .getSettings(let context):
            guard let instance = self.instance(context: context) else { return }
            let row = instance.keyIndex / StreamDock293S.columns
            let column = instance.keyIndex % StreamDock293S.columns
            send(SDProtocol.didReceiveSettings(
                action: instance.actionUUID, context: instance.contextID,
                settings: currentSettings(instance), row: row, column: column
            ), runtime: runtime)

        case .setGlobalSettings(_, let settings):
            var document = document(pluginUUID: pluginUUID)
            document.globalSettings = settings
            saveDocument(document, pluginUUID: pluginUUID)

        case .getGlobalSettings:
            // OBS 插件硬需求:必答,否则其全局设置为空
            send(SDProtocol.didReceiveGlobalSettings(
                pluginUUID: pluginUUID,
                settings: document(pluginUUID: pluginUUID).globalSettings
            ), runtime: runtime)

        case .showOk:
            hooks.log("插件 showOk(设备无对应反馈,仅记录)")
        case .showAlert:
            hooks.log("插件报告异常(showAlert)")
        case .openURL(let url):
            hooks.open(URL(string: url) ?? URL(fileURLWithPath: "/dev/null"))
        case .logMessage(let text):
            hooks.log("插件日志:\(text)")
        case .unhandled(let event):
            hooks.log("插件事件(忽略):\(event)")
        case nil:
            hooks.log("插件发来非 JSON 帧(\(data.count)B),忽略")
        }
    }

    private func handleDisconnect(_ connection: PluginServer.Connection) {
        // 只标记状态;重启统一由进程退出路径负责(插件进程在 ws 关闭时会自行退出,
        // 避免这里重启出一个、旧的还活着的双进程局面)
        guard let pluginUUID = pluginByConnection.removeValue(forKey: connection.id),
              let runtime = runtimes[pluginUUID]
        else { return }
        runtime.connection = nil
        runtime.registered = false
        hooks.log("插件连接断开:\(pluginUUID)")
    }

    // MARK: - 渲染

    private func redraw(_ instance: Instance) {
        let index = instance.keyIndex
        let column = index % StreamDock293S.columns
        let size = StreamDock293S.keySize(column: column)
        let base = instance.stateImages[instance.state]
            ?? instance.allStateImage
            ?? manifestDefaultImage(instance)
        guard let image = IconRenderer.render(
            size: size,
            backgroundColorHex: hooks.backgroundColor(index),
            title: instance.title,
            baseImage: base
        ) else {
            hooks.log("插件键面渲染失败 key=\(index)")
            return
        }
        hooks.draw(index, image)
    }

    /// manifest States[state].Image → CGImage(图片常无扩展名,由 SDManifest 探测)
    private func manifestDefaultImage(_ instance: Instance) -> CGImage? {
        guard let runtime = runtimes[instance.pluginUUID],
              let action = runtime.action(uuid: instance.actionUUID)
        else { return nil }
        let path = instance.state < action.stateImages.count ? action.stateImages[instance.state] : nil
        guard let url = SDManifest.resolveImageURL(pluginRoot: runtime.directoryURL, manifestPath: path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func setState(_ instance: Instance, _ state: Int) {
        instance.state = state
        var document = document(pluginUUID: instance.pluginUUID)
        document.contexts[instance.contextID, default: PluginContextRecord()].state = state
        saveDocument(document, pluginUUID: instance.pluginUUID)
        redraw(instance)
    }

    private func document(pluginUUID: String) -> PluginSettingsDocument {
        if let cached = settingsCache[pluginUUID] { return cached }
        let document = settingsStore.document(pluginUUID: pluginUUID)
        settingsCache[pluginUUID] = document
        return document
    }

    private func saveDocument(_ document: PluginSettingsDocument, pluginUUID: String) {
        guard settingsCache[pluginUUID] != document else { return }
        settingsCache[pluginUUID] = document
        settingsStore.save(document, pluginUUID: pluginUUID)
    }

    private func currentSettings(_ instance: Instance) -> JSONValue {
        document(pluginUUID: instance.pluginUUID).contexts[instance.contextID]?.settings ?? .object([:])
    }

    // MARK: - 进程管理

    @discardableResult
    private func ensureRuntime(pluginUUID: String) -> Runtime? {
        if let runtime = runtimes[pluginUUID] { return runtime }
        guard let installed = installedPlugins.first(where: { $0.manifest.pluginUUID == pluginUUID }) else {
            return nil
        }
        let runtime = Runtime(manifest: installed.manifest, directoryURL: installed.directoryURL)
        runtimes[pluginUUID] = runtime
        if port == 0 {
            runtime.wantsSpawn = true // 服务未就绪,onReady 时补拉起
        } else {
            spawn(runtime)
        }
        return runtime
    }

    private func spawn(_ runtime: Runtime) {
        guard port != 0, runtime.process == nil,
              let entry = runtime.manifest.entryPathMac
        else { return }
        guard let nodeURL = NodeLocator.locate() else {
            hooks.log("未找到 node(装官方 StreamDock.app 或系统 node 后重试):\(runtime.manifest.pluginUUID)")
            return
        }
        let info = SDProtocol.registrationInfo(
            pluginUUID: runtime.manifest.pluginUUID,
            pluginVersion: runtime.manifest.version,
            device: .streamDock293V3
        )
        let process = PluginProcess(
            pluginUUID: runtime.manifest.pluginUUID,
            nodeURL: nodeURL,
            entryURL: runtime.directoryURL.appendingPathComponent(entry),
            workingDirectory: runtime.directoryURL,
            port: port,
            infoJSON: String(data: SDProtocol.encode(info), encoding: .utf8) ?? "{}"
        )
        process.onExit = { [weak self] _, code, tail in
            Task { @MainActor in
                guard let self, let runtime = self.runtimes[process.pluginUUID],
                      runtime.process === process
                else { return } // 已被收割/替换
                runtime.process = nil
                self.hooks.log("插件进程退出 code=\(code)\(tail.isEmpty ? "" : " | \(tail.suffix(300))")")
                self.handleDisconnectAttempt(runtime)
            }
        }
        process.onSpawnError = { [weak self] message in
            Task { @MainActor in self?.hooks.log(message) }
        }
        runtime.wantsSpawn = false
        runtime.process = process
        process.start()
        hooks.log("已拉起插件进程:\(runtime.manifest.pluginUUID) @:\(port)")
    }

    /// 进程退出后的重启判定(handleDisconnect 管连接级,这里管进程级)
    private func handleDisconnectAttempt(_ runtime: Runtime) {
        guard hasInstances(pluginUUID: runtime.manifest.pluginUUID) else { return }
        guard runtime.respawnAttempts < 3 else {
            hooks.log("插件连续失败,停止重启:\(runtime.manifest.pluginUUID)")
            return
        }
        runtime.respawnAttempts += 1
        let delay = Double(runtime.respawnAttempts) * 2
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, let runtime = self.runtimes[runtime.manifest.pluginUUID],
                  runtime.process == nil, self.serverStarted
            else { return }
            self.spawn(runtime)
        }
    }

    private func hasInstances(pluginUUID: String) -> Bool {
        instances.values.contains { $0.pluginUUID == pluginUUID }
    }

    // MARK: - 发送辅助

    private func sendWillAppear(_ instance: Instance, runtime: Runtime) {
        let record = document(pluginUUID: instance.pluginUUID).contexts[instance.contextID] ?? PluginContextRecord()
        send(SDProtocol.willAppear(
            action: instance.actionUUID,
            context: instance.contextID,
            device: .streamDock293V3,
            settings: record.settings,
            row: instance.keyIndex / StreamDock293S.columns,
            column: instance.keyIndex % StreamDock293S.columns,
            state: record.state
        ), runtime: runtime)
    }

    private func sendWillDisappear(_ instance: Instance) {
        guard let runtime = runtimes[instance.pluginUUID], runtime.registered else { return }
        send(SDProtocol.willDisappear(
            action: instance.actionUUID,
            context: instance.contextID,
            device: .streamDock293V3,
            settings: currentSettings(instance),
            row: instance.keyIndex / StreamDock293S.columns,
            column: instance.keyIndex % StreamDock293S.columns,
            state: instance.state
        ), runtime: runtime)
    }

    private func send(_ event: JSONValue, runtime: Runtime) {
        guard let connection = runtime.connection else { return }
        #if DEBUG
        if case .object(let o) = event, let ev = o["event"]?.stringValue {
            print("📤 \(ev) ctx=\(o["context"]?.stringValue ?? "-")")
        }
        #endif
        server.send(SDProtocol.encode(event), to: connection)
    }

    /// 消息自带 context(实例身份),按它路由——同一插件的多个键位实例互不干扰
    private func instance(context: String) -> Instance? {
        instances[context]
    }

    // MARK: - 插件管理器支撑

    func installPlugin(from url: URL) throws -> SDManifest {
        let manifest = try registry.install(from: url)
        reloadInstalledPlugins()
        return manifest
    }

    func importFromOfficialApp() -> [(name: String, error: String?)] {
        let results = registry.importFromOfficialDirectory()
        reloadInstalledPlugins()
        return results
    }

    func uninstallPlugin(id: String) throws {
        guard let installed = installedPlugins.first(where: { $0.manifest.pluginUUID == id }) else { return }
        try registry.uninstall(directoryName: installed.manifest.directoryName)
        settingsStore.removeDocument(pluginUUID: id)
        if let runtime = runtimes[id] {
            runtime.process?.terminate()
            runtime.process = nil
            runtime.connection = nil
            runtime.registered = false
            runtimes.removeValue(forKey: id)
        }
        settingsCache.removeValue(forKey: id)
        reloadInstalledPlugins()
    }

    /// 插件是否有存活进程(管理器状态点)
    func isRunning(pluginUUID: String) -> Bool {
        runtimes[pluginUUID]?.process != nil
    }
}
