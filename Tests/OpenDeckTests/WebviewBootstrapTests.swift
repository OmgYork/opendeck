import Foundation
import Testing

@testable import OpenDeck

/// 引导脚本收敛的守护测试:两份手写字符串曾被同步维护,合并后必须证明
/// 生成结果与收敛前逐 token 一致——缩进可以变,参数形状/顺序/轮询阈值不能变。
/// OpenDeck target 开了 defaultIsolation(MainActor),脚本构建器因此也是主线程隔离的;
/// 测试同样标 @MainActor,不为测试去放宽生产代码的隔离声明。
@Suite("WKWebView 引导脚本")
@MainActor
struct WebviewBootstrapTests {
    /// 去掉全部空白后比较:JS 的分号、括号、参数顺序都比缩进重要
    private func tokens(_ js: String) -> String {
        js.split(whereSeparator: { $0.isWhitespace }).joined()
    }

    private let port: UInt16 = 1234
    private let pluginUUID = "ABCD-1234"
    private let contextID = "ctx-42"
    private let appJSON = #"{"application":{"language":"zh_CN"}}"#
    private let actionInfoJSON = #"{"action":"com.test.act","context":"ctx-42","payload":{"settings":{}}}"#

    @Test("插件页引导:与收敛前的 4 参脚本逐 token 一致")
    func pluginVariantMatchesLegacy() {
        let legacy = """
        (function() {
            var app = \(appJSON);
            var tries = 0;
            var timer = setInterval(function() {
                tries += 1;
                if (typeof window.connectElgatoStreamDeckSocket === 'function') {
                    clearInterval(timer);
                    window.connectElgatoStreamDeckSocket(
                        '\(port)', '\(pluginUUID)', 'registerPlugin', JSON.stringify(app));
                } else if (tries > 200) {
                    clearInterval(timer);
                }
            }, 50);
        })();
        """
        let actual = WebviewBootstrap.script(
            for: .plugin(port: port, pluginUUID: pluginUUID, infoJSON: appJSON)
        )
        #expect(tokens(actual) == tokens(legacy), "实际生成:\n\(actual)")
    }

    @Test("Property Inspector 引导:与收敛前的 5 参脚本逐 token 一致")
    func inspectorVariantMatchesLegacy() {
        let legacy = """
        (function() {
            var app = \(appJSON);
            var info = \(actionInfoJSON);
            var tries = 0;
            var timer = setInterval(function() {
                tries += 1;
                if (typeof window.connectElgatoStreamDeckSocket === 'function') {
                    clearInterval(timer);
                    window.connectElgatoStreamDeckSocket(
                        \(port), '\(contextID)', 'registerPropertyInspector',
                        JSON.stringify(app), JSON.stringify(info));
                } else if (tries > 200) {
                    clearInterval(timer);
                }
            }, 50);
        })();
        """
        let actual = WebviewBootstrap.script(
            for: .propertyInspector(port: port, contextID: contextID, appJSON: appJSON, actionInfoJSON: actionInfoJSON)
        )
        #expect(tokens(actual) == tokens(legacy), "实际生成:\n\(actual)")
    }

    @Test("两种页面共用同一套轮询骨架(50ms 一次、200 次放弃)")
    func sharedSkeleton() {
        let plugin = WebviewBootstrap.script(for: .plugin(port: port, pluginUUID: pluginUUID, infoJSON: appJSON))
        let inspector = WebviewBootstrap.script(
            for: .propertyInspector(port: port, contextID: contextID, appJSON: appJSON, actionInfoJSON: actionInfoJSON)
        )
        for js in [plugin, inspector] {
            #expect(js.contains("setInterval(function()"))
            #expect(js.contains("typeof window.connectElgatoStreamDeckSocket === 'function'"))
            #expect(js.contains("tries > 200"))
            #expect(js.contains("}, 50);"))
            // 就绪即清掉 interval,不留悬挂定时器
            #expect(js.contains("clearInterval(timer);"))
        }
        // 注册类型只应出现一次(改错会同时发两条注册)
        #expect(plugin.components(separatedBy: "registerPlugin").count == 2)
        #expect(inspector.components(separatedBy: "registerPropertyInspector").count == 2)
    }

    @Test("注入的 JSON 原样进入脚本,不做二次转义")
    func jsonInjectedVerbatim() {
        let plugin = WebviewBootstrap.script(for: .plugin(port: port, pluginUUID: pluginUUID, infoJSON: appJSON))
        #expect(plugin.contains("var app = \(appJSON);"))
        let inspector = WebviewBootstrap.script(
            for: .propertyInspector(port: port, contextID: contextID, appJSON: appJSON, actionInfoJSON: actionInfoJSON)
        )
        #expect(inspector.contains("var info = \(actionInfoJSON);"))
    }
}
