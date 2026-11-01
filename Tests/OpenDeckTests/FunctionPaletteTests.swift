import Foundation
import StreamDockKit
import Testing

@testable import OpenDeck

/// 功能调色盘目录契约：载荷可解析、互不碰撞、即用/模板二分、KeyConfig 兼容。
/// 槽位绑定、磁贴渲染、点选提示三处共用 item(forPayload:) 单一映射器，
/// 这里守护的是「视图渲染出的每个载荷都能落键」与「旧配置可解码」两条底线。
@Suite("功能调色盘目录")
@MainActor
struct FunctionPaletteTests {
    /// 渲染源全集：扁平分类 + 显示器命令 + 复合磁贴
    private var allRenderedPayloads: [String] {
        let flat = FunctionPaletteCatalog.flatCategories.flatMap { $0.items.map(\.payload) }
        let commands = MonitorCommand.allCases.map(\.rawValue)
        let composites = MonitorCompositeCatalog.all.map(\.payload)
        return flat + commands + composites
    }

    @Test("视图渲染出的每个载荷都能经单一映射器落键")
    func everyRenderedPayloadResolves() {
        for payload in allRenderedPayloads {
            let item = FunctionPaletteCatalog.item(forPayload: payload)
            #expect(item != nil, "\(payload) 无法解析,拖到槽位会被拒绝")
        }
    }

    @Test("载荷互不碰撞(前缀方案 vs 命令 rawValue vs 复合 id)")
    func payloadsAreUnique() {
        let payloads = allRenderedPayloads
        let duplicates = Dictionary(grouping: payloads, by: \.self)
            .filter { $0.value.count > 1 }.keys
        #expect(payloads.count == Set(payloads).count, "载荷重复:\(duplicates.sorted())")
    }

    @Test("即用项与模板项二分,标题非空")
    func itemsAreReadyOrTemplate() {
        for category in FunctionPaletteCatalog.flatCategories {
            #expect(!category.items.isEmpty, "\(category.key) 分类为空")
            for item in category.items {
                #expect(!item.title.isEmpty, "\(item.payload) 缺键帽标题")
                #expect((item.action != nil) != (item.template != nil),
                        "\(item.payload) 必须是即用动作或待配置模板二选一")
            }
        }
    }

    @Test("模板载荷与 KeyTemplate 一一对应")
    func templatePayloadsMatchKeyTemplates() {
        for kind in KeyTemplate.allCases {
            let payload = "template:\(kind.rawValue)"
            let item = FunctionPaletteCatalog.item(forPayload: payload)
            #expect(item?.template == kind, "\(payload) 解析回的模板不符")
        }
    }

    @Test("显示器输入类命令派生时自动带 monitorInput 动效")
    func monitorCommandsCarryInputAnimation() {
        for command in MonitorCommand.allCases {
            let item = FunctionPaletteCatalog.item(forPayload: command.rawValue)
            #expect(item?.animation == (command.carriesInputAnimation ? .monitorInput : nil),
                    "\(command.rawValue) 动效派生与 carriesInputAnimation 不符")
        }
    }

    @Test("旧配置(无 template 字段)解码为 nil 占位")
    func legacyKeyConfigDecodesWithoutTemplate() throws {
        // 模拟旧配置:现编码产物剥掉 template 键,不手猜 KeyAction 的编码形状
        let config = KeyConfig(title: "亮度 +", backgroundColorHex: "#000000",
                               action: .monitor(.brightnessUp))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
            as! [String: Any]
        object.removeValue(forKey: "template")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(KeyConfig.self, from: legacy)
        #expect(decoded.template == nil)
        #expect(decoded.action == .monitor(.brightnessUp))
    }

    @Test("模板占位随 KeyConfig 编解码往返")
    func templateRoundTrip() throws {
        let config = KeyConfig(title: "打开应用", template: .openApp)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(KeyConfig.self, from: data)
        #expect(decoded.template == .openApp)
        #expect(decoded.action == nil)
    }

    @Test("统计动作(GPU/CPU/温度)编解码往返稳定")
    func statActionRoundTrip() throws {
        for kind in StatKind.allCases {
            let original = KeyAction.stat(kind)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(KeyAction.self, from: data)
            #expect(decoded == original, "\(kind.rawValue) 往返失真")
        }
    }

    @Test("畸形/越界载荷一律拒绝,不误落到任何磁贴")
    func malformedPayloadsAreRejected() {
        let malformed = [
            "action:",                      // 空动作名
            "action:mediaKey:",             // 空媒体取值
            "action:mediaKey:notAMediaKey", // 未定义取值
            "action:stat:",                 // 空统计项
            "action:stat:notAKind",         // 未定义统计项
            "template:",                    // 空模板
            "template:notAKind",            // 未定义模板
            "draft:",                       // 空草稿(草稿由 bindPayload 直接消费,目录不解析)
            "slot:",                        // 空槽位
            "slot:abc",                     // 非数字槽位
            "slot:-1",                      // 越界槽位
            "composite:",                   // 空复合 id
            "composite:notATile",           // 未登记复合 id
            "brightnessUp2",                // 命令名打错
            "",                             // 空串
        ]
        for payload in malformed {
            #expect(FunctionPaletteCatalog.item(forPayload: payload) == nil,
                    "畸形载荷 \(payload) 竟被解析")
        }
    }

    @Test("自定义镜像索引清单落在面板范围内且不含保留槽")
    func customSlotIndicesAreValid() {
        let total = StreamDock293S.rows * StreamDock293S.columns
        for index in FunctionPaletteCatalog.customSlotIndices {
            #expect(index >= 0 && index < total, "镜像索引 \(index) 越界")
            #expect(AppModel.reservedSlot(at: index) == nil, "镜像索引 \(index) 撞上保留槽")
        }
        #expect(Set(FunctionPaletteCatalog.customSlotIndices).count == FunctionPaletteCatalog.customSlotIndices.count,
                "镜像索引重复")
    }
}

