// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.03, AC-20.04, AC-20.05, AC-20.06; US-12, AC-12.02; US-06, AC-06.01, AC-06.02, AC-06.05.
// Refs: US-36, AC-36.02, AC-36.03, AC-36.04.
import Foundation
import Testing
import LunletCore
@testable import LunletMessaging

private final class SlackHTTPState: @unchecked Sendable {
    struct Request { let path: String; let bearer: String?; let body: Data }
    private let lock = NSLock()
    private var replies: [Data] = []
    private var captured: [Request] = []
    func reset(_ replies: [Data]) { lock.withLock { self.replies = replies; captured = [] } }
    func receive(_ request: URLRequest) -> Data? {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        return lock.withLock {
            captured.append(.init(path: request.url!.path, bearer: request.value(forHTTPHeaderField: "Authorization"), body: body))
            return replies.isEmpty ? nil : replies.removeFirst()
        }
    }
    func requests() -> [Request] { lock.withLock { captured } }
}

private final class SlackHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = SlackHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let data = Self.state.receive(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ReceivedSlackReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [BotReply] = []
    func append(_ reply: BotReply) { lock.withLock { replies.append(reply) } }
    var values: [BotReply] { lock.withLock { replies } }
}

private actor SlackSocketFixture: ChannelSocket {
    private var frames: [Data]
    private var pending: CheckedContinuation<Data, any Error>?
    private var sent: [Data] = []
    private(set) var closed = false
    private(set) var receiveCount = 0
    init(_ frames: [Data]) { self.frames = frames }
    func receive() async throws -> Data {
        receiveCount += 1
        if closed { throw BotChannelFailure.canceled }
        if !frames.isEmpty { return frames.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func send(_ data: Data) async throws {
        guard !closed else { throw BotChannelFailure.canceled }
        sent.append(data)
    }
    func close() async {
        closed = true
        pending?.resume(throwing: BotChannelFailure.canceled); pending = nil
    }
    func acknowledgments() -> [String] {
        sent.compactMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: String])?["envelope_id"] }
    }
    func acknowledgmentPayloads() -> [[String: String]] {
        sent.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
    }
}

