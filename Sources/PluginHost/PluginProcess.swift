import Foundation

/// node 插件子进程:按协议 argv 顺序拉起,收割(SIGTERM→宽限→SIGKILL),捕获 stderr 尾部供诊断。
public final class PluginProcess: @unchecked Sendable {
    public let pluginUUID: String
    public private(set) var isRunning = false
    /// 进程非预期退出(崩溃/自行退出);宿主主动 terminate() 不触发。诊断尾部为 stdout+stderr 最后 8KB
    public var onExit: (@Sendable (PluginProcess, Int32, String) -> Void) = { _, _, _ in }
    public var onSpawnError: (@Sendable (String) -> Void) = { _ in }

    private let process = Process()
    private let stderrLock = NSLock()
    private var stderrData = Data()
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
            guard !chunk.isEmpty else { return }
            self?.stderrLock.lock()
            self?.stderrData.append(chunk)
            if self?.stderrData.count ?? 0 > 8192 {
                self?.stderrData = self?.stderrData.suffix(8192) ?? Data()
            }
            self?.stderrLock.unlock()
        }

        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            // 终读:readabilityHandler 与退出回调竞速,把管道残余数据兜进来再上报
            if let handle = self.diagnosticReadHandle {
                let remaining = handle.availableData
                if !remaining.isEmpty {
                    self.stderrLock.lock()
                    self.stderrData.append(remaining)
                    self.stderrLock.unlock()
                }
            }
            self.stderrPipeCleanup()
            let wasRunning = self.isRunning
            self.isRunning = false
            guard wasRunning else { return } // 收割流程已上报,避免双发
            self.stderrLock.lock()
            let tail = String(data: self.stderrData, encoding: .utf8) ?? ""
            self.stderrLock.unlock()
            self.onExit(self, terminated.terminationStatus, tail)
        }
    }

    deinit {
        stderrPipeCleanup()
    }

    public func start() {
        do {
            try process.run()
            isRunning = true
        } catch {
            onSpawnError("node 拉起失败: \(error.localizedDescription)")
        }
    }

    /// SIGTERM → 2s 宽限 → SIGKILL;主动收割不触发 onExit(模型以此区分「主动停」与「崩溃需重启」)
    public func terminate() {
        guard process.isRunning else { return }
        isRunning = false
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

    private func stderrPipeCleanup() {
        (process.standardOutput as? FileHandle)?.readabilityHandler = nil
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
