import CryptoKit
import Foundation
import os

/// 临时诊断插桩(M3-1 排障:新连接握手后消息不再处理;随根因修复一并移除)
private let serverLog = Logger(subsystem: "opendeck", category: "server")

/// 插件侧 WebSocket 服务端:BSD socket 手写 RFC6455(仅回环,临时端口)。
/// 不用 NWListener:macOS 15+ 本地网络隐私对无 Info.plist 的裸进程直接 EINVAL(实测 2026-10-13),
/// 而回环监听本不需要任何网络权限,自实现反而消除整类环境风险。
/// 所有连接状态收敛在内部串行队列;回调跳出到任意线程,上层自行转主线程。
public final class PluginServer: @unchecked Sendable {
    /// 状态由服务端串行队列独占守卫,跨线程传递安全
    public final class Connection: @unchecked Sendable {
        public let id: UUID
        fileprivate let fileDescriptor: Int32
        fileprivate var isClosed = false
        fileprivate var inbox = Data()
        fileprivate var outbox = Data()
        fileprivate var readSource: DispatchSourceRead?
        /// outbox 暂不可写时挂写就绪源;排空即撤(隐藏的 webview 不读事件,靠读事件重试会永久滞留)
        fileprivate var writeSource: DispatchSourceWrite?
        /// 握手完成前收到的是 HTTP 升级请求
        fileprivate var isHandshaken = false
        /// 分片帧累积(opcode 0x1 首帧 + 0x0 续帧,直到 FIN)
        fileprivate var pendingOpcode: UInt8 = 0
        fileprivate var pendingPayload = Data()

        fileprivate init(id: UUID, fileDescriptor: Int32) {
            self.id = id
            self.fileDescriptor = fileDescriptor
        }
    }

