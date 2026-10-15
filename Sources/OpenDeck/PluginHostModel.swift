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
    private let registry: PluginRegistry
    private let settingsStore: PluginSettingsStore

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

    /// 在开的 Property Inspector 连接归属(WKWebView 直连同一 WS 端口,注册包首条消息定归属)
    private final class PIRegistration {
        let pluginUUID: String
        let actionUUID: String
        let contextID: String
        let connection: PluginServer.Connection

        init(pluginUUID: String, actionUUID: String, contextID: String, connection: PluginServer.Connection) {
            self.pluginUUID = pluginUUID
            self.actionUUID = actionUUID
            self.contextID = contextID
            self.connection = connection
        }
    }

    private var piByConnection: [UUID: PIRegistration] = [:]
    /// 草稿态 PI 预登记:键尚未保存时 instances 查不到 context,注册包到达靠它兜底归属
    private var pendingPI: [String: PIIdentity] = [:]

    /// PI 归属三元组(预登记用;入表时与真实连接组成 PIRegistration)
    private struct PIIdentity {
        let pluginUUID: String
        let actionUUID: String
        let contextID: String
    }

    /// pluginsRoot/settingsRoot 可注入(单测指向临时目录);缺省 = 用户目录
    init(pluginsRoot: URL? = nil, settingsRoot: URL? = nil) {
        let root = pluginsRoot ?? PluginRegistry.defaultRoot()
        self.registry = PluginRegistry(pluginsRoot: root)
        self.settingsStore = PluginSettingsStore(
            baseURL: settingsRoot ?? root.deletingLastPathComponent().appendingPathComponent("pluginSettings")
        )
    }

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
        piByConnection.removeAll()
        pendingPI.removeAll()
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
        // PI 已归属连接:走 PI 专属处理(应答按请求连接寻址,不与插件连接混路)
        if piByConnection[connection.id] != nil {
            handlePIMessage(connection: connection, data: data)
            return
        }
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

        // PI 注册包(新连接首条消息):按 contextID 反查归属(instances 优先,草稿态预登记兜底)
        if let first = SDProtocol.parse(data), case .registeredPI(let contextID) = first {
            handlePIRegistration(connection: connection, contextID: contextID)
            return
        }

        guard let pluginUUID = pluginByConnection[connection.id],
              let runtime = runtimes[pluginUUID]
        else { return } // 未注册的连接不发业务消息

        switch SDProtocol.parse(data) {
        case .registered:
            break // 已由上方注册分支处理
        case .registeredPI, .sendToPlugin:
            hooks.log("插件连接发来 PI 专属消息,忽略")
        case .sendToPropertyInspector(let context, _):
            relayFrameToPI(context: context, data: data) // 插件 → PI 原帧透传

        case .setImage(let context, let image, let state, let target):
            applyImage(context: context, image: image, state: state, target: target)

        case .setTitle(let context, let title, _, _):
            applyTitle(context: context, title: title)

        case .setState(let context, let state):
            applyState(context: context, state: state)

        case .setSettings(let context, let settings):
            guard let instance = self.instance(context: context) else { return }
            persistContextSettings(pluginUUID: instance.pluginUUID, contextID: instance.contextID, settings: settings)
            // 在开 PI 同步(编辑器开着时插件改 settings,PI 界面不脱节)
            pushSettingsToPI(
                pluginUUID: instance.pluginUUID, actionUUID: instance.actionUUID,
                contextID: instance.contextID, settings: settings
            )

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

    // MARK: - Property Inspector 路由(M3)

    /// 实例业务逻辑(插件连接与 PI 连接共用;PI 会直接发 setTitle/setState/setImage 操纵键面)
    private func applyImage(context: String, image: String?, state: Int?, target: Int) {
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
    }

    private func applyTitle(context: String, title: String?) {
        guard let instance = self.instance(context: context) else { return }
        // M2 已知限制:多行标题折叠为单行
        instance.title = title?.replacingOccurrences(of: "\n", with: " ")
        redraw(instance)
    }

    private func applyState(context: String, state: Int) {
        guard let instance = self.instance(context: context) else { return }
        setState(instance, state)
    }

    private func persistContextSettings(pluginUUID: String, contextID: String, settings: JSONValue) {
        var document = document(pluginUUID: pluginUUID)
        document.contexts[contextID, default: PluginContextRecord()].settings = settings
        saveDocument(document, pluginUUID: pluginUUID)
    }

    /// settings 变更推给该 context 所有在开 PI(编辑器可同时开多个同 context 的 PI 吗?不能,但
    /// 草稿与实例短暂并存时靠它兜底;含发送方回显——OBS PI 的 onmessage 只换代理对象,无回路)
    private func pushSettingsToPI(pluginUUID: String, actionUUID: String, contextID: String, settings: JSONValue) {
        let instance = self.instance(context: contextID)
        let event = SDProtocol.didReceiveSettings(
            action: actionUUID, context: contextID, settings: settings,
            row: instance.map { $0.keyIndex / StreamDock293S.columns } ?? 0,
            column: instance.map { $0.keyIndex % StreamDock293S.columns } ?? 0
        )
        for pi in piByConnection.values where pi.contextID == contextID {
            send(event, to: pi.connection)
        }
    }

    /// PI 注册:归属反查 → 记表 → 推 didReceiveSettings(时序硬约束,OBS PI 等首条下行才初始化)
    private func handlePIRegistration(connection: PluginServer.Connection, contextID: String) {
        let registration: PIRegistration
        if let instance = instance(context: contextID) {
            registration = PIRegistration(
                pluginUUID: instance.pluginUUID, actionUUID: instance.actionUUID,
                contextID: contextID, connection: connection
            )
        } else if let pending = pendingPI.removeValue(forKey: contextID) {
            registration = PIRegistration(
                pluginUUID: pending.pluginUUID, actionUUID: pending.actionUUID,
                contextID: contextID, connection: connection
            )
        } else {
            hooks.log("PI 注册被拒:未知 context=\(contextID)")
            return
        }
        piByConnection[connection.id] = registration
        hooks.log("PI 已注册:\(registration.pluginUUID) ctx=\(contextID)")

        let instance = instance(context: contextID)
        send(SDProtocol.didReceiveSettings(
            action: registration.actionUUID,
            context: contextID,
            settings: piSettings(pluginUUID: registration.pluginUUID, contextID: contextID),
            row: instance.map { $0.keyIndex / StreamDock293S.columns } ?? 0,
            column: instance.map { $0.keyIndex % StreamDock293S.columns } ?? 0
        ), to: connection)

        // 插件感知 PI 出现(已注册的运行时才有接收方)
        if let runtime = runtimes[registration.pluginUUID], runtime.registered {
            send(SDProtocol.propertyInspectorDidAppear(
                action: registration.actionUUID, context: contextID, device: .streamDock293V3
            ), runtime: runtime)
        }
    }

    /// PI 连接消息:与插件路径共用实例业务逻辑,差别 = 应答按请求连接寻址 + 转发方向相反
    private func handlePIMessage(connection: PluginServer.Connection, data: Data) {
        guard let registration = piByConnection[connection.id] else { return }
        switch SDProtocol.parse(data) {
        case .getSettings(let context):
            let instance = self.instance(context: context)
            send(SDProtocol.didReceiveSettings(
                action: instance?.actionUUID ?? registration.actionUUID,
                context: context,
                settings: piSettings(pluginUUID: registration.pluginUUID, contextID: context),
                row: instance.map { $0.keyIndex / StreamDock293S.columns } ?? 0,
                column: instance.map { $0.keyIndex % StreamDock293S.columns } ?? 0
            ), to: connection)

        case .setSettings(let context, let settings):
            persistContextSettings(pluginUUID: registration.pluginUUID, contextID: context, settings: settings)
            // 实时生效:插件收 didReceiveSettings;在开 PI 同步(草稿/实例并存期不脱节)
            if let instance = instance(context: context) {
                pushSettingsToPlugin(instance, settings: settings)
            }
            pushSettingsToPI(
                pluginUUID: registration.pluginUUID, actionUUID: registration.actionUUID,
                contextID: context, settings: settings
            )

        case .getGlobalSettings:
            // PI 侧 context 字段填 contextID(action.js 实证),归属以注册反查结果为准
            send(SDProtocol.didReceiveGlobalSettings(
                pluginUUID: registration.pluginUUID,
                settings: document(pluginUUID: registration.pluginUUID).globalSettings
            ), to: connection)

        case .setGlobalSettings(_, let settings):
            var doc = document(pluginUUID: registration.pluginUUID)
            doc.globalSettings = settings
            saveDocument(doc, pluginUUID: registration.pluginUUID)
            if let runtime = runtimes[registration.pluginUUID], runtime.registered {
                send(SDProtocol.didReceiveGlobalSettings(
                    pluginUUID: registration.pluginUUID, settings: settings
                ), runtime: runtime)
            }

        case .sendToPlugin:
            // PI → 插件原帧透传(已注册的运行时才有接收方)
            if let runtime = runtimes[registration.pluginUUID], let target = runtime.connection {
                server.send(data, to: target)
            } else {
                hooks.log("sendToPlugin 无已注册插件接收,丢弃:\(registration.pluginUUID)")
            }

        case .setImage(let context, let image, let state, let target):
            applyImage(context: context, image: image, state: state, target: target)
        case .setTitle(let context, let title, _, _):
            applyTitle(context: context, title: title)
        case .setState(let context, let state):
            applyState(context: context, state: state)

        case .registered, .registeredPI, .sendToPropertyInspector:
            break // 不该出现在 PI 连接上
        case .showOk:
            hooks.log("PI showOk(设备无对应反馈,仅记录)")
        case .showAlert:
            hooks.log("PI 报告异常(showAlert)")
        case .openURL(let url):
            hooks.open(URL(string: url) ?? URL(fileURLWithPath: "/dev/null"))
        case .logMessage(let text):
            hooks.log("PI 日志:\(text)")
        case .unhandled(let event):
            hooks.log("PI 事件(忽略):\(event)")
        case nil:
            hooks.log("PI 发来非 JSON 帧(\(data.count)B),忽略")
        }
    }

    /// 插件 → PI 原帧透传:按 context 找在开 PI;无接收方记日志丢弃
    private func relayFrameToPI(context: String?, data: Data) {
        guard let context else { return }
        var relayed = 0
        for pi in piByConnection.values where pi.contextID == context {
            server.send(data, to: pi.connection)
            relayed += 1
        }
        if relayed == 0 {
            hooks.log("sendToPropertyInspector 无在开 PI,丢弃 ctx=\(context)")
        }
    }

    /// PI 侧 setSettings 后实时通知插件(与插件路径共用 send 寻址)
    private func pushSettingsToPlugin(_ instance: Instance, settings: JSONValue) {
        guard let runtime = runtimes[instance.pluginUUID], runtime.registered else { return }
        send(SDProtocol.didReceiveSettings(
            action: instance.actionUUID, context: instance.contextID, settings: settings,
            row: instance.keyIndex / StreamDock293S.columns,
            column: instance.keyIndex % StreamDock293S.columns
        ), runtime: runtime)
    }

    // MARK: - PI 公共 API(UI 层:PropertyInspectorView)

    /// 打开 PI 前调用:确保插件运行时就绪(sendToPlugin/DidAppear 才有接收方)
    func prepareForPI(pluginUUID: String) {
        ensureRuntime(pluginUUID: pluginUUID)
    }

    /// 草稿态预登记(键未保存时 instances 查不到 context);PI 注册成功即消费,取消时显式清除
    func registerPendingPI(pluginUUID: String, actionUUID: String, contextID: String) {
        pendingPI[contextID] = PIIdentity(pluginUUID: pluginUUID, actionUUID: actionUUID, contextID: contextID)
    }

    func clearPendingPI(contextID: String) {
        pendingPI.removeValue(forKey: contextID)
    }

    /// context 的当前 settings(草稿态无实例也查得到;PI 引导 info 用)
    func piSettings(pluginUUID: String, contextID: String) -> JSONValue {
        document(pluginUUID: pluginUUID).contexts[contextID]?.settings ?? .object([:])
    }

    /// PI 页面文件 URL(插件根 + manifest 相对路径);该动作无 PI 页返回 nil
    func piPageURL(pluginID: String, actionUUID: String) -> URL? {
        guard let installed = installedPlugins.first(where: { $0.manifest.pluginUUID == pluginID }),
              let path = installed.manifest.piPagePath(actionUUID: actionUUID)
        else { return nil }
        return installed.directoryURL.appendingPathComponent(path)
    }

    /// PI 文件访问域 = 插件根(PI 需 XHR 插件根的 <lang>.json i18n 文件,已实证)
    func pluginRootURL(pluginID: String) -> URL? {
        installedPlugins.first(where: { $0.manifest.pluginUUID == pluginID })?.directoryURL
    }

    /// PI 引导第 4 参:app JSON(registrationInfo 全量;PI 取 .application.language 加载语言包)
    func piRegistrationInfoJSON(pluginID: String) -> String? {
        guard let installed = installedPlugins.first(where: { $0.manifest.pluginUUID == pluginID }) else {
            return nil
        }
        let info = SDProtocol.registrationInfo(
            pluginUUID: installed.manifest.pluginUUID,
            pluginVersion: installed.manifest.version,
            device: .streamDock293V3
        )
        return String(data: SDProtocol.encode(info), encoding: .utf8)
    }

    /// PI 引导第 5 参:actionInfo JSON({action, context, payload.settings})
    func piActionInfoJSON(pluginID: String, actionUUID: String, contextID: String) -> String {
        let info = JSONValue.object([
            "action": .string(actionUUID),
            "context": .string(contextID),
            "payload": .object([
                "settings": piSettings(pluginUUID: pluginID, contextID: contextID),
                "coordinates": .object(["column": .int(0), "row": .int(0)]),
            ]),
        ])
        return String(data: SDProtocol.encode(info), encoding: .utf8) ?? "{}"
    }

    /// 删除 context 的持久化记录(草稿取消时清理 PI 已写入的孤儿数据)
    func removeContextRecord(pluginID: String, contextID: String) {
        var document = document(pluginUUID: pluginID)
        guard document.contexts.removeValue(forKey: contextID) != nil else { return }
        saveDocument(document, pluginUUID: pluginID)
    }

    private func handleDisconnect(_ connection: PluginServer.Connection) {
        // PI 连接:通知插件 PI 已消失并摘表;与插件进程断开语义无关
        if let pi = piByConnection.removeValue(forKey: connection.id) {
            if let runtime = runtimes[pi.pluginUUID], runtime.registered {
                send(SDProtocol.propertyInspectorDidDisappear(
                    action: pi.actionUUID, context: pi.contextID, device: .streamDock293V3
                ), runtime: runtime)
            }
            hooks.log("PI 连接断开:ctx=\(pi.contextID)")
            return
        }
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

    /// 按连接定向发送(PI 应答用;插件路径走 send(_:runtime:))
    private func send(_ event: JSONValue, to connection: PluginServer.Connection) {
        #if DEBUG
        if case .object(let o) = event, let ev = o["event"]?.stringValue {
            print("📤(PI) \(ev) ctx=\(o["context"]?.stringValue ?? "-")")
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
