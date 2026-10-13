import Foundation

/// Elgato Stream Deck SDK v2 插件协议,宿主侧编解码。
/// 事实来源:developer.elgato.com 经典 v2 文档 + MiraBox 官方 OBS 插件源码归纳(2026-10-13 侦察,
/// 见 HANDOFF.md §1.4)。关键差异点:插件按 argv 位置取参、注册后必答 didReceiveGlobalSettings。
public enum SDProtocol {
    /// 提供给插件的设备描述;type 0 = Stream Deck(15 键 5×3),与 293V3 一致
    public struct Device: Sendable, Equatable {
        public let id: String
        public let name: String
        public let columns: Int
        public let rows: Int

        public init(id: String, name: String, columns: Int, rows: Int) {
            self.id = id
            self.name = name
            self.columns = columns
            self.rows = rows
        }

        /// 293V3:5 列 × 3 行
        public static let streamDock293V3 = Device(id: "OpenDeck-293V3", name: "Stream Dock", columns: 5, rows: 3)
    }

    // MARK: - info JSON(经 -info 参数传给插件进程;argv 顺序必须为 port/uuid/registerEvent/info)

    /// 经典 v2 结构;OBS 插件类初始化即 JSON.parse 后读 .application.language,缺失会启动即崩
    public static func registrationInfo(
        pluginUUID: String,
        pluginVersion: String,
        device: Device,
        appVersion: String = "6.5.0.20744"
    ) -> JSONValue {
        let language = Locale.preferredLanguages.first?
            .split(separator: "-").prefix(2).joined(separator: "_") ?? "en"
        return .object([
            "application": .object([
                "font": .string(".AppleSystemUIFont"),
                "language": .string(language),
                "platform": .string("mac"),
                "platformVersion": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                "version": .string(appVersion),
            ]),
            "colors": .object([
                "buttonMouseOverBackgroundColor": .string("#464646FF"),
                "buttonPressedBackgroundColor": .string("#303030FF"),
                "buttonPressedBorderColor": .string("#646464FF"),
                "buttonPressedTextColor": .string("#969696FF"),
                "highlightColor": .string("#0078FFFF"),
            ]),
            "devicePixelRatio": .int(2),
            "devices": .array([.object([
                "id": .string(device.id),
                "name": .string(device.name),
                "size": .object(["columns": .int(device.columns), "rows": .int(device.rows)]),
                "type": .int(0),
            ])]),
            // v2 键名为 plugin;pluginInfo 是极早期变体,两份都发对插件无害
            "plugin": .object(["uuid": .string(pluginUUID), "version": .string(pluginVersion)]),
            "pluginInfo": .object(["uuid": .string(pluginUUID), "version": .string(pluginVersion)]),
        ])
    }

    // MARK: - host → plugin 事件

