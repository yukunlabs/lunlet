// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.02, AC-01.04; US-10, AC-10.01, AC-10.04.
// Refs: US-11, AC-11.01, AC-11.02; US-12, AC-12.02, AC-12.04.
import Foundation
import Testing
import SwiftProtobuf
@testable import LunletFeishu

private actor SyntheticEndpointProvider: FeishuEndpointProviding {
    let endpoint: FeishuConnectionEndpoint?
    let failure: FeishuBotFailure?
    private(set) var requests = 0
    init(endpoint: FeishuConnectionEndpoint? = nil, failure: FeishuBotFailure? = nil) {
        self.endpoint = endpoint; self.failure = failure
    }
    func requestConnectionEndpoint() throws -> FeishuConnectionEndpoint {
        requests += 1
        if let failure { throw failure }
        return endpoint!
    }
}

private final class TransportStates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FeishuTransportState] = []
    func append(_ state: FeishuTransportState) { lock.withLock { values.append(state) } }
    func snapshot() -> [FeishuTransportState] { lock.withLock { values } }
}

struct FeishuConnectionRunnerTests {
    @Test func retryLimitsCountFreshEndpointDiscoveryAndRespectAMinimumDelay() async throws {
        let endpoint = FeishuConnectionEndpoint(url: URL(string: "ws://127.0.0.1:1/synthetic")!, serviceID: 42, deviceID: "synthetic",
                                                settings: .init(pingInterval: 120, maximumReconnects: 2,
                                                                reconnectInterval: 0, reconnectNonce: 0))
        let provider = SyntheticEndpointProvider(endpoint: endpoint)
        // Exercise real retry policy through immediate path loss. Native socket
        // handshakes have separate coverage; their deadlines are irrelevant here.
        let runner = FeishuConnectionRunner(provider: provider, makePath: { SyntheticFeishuPath(interruptOnStart: true) })
        let states = TransportStates()
        await #expect(throws: FeishuBotFailure.unavailable) {
            try await runner.run(router: CardActionRouter(), onState: { states.append($0) },
                                 onAction: { _ in Issue.record("An unavailable network path cannot emit an action") })
        }
        #expect(await provider.requests == 3)
        let delays = states.snapshot().compactMap { state -> Int? in
            if case .waitingToReconnect(_, let seconds) = state { return seconds }; return nil
        }
        #expect(delays == [1, 1])
        #expect(states.snapshot().last == .blocked(.unavailable))
    }

    @Test func cancellationInterruptsTheRetryDelayWithoutAnotherDiscoveryRequest() async throws {
        let provider = SyntheticEndpointProvider(failure: .unavailable)
        let runner = FeishuConnectionRunner(provider: provider, makePath: { SyntheticFeishuPath() })
        let states = TransportStates()
        let running = Task {
            try await runner.run(router: CardActionRouter(), onState: { states.append($0) },
                                 onAction: { _ in Issue.record("No connection exists") })
        }
        for _ in 0..<3_000 {
            if states.snapshot().contains(where: { if case .waitingToReconnect = $0 { return true }; return false }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await provider.requests == 1)
        #expect(states.snapshot().last == .stopped)
    }

    @Test(arguments: [FeishuBotFailure.providerRejected(514), .providerRejected(403), .invalidResponse, .disconnected])
    func authenticationAndProtocolFailuresRequireExplicitRecovery(_ failure: FeishuBotFailure) async throws {
        let provider = SyntheticEndpointProvider(failure: failure)
        let runner = FeishuConnectionRunner(provider: provider, makePath: { SyntheticFeishuPath() })
        let states = TransportStates()
        await #expect(throws: failure) {
            try await runner.run(router: CardActionRouter(), onState: { states.append($0) }, onAction: { _ in })
        }
        #expect(await provider.requests == 1)
        #expect(states.snapshot().last == .blocked(failure))
    }
    @Test func pongRetryLimitsApplyWhenTheConnectionEnds() async throws {
        let server = try WebSocketTestServer()
        defer { server.stop() }
        var pong = FeishuWireFrame()
        pong.seqID = 0; pong.logID = 0; pong.service = 42; pong.method = 0
        var header = FeishuWireHeader(); header.key = "type"; header.value = "pong"
        pong.headers = [header]
        pong.payload = Data(#"{"ReconnectCount":0,"ReconnectInterval":0,"ReconnectNonce":0}"#.utf8)
        server.sendOnConnect([try pong.serializedData()])
        let endpoint = FeishuConnectionEndpoint(url: try await server.start(), serviceID: 42, deviceID: "synthetic",
                                                settings: .init(pingInterval: 1, maximumReconnects: 2,
                                                                reconnectInterval: 0, reconnectNonce: 0))
        let provider = SyntheticEndpointProvider(endpoint: endpoint)
        let runner = FeishuConnectionRunner(provider: provider, makePath: { SyntheticFeishuPath() })
        let states = TransportStates()
        let running = Task {
            try await runner.run(router: CardActionRouter(), onState: { states.append($0) }, onAction: { _ in })
        }
        defer { running.cancel() }
        for _ in 0..<3_000 {
            if !server.messages().isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!server.messages().isEmpty)
        server.stop()
        for _ in 0..<3_000 {
            if states.snapshot().contains(where: {
                if case .blocked = $0 { return true }
                if case .waitingToReconnect = $0 { return true }
                return false
            }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        if states.snapshot().contains(where: { if case .waitingToReconnect = $0 { return true }; return false }) {
            running.cancel()
        }
        await #expect(throws: FeishuBotFailure.unavailable) { try await running.value }
        #expect(await provider.requests == 1)
        #expect(states.snapshot().last == .blocked(.unavailable))
    }
}
