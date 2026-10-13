import Foundation
import Network

/// 插件侧 WebSocket 服务端:NWListener + NWProtocolWebSocket,只监听 127.0.0.1,端口由系统分配。
/// 回调全部在内部串行队列触发;上层(主线程模型)自行跳线程。每个连接即一个插件进程。
public final class PluginServer: @unchecked Sendable {
    public final class Connection: @unchecked Sendable {
        public let id: UUID
        fileprivate let socket: NWConnection
        fileprivate var isClosed = false

        fileprivate init(id: UUID, socket: NWConnection) {
            self.id = id
            self.socket = socket
        }
    }

    public var onReady: (@Sendable (UInt16) -> Void)?
    public var onOpen: (@Sendable (Connection) -> Void)?
    public var onMessage: (@Sendable (Connection, Data) -> Void)?
    public var onClose: (@Sendable (Connection) -> Void)?
    public var onError: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "opendeck.plugin.server")
    private var listener: NWListener?
    private var connections: [UUID: Connection] = [:]
    private(set) public var port: UInt16 = 0

    public init() {}

    public func start() {
        let parameters = NWParameters()
        parameters.allowLocalEndpointReuse = true
        // 插件只从本机连接;不暴露到局域网
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        do {
            let listener = try NWListener(using: parameters, on: .any)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let port = self?.listener?.port?.rawValue ?? 0
                    self?.port = port
                    self?.onReady?(port)
                case .failed(let error):
                    self?.onError?("WebSocket 监听失败: \(error)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] socket in
                self?.accept(socket)
            }
            listener.start(queue: queue)
        } catch {
            onError?("WebSocket 监听创建失败: \(error.localizedDescription)")
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values {
                connection.socket.cancel()
            }
            self.connections.removeAll()
        }
    }

    /// 发送一帧文本 JSON
    public func send(_ data: Data, to connection: Connection) {
        queue.async { [weak self] in
            guard let self, !connection.isClosed else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
            connection.socket.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    if let error {
                        self?.onError?("发送失败: \(error)")
                    }
                }
            )
        }
    }

    public func close(_ connection: Connection) {
        queue.async { [weak self] in
            guard let self, !connection.isClosed else { return }
            connection.isClosed = true
            connection.socket.cancel()
            self.connections.removeValue(forKey: connection.id)
            self.onClose?(connection)
        }
    }

    // MARK: - 私有(queue 上执行)

    private func accept(_ socket: NWConnection) {
        let connection = Connection(id: UUID(), socket: socket)
        connections[connection.id] = connection
        socket.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onOpen?(connection)
            case .failed, .cancelled:
                self?.finish(connection)
            default:
                break
            }
        }
        socket.start(queue: queue)
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: Connection) {
        // receiveMessage 对 WebSocket 返回一条完整消息(自动拼装分片帧)
        connection.socket.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.onMessage?(connection, data)
            }
            if error == nil {
                self.receiveLoop(connection)
            } else {
                self.finish(connection)
            }
        }
    }

    private func finish(_ connection: Connection) {
        guard !connection.isClosed else { return }
        connection.isClosed = true
        connections.removeValue(forKey: connection.id)
        onClose?(connection)
    }
}