    /// 监听就绪(带实际端口)
    public var onReady: (@Sendable (UInt16) -> Void)?
    public var onOpen: (@Sendable (Connection) -> Void)?
    public var onMessage: (@Sendable (Connection, Data) -> Void)?
    public var onClose: (@Sendable (Connection) -> Void)?
    public var onError: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "opendeck.plugin.server")
    private var listenDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var connections: [UUID: Connection] = [:]
    /// EMFILE/ENFILE 冷却标志:读源挂起期间为 true,恢复时置回(stop 前须 resume,否则挂起态 cancel 卡住 fd)
    private var acceptThrottled = false
    private(set) public var port: UInt16 = 0

    /// 单连接缓冲上限:正常 setImage 帧 ~22KB,32MB 足够宽裕;对端喂超大帧头、
    /// 无 FIN 续帧或拒收时到顶即熔断断连(插件会被 respawn),防缓冲无界。
    /// 与 inbox 压缩互补:压缩治慢性增长,熔断兜异常对端。
    private static let bufferLimitBytes = 32 * 1024 * 1024
    /// 握手前 header 专用上限:HTTP 升级头只有几百字节,迟迟不来 `\r\n\r\n` 的连接
    /// 到顶即断(否则 inbox 永远走不到握手后的 32MB 检查,可无界增长)
    private static let handshakeHeaderLimitBytes = 64 * 1024

    public init() {}

    public func start() {
        queue.async { [weak self] in
            self?.bindLoopback()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            // EMFILE 冷却中的挂起必须先配平 resume,cancel handler 才会执行(fd 得以关闭)
            if self.acceptThrottled {
                self.acceptThrottled = false
                self.readSource?.resume()
            }
            self.readSource?.cancel()
            self.readSource = nil
            for connection in self.connections.values {
                self.shutdown(connection)
            }
            self.connections.removeAll()
            if self.listenDescriptor >= 0 {
                Darwin.close(self.listenDescriptor)
                self.listenDescriptor = -1
            }
        }
    }

    /// 发送一帧文本 JSON
    public func send(_ data: Data, to connection: Connection) {
        queue.async { [weak self] in
            guard let self, !connection.isClosed else { return }
            self.enqueueFrame(opcode: 0x1, payload: data, connection: connection)
            self.flush(connection)
        }
    }

    public func close(_ connection: Connection) {
        queue.async { [weak self] in
            guard let self, !connection.isClosed else { return }
            self.enqueueFrame(opcode: 0x8, payload: Data(), connection: connection)
            self.flush(connection)
            self.shutdown(connection)
            self.connections.removeValue(forKey: connection.id)
            self.onClose?(connection)
        }
    }

    // MARK: - 监听与接受(queue 上执行)

    private func bindLoopback() {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            onError?("socket 创建失败 errno=\(errno)")
            return
        }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        // 对端断开后写入不再抛 SIGPIPE 杀死整个进程(测试宿主/正式 app 同源),改为写入返回 EPIPE 走关闭路径
        var nosigpipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        // 非阻塞:level-triggered 读源已保证就绪才进 accept,再阻塞式 accept 会卡死串行队列(实测踩坑)
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = 0 // 临时端口
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(descriptor, 8) == 0 else {
            onError?("监听失败 errno=\(errno)")
            Darwin.close(descriptor)
            return
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getsockname(descriptor, withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, &length) == 0 else {
            onError?("getsockname 失败")
            Darwin.close(descriptor)
            return
        }
        port = UInt16(bigEndian: boundAddress.sin_port)
        listenDescriptor = descriptor

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.listenDescriptor >= 0 else { return }
            Darwin.close(self.listenDescriptor)
            self.listenDescriptor = -1
        }
        source.resume()
        readSource = source
        onReady?(port)
    }

    private func acceptPending() {
        // 一次事件只 accept 一个:fd 已非阻塞且读源水平触发,还有积压会立刻再次进来
        var address = sockaddr()
        var length = socklen_t(MemoryLayout<sockaddr>.size)
        let descriptor = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listenDescriptor, $0, &length)
            }
        }
        guard descriptor >= 0 else {
            // fd 耗尽(EMFILE/ENFILE)时读源水平触发会立刻再进 accept,形成热循环空转;
            // 挂起读源 1s 给对端时间关闭,期间其余串行队列任务照常
            if (errno == EMFILE || errno == ENFILE), !acceptThrottled {
                serverLog.error("server: accept fd 耗尽 errno=\(errno),读源挂起 1s")
                acceptThrottled = true
                readSource?.suspend()
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.acceptThrottled else { return }
                    self.acceptThrottled = false
                    self.readSource?.resume()
                }
            }
            return // EAGAIN = 没了
        }

        var nodelay: Int32 = 1
        setsockopt(descriptor, Int32(IPPROTO_TCP), TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
        // 同监听端:已接受连接也要关 SIGPIPE(webview 重载/客户端断连后的写路径)
        var nosigpipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        // 已接受 fd 必须显式设非阻塞:BSD 语义 accept 不继承监听端的 O_NONBLOCK,阻塞式
        // socket 上对端停止读时 write 会直接挂死在串行队列(而非返回 EAGAIN 走写就绪源),
        // 新连接/其他插件收发/stop() 全部排队卡死
        let acceptedFlags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, acceptedFlags | O_NONBLOCK)

        let connection = Connection(id: UUID(), fileDescriptor: descriptor)
        connections[connection.id] = connection
        serverLog.info("server: accept fd=\(descriptor) 连接数=\(self.connections.count)")
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailable(connection)
        }
        source.setCancelHandler { [weak connection] in
            guard let connection else { return }
            Darwin.close(connection.fileDescriptor)
        }
        connection.readSource = source
        source.resume()
        onOpen?(connection)
    }

    private func readAvailable(_ connection: Connection) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = read(connection.fileDescriptor, &buffer, buffer.count)
        serverLog.info("server: read fd=\(connection.fileDescriptor) n=\(count)")
        if count == 0 {
            finish(connection) // 对端正常关闭
            return
        }
        if count < 0 {
            // EAGAIN(水平触发的边界竞态)/EINTR 都不是致命错误,保留连接;其余按断开走优雅关闭
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
            finish(connection)
            return
        }
        connection.inbox.append(contentsOf: buffer[0..<count])
        drainInbox(connection)
    }

    private func drainInbox(_ connection: Connection) {
        if !connection.isHandshaken {
            completeHandshakeIfNeeded(connection)
            if !connection.isHandshaken {
                // 握手前也要熔断:header 永远不来齐的连接在下方 32MB 检查之前就能吃满内存
                if connection.inbox.count > Self.handshakeHeaderLimitBytes {
                    serverLog.error("server: 握手前 inbox 超限 \(connection.inbox.count)B,熔断 fd=\(connection.fileDescriptor)")
                    finish(connection)
                }
                return
            }
            serverLog.info("server: 握手完成 fd=\(connection.fileDescriptor)")
        }
        while true {
            guard let frame = parseFrame(connection) else { break }
            serverLog.info("server: 帧 fd=\(connection.fileDescriptor) op=\(frame.opcode) len=\(frame.payload.count) final=\(frame.isFinal)")
            switch frame.opcode {
            case 0x1, 0x2: // text / binary
                if frame.isFinal {
                    onMessage?(connection, frame.payload)
                } else {
                    connection.pendingOpcode = frame.opcode
                    connection.pendingPayload = frame.payload
                }
            case 0x0: // 续帧
                connection.pendingPayload.append(frame.payload)
                if connection.pendingPayload.count > Self.bufferLimitBytes {
                    serverLog.error("server: 分片消息超限 \(connection.pendingPayload.count)B,熔断 fd=\(connection.fileDescriptor)")
                    finish(connection)
                    return
                }
                if frame.isFinal {
                    onMessage?(connection, connection.pendingPayload)
                    connection.pendingPayload.removeAll()
                }
            case 0x8: // close
                enqueueFrame(opcode: 0x8, payload: Data(), connection: connection)
                flush(connection)
                finish(connection)
                return
            case 0x9: // ping → pong
                enqueueFrame(opcode: 0xA, payload: frame.payload, connection: connection)
            default:
                break // pong 等,忽略
            }
        }
        // Data 的 removeFirst 只前移游标、append 不回用已消费前缀,底层存储随累计收包量
        // 只增不减(2026-10-30 内存体检实测吞吐与 footprint 1:1)。消费后显式压缩,只保留
        // 未完成的帧尾;isEmpty 分支的引用重置同样释放底层存储。
        if connection.inbox.isEmpty {
            connection.inbox = Data()
        } else if connection.inbox.startIndex > 0 {
            connection.inbox = Data(connection.inbox)
        }
        if connection.inbox.count > Self.bufferLimitBytes {
            // 到这里说明对端在喂超大帧头或无终止的垃圾字节,等不齐完整帧了
            serverLog.error("server: inbox 超限 \(connection.inbox.count)B,熔断 fd=\(connection.fileDescriptor)")
            finish(connection)
        }
    }

    // MARK: - WebSocket 握手(queue 上执行)

    private func completeHandshakeIfNeeded(_ connection: Connection) {
        let headerTerminator = Data("\r\n\r\n".utf8)
        guard let range = connection.inbox.range(of: headerTerminator) else { return }
        let headerText = String(data: connection.inbox[connection.inbox.startIndex..<range.lowerBound], encoding: .utf8) ?? ""
        connection.inbox.removeSubrange(connection.inbox.startIndex..<range.upperBound)

        guard headerText.uppercased().contains("UPGRADE: WEBSOCKET"),
              let keyLine = headerText
                  .split(separator: "\r\n")
                  .first(where: { $0.uppercased().hasPrefix("SEC-WEBSOCKET-KEY:") }),
              let clientKey = String(keyLine.split(separator: ":", maxSplits: 1).last ?? "")
                  .trimmingCharacters(in: .whitespaces) as String?,
              !clientKey.isEmpty
        else {
            onError?("非法 WebSocket 升级请求")
            finish(connection)
            return
        }

        // RFC6455:accept = base64(sha1(key + GUID))
        let magic = clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Data(Insecure.SHA1.hash(data: Data(magic.utf8)))
        let acceptKey = digest.base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
        connection.outbox.append(Data(response.utf8))
        flush(connection)
        connection.isHandshaken = true
    }

    // MARK: - 帧编解码(queue 上执行)

    private struct Frame {
        let opcode: UInt8
        let isFinal: Bool
        let payload: Data
    }

    /// 服务端帧不掩码;客户端(插件)帧必须掩码
    private func parseFrame(_ connection: Connection) -> Frame? {
        let data = connection.inbox
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        let opcode = bytes[0] & 0x7F
        let isFinal = (bytes[0] & 0x80) != 0
        let masked = (bytes[1] & 0x80) != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard data.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard data.count >= 10 else { return nil }
            // 64 位长度逐字节累积:普通 << 在溢出时直接 trap 整个宿主进程,必须用
            // 报溢出的安全算术;合法帧(最大 ~22KB)也远小于缓冲上限,超限即敌意
            // 帧头,当场熔断断连——不能只返回 nil 等收齐:对端只发 10 字节帧头时
            // inbox 永远不涨,32MB 熔断永远够不着
            var accumulated = 0
            for byte in bytes[2..<10] {
                let (shifted, shiftOverflow) = accumulated.multipliedReportingOverflow(by: 256)
                let (added, addOverflow) = shifted.addingReportingOverflow(Int(byte))
                guard !shiftOverflow, !addOverflow, added <= Self.bufferLimitBytes else {
                    serverLog.error("server: 64 位帧长度超限/溢出,熔断 fd=\(connection.fileDescriptor)")
                    finish(connection)
                    return nil
                }
                accumulated = added
            }
            length = accumulated
            offset = 10
        }
        var maskKey: [UInt8] = []
        if masked {
            guard data.count >= offset + 4 else { return nil }
            maskKey = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }
        guard data.count >= offset + length else { return nil }
        var payload = Data(bytes[offset..<(offset + length)])
        if masked {
            for index in 0..<payload.count {
                payload[index] ^= maskKey[index % 4]
            }
        }
        connection.inbox.removeFirst(offset + length)
        return Frame(opcode: opcode, isFinal: isFinal, payload: payload)
    }

    private func enqueueFrame(opcode: UInt8, payload: Data, connection: Connection) {
        var header: [UInt8]
        let length = payload.count
        if length < 126 {
            header = [0x80 | opcode, UInt8(length)]
        } else if length < 65536 {
            header = [0x80 | opcode, 126, UInt8(length >> 8), UInt8(length & 0xFF)]
        } else {
            header = [0x80 | opcode, 127]
            header.append(contentsOf: (0..<8).reversed().map { UInt8((length >> ($0 * 8)) & 0xFF) })
        }
        connection.outbox.append(Data(header))
        connection.outbox.append(payload)
        if connection.outbox.count > Self.bufferLimitBytes {
            // 对端拒收(写不出去还继续排队)才可能到顶;finish 幂等,与 close 路径不冲突
            serverLog.error("server: outbox 超限 \(connection.outbox.count)B,熔断 fd=\(connection.fileDescriptor)")
            finish(connection)
        }
    }

    private func flush(_ connection: Connection) {
        while !connection.outbox.isEmpty {
            let written = connection.outbox.withUnsafeBytes { rawBuffer in
                write(connection.fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if written > 0 {
                connection.outbox.removeFirst(written)
            } else if written < 0, errno == EINTR {
                continue // 信号中断:同读路径语义,原样重试,不算对端故障
            } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                // 写缓冲满:挂写就绪源排空——隐藏的 webview 不产生读事件,靠读事件重试会永久滞留
                armWriteSource(connection)
                return
            } else {
                finish(connection)
                return
            }
        }
    }

    /// 写就绪源:outbox 非空且 socket 暂不可写时挂起,可写即排空;排空即撤
    private func armWriteSource(_ connection: Connection) {
        guard connection.writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: connection.fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.flush(connection)
            if connection.outbox.isEmpty {
                connection.writeSource?.cancel()
                connection.writeSource = nil
            }
        }
        connection.writeSource = source
        source.resume()
    }

    private func finish(_ connection: Connection) {
        guard !connection.isClosed else { return }
        serverLog.info("server: finish fd=\(connection.fileDescriptor)")
        shutdown(connection)
        connections.removeValue(forKey: connection.id)
        onClose?(connection)
    }

    private func shutdown(_ connection: Connection) {
        connection.isClosed = true
        connection.readSource?.cancel()
        connection.readSource = nil
        connection.writeSource?.cancel()
        connection.writeSource = nil
    }
}
