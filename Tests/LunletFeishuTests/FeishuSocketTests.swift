// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.02, AC-01.04; US-10, AC-10.01, AC-10.02, AC-10.04.
// Refs: US-11, AC-11.01, AC-11.02; US-12, AC-12.02, AC-12.04; US-05, AC-05.09.
import Foundation
import Testing
import SwiftProtobuf
import LunletCore
@testable import LunletFeishu

private final class SocketActions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FeishuSocketAction] = []
    func append(_ action: FeishuSocketAction) { lock.withLock { values.append(action) } }
    func snapshot() -> [FeishuSocketAction] { lock.withLock { values } }
}

private final class SocketRefusals: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FeishuCardRefusal] = []
    func append(_ refusal: FeishuCardRefusal) { lock.withLock { values.append(refusal) } }
    func snapshot() -> [FeishuCardRefusal] { lock.withLock { values } }
}

struct FeishuSocketTests {
    private func endpoint(_ url: URL, ping: Int = 120) -> FeishuConnectionEndpoint {
        // Insecure loopback is injected only here; production discovery requires WSS.
        FeishuConnectionEndpoint(url: url, serviceID: 42, deviceID: "synthetic", settings: .init(pingInterval: ping))
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<3_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("The synthetic WebSocket exchange did not complete")
        throw URLError(.timedOut)
    }

