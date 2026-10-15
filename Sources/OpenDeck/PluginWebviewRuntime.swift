import WebKit

/// HTML 家族插件运行时:无宿主 WKWebView(不入视图层级即可加载页面、执行 JS、
/// 发起 WebSocket——WebKit 平台行为,PI 的「连接随释放断开」已依赖同款语义)。
/// 页面加载完成后经 documentEnd 用户脚本注入 4 参引导调用
/// `connectElgatoStreamDeckSocket(port, pluginUUID, "registerPlugin", infoJSON)`
/// ——契约源:官方 time/weather/memo 等 HTML 插件(与 PI 的 5 参调用同函数不同形,
/// 参数全部单引号字符串,插件自行 JSON.parse)。页面自行回连宿主 WebSocket 并注册,
/// 之后与 Node 插件走完全相同的路由管线。
/// WebContent 进程崩溃经 webViewWebContentProcessDidTerminate 上报 onGone,
/// 由 PluginHostModel 走既有 respawn ×3 路径;主动 close() 不触发(镜像 PluginProcess)。
@MainActor
final class PluginWebviewRuntime: NSObject, WKNavigationDelegate {
    let pluginUUID: String
    private let webView: WKWebView
    private let log: (String) -> Void
    /// WebContent 进程崩溃等价物(主动 close 不触发)
    var onGone: (() -> Void)?
    private var gone = false

    init(pluginUUID: String, directoryURL: URL, entryURL: URL, port: UInt16, infoJSON: String, log: @escaping (String) -> Void) {
        self.pluginUUID = pluginUUID
        self.log = log
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent() // 插件间隔离;localStorage 不跨重启(v1 边界)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.bootstrapScript(port: port, pluginUUID: pluginUUID, infoJSON: infoJSON),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .black // 插件页面多为深色,加载前防白闪
        webView.loadFileURL(entryURL, allowingReadAccessTo: directoryURL) // 读取域 = 插件根(根级 i18n/Worker/字体)
    }

    /// 主动拆除(卸载/关停):不触发 onGone;持有方随后摘除引用,连接随释放断开
    func close() {
        gone = true
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    /// 4 参引导:部分 HTML 插件的全局函数由异步脚本定义,轮询就绪后调用,10s 上限放弃
    private static func bootstrapScript(port: UInt16, pluginUUID: String, infoJSON: String) -> String {
        """
        (function() {
            var app = \(infoJSON);
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
    }

    // MARK: - WKNavigationDelegate

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !gone else { return }
        gone = true
        log("HTML 插件 WebContent 进程终止:\(pluginUUID)")
        onGone?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // 入口页加载失败(文件缺失/坏 HTML):重spawn也无济于事,记录并放弃(respawn 上限仍兜底)
        log("HTML 插件页加载失败:\(pluginUUID) \(error.localizedDescription)")
        gone = true
        onGone?()
    }
}
