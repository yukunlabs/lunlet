// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-14, AC-14.01, AC-14.02, AC-14.03, AC-14.06.
// Refs: US-01, AC-01.02, AC-01.04; US-10, AC-10.01, AC-10.02, AC-10.04.
// Refs: US-11, AC-11.01, AC-11.02; US-12, AC-12.02, AC-12.04; US-05, AC-05.09.
import Foundation
import LunletCore

enum FeishuSocketFailure: Error, Equatable { case closed, unavailable, invalidProtocol }

public struct FeishuSocketAction: Sendable, CustomStringConvertible {
    public let connectionID: UUID
    public let continuation: AuthorizedContinuation
    public var description: String { "Feishu socket action (redacted)" }
}

/// One owned connection. A reconnect must discover a fresh endpoint and create a new instance.
final class FeishuSocket: Sendable {
    let connectionID = UUID()
    private let diagnostic: DiagnosticOperation
    private let endpoint: FeishuConnectionEndpoint
    private let state: SocketState
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let path: any FeishuPathObserving
    private let pulse: SocketHeartbeat
    var currentSettings: FeishuConnectionSettings { pulse.currentSettings }

    init(endpoint: FeishuConnectionEndpoint, path: any FeishuPathObserving = SystemFeishuPath(),
         diagnostic: DiagnosticOperation = DiagnosticOperation()) {
        self.diagnostic = diagnostic
        self.endpoint = endpoint
        self.path = path
        pulse = SocketHeartbeat(settings: endpoint.settings)
        let state = SocketState()
        self.state = state
        let session = HardenedHTTP.session(requestTimeout: 15, resourceTimeout: nil, delegate: SocketDelegate(state: state))
        self.session = session
        socket = session.webSocketTask(with: endpoint.url)
        socket.maximumMessageSize = 65_536
    }

    deinit { pulse.stop(); path.cancel(); socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }

    func run(router: CardActionRouter, onOpen: @escaping @Sendable () async -> Void = {},
             onAction: @escaping @Sendable (FeishuSocketAction) -> Void,
             onRefusal: @escaping @Sendable (FeishuCardRefusal) -> Void = { _ in }) async throws {
        guard state.begin() else { throw FeishuSocketFailure.closed }
        DiagnosticLog.record(.connection, component: .feishu, outcome: .started, operation: diagnostic)
        try await withTaskCancellationHandler {
            try await runOwned(router: router, onOpen: onOpen, onAction: onAction, onRefusal: onRefusal)
        } onCancel: { close() }
    }

