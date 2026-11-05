import Foundation

/// node 插件子进程:按协议 argv 顺序拉起,收割(SIGTERM→宽限→SIGKILL),捕获 stderr 尾部供诊断。
public final class PluginProcess: @unchecked Sendable {
    public let pluginUUID: String
    /// 进程存活状态(NSLock 守卫:terminationHandler 在 Foundation 后台线程执行,
    /// 与调用线程的 start()/terminate() 无同步即是数据竞争)
    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }
    /// 进程非预期退出(崩溃/自行退出);宿主主动 terminate() 不触发。诊断尾部为 stdout+stderr 最后 8KB。
    /// 闭包第一个参数即退出中的进程自身——宿主侧以此判定身份,**不要**在闭包里强捕获进程对象
    /// (闭包被 onExit 属性强持有,捕获即成 PluginProcess ↔ 闭包保留环,实例永不释放)
    public var onExit: (@Sendable (PluginProcess, Int32, String) -> Void) = { _, _, _ in }
    public var onSpawnError: (@Sendable (String) -> Void) = { _ in }

    private let process = Process()
    private let stderrLock = NSLock()
    private var stderrData = Data()
    private let stateLock = NSLock()
    private var _isRunning = false
    /// terminate() 已请求主动收割。不用「terminate 前翻转 isRunning」判断收割:
    /// SIGTERM 与自然崩溃同毫秒时 terminationHandler 会读到 wasRunning == false,真崩溃被静默吞掉(漏 respawn)
    private var terminationRequested = false
    private var diagnosticReadHandle: FileHandle?

    /// - Parameters:
    ///   - entryURL: manifest 入口 JS 绝对路径(CodePathMac 相对插件根)
    ///   - workingDirectory: 插件根目录(插件 log4js 等以相对路径写自身目录)
    ///   - infoJSON: -info 参数原文(单元素 argv;插件 JSON.parse 它,格式非法会启动即崩)
    public init(pluginUUID: String, nodeURL: URL, entryURL: URL, workingDirectory: URL, port: UInt16, infoJSON: String) {
        self.pluginUUID = pluginUUID
        process.executableURL = nodeURL
        // argv 顺序是协议的一部分:OBS 插件按位置取 argv[3]/[5]/[7]/[9],不可增删或换序
        process.arguments = [
            entryURL.path,
            "-port", String(port),
            "-pluginUUID", pluginUUID,
            "-registerEvent", "registerPlugin",
            "-info", infoJSON,
        ]
        process.currentDirectoryURL = workingDirectory

        // stdout+stderr 合流入诊断缓冲(插件 console.log 是主要的自诊断来源)
        let diagnosticPipe = Pipe()
        process.standardOutput = diagnosticPipe.fileHandleForWriting
        process.standardError = diagnosticPipe.fileHandleForWriting
        diagnosticReadHandle = diagnosticPipe.fileHandleForReading
        diagnosticPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF 必须自摘 handler:EOF 的 fd 对 dispatch read source 恒「可读」,
                // 不摘则 handler 被无限空转调用,后台队列烧 CPU(子进程一退出即触发)
                handle.readabilityHandler = nil
                return
            }
            self?.appendDiagnostic(chunk)
        }

        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            // 先摘读端 handler 再终读:消除 availableData 与 readabilityHandler 对同一
            // FileHandle 的并发读;EOF 自摘(见上)兜不住「进程死亡与 handler 竞速」的窗口
            self.diagnosticReadHandle?.readabilityHandler = nil
            if let handle = self.diagnosticReadHandle {
                let remaining = handle.availableData
                if !remaining.isEmpty {
                    self.appendDiagnostic(remaining)
                }
            }
            self.stderrPipeCleanup()
            let shouldReportExit = self.stateLock.withLock {
                let wasRunning = self._isRunning
                self._isRunning = false
                return wasRunning && !self.terminationRequested
            }
            guard shouldReportExit else { return } // 主动收割不触发 onExit,避免双发
            let tail = self.diagnosticTail
            self.onExit(self, terminated.terminationStatus, tail)
        }
    }

    deinit {
        stderrPipeCleanup()
    }

    public func start() {
        do {
            try process.run()
            stateLock.withLock { _isRunning = true }
        } catch {
            onSpawnError("node 拉起失败: \(error.localizedDescription)")
        }
    }

    /// SIGTERM → 2s 宽限 → SIGKILL;主动收割不触发 onExit(模型以此区分「主动停」与「崩溃需重启」)
    public func terminate() {
        let shouldTerminate = stateLock.withLock { () -> Bool in
            guard _isRunning, !terminationRequested else { return false }
            terminationRequested = true
            return true
        }
        guard shouldTerminate else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.process.isRunning else { return }
            kill(self.process.processIdentifier, SIGKILL)
        }
    }

    /// 当前已捕获的诊断尾部(实时;不等进程退出)
    public var diagnosticTail: String {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        return String(data: stderrData, encoding: .utf8) ?? ""
    }

    private func appendDiagnostic(_ chunk: Data) {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        stderrData.append(chunk)
        if stderrData.count > 8192 {
            stderrData = stderrData.suffix(8192)
        }
    }

    private func stderrPipeCleanup() {
        // 清理对象是「读端」——handler 装在 diagnosticReadHandle 上;
        // process.standardOutput 是写端(宿主持有以维持管道),从未装过 handler
        diagnosticReadHandle?.readabilityHandler = nil
    }
}

/// node 运行时探测:官方 StreamDock.app 捆绑的 node20(与插件生态同款)优先,系统安装兜底。
public enum NodeLocator {
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates = [
            "/Applications/StreamDock.app/Contents/Helpers/node20",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") {
                candidates.append("\(directory)/node")
            }
        }
        let fileManager = FileManager.default
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