@Suite(.serialized) struct SlackBotClientTests {
    private let auth = Data(#"{"ok":true,"team_id":"TTEST","bot_id":"BTEST","user_id":"UTESTBOT","user":"Lunlet"}"#.utf8)
    private let bot = Data(#"{"ok":true,"bot":{"id":"BTEST","user_id":"UTESTBOT","name":"Lunlet","app_id":"ATEST","deleted":false}}"#.utf8)
    private let connection = Data(#"{"ok":true,"url":"wss://wss.slack.com/link/?ticket=synthetic"}"#.utf8)
    private let hello = Data(#"{"type":"hello","connection_info":{"app_id":"ATEST"}}"#.utf8)
    private let receipt = Data(#"{"ok":true,"channel":"DTEST","ts":"1001.000001","message":{"ts":"1001.000001","bot_id":"BTEST","user":"UTESTBOT","team":"TTEST","app_id":"ATEST"}}"#.utf8)

    private var binding: BotBinding {
        .init(channel: .slack, botID: "BTEST", botName: "Lunlet", ownerID: "UOWNER", chatID: "DTEST",
              workspaceID: "TTEST", applicationID: "ATEST")
    }
    private var snapshot: SessionSnapshot {
        .init(observation: .init(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                 connectionID: UUID(), liveness: .alive, phase: .idle(completedTurnID: "turn-test")),
              project: "Synthetic", title: "Completion", publicConclusion: "Updated <@UOTHER> safely.", outcome: .succeeded,
              turnID: "turn-test")
    }
    private func event(_ envelope: String = "good", eventChanges: [String: Any] = [:],
                       payloadChanges: [String: Any] = [:], frameType: String = "events_api") throws -> Data {
        var event: [String: Any] = ["type": "message", "channel_type": "im", "channel": "DTEST", "user": "UOWNER",
                                    "text": "lunlet PAIRCODE", "ts": "1000.100000", "event_ts": "1000.100000"]
        event.merge(eventChanges) { _, new in new }
        var payload: [String: Any] = ["type": "event_callback", "team_id": "TTEST", "api_app_id": "ATEST", "event": event]
        payload.merge(payloadChanges) { _, new in new }
        return try JSONSerialization.data(withJSONObject: ["type": frameType, "envelope_id": envelope, "payload": payload])
    }
    private func client(_ replies: [Data], socket: SlackSocketFixture = .init([]),
                        now: Date = Date(timeIntervalSince1970: 1001)) -> SlackBotClient {
        SlackHTTPProtocol.state.reset(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlackHTTPProtocol.self]
        return SlackBotClient(credentials: .init(channel: .slack, botToken: "xoxb-synthetic", appToken: "xapp-synthetic"),
                              http: ChannelHTTPClient(allowedHosts: ["slack.com"], configuration: configuration),
                              socketFactory: { _ in socket }, now: { now })
    }
    private func waitForReceive(_ socket: SlackSocketFixture, count: Int = 2) async throws {
        for _ in 0..<1000 {
            if await socket.receiveCount >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Synthetic socket did not start receiving")
    }

    // AC-20.04, AC-20.06: a user token or unrelated bots.info result must never prepare a bot identity.
    @Test func preparesBotTeamAndApplicationWithoutSending() async throws {
        let service = client([auth, bot])
        let identity = try await service.prepare()
        #expect(identity == BotIdentity(channel: .slack, id: "BTEST", name: "Lunlet", workspaceID: "TTEST", applicationID: "ATEST"))
        let requests = SlackHTTPProtocol.state.requests()
        #expect(requests.map(\.path) == ["/api/auth.test", "/api/bots.info"])
        #expect(requests.allSatisfy { $0.bearer == "Bearer xoxb-synthetic" })
        // bots.info goes as a form, which every Slack method accepts; the bot ID is its only field.
        #expect(String(decoding: requests[1].body, as: UTF8.self) == "bot=BTEST")
        await service.close()
    }

    @Test(arguments: [
        #"{"ok":true,"bot":{"id":"BOTHER","user_id":"UTESTBOT","name":"Lunlet","app_id":"ATEST"}}"#,
        #"{"ok":true,"bot":{"id":"BTEST","user_id":"UOTHER","name":"Lunlet","app_id":"ATEST"}}"#,
        #"{"ok":true,"bot":{"id":"BTEST","user_id":"UTESTBOT","name":"Lunlet","app_id":"ATEST","deleted":true}}"#,
        #"{"ok":true,"bot":{"id":"BTEST","user_id":"UTESTBOT","name":"Lunlet"}}"#,
    ]) func rejectsUnverifiedBotMetadata(_ body: String) async throws {
        let service = client([auth, Data(body.utf8)])
        await #expect(throws: BotChannelFailure.invalidResponse) { try await service.prepare() }
        await service.close()
    }

    // AC-20.03, AC-20.04: only the private fresh ordinary message may establish owner and destination.
    @Test func pairsPrivateOwnerAndAcknowledgesIrrelevantEnvelopesWithoutDispatch() async throws {
        let socket = SlackSocketFixture([hello, try event("interactive", frameType: "interactive"),
                                          try event("group", eventChanges: ["channel_type": "mpim", "channel": "GTEST"]),
                                          try event("stale", eventChanges: ["ts": "999.9"]),
                                          try event("other-code", eventChanges: ["text": "lunlet OLDCODE"]),
                                          try event()])
        let service = client([auth, bot, connection], socket: socket)
        let result = try await service.pair(.init(code: "PAIRCODE", now: Date(timeIntervalSince1970: 1000)))
        #expect(result == binding)
        #expect(await socket.acknowledgments() == ["interactive", "group", "stale", "other-code", "good"])
        #expect(await socket.acknowledgmentPayloads().allSatisfy { $0.count == 1 })
        #expect(await socket.closed)
        #expect(SlackHTTPProtocol.state.requests().last?.bearer == "Bearer xapp-synthetic")
        await service.close()
    }

    @Test(arguments: ["workspace", "application", "bot", "edited", "forwarded", "future", "channel", "subtype"])
    func ignoresMessagesOutsideThePrivateFreshOwnerBoundary(_ variant: String) async throws {
        var changes: [String: Any] = [:]
        var payload: [String: Any] = [:]
        switch variant {
        case "workspace": payload["team_id"] = "TOTHER"
        case "application": payload["api_app_id"] = "AOTHER"
        case "bot": changes["bot_id"] = "BOTHER"
        case "edited": changes["edited"] = ["ts": "1000.2"]
        case "forwarded": changes["subtype"] = "message_replied"
        case "future": changes["ts"] = "1002.0"
        case "channel": changes["channel"] = "CTEST"
        default: changes["subtype"] = "bot_message"
        }
        let socket = SlackSocketFixture([hello, try event("rejected", eventChanges: changes, payloadChanges: payload), try event()])
        let service = client([auth, bot, connection], socket: socket)
        let result = try await service.pair(.init(code: "PAIRCODE", now: Date(timeIntervalSince1970: 1000)))
        #expect(result == binding)
        #expect(await socket.acknowledgments() == ["rejected", "good"])
        await service.close()
    }

    @Test func mismatchedSocketApplicationCannotPairOrReceiveAcknowledgments() async throws {
        let wrongHello = Data(#"{"type":"hello","connection_info":{"app_id":"AOTHER"}}"#.utf8)
        let socket = SlackSocketFixture([wrongHello, try event()])
        let service = client([auth, bot, connection], socket: socket)
        await #expect(throws: BotChannelFailure.identityMismatch) {
            try await service.pair(.init(code: "PAIRCODE", now: Date(timeIntervalSince1970: 1000)))
        }
        #expect(await socket.closed)
        #expect(await socket.acknowledgments().isEmpty)
        await service.close()
    }

    @Test func untrustedSocketURLNeverReachesTheSocketFactory() async throws {
        let socket = SlackSocketFixture([hello, try event()])
        let untrusted = Data(#"{"ok":true,"url":"wss://wss.slack.com.attacker.invalid/?ticket=synthetic"}"#.utf8)
        let service = client([auth, bot, untrusted], socket: socket)
        await #expect(throws: BotChannelFailure.invalidResponse) {
            try await service.pair(.init(code: "PAIRCODE", now: Date(timeIntervalSince1970: 1000)))
        }
        #expect(await socket.receiveCount == 0)
        await service.close()
    }

    @Test func oversizedSocketFrameCannotEstablishPairing() async throws {
        let socket = SlackSocketFixture([hello, Data(repeating: 32, count: 1_048_577), try event()])
        let service = client([auth, bot, connection], socket: socket)
        await #expect(throws: BotChannelFailure.invalidResponse) {
            try await service.pair(.init(code: "PAIRCODE", now: Date(timeIntervalSince1970: 1000)))
        }
        #expect(await socket.closed)
        await service.close()
    }

    // AC-20.05; AC-12.02: all exits must close the receive, including an idle provider.
    @Test func idlePairingExpiresAndClosesItsSocket() async throws {
        let socket = SlackSocketFixture([hello])
        let service = client([auth, bot, connection], socket: socket, now: Date(timeIntervalSince1970: 1599.99))
        await #expect(throws: BotChannelFailure.expired) {
            try await service.pair(.init(code: "PAIRCODE", now: Date(timeIntervalSince1970: 1000)))
        }
        #expect(await socket.closed)
        await service.close()
    }

    @Test func canceledPairingClosesAnIdleReceive() async throws {
        let socket = SlackSocketFixture([hello])
        let service = client([auth, bot, connection], socket: socket)
        let task = Task { try await service.pair(.init(code: "PAIRCODE", now: Date(timeIntervalSince1970: 1000))) }
        try await waitForReceive(socket)
        task.cancel()
        await #expect(throws: BotChannelFailure.canceled) { try await task.value }
        #expect(await socket.closed)
        await service.close()
    }

    @Test func closingClientInvalidatesAndJoinsIdlePairing() async throws {
        let socket = SlackSocketFixture([hello])
        let service = client([auth, bot, connection], socket: socket)
        let task = Task { try await service.pair(.init(code: "PAIRCODE", now: Date(timeIntervalSince1970: 1000))) }
        try await waitForReceive(socket)
        await service.close()
        await #expect(throws: BotChannelFailure.canceled) { try await task.value }
        await #expect(throws: BotChannelFailure.canceled) { try await service.prepare() }
        #expect(await socket.closed)
    }

    @Test func expiredChallengeDoesNotOpenNetwork() async throws {
        let service = client([])
        await #expect(throws: BotChannelFailure.expired) {
            try await service.pair(.init(code: "PAIRCODE", now: Date(timeIntervalSince1970: 0)))
        }
        #expect(SlackHTTPProtocol.state.requests().isEmpty)
        await service.close()
    }

    @Test func refreshRequestedReconnectsWithinTheSamePairingChallenge() async throws {
        let socket = SlackSocketFixture([hello, Data(#"{"type":"disconnect","reason":"refresh_requested"}"#.utf8)])
        let second = SlackSocketFixture([hello, try event()])
        let source = SlackSocketSequence([socket, second])
        SlackHTTPProtocol.state.reset([auth, bot, connection, connection])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlackHTTPProtocol.self]
        let service = SlackBotClient(credentials: .init(channel: .slack, botToken: "xoxb-synthetic", appToken: "xapp-synthetic"),
                                      http: ChannelHTTPClient(allowedHosts: ["slack.com"], configuration: configuration),
                                      socketFactory: { _ in try await source.next() },
                                      now: { Date(timeIntervalSince1970: 1001) })
        #expect(try await service.pair(.init(code: "PAIRCODE", now: Date(timeIntervalSince1970: 1000))) == binding)
        #expect(await socket.closed)
        #expect(await second.closed)
        await service.close()
    }

    // AC-20.06: authorization may refresh identity, but never deliver or retarget a private recipient.
    @Test func authorizationCheckRejectsChangedIdentityWithoutSending() async throws {
        let other = Data(#"{"ok":true,"team_id":"TOTHER","bot_id":"BTEST","user_id":"UTESTBOT","user":"Lunlet"}"#.utf8)
        let service = client([auth, bot, other, bot])
        _ = try await service.prepare()
        await #expect(throws: BotChannelFailure.identityMismatch) { try await service.checkAuthorization(binding) }
        #expect(!SlackHTTPProtocol.state.requests().contains { $0.path == "/api/chat.postMessage" })
        await service.close()
    }

    // Refs: US-06, AC-06.01, AC-06.02, AC-06.05: the notice reaches only the saved chat, without controls or mentions.
    @Test func sendsTheBoundedNoticeWithoutControlsToTheSavedPrivateChat() async throws {
        let service = client([auth, bot, receipt])
        let sent = try await service.sendCompletion(snapshot, binding: binding)
        #expect(sent.chatID == "DTEST" && sent.messageID == "1001.000001")
        let request = try #require(SlackHTTPProtocol.state.requests().last)
        #expect(request.path == "/api/chat.postMessage")
        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["channel"] as? String == "DTEST")
        #expect(body["mrkdwn"] as? Bool == false)
        #expect(body["unfurl_links"] as? Bool == false && body["unfurl_media"] as? Bool == false)
        #expect(body["parse"] as? String == "none")
        #expect((body["text"] as? String)?.contains("Codex succeeded · Synthetic") == true)
        let blocks = try #require(body["blocks"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["header", "context", "section"])
        #expect(!blocks.contains { ["actions", "input"].contains($0["type"] as? String) || $0["accessory"] != nil })
        let text = String(decoding: request.body, as: UTF8.self)
        #expect(text.contains("&lt;@UOTHER&gt;") && !text.contains("<@UOTHER>"))
        #expect(request.body.count < 16_384)
        await service.close()
    }

    @Test func documentedBotReceiptDoesNotRequireUndocumentedOptionalUserOrTeamFields() async throws {
        let minimal = Data(#"{"ok":true,"channel":"DTEST","ts":"1001.000001","message":{"ts":"1001.000001","bot_id":"BTEST"}}"#.utf8)
        let service = client([auth, bot, minimal])
        let sent = try await service.sendCompletion(snapshot, binding: binding)
        #expect(sent.chatID == "DTEST" && sent.messageID == "1001.000001")
        await service.close()
    }

    @Test(arguments: [
        #"{"ok":true,"channel":"DOTHER","ts":"1001.000001","message":{"ts":"1001.000001","bot_id":"BTEST","user":"UTESTBOT","team":"TTEST"}}"#,
        #"{"ok":true,"channel":"DTEST","ts":"1001.000001","message":{"ts":"1001.000001","bot_id":"BOTHER","user":"UTESTBOT","team":"TTEST"}}"#,
        #"{"ok":true,"channel":"DTEST","ts":"1001.000001","message":{"ts":"1001.000001","bot_id":"BTEST","user":"UOTHER","team":"TTEST"}}"#,
        #"{"ok":true,"channel":"DTEST","ts":"1001.000001","message":{"ts":"1001.000002","bot_id":"BTEST","user":"UTESTBOT","team":"TTEST"}}"#,
        #"{"ok":true,"channel":"DTEST","ts":"1001.000001","message":{"ts":"1001.000001","bot_id":"BTEST","user":"UTESTBOT","team":"TOTHER"}}"#,
    ]) func uncertainOrRetargetedReceiptsAreNeverRetried(_ response: String) async throws {
        let service = client([auth, bot, Data(response.utf8), receipt])
        await #expect(throws: BotChannelFailure.deliveryUncertain) { try await service.sendCompletion(snapshot, binding: binding) }
        #expect(SlackHTTPProtocol.state.requests().filter { $0.path == "/api/chat.postMessage" }.count == 1)
        await service.close()
    }

    @Test func providerErrorsDoNotExposeResponseTextOrCredentialMaterial() async throws {
        let error = Data(#"{"ok":false,"error":"invalid_auth","detail":"xoxb-synthetic private response"}"#.utf8)
        let service = client([error])
        await #expect(throws: BotChannelFailure.unauthorized) { try await service.prepare() }
        #expect(SlackHTTPProtocol.state.requests().count == 1)
        await service.close()
    }

    // Only the paired owner's message in a notice's thread is handed over; every envelope is acknowledged and
    // nothing else leaves the socket.
    @Test func receivesTheOwnersThreadRepliesAndAcknowledgesEverything() async throws {
        let socket = SlackSocketFixture([hello,
            try event("r1", eventChanges: ["text": "Run the tests", "ts": "1000.200000", "thread_ts": "1000.100000"]),
            try event("r2", eventChanges: ["text": "not in a thread", "ts": "1000.300000"]),
            try event("r3", eventChanges: ["user": "UOTHER", "text": "stranger", "ts": "1000.400000", "thread_ts": "1000.100000"]),
            try event("r4", eventChanges: ["text": "edited", "ts": "1000.500000", "thread_ts": "1000.100000", "edited": ["ts": "1"]]),
        ])
        let client = client([auth, bot, connection], socket: socket)
        let received = ReceivedSlackReplies()
        let task = Task { try await client.receiveReplies(binding: binding) { if case .reply(let reply) = $0 { received.append(reply) } } }
        try await waitForReceive(socket, count: 6)
        #expect(received.values == [BotReply(messageID: "1000.200000", repliedTo: "1000.100000", text: "Run the tests",
                                              sentAt: Date(timeIntervalSince1970: 1000.2))])
        #expect(await socket.acknowledgments() == ["r1", "r2", "r3", "r4"])
        task.cancel()
        _ = await task.result
        #expect(await socket.closed)
    }

    // A notice is rewritten through chat.update on the bot's own message in the saved direct message.
    @Test func updatesTheNoticeInPlaceThroughChatUpdate() async throws {
        let client = client([auth, bot, Data(#"{"ok":true,"channel":"DTEST","ts":"1001.000001"}"#.utf8)])
        try await client.updateCompletion(snapshot, binding: binding, messageID: "1001.000001", reply: .finished(.delivered, "Go"))
        let request = try #require(SlackHTTPProtocol.state.requests().last)
        let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        #expect(request.path == "/api/chat.update" && body?["ts"] as? String == "1001.000001" && body?["channel"] as? String == "DTEST")
        #expect(String(decoding: request.body, as: UTF8.self).contains("*Delivered* · Codex is continuing on your Mac"))
    }
}

private actor SlackSocketSequence {
    private var sockets: [SlackSocketFixture]
    init(_ sockets: [SlackSocketFixture]) { self.sockets = sockets }
    func next() throws -> any ChannelSocket {
        guard !sockets.isEmpty else { throw BotChannelFailure.unavailable }
        return sockets.removeFirst()
    }
}
