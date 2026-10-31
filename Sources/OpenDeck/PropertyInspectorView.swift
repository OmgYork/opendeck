import SwiftUI
import WebKit

/// Property Inspector 宿主:WKWebView 加载插件自带 propertyInspector/ 页面(文件域限定插件根,
/// PI 需 XHR 插件根的 <lang>.json i18n),经 documentEnd 用户脚本注入引导调用——
/// `connectElgatoStreamDeckSocket(port, contextID, "registerPropertyInspector", app, info)`,
/// PI 脚本自行回连宿主 WebSocket 并注册(契约源:OBS 插件 propertyInspector/utils/action.js)。
/// 连接随 webview 释放自动断开,宿主侧据此发 propertyInspectorDidDisappear。
/// 已知边界:PI 页面的 <input type="file"> 无面板可弹(官方宿主走 onFilePickerReturn 自定义回调,
/// 已知在装插件未用文件输入;WKUIDelegate 可选方法与 MainActor 默认隔离相抵,不引入)。
struct PropertyInspectorView: NSViewRepresentable {
    let pageURL: URL
    let readAccessRoot: URL
    let port: UInt16
    let contextID: String
    /// JSON 文本(registrationInfo 全量对象;PI 取 .application.language 加载语言包)
    let appJSON: String
    /// JSON 文本({action, context, payload.settings})
    let actionInfoJSON: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 引导注入:与 HTML 插件页共用同一套轮询骨架(见 WebviewBootstrap)
        let bootstrap = WebviewBootstrap.script(for: .propertyInspector(
            port: port, contextID: contextID, appJSON: appJSON, actionInfoJSON: actionInfoJSON
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: bootstrap, injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsLinkPreview = false
        webView.underPageBackgroundColor = .darkGray // 加载前防白闪(PI 页面自带深色背景)
        webView.loadFileURL(pageURL, allowingReadAccessTo: readAccessRoot)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