    func close() {
        state.close()
        pulse.stop()
        path.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    private func runOwned(router: CardActionRouter, onOpen: @Sendable () async -> Void,
                          onAction: @Sendable (FeishuSocketAction) -> Void,
                          onRefusal: @Sendable (FeishuCardRefusal) -> Void) async throws {
        let socket = socket, state = state, session = session
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            if state.finish(.failure(.unavailable)) { socket.cancel(with: .goingAway, reason: nil) }
        }
        var heartbeat: Task<Void, Never>?
        do {
            try checkActive()
            path.start {
                state.interrupt()
                socket.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            }
            socket.resume()
            try await state.opened()
            deadline.cancel()
            try checkActive()
            DiagnosticLog.record(.connection, component: .feishu, outcome: .completed, operation: diagnostic)
            await onOpen()
            try checkActive()
            let pulse = pulse
            pulse.start()
            let serviceID = endpoint.serviceID
            heartbeat = Task {
                do {
                    for await _ in pulse.ticks {
                        try Task.checkCancellation()
                        guard !pulse.expired() else {
                            socket.cancel(with: .goingAway, reason: nil)
                            session.invalidateAndCancel()
                            return
                        }
                        try await socket.send(.data(FrameAssembler.ping(serviceID: serviceID)))
                    }
                } catch {
                    if !Task.isCancelled {
                        socket.cancel(with: .goingAway, reason: nil)
                        session.invalidateAndCancel()
                    }
                }
            }
            let assembler = FrameAssembler(serviceID: endpoint.serviceID)
            let origin = ContinuousClock.now
            while true {
                let message = try await socket.receive()
                let started = ContinuousClock.now
                try checkActive()
                guard case .data(let data) = message else { throw FeishuSocketFailure.invalidProtocol }
                switch try assembler.receive(data, now: Self.seconds(origin.duration(to: started))) {
                case .incomplete, .ignored: continue
                case .pong(let data): try pulse.pong(data)
                case .event(let event):
                    let result = await router.handle(event.payload, connectionID: connectionID)
                    try checkActive()
                    let milliseconds = Int(min(60_000, max(0, Self.seconds(started.duration(to: .now)) * 1_000)))
                    // One refusal report per bound card lets its owner receive a session-named receipt.
                    if case .refused(_, let report?) = result { onRefusal(report) }
                    if milliseconds >= 2_500 {
                        if case .received(let action) = result { await router.updateReceipt(action.receipt.id, status: .failed) }
                        try await socket.send(.data(FrameAssembler.acknowledgment(for: event, responseJSON: nil,
                                                                                   elapsedMilliseconds: milliseconds)))
                        continue
                    }
                    let response = try result.responseJSON()
                    try await socket.send(.data(FrameAssembler.acknowledgment(for: event, responseJSON: response,
                                                                               elapsedMilliseconds: milliseconds)))
                    try checkActive()
                    if case .received(let action) = result {
                        // The consumer must revalidate this connection and session before dispatch.
                        onAction(FeishuSocketAction(connectionID: connectionID, continuation: action))
                    }
                }
            }
        } catch {
            let failure: any Error
            if Task.isCancelled { failure = CancellationError() }
            else if state.isInterrupted { failure = FeishuSocketFailure.unavailable }
            else if let socketError = error as? FeishuSocketFailure { failure = socketError }
            else if error is FeishuFrameFailure || error is FeishuBotFailure { failure = FeishuSocketFailure.invalidProtocol }
            else { failure = state.isClosed ? FeishuSocketFailure.closed : FeishuSocketFailure.unavailable }
            FeishuDiagnostics.failure(.connection, operation: diagnostic, error: failure)
            close()
            deadline.cancel()
            heartbeat?.cancel()
            await deadline.value
            await heartbeat?.value
            await router.connectionClosed(connectionID)
            throw failure
        }
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !state.isInterrupted else { throw FeishuSocketFailure.unavailable }
        guard !state.isClosed else { throw FeishuSocketFailure.closed }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

private final class SocketState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var closed = false
    private var interrupted = false
    private var result: Result<Void, FeishuSocketFailure>?
    private var waiter: CheckedContinuation<Void, any Error>?
    var isClosed: Bool { lock.withLock { closed } }
    var isInterrupted: Bool { lock.withLock { interrupted } }

    func begin() -> Bool { lock.withLock { guard !started, !closed else { return false }; started = true; return true } }
    func close() { lock.withLock { closed = true }; finish(.failure(.closed)) }
    func interrupt() { lock.withLock { interrupted = true }; finish(.failure(.unavailable)) }

    @discardableResult func finish(_ result: Result<Void, FeishuSocketFailure>) -> Bool {
        let pending: (Bool, CheckedContinuation<Void, any Error>?) = lock.withLock {
            guard self.result == nil else { return (false, nil) }
            self.result = result
            let current = waiter; waiter = nil
            return (true, current)
        }
        pending.1?.resume(with: result.mapError { $0 as any Error })
        return pending.0
    }

    func opened() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let current: Result<Void, FeishuSocketFailure>? = lock.withLock {
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let current { continuation.resume(with: current.mapError { $0 as any Error }) }
        }
    }
}

/// Holds only lock-protected socket state; redirects stay refused by the base class.
private final class SocketDelegate: RedirectBlocker, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let state: SocketState
    init(state: SocketState) { self.state = state }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        state.finish(.success(()))
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        state.finish(.failure(.unavailable))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        state.finish(.failure(.unavailable))
    }
}

/// Rescheduling the timer wakes the next heartbeat at the provider's current interval.
private final class SocketHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: FeishuConnectionSettings
    private var lastPong = ContinuousClock.now
    private var stopped = false
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "lunlet.feishu-heartbeat"))
    let ticks: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(settings: FeishuConnectionSettings) {
        self.settings = settings
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        ticks = stream.stream
        continuation = stream.continuation
        let continuation = continuation
        timer.setEventHandler { continuation.yield(()) }
        timer.schedule(deadline: .distantFuture)
        timer.activate()
    }

    var currentSettings: FeishuConnectionSettings { lock.withLock { settings } }
    func start() {
        lock.withLock {
            guard !stopped else { return }
            lastPong = .now
            timer.schedule(deadline: .now() + .seconds(settings.pingSeconds), repeating: .seconds(settings.pingSeconds))
        }
    }

    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            timer.setEventHandler {}
            timer.cancel()
            continuation.finish()
        }
    }

    deinit { timer.cancel(); continuation.finish() }
    func expired() -> Bool { lock.withLock { lastPong.duration(to: .now) >= .seconds(settings.pingSeconds * 2) } }
    func pong(_ data: Data) throws {
        guard data.count <= 65_536, let update = try? JSONDecoder().decode(FeishuConnectionSettings.self, from: data) else {
            throw FeishuSocketFailure.invalidProtocol
        }
        try lock.withLock {
            guard !stopped else { throw FeishuSocketFailure.closed }
            var next = settings
            if let value = update.pingInterval { next.pingInterval = value }
            if let value = update.maximumReconnects { next.maximumReconnects = value }
            if let value = update.reconnectInterval { next.reconnectInterval = value }
            if let value = update.reconnectNonce { next.reconnectNonce = value }
            try next.validate()
            settings = next
            lastPong = .now
            timer.schedule(deadline: .now() + .seconds(settings.pingSeconds), repeating: .seconds(settings.pingSeconds))
        }
    }
}