/// 落键政策纯函数(landingConfig):槽位镜像/草稿消费/目录磁贴三种来源的落键语义。
/// 这是调色盘拖拽的核心契约——拖错写错场景、克隆抢实例这类事故都在这一层拦截。
@Suite("落键政策")
@MainActor
struct LandingPolicyTests {
    private let current = KeyConfig(title: "旧标题", backgroundColorHex: "#123456")

    private func landing(_ payload: String, target: Int = 0,
                         home: (Int) -> KeyConfig? = { _ in nil },
                         draft: (KeyTemplate) -> KeyConfig? = { _ in nil }) -> KeyConfig? {
        AppModel.landingConfig(payload: payload, targetIndex: target, current: current,
                               homeKey: home, draft: draft)
    }

    @Test("保留槽目标与镜像源一律拒绝")
    func reservedRejected() {
        #expect(landing("action:screenOff", target: 13) == nil, "导航保留槽不可落键")
        #expect(landing("slot:14", target: 0,
                        home: { $0 == 14 ? KeyConfig(title: "x") : nil }) == nil, "镜像源是保留槽")
    }

    @Test("即用动作落键:写短标签,保留目标槽底色")
    func readyActionLands() {
        let key = landing("action:screenOff")
        #expect(key?.action == .screenOff)
        #expect(key?.title == "熄屏")
        #expect(key?.backgroundColorHex == "#123456", "底色沿用目标槽现状")
    }

    @Test("槽位镜像整键复刻首页配置,插件键换新 contextID")
    func slotCloneCopiesHomeWithFreshContext() {
        let home = KeyConfig(title: "状态灯", backgroundColorHex: "#00FF00",
                             action: .plugin(pluginID: "p", actionUUID: "a", contextID: "ctx-old"))
        let key = landing("slot:1", home: { $0 == 1 ? home : nil })
        #expect(key?.title == "状态灯")
        #expect(key?.backgroundColorHex == "#00FF00", "整键复刻含底色")
        if case .plugin(_, _, let contextID)? = key?.action {
            #expect(contextID != "ctx-old", "克隆必须换新实例身份")
        } else {
            #expect(Bool(false), "插件动作应保持插件类型")
        }
    }

    @Test("草稿落键清模板占位,畸形草稿值不崩溃")
    func draftLands() {
        let ready = KeyConfig(title: "Safari", action: .openApp(path: "/Applications/Safari.app"))
        let key = landing("draft:openApp", draft: { $0 == .openApp ? ready : nil })
        #expect(key?.action == .openApp(path: "/Applications/Safari.app"))
        #expect(key?.title == "Safari")
        #expect(key?.template == nil, "落键即非模板态")
        #expect(landing("draft:notAKind", draft: { _ in nil }) == nil)
    }

    @Test("畸形与未知载荷一律拒绝")
    func malformedRejected() {
        for payload in ["", "slot:", "slot:abc", "slot:-1", "draft:", "unknown", "brightnessUp2"] {
            #expect(landing(payload) == nil, "载荷 \(payload) 竟被解析")
        }
    }
}
