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
/// 插件页运行时读盘走 opendeckReadFile 桥(WKScriptMessageHandler):file:// 页面的
/// fetch()/XHR 被 WebKit 即刻拒绝(TypeError: Load failed,2026-10-16 遥测实锤),
/// loadFileURL 的 allowingReadAccessTo 只放行 img/script 子资源,不含 fetch API。
@MainActor
final class PluginWebviewRuntime: NSObject, WKNavigationDelegate {
    let pluginUUID: String
    private let webView: WKWebView
    private let log: (String) -> Void
    private let rootURL: URL // 文件桥沙盒:仅插件根内相对路径可读
    /// WebContent 进程崩溃等价物(主动 close 不触发)
    var onGone: (() -> Void)?
    private var gone = false
    /// 宿主驱动轮询心跳:页面自链 setTimeout 会在隐藏 ~2 分钟后被 WebKit 治理冻毙
    /// (2026-10-16 实测:1s 节拍 2 分钟后归零永不恢复),故由宿主定时器推拍,
    /// 页面定义 __opendeckPulse 即接入;Foundation 定时器不受页面节流影响
    private var pulseTimer: Timer?

    init(pluginUUID: String, directoryURL: URL, entryURL: URL, port: UInt16, infoJSON: String, log: @escaping (String) -> Void) {
        self.pluginUUID = pluginUUID
        self.log = log
        self.rootURL = directoryURL.standardizedFileURL
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent() // 插件间隔离;localStorage 不跨重启(v1 边界)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.fileBridgeScript,
            injectionTime: .atDocumentStart, // 插件脚本求值前就绪
            forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.bootstrapScript(port: port, pluginUUID: pluginUUID, infoJSON: infoJSON),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        // documentEnd 时若页面已定义 __opendeckPulse,经文件桥通道回报一次,宿主起推拍定时器
        configuration.userContentController.addUserScript(WKUserScript(
            source: "if (typeof window.__opendeckPulse === 'function') window.webkit.messageHandlers.opendeckFile.postMessage({ pulse: true });",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        // 弱代理注册须在 super.init() 后(需 self);UserContentController 强持代理,代理弱持 self,不成环
        webView.configuration.userContentController.add(WeakScriptMessageHandler(self), name: "opendeckFile")
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .black // 插件页面多为深色,加载前防白闪
        webView.loadFileURL(entryURL, allowingReadAccessTo: directoryURL) // 读取域 = 插件根(根级 i18n/Worker/字体)
    }

    /// 主动拆除(卸载/关停):不触发 onGone;持有方随后摘除引用,连接随释放断开
    func close() {
        gone = true
        pulseTimer?.invalidate()
        pulseTimer = nil
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "opendeckFile")
        webView.stopLoading()
    }

    /// JS 侧 polyfill:window.opendeckReadFile(相对路径) → Promise<base64>。
    /// 超时兜底防 pendings 泄漏;宿主回复经 __opendeckFileResolve 回填。
    private static let fileBridgeScript = """
    (function() {
        var seq = 0, pending = {};
        window.opendeckReadFile = function(path) {
            return new Promise(function(resolve, reject) {
                var id = ++seq;
                pending[id] = { resolve: resolve, reject: reject };
                window.webkit.messageHandlers.opendeckFile.postMessage({ seq: id, path: String(path) });
                setTimeout(function() {
                    if (pending[id]) { delete pending[id]; reject(new Error('opendeckReadFile timeout')); }
                }, 5000);
            });
        };
        window.__opendeckFileResolve = function(id, ok, b64, errText) {
            var p = pending[id];
            if (!p) return;
            delete pending[id];
            if (ok) { p.resolve(b64); } else { p.reject(new Error(errText || 'read failed')); }
        };
    })();
    """

    /// 文件桥请求:沙盒校验(仅插件根内相对路径)→ 读盘 → base64 回填 Promise
    fileprivate func handleFileRequest(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if (body["pulse"] as? Bool) == true {
            startPulseTimer()
            return
        }
        guard let seq = body["seq"] as? Int,
              let path = body["path"] as? String, !path.isEmpty
        else { return }
        func reject(_ reason: String) {
            let js = "__opendeckFileResolve(\(seq), false, null, '\(reason)')"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        guard !path.hasPrefix("/") else { return reject("relative path required") }
        let target = rootURL.appendingPathComponent(path).standardizedFileURL
        guard target.path.hasPrefix(rootURL.path + "/") else { return reject("path escapes plugin root") }
        guard let data = try? Data(contentsOf: target) else { return reject("notfound or unreadable") }
        let b64 = data.base64EncodedString()
        webView.evaluateJavaScript("__opendeckFileResolve(\(seq), true, '\(b64)', '')", completionHandler: nil)
    }

    /// 宿主推拍:调页面 __opendeckPulse。evaluateJavaScript 不经 DOM 定时器队列,
    /// 不受隐藏页节流治理;单拍异常由下拍自愈(页面侧自链一断即永久死亡,不可用)。
    /// 自适应节拍契约:页面返回期望的下一拍间隔(ms,钳制 200…5000),宿主按其重排
    private func startPulseTimer() {
        guard pulseTimer == nil else { return }
        log("HTML 插件接入宿主推拍:\(pluginUUID)")
        schedulePulse(after: 0.05)
    }

    private func schedulePulse(after seconds: TimeInterval) {
        pulseTimer?.invalidate()
        guard !gone else { return }
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.gone else { return }
                self.webView.evaluateJavaScript(
                    "window.__opendeckPulse&&window.__opendeckPulse()",
                    completionHandler: { [weak self] result, _ in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            var interval = 1.0
                            if let n = result as? NSNumber, (200...5000).contains(n.doubleValue) {
                                interval = n.doubleValue / 1000.0
                            }
                            self.schedulePulse(after: interval)
                        }
                    }
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
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

/// 弱引用代理:UserContentController 强持 handler,直加 self 会成环(Runtime↔webview)
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: PluginWebviewRuntime?

    init(_ target: PluginWebviewRuntime) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handleFileRequest(message)
    }
}
