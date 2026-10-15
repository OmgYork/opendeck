import Foundation
import Testing

@testable import PluginHost

/// 协议编解码黄金测试:字段对照 Elgato v2 文档与 MiraBox OBS 插件实际用面(2026-10-13 侦察)
@Suite("SDProtocol 编解码")
struct SDProtocolTests {
    private let device = SDProtocol.Device.streamDock293V3

    // MARK: plugin → host

    @Test("注册包:uuid 字段识别")
    func parseRegister() {
        let data = Data(#"{"uuid":"com.mirabox.obs","event":"registerPlugin"}"#.utf8)
        #expect(SDProtocol.parse(data) == .registered(pluginUUID: "com.mirabox.obs"))
    }

    @Test("setImage 全字段")
    func parseSetImage() {
        let data = Data(#"{"event":"setImage","context":"ctx1","payload":{"image":"data:image/png;base64,QUJD","target":0,"state":1}}"#.utf8)
        #expect(SDProtocol.parse(data) == .setImage(context: "ctx1", image: "data:image/png;base64,QUJD", state: 1, target: 0))
    }

    @Test("setImage 最小形态:target 缺省 0,state 缺省 nil;空串语义保留")
    func parseSetImageMinimal() {
        #expect(SDProtocol.parse(Data(#"{"event":"setImage","context":"c","payload":{"image":""}}"#.utf8))
            == .setImage(context: "c", image: "", state: nil, target: 0))
        #expect(SDProtocol.parse(Data(#"{"event":"setImage","context":"c","payload":{"image":"data:image/png;base64,x"}}"#.utf8))
            == .setImage(context: "c", image: "data:image/png;base64,x", state: nil, target: 0))
    }

    @Test("getGlobalSettings 的 context 即 pluginUUID")
    func parseGlobalSettings() {
        let data = Data(#"{"event":"getGlobalSettings","context":"com.mirabox.obs"}"#.utf8)
        #expect(SDProtocol.parse(data) == .getGlobalSettings(pluginUUID: "com.mirabox.obs"))
    }

    @Test("setSettings 携带任意对象 payload")
    func parseSetSettings() {
        let data = Data(#"{"event":"setSettings","context":"c","payload":{"chapterName":"第1章","n":3,"ok":true}}"#.utf8)
        #expect(SDProtocol.parse(data) == .setSettings(
            context: "c",
            settings: .object(["chapterName": .string("第1章"), "n": .int(3), "ok": .bool(true)])
        ))
    }

    @Test("宽容性:未知事件/缺 context 不崩,非法 JSON 返回 nil")
    func parseLenient() {
        #expect(SDProtocol.parse(Data(#"{"event":"dialRotate","context":"c","payload":{}}"#.utf8)) == .unhandled(event: "dialRotate"))
        #expect(SDProtocol.parse(Data(#"{"event":"setImage","payload":{"image":"x"}}"#.utf8)) == .unhandled(event: "setImage"))
        #expect(SDProtocol.parse(Data("不是 JSON".utf8)) == nil)
        #expect(SDProtocol.parse(Data(#"[1,2,3]"#.utf8)) == nil)
    }

    // MARK: PI(Property Inspector)