    public static func encode(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    public static func willAppear(
        action: String, context: String, device: Device,
        settings: JSONValue, row: Int, column: Int, state: Int?
    ) -> JSONValue {
        instanceEvent("willAppear", action: action, context: context, device: device.id,
                      settings: settings, row: row, column: column, state: state)
    }

    public static func willDisappear(
        action: String, context: String, device: Device,
        settings: JSONValue, row: Int, column: Int, state: Int?
    ) -> JSONValue {
        instanceEvent("willDisappear", action: action, context: context, device: device.id,
                      settings: settings, row: row, column: column, state: state)
    }

    public static func keyDown(
        action: String, context: String, device: Device,
        settings: JSONValue, row: Int, column: Int, state: Int?
    ) -> JSONValue {
        instanceEvent("keyDown", action: action, context: context, device: device.id,
                      settings: settings, row: row, column: column, state: state)
    }

    public static func keyUp(
        action: String, context: String, device: Device,
        settings: JSONValue, row: Int, column: Int, state: Int?
    ) -> JSONValue {
        instanceEvent("keyUp", action: action, context: context, device: device.id,
                      settings: settings, row: row, column: column, state: state)
    }

    /// getSettings 的应答;插件据此更新自身缓存
    public static func didReceiveSettings(
        action: String, context: String, settings: JSONValue, row: Int, column: Int
    ) -> JSONValue {
        makeEvent("didReceiveSettings", action: action, context: context, payload: .object([
            "settings": settings,
            "coordinates": coordinates(row: row, column: column),
            "isInMultiAction": .bool(false),
        ]))
    }

    /// getGlobalSettings 的应答。OBS 插件收到首条宿主消息即发 getGlobalSettings 并等本应答,
    /// 不答则其全局设置永远为空(硬需求,2026-10-13 源码归纳)。
    public static func didReceiveGlobalSettings(pluginUUID: String, settings: JSONValue) -> JSONValue {
        makeEvent("didReceiveGlobalSettings", context: pluginUUID, payload: .object(["settings": settings]))
    }

    public static func deviceDidConnect(_ device: Device) -> JSONValue {
        makeEvent("deviceDidConnect", device: device.id, deviceInfo: .object([
            "name": .string(device.name),
            "type": .int(0),
            "size": .object(["columns": .int(device.columns), "rows": .int(device.rows)]),
        ]))
    }

    public static func deviceDidDisconnect(deviceID: String) -> JSONValue {
        makeEvent("deviceDidDisconnect", device: deviceID)
    }

    public static func systemDidWakeUp() -> JSONValue {
        makeEvent("systemDidWakeUp")
    }

    // MARK: - plugin → host 解析

    /// 宽容解析:未知字段忽略、未知事件归入 .unhandled(吞掉不崩),非法 JSON 返回 nil。
    /// M2 明确不执行的事件(PI 相关/titleParametersDidChange/switchToProfile 等)同样落 .unhandled。
    public static func parse(_ data: Data) -> PluginInbound? {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any],
              let event = object["event"] as? String else { return nil }
        let json = JSONValue(any: any)
        let payload = json["payload"] ?? .null
        let context = json["context"]?.stringValue

        switch event {
        case "registerPlugin":
            return .registered(pluginUUID: json["uuid"]?.stringValue ?? context ?? "")
        case "setImage":
            guard let context else { return .unhandled(event: event) }
            return .setImage(
                context: context,
                // 空字符串 = 恢复 manifest 默认图(与字段缺失语义相同,保留原文便于日志)
                image: payload["image"]?.stringValue,
                state: payload["state"]?.intValue,
                target: payload["target"]?.intValue ?? 0
            )
        case "setTitle":
            guard let context else { return .unhandled(event: event) }
            return .setTitle(
                context: context,
                title: payload["title"]?.stringValue,
                state: payload["state"]?.intValue,
                target: payload["target"]?.intValue ?? 0
            )
        case "setState":
            guard let context, let state = payload["state"]?.intValue else { return .unhandled(event: event) }
            return .setState(context: context, state: state)
        case "setSettings":
            guard let context else { return .unhandled(event: event) }
            return .setSettings(context: context, settings: payload)
        case "getSettings":
            guard let context else { return .unhandled(event: event) }
            return .getSettings(context: context)
        case "setGlobalSettings":
            // 协议规定 context 填 pluginUUID
            guard let pluginUUID = context else { return .unhandled(event: event) }
            return .setGlobalSettings(pluginUUID: pluginUUID, settings: payload)
        case "getGlobalSettings":
            guard let pluginUUID = context else { return .unhandled(event: event) }
            return .getGlobalSettings(pluginUUID: pluginUUID)
        case "showOk":
            return .showOk(context: context)
        case "showAlert":
            return .showAlert(context: context)
        case "openUrl":
            guard let url = payload["url"]?.stringValue else { return .unhandled(event: event) }
            return .openURL(url)
        case "logMessage":
            return .logMessage(payload["message"]?.stringValue ?? "")
        default:
            return .unhandled(event: event)
        }
    }

    // MARK: - 私有

    /// 实例事件公共形态:keyDown/keyUp/willAppear/willDisappear
    private static func instanceEvent(
        _ event: String, action: String, context: String, device: String,
        settings: JSONValue, row: Int, column: Int, state: Int?
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "settings": settings,
            "coordinates": coordinates(row: row, column: column),
            "isInMultiAction": .bool(false),
        ]
        if let state {
            payload["state"] = .int(state)
        }
        return makeEvent(event, action: action, context: context, device: device, payload: .object(payload))
    }

    private static func coordinates(row: Int, column: Int) -> JSONValue {
        .object(["column": .int(column), "row": .int(row)])
    }

    private static func makeEvent(
        _ event: String, action: String? = nil, context: String? = nil,
        device: String? = nil, payload: JSONValue? = nil, deviceInfo: JSONValue? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = ["event": .string(event)]
        if let action { object["action"] = .string(action) }
        if let context { object["context"] = .string(context) }
        if let device { object["device"] = .string(device) }
        if let payload { object["payload"] = payload }
        if let deviceInfo { object["deviceInfo"] = deviceInfo }
        return .object(object)
    }
}

/// 插件发来的已解析消息
public enum PluginInbound: Sendable, Equatable {
    case registered(pluginUUID: String)
    case setImage(context: String, image: String?, state: Int?, target: Int)
    case setTitle(context: String, title: String?, state: Int?, target: Int)
    case setState(context: String, state: Int)
    case setSettings(context: String, settings: JSONValue)
    case getSettings(context: String)
    case setGlobalSettings(pluginUUID: String, settings: JSONValue)
    case getGlobalSettings(pluginUUID: String)
    case showOk(context: String?)
    case showAlert(context: String?)
    case openURL(String)
    case logMessage(String)
    /// M2 不执行(PI 相关等)或未知的事件;宿主按日志处理,绝不能因此崩
    case unhandled(event: String)
}