    @Test func nativeWebSocketAcknowledgesBoundCallbacksAndReleasesTheConnection() async throws {
        let server = try WebSocketTestServer()
        defer { server.stop() }
        let socket = FeishuSocket(endpoint: endpoint(try await server.start()), path: SyntheticFeishuPath())
        defer { socket.close() }
        let router = CardActionRouter(elapsed: { 0 }, wallTime: { CardCallbackFixture.date })
        let access = MobileAccess(owner: CardCallbackFixture.owner, connected: true, awayMode: true, inputEnabled: true)
        await router.setAccess(access, connectionID: socket.connectionID)
        let observed = ObservedSession(sessionID: UUID(), connectionID: UUID(), liveness: .alive, phase: .idle(completedTurnID: "turn_synthetic"))
        await router.observe(observed)
        let control = try #require(await router.prepare(sessionID: observed.sessionID, form: .followup(field: "followup")))
        let receipt = FeishuMessageReceipt(messageID: "om_synthetic", chatID: "oc_synthetic", applicationID: "cli_synthetic", ownerID: "ou_owner", tenantID: "tenant_synthetic")
        #expect(await router.bind(controlID: control.id, receipt: receipt))
        var frame = FeishuWireFrame()
        frame.seqID = UInt64.max; frame.logID = 2; frame.service = 42; frame.method = 1
        frame.headers = [("type", "event"), ("message_id", "message_synthetic"), ("seq", "0"), ("sum", "1")].map { key, value in
            var header = FeishuWireHeader(); header.key = key; header.value = value; return header
        }
        frame.payload = try CardCallbackFixture.data(control: control.id)
        server.sendOnConnect([try frame.serializedData(), try frame.serializedData()])
        let actions = SocketActions()
        let running = Task { try await socket.run(router: router, onAction: { actions.append($0) }) }
        try await waitUntil { server.messages().count >= 2 && actions.snapshot().count == 1 }
        let emitted = try #require(actions.snapshot().first)
        #expect(emitted.connectionID == socket.connectionID)
        #expect(emitted.continuation.session == observed)
        #expect(emitted.continuation.receipt.status == .received)
        let ack = try FeishuWireFrame(serializedBytes: server.messages()[0])
        #expect(ack.seqID == UInt64.max)
        let response = try JSONSerialization.jsonObject(with: ack.payload) as! [String: Any]
        #expect(response["code"] as? Int == 200)
        socket.close()
        do { try await running.value; Issue.record("Closing must stop the receive loop") }
        catch { #expect(error as? FeishuSocketFailure == .closed) }
        #expect(await router.prepare(sessionID: observed.sessionID, form: .followup(field: "followup")) == nil)
    }

    // Refs: US-05, AC-05.09; US-10, AC-10.01.
    @Test func aRevokedCardIsAnsweredWithItsReasonAndReportedOnceWithoutAnAction() async throws {
        let server = try WebSocketTestServer()
        defer { server.stop() }
        let socket = FeishuSocket(endpoint: endpoint(try await server.start()), path: SyntheticFeishuPath())
        defer { socket.close() }
        let router = CardActionRouter(elapsed: { 0 }, wallTime: { CardCallbackFixture.date })
        var access = MobileAccess(owner: CardCallbackFixture.owner, connected: true, awayMode: true, inputEnabled: true)
        await router.setAccess(access, connectionID: socket.connectionID)
        let observed = ObservedSession(sessionID: UUID(), connectionID: UUID(), liveness: .alive, phase: .idle(completedTurnID: "turn_synthetic"))
        await router.observe(observed)
        let control = try #require(await router.prepare(sessionID: observed.sessionID, form: .followup(field: "followup")))
        let receipt = FeishuMessageReceipt(messageID: "om_synthetic", chatID: "oc_synthetic", applicationID: "cli_synthetic", ownerID: "ou_owner", tenantID: "tenant_synthetic")
        #expect(await router.bind(controlID: control.id, receipt: receipt))
        access.awayMode = false
        await router.setAccess(access, connectionID: socket.connectionID)
        var frames: [Data] = []
        for (index, event) in ["event_first_tap", "event_second_tap"].enumerated() {
            var frame = FeishuWireFrame()
            frame.seqID = UInt64(index + 1); frame.logID = 2; frame.service = 42; frame.method = 1
            frame.headers = [("type", "event"), ("message_id", "message_\(index)"), ("seq", "0"), ("sum", "1")].map { key, value in
                var header = FeishuWireHeader(); header.key = key; header.value = value; return header
            }
            frame.payload = try CardCallbackFixture.data(control: control.id, event: event)
            frames.append(try frame.serializedData())
        }
        server.sendOnConnect(frames)
        let actions = SocketActions(), refusals = SocketRefusals()
        let running = Task {
            try await socket.run(router: router, onAction: { actions.append($0) }, onRefusal: { refusals.append($0) })
        }
        try await waitUntil { server.messages().count >= 2 }
        #expect(actions.snapshot().isEmpty)
        #expect(refusals.snapshot().map { [$0.sessionID: $0.reason] } == [[observed.sessionID: .replyWindowClosed]])
        #expect(refusals.snapshot().first?.controlID != nil)
        let ack = try FeishuWireFrame(serializedBytes: server.messages()[0])
        let response = try #require(JSONSerialization.jsonObject(with: ack.payload) as? [String: Any])
        let encoded = try #require(response["data"] as? String)
        let data = try #require(Data(base64Encoded: encoded))
        let toast = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
        #expect(toast["toast"]?["content"] == ContinuationRefusal.replyWindowClosed.explanation)
        socket.close()
        _ = try? await running.value
    }

    @Test func taskCancellationClosesAnIdleReceiveWithoutLeavingBackgroundWork() async throws {
        let server = try WebSocketTestServer()
        defer { server.stop() }
        let socket = FeishuSocket(endpoint: endpoint(try await server.start(), ping: 1), path: SyntheticFeishuPath())
        defer { socket.close() }
        let router = CardActionRouter()
        let running = Task { try await socket.run(router: router, onAction: { _ in Issue.record("No event was sent") }) }
        // Observing the application ping proves the native handshake completed.
        try await waitUntil { !server.messages().isEmpty }
        let ping = try FeishuWireFrame(serializedBytes: server.messages()[0])
        #expect(ping.method == 0 && ping.headers.contains { $0.key == "type" && $0.value == "ping" })
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
    }

    @Test func malformedBinaryFramesCloseTheConnectionWithoutEmittingActions() async throws {
        let server = try WebSocketTestServer()
        defer { server.stop() }
        server.sendOnConnect([Data([0x80])])
        let socket = FeishuSocket(endpoint: endpoint(try await server.start()), path: SyntheticFeishuPath())
        defer { socket.close() }
        let router = CardActionRouter()
        await #expect(throws: FeishuSocketFailure.invalidProtocol) {
            try await socket.run(router: router, onAction: { _ in Issue.record("Invalid frames cannot authorize actions") })
        }
    }
    @Test func networkLossRejectsQueuedCallbacksAndInvalidatesOldControls() async throws {
        let server = try WebSocketTestServer()
        defer { server.stop() }
        let path = SyntheticFeishuPath()
        let socket = FeishuSocket(endpoint: endpoint(try await server.start(), ping: 1), path: path)
        defer { socket.close() }
        let router = CardActionRouter(elapsed: { 0 }, wallTime: { CardCallbackFixture.date })
        let access = MobileAccess(owner: CardCallbackFixture.owner, connected: true, awayMode: true, inputEnabled: true)
        await router.setAccess(access, connectionID: socket.connectionID)
        let observed = ObservedSession(sessionID: UUID(), connectionID: UUID(), liveness: .alive, phase: .idle(completedTurnID: "turn_synthetic"))
        await router.observe(observed)
        let control = try #require(await router.prepare(sessionID: observed.sessionID, form: .followup(field: "followup")))
        let receipt = FeishuMessageReceipt(messageID: "om_synthetic", chatID: "oc_synthetic", applicationID: "cli_synthetic", ownerID: "ou_owner", tenantID: "tenant_synthetic")
        #expect(await router.bind(controlID: control.id, receipt: receipt))
        var frame = FeishuWireFrame()
        frame.seqID = UInt64.max; frame.logID = 2; frame.service = 42; frame.method = 1
        frame.headers = [("type", "event"), ("message_id", "message_synthetic"), ("seq", "0"), ("sum", "1")].map { key, value in
            var header = FeishuWireHeader(); header.key = key; header.value = value; return header
        }
        frame.payload = try CardCallbackFixture.data(control: control.id)
        let actions = SocketActions()
        let running = Task { try await socket.run(router: router, onAction: { actions.append($0) }) }
        try await waitUntil { !server.messages().isEmpty }
        path.interrupt()
        server.broadcast(try frame.serializedData())
        await #expect(throws: FeishuSocketFailure.unavailable) { try await running.value }
        #expect(actions.snapshot().isEmpty)
        #expect(await router.prepare(sessionID: observed.sessionID, form: .followup(field: "followup")) == nil)
    }

    @Test func aShorterPongIntervalReschedulesTheNextNativePing() async throws {
        let server = try WebSocketTestServer()
        defer { server.stop() }
        var pong = FeishuWireFrame()
        pong.seqID = 0; pong.logID = 0; pong.service = 42; pong.method = 0
        var header = FeishuWireHeader(); header.key = "type"; header.value = "pong"
        pong.headers = [header]
        pong.payload = Data(#"{"PingInterval":1}"#.utf8)
        let bytes = try pong.serializedData()
        server.sendOnConnect([bytes])
        let socket = FeishuSocket(endpoint: endpoint(try await server.start(), ping: 4), path: SyntheticFeishuPath())
        defer { socket.close() }
        let running = Task { try await socket.run(router: CardActionRouter(), onAction: { _ in }) }
        defer { running.cancel() }
        try await waitUntil { !server.messages().isEmpty }
        server.broadcast(bytes)
        try await waitUntil { server.messages().count >= 2 }
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
    }
}
