// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-14, AC-14.01, AC-14.02, AC-14.03, AC-14.06.
// Refs: US-01, AC-01.02, AC-01.04; US-10, AC-10.01, AC-10.04.
// Refs: US-11, AC-11.01, AC-11.02; US-12, AC-12.02, AC-12.04; US-05, AC-05.09.
import Foundation
import LunletCore
import os

public enum FeishuTransportState: Equatable, Sendable {
    case connecting, socketOpen(UUID), waitingToReconnect(attempt: Int, delaySeconds: Int)
    case blocked(FeishuBotFailure), stopped
}

/// A callback long connection that is run once; cancel and await the calling Task to close it.
public protocol FeishuCallbackConnecting: Sendable {
    func run(router: CardActionRouter, onState: @escaping @Sendable (FeishuTransportState) async -> Void,
             onAction: @escaping @Sendable (FeishuSocketAction) -> Void,
             onRefusal: @escaping @Sendable (FeishuCardRefusal) -> Void) async throws
}

/// Own the calling Task: cancel and await it to close the socket and pending retry.
/// Socket-open state does not establish callback configuration or mobile readiness.
public actor FeishuConnectionRunner: FeishuCallbackConnecting {
    private let provider: any FeishuEndpointProviding
    private let makePath: @Sendable () -> any FeishuPathObserving
    private var hasRun = false
    public init(client: FeishuBotClient) { provider = client; makePath = { SystemFeishuPath() } }
    init(provider: any FeishuEndpointProviding,
         makePath: @escaping @Sendable () -> any FeishuPathObserving = { SystemFeishuPath() }) {
        self.provider = provider; self.makePath = makePath
    }

    public func run(router: CardActionRouter, onState: @escaping @Sendable (FeishuTransportState) async -> Void,
                    onAction: @escaping @Sendable (FeishuSocketAction) -> Void,
                    onRefusal: @escaping @Sendable (FeishuCardRefusal) -> Void = { _ in }) async throws {
        guard !hasRun else { throw FeishuBotFailure.disconnected }
        hasRun = true
        let diagnostic = DiagnosticOperation()
        var settings = FeishuConnectionSettings()
        var retries = 0
        do {
            while true {
                try Task.checkCancellation()
                await onState(.connecting)
                let opened = OSAllocatedUnfairLock(initialState: false)
                var activeSocket: FeishuSocket?
                do {
                    let endpoint = try await provider.requestConnectionEndpoint()
                    settings = endpoint.settings
                    try settings.validate()
                    let socket = FeishuSocket(endpoint: endpoint, path: makePath(), diagnostic: diagnostic)
                    activeSocket = socket
                    try await socket.run(router: router, onOpen: {
                        opened.withLock { $0 = true }
                        await onState(.socketOpen(socket.connectionID))
                    }, onAction: onAction, onRefusal: onRefusal)
                    throw FeishuSocketFailure.unavailable
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    if let activeSocket { settings = activeSocket.currentSettings }
                    if opened.withLock({ $0 }) { retries = 0 }
                    let failure = Self.failure(error)
                    guard Self.retryable(failure), settings.reconnectCount == -1 || retries < settings.reconnectCount else {
                        FeishuDiagnostics.failure(.reconnect, operation: diagnostic, error: failure)
                        await onState(.blocked(failure))
                        throw failure
                    }
                    retries += 1
                    let delay = max(1, settings.reconnectSeconds) + Int.random(in: 0...settings.reconnectJitterSeconds)
                    DiagnosticLog.record(.reconnect, component: .feishu, outcome: .retrying, operation: diagnostic)
                    await onState(.waitingToReconnect(attempt: retries, delaySeconds: delay))
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                DiagnosticLog.record(.connection, component: .feishu, outcome: .cancelled, operation: diagnostic)
                await onState(.stopped)
                throw CancellationError()
            }
            throw error
        }
    }

    private static func failure(_ error: any Error) -> FeishuBotFailure {
        if let failure = error as? FeishuBotFailure { return failure }
        if let failure = error as? FeishuSocketFailure { return failure == .invalidProtocol ? .invalidResponse : .unavailable }
        return .invalidResponse
    }

    private static func retryable(_ failure: FeishuBotFailure) -> Bool {
        switch failure {
        case .unavailable, .rateLimited, .providerRejected(1), .providerRejected(1000040343): return true
        default: return false
        }
    }
}