    @Test("PI 注册包:uuid 即 contextID,无 action 字段(OBS action.js 实测)")
    func parseRegisterPI() {
        #expect(SDProtocol.parse(Data(#"{"event":"registerPropertyInspector","uuid":"ctx-1"}"#.utf8))
            == .registeredPI(uuid: "ctx-1"))
        // uuid 缺失时不落 .registeredPI(否则无法定归属)
        #expect(SDProtocol.parse(Data(#"{"event":"registerPropertyInspector"}"#.utf8))
            == .unhandled(event: "registerPropertyInspector"))
    }

    @Test("sendToPlugin / sendToPropertyInspector 解析(宿主两侧原帧透传)")
    func parseSendToRelay() {
        #expect(SDProtocol.parse(Data(#"{"event":"sendToPlugin","action":"a","context":"c","payload":{"k":1}}"#.utf8))
            == .sendToPlugin(action: "a", context: "c", payload: .object(["k": .int(1)])))
        #expect(SDProtocol.parse(Data(#"{"event":"sendToPropertyInspector","context":"c","payload":{"x":"y"}}"#.utf8))
            == .sendToPropertyInspector(context: "c", payload: .object(["x": .string("y")])))
        #expect(SDProtocol.parse(Data(#"{"event":"sendToPlugin","payload":{}}"#.utf8))
            == .sendToPlugin(action: nil, context: nil, payload: .object([:])))
    }

    // MARK: host → plugin

    @Test("willAppear 黄金结构:含 settings/coordinates/state/isInMultiAction")
    func encodeWillAppear() {
        let event = SDProtocol.willAppear(
            action: "com.mirabox.streamdock.obs.studio.stream",
            context: "ctx-9", device: device,
            settings: .object(["a": .string("b")]),
            row: 1, column: 2, state: 0
        )
        let expected = JSONValue.object([
            "event": .string("willAppear"),
            "action": .string("com.mirabox.streamdock.obs.studio.stream"),
            "context": .string("ctx-9"),
            "device": .string("OpenDeck-293V3"),
            "payload": .object([
                "settings": .object(["a": .string("b")]),
                "coordinates": .object(["column": .int(2), "row": .int(1)]),
                "state": .int(0),
                "isInMultiAction": .bool(false),
            ]),
        ])
        #expect(event == expected)
        // 编码后能被自身 parse 往返(JSON 合法性自证)
        #expect(SDProtocol.parse(SDProtocol.encode(event)) != nil)
    }

    @Test("keyDown 不带 state 时 payload 无 state 字段")
    func encodeKeyDownNoState() {
        let event = SDProtocol.keyDown(action: "a", context: "c", device: device,
                                       settings: .object([:]), row: 0, column: 0, state: nil)
        #expect(event["payload"]?["state"] == nil)
        #expect(event["payload"]?["isInMultiAction"] == .bool(false))
    }

    @Test("didReceiveGlobalSettings:OBS 插件硬需求,context=pluginUUID")
    func encodeGlobalSettingsReply() {
        let event = SDProtocol.didReceiveGlobalSettings(pluginUUID: "com.x", settings: .object([:]))
        #expect(event["event"] == .string("didReceiveGlobalSettings"))
        #expect(event["context"] == .string("com.x"))
        #expect(event["payload"]?["settings"] == .object([:]))
    }

    @Test("deviceDidConnect:deviceInfo 含 type=0 与 5×3 size")
    func encodeDeviceDidConnect() {
        let event = SDProtocol.deviceDidConnect(device)
        #expect(event["device"] == .string("OpenDeck-293V3"))
        #expect(event["deviceInfo"]?["type"] == .int(0))
        #expect(event["deviceInfo"]?["size"] == .object(["columns": .int(5), "rows": .int(3)]))
    }

    @Test("propertyInspectorDidAppear/DidDisappear 黄金结构")
    func encodePIVisibility() {
        let appear = SDProtocol.propertyInspectorDidAppear(action: "a", context: "c", device: device)
        #expect(appear == .object([
            "event": .string("propertyInspectorDidAppear"),
            "action": .string("a"),
            "context": .string("c"),
            "device": .string("OpenDeck-293V3"),
        ]))
        let disappear = SDProtocol.propertyInspectorDidDisappear(action: "a", context: "c", device: device)
        #expect(disappear["event"] == .string("propertyInspectorDidDisappear"))
        #expect(SDProtocol.parse(SDProtocol.encode(appear)) != nil)
        #expect(SDProtocol.parse(SDProtocol.encode(disappear)) != nil)
    }

    @Test("registrationInfo:application.language 等硬字段齐备")
    func registrationInfoGolden() {
        let info = SDProtocol.registrationInfo(pluginUUID: "com.x", pluginVersion: "1.0", device: device)
        // OBS 插件类初始化就读这个字段,缺失即崩
        #expect(info["application"]?["language"]?.stringValue?.isEmpty == false)
        #expect(info["application"]?["platform"] == .string("mac"))
        #expect(info["plugin"]?["uuid"] == .string("com.x"))
        #expect(info["pluginInfo"]?["uuid"] == .string("com.x"))
        #expect(info["devices"]?[0]?["type"] == .int(0))
        #expect(info["devices"]?[0]?["size"] == .object(["columns": .int(5), "rows": .int(3)]))
        #expect(info["colors"]?["highlightColor"] == .string("#0078FFFF"))
        // info 必须是单行合法 JSON(argv 单元素传递,不能含裸换行)
        let encoded = SDProtocol.encode(info)
        #expect(!encoded.isEmpty)
        #expect(!encoded.contains(where: { $0 == 0x0A }))
    }

    @Test("encode:斜杠不转义(sortedKeys 稳定输出)")
    func encodeStable() {
        let event = SDProtocol.systemDidWakeUp()
        let text = String(data: SDProtocol.encode(event), encoding: .utf8)
        #expect(text == #"{"event":"systemDidWakeUp"}"#)
    }
}
