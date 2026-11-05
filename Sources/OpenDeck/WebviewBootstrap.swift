import Foundation

/// WKWebView 就绪轮询引导脚本——HTML 插件入口页与 Property Inspector 页共用一套。
///
/// 两个页面的注入时机(.atDocumentEnd,仅主框架)与轮询骨架完全一致,只有
/// `connectElgatoStreamDeckSocket` 的参数形状不同(插件 4 参 / PI 5 参)。
/// 此前是两份手写字符串,改一处忘另一处就会出现「插件能连、PI 连不上」这类
/// 只在真机复现的问题。
///
/// 为什么要轮询:部分页面的这个全局函数由异步加载的脚本定义,documentEnd 时还没就绪;
/// 50ms 一次,200 次(≈10s)后放弃,不把 interval 永久挂着。
///
/// 契约源:OBS 插件的 propertyInspector/utils/action.js(见 PropertyInspectorView 注释)。
enum WebviewBootstrap {
    enum Target {
        /// HTML 插件入口页:`connectElgatoStreamDeckSocket(port, pluginUUID, "registerPlugin", app)`
        case plugin(port: UInt16, pluginUUID: String, infoJSON: String)
        /// Property Inspector 页:`connectElgatoStreamDeckSocket(port, contextID, "registerPropertyInspector", app, info)`
        case propertyInspector(port: UInt16, contextID: String, appJSON: String, actionInfoJSON: String)
    }

    static func script(for target: Target) -> String {
        let setup: String
        let call: String
        switch target {
        case .plugin(let port, let pluginUUID, let infoJSON):
            setup = "var app = \(infoJSON);"
            // uuid 源自插件目录名(导入路径可控),单引号字符串里必须转义,否则引导 JS 语法错误、页面永不注册
            let uuid = jsEscaped(pluginUUID)
            call = """
            window.connectElgatoStreamDeckSocket(
                                '\(port)', '\(uuid)', 'registerPlugin', JSON.stringify(app));
            """
        case .propertyInspector(let port, let contextID, let appJSON, let actionInfoJSON):
            setup = "var app = \(appJSON);\n            var info = \(actionInfoJSON);"
            let context = jsEscaped(contextID)
            call = """
            window.connectElgatoStreamDeckSocket(
                                \(port), '\(context)', 'registerPropertyInspector',
                                JSON.stringify(app), JSON.stringify(info));
            """
        }
        return """
        (function() {
            \(setup)
            var tries = 0;
            var timer = setInterval(function() {
                tries += 1;
                if (typeof window.connectElgatoStreamDeckSocket === 'function') {
                    clearInterval(timer);
                    \(call)
                } else if (tries > 200) {
                    clearInterval(timer);
                }
            }, 50);
        })();
        """
    }

    /// 单引号 JS 字符串字面量的最小转义(反斜杠/引号/换行;uuid 与 contextID 皆为受限字符集,余下不可能出现)
    static func jsEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
