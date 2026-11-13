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
    /// How long a connection must have stayed open to count as one that worked.
    private let settledAfter: Duration
    public init(client: FeishuBotClient) { provider = client; makePath = { SystemFeishuPath() }; settledAfter = .seconds(5) }
    init(provider: any FeishuEndpointProviding,
         makePath: @escaping @Sendable () -> any FeishuPathObserving = { SystemFeishuPath() },
         settledAfter: Duration = .seconds(5)) {
        self.provider = provider; self.makePath = makePath; self.settledAfter = settledAfter
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
                let opened = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
                var activeSocket: FeishuSocket?
                do {
                    let endpoint = try await provider.requestConnectionEndpoint()
                    settings = endpoint.settings
                    try settings.validate()
                    let socket = FeishuSocket(endpoint: endpoint, path: makePath(), diagnostic: diagnostic)
                    activeSocket = socket
                    try await socket.run(router: router, onOpen: {
                        opened.withLock { $0 = .now }
                        await onState(.socketOpen(socket.connectionID))
                    }, onAction: onAction, onRefusal: onRefusal)
                    throw FeishuSocketFailure.unavailable
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    if let activeSocket { settings = activeSocket.currentSettings }
                    let openedAt = opened.withLock { $0 }
                    if openedAt != nil { retries = 0 }
                    // A connection the provider dropped as soon as it opened did not work; only one that stayed
                    // open earns the quick retry below, so an accept-then-close fault never becomes a storm.
                    let settled = openedAt.map { $0.duration(to: .now) >= settledAfter } ?? false
                    let failure = Self.failure(error)
                    guard Self.retryable(failure), settings.reconnectCount == -1 || retries < settings.reconnectCount else {
                        FeishuDiagnostics.failure(.reconnect, operation: diagnostic, error: failure)
                        await onState(.blocked(failure))
                        throw failure
                    }
                    retries += 1
                    // A connection that had worked is retried after the jitter alone, as the provider's own clients
                    // do, so a card finishing right after a network blip still gets its reply box (AC-05.09); the
                    // provider's interval separates consecutive failures. Never less than a second.
                    let jitter = Int.random(in: 0...settings.reconnectJitterSeconds)
                    let delay = settled ? max(1, jitter) : max(1, settings.reconnectSeconds) + jitter
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

    /// Faults of the network, of one answer or of one frame are retried under the provider's limit. An answer
    /// that cannot be read (a proxy's page, a cut-off body, a rejected frame) says nothing about the app, so it
    /// is retried too; the provider's credential and permission verdicts and a closed client are not.
    private static func retryable(_ failure: FeishuBotFailure) -> Bool {
        switch failure {
        case .unavailable, .rateLimited, .invalidResponse: return true
        case .providerRejected(let code): return FeishuBotFailure.transientProviderCodes.contains(code)
        default: return false
        }
    }
}
