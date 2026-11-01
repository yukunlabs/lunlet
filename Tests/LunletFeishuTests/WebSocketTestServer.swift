// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.02; US-10, AC-10.01, AC-10.04.
// Refs: US-11, AC-11.01, AC-11.02; US-12, AC-12.04.
import Foundation
import Network

private final class SocketTestOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// Real loopback WebSocket server; Network.framework owns RFC framing and handshakes.
final class WebSocketTestServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lunlet.synthetic-websocket")
    private let listener: NWListener
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var received: [Data] = []
    private var initial: [Data] = []

    init(acceptHandshake: Bool = true) throws {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 65_536
        let queue = queue
        webSocket.setClientRequestHandler(queue) { _, _ in .init(status: acceptHandshake ? .accept : .reject, subprotocol: nil) }
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    func start() async throws -> URL {
        let once = SocketTestOnce(), listener = listener
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take(), let port = listener.port { listener.stateUpdateHandler = nil; continuation.resume(returning: port) }
                case .failed(let error): if once.take() { listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
                case .cancelled: if once.take() { listener.stateUpdateHandler = nil; continuation.resume(throwing: URLError(.cancelled)) }
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 3) {
                if once.take() { listener.stateUpdateHandler = nil; listener.cancel(); continuation.resume(throwing: URLError(.timedOut)) }
            }
            listener.start(queue: queue)
        }
        return URL(string: "ws://127.0.0.1:\(port.rawValue)/synthetic")!
    }

    func sendOnConnect(_ data: [Data]) { lock.withLock { initial = data } }
    func messages() -> [Data] { lock.withLock { received } }
    func broadcast(_ data: Data) {
        let active = lock.withLock { connections }
        for connection in active {
            let context = NWConnection.ContentContext(identifier: "synthetic-event",
                                                      metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }
    }
    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        let active = lock.withLock { let value = connections; connections = []; return value }
        active.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let self {
                connection.stateUpdateHandler = nil
                let values = self.lock.withLock { self.initial }
                for data in values {
                    let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
                    let context = NWConnection.ContentContext(identifier: "synthetic-event", metadata: [metadata])
                    connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
                }
                self.receive(connection)
            } else if case .failed = state {
                connection.stateUpdateHandler = nil
                connection.cancel()
            } else if case .cancelled = state {
                connection.stateUpdateHandler = nil
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let data { self.lock.withLock { self.received.append(data) } }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error == nil && metadata?.opcode != .close { self.receive(connection) }
        }
    }
}
