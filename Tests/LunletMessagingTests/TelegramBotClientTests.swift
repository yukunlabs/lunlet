// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.03, AC-20.04, AC-20.05, AC-20.06; US-12, AC-12.02; US-06, AC-06.01, AC-06.02, AC-06.05.
// Refs: US-36, AC-36.02, AC-36.03, AC-36.04.
// Synthetic provider-boundary fixtures; no credentials, external requests or Codex input.
import Foundation
import Testing
import LunletCore
@testable import LunletMessaging

private final class TelegramHTTPState: @unchecked Sendable {
    enum Reply { case json(String), lost, held }
    struct Request: Sendable { let method: String; let body: Data }
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var captured: [Request] = []
    private var stopCount = 0
    func reset(_ values: [Reply]) { lock.withLock { replies = values; captured = []; stopCount = 0 } }
    func receive(_ request: URLRequest) -> Reply {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return lock.withLock {
            captured.append(Request(method: request.url!.lastPathComponent, body: data))
            return replies.isEmpty ? .lost : replies.removeFirst()
        }
    }
    func stopped(_ request: URLRequest) {
        guard request.url?.lastPathComponent == "getUpdates" else { return }
        lock.withLock { stopCount += 1 }
    }
    func stops() -> Int { lock.withLock { stopCount } }
    func requests() -> [Request] { lock.withLock { captured } }
}

private final class TelegramHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = TelegramHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch Self.state.receive(request) {
        case .json(let text):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .lost: client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .held: break
        }
    }
    override func stopLoading() { Self.state.stopped(request) }
}

private final class ReceivedReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BotReplyEvent] = []
    func append(_ event: BotReplyEvent) { lock.withLock { events.append(event) } }
    var values: [BotReplyEvent] { lock.withLock { events } }
}

private final class TelegramPairingOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: BotChannelFailure?
    func record(_ value: BotChannelFailure) { lock.withLock { failure = value } }
    func result() -> BotChannelFailure? { lock.withLock { failure } }
}

@Suite(.serialized) struct TelegramBotClientTests {
    private func expectStoppedPolling() async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while TelegramHTTPProtocol.state.stops() == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(TelegramHTTPProtocol.state.stops() > 0)
    }
    private let bot = #"{"ok":true,"result":{"id":9001,"is_bot":true,"first_name":"Synthetic","username":"SyntheticLunletBot"}}"#
    private let webhook = #"{"ok":true,"result":{"url":"","has_custom_certificate":false,"pending_update_count":0}}"#
    private let challenge = PairingChallenge(code: "synthetic_fresh_pairing_code", now: Date(timeIntervalSince1970: 1_000))
    private let binding = BotBinding(channel: .telegram, botID: "9001", botName: "SyntheticLunletBot", ownerID: "42", chatID: "42")

    private func client(_ replies: [TelegramHTTPState.Reply], time: TimeInterval = 1_001,
                        channel: BotChannel = .telegram, token: String = "9001:synthetic-token") -> TelegramBotClient {
        TelegramHTTPProtocol.state.reset(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelegramHTTPProtocol.self]
        return TelegramBotClient(credentials: BotCredentials(channel: channel, botToken: token),
                                 http: ChannelHTTPClient(allowedHosts: ["api.telegram.org"], configuration: configuration),
                                 now: { Date(timeIntervalSince1970: time) })
    }
    private func update(_ id: Int = 8, text: String = "/start synthetic_fresh_pairing_code",
                        user: Int = 42, chat: Int = 42, type: String = "private", date: Int = 1_001,
                        extras: [String: Any] = [:], key: String = "message") -> [String: Any] {
        var message: [String: Any] = ["message_id": 11, "date": date,
            "from": ["id": user, "is_bot": false, "first_name": "Synthetic Owner"],
            "chat": ["id": chat, "type": type, "first_name": "Synthetic Owner"], "text": text]
        message.merge(extras) { _, new in new }
        return ["update_id": id, key: message]
    }
    private func updates(_ values: [[String: Any]]) -> TelegramHTTPState.Reply {
        .json(String(decoding: try! JSONSerialization.data(withJSONObject: ["ok": true, "result": values]), as: UTF8.self))
    }
    private func receipt(chat: Int = 42, botID: Int = 9001, type: String = "private", messageID: Int = 21) -> TelegramHTTPState.Reply {
        .json("{\"ok\":true,\"result\":{\"message_id\":\(messageID),\"date\":1001,\"from\":{\"id\":\(botID),\"is_bot\":true,\"first_name\":\"Synthetic\"},\"chat\":{\"id\":\(chat),\"type\":\"\(type)\",\"first_name\":\"Synthetic Owner\"},\"text\":\"Synthetic completion\"}}")
    }
    private func snapshot() -> SessionSnapshot {
        SessionSnapshot(observation: ObservedSession(sessionID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            connectionID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!, liveness: .alive,
            phase: .idle(completedTurnID: "synthetic-turn")), project: "Project", title: "Synthetic task",
            publicConclusion: "Completed the synthetic task.", outcome: .succeeded, turnID: "synthetic-turn")
    }
    private func waitForRequests(_ count: Int) async throws {
        for _ in 0..<1_000 {
            if TelegramHTTPProtocol.state.requests().count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("The expected synthetic Telegram request was not made")
    }

    @Test func preparationChecksBotIdentityWithoutSending() async throws {
        let service = client([.json(bot)])
        let result = try await service.prepare()
        #expect(result == BotIdentity(channel: .telegram, id: "9001", name: "SyntheticLunletBot"))
        #expect(TelegramHTTPProtocol.state.requests().map(\.method) == ["getMe"])
        await service.close()
    }

    @Test(arguments: ["", "token/extra", "9001:token?query", "9001:token\n"])
    func rejectsUnsafeCredentialsWithoutNetwork(_ token: String) async {
        let service = client([], token: token)
        await #expect(throws: BotChannelFailure.invalidCredentials) { try await service.prepare() }
        #expect(TelegramHTTPProtocol.state.requests().isEmpty)
        await service.close()
    }

    @Test func rejectsNonBotAndWrongProviderCredentials() async {
        let nonbot = bot.replacingOccurrences(of: "\"is_bot\":true", with: "\"is_bot\":false")
        let service = client([.json(nonbot)])
        await #expect(throws: BotChannelFailure.invalidResponse) { try await service.prepare() }
        await service.close()
        let wrong = client([], channel: .slack)
        await #expect(throws: BotChannelFailure.invalidCredentials) { try await wrong.prepare() }
        #expect(TelegramHTTPProtocol.state.requests().isEmpty)
        await wrong.close()
    }

    @Test func preservesExistingWebhookAndRefusesPolling() async throws {
        let existing = #"{"ok":true,"result":{"url":"https://synthetic.invalid/webhook","has_custom_certificate":false,"pending_update_count":2}}"#
        let service = client([.json(bot), .json(existing)])
        _ = try await service.prepare()
        await #expect(throws: BotChannelFailure.webhookInUse) { try await service.pair(challenge) }
        #expect(TelegramHTTPProtocol.state.requests().map(\.method) == ["getMe", "getWebhookInfo"])
        await service.close()
    }

    @Test func pairsOnlyFreshPrivateDirectCodeAndAdvancesPastRejectedUpdates() async throws {
        let rejected = [update(8, type: "group"), update(9, date: 999), update(10, user: 43),
                        update(11, extras: ["forward_origin": ["type": "hidden_user", "date": 1_001, "sender_user_name": "Synthetic"]]),
                        update(12, key: "edited_message"), update(13, text: "unrelated"),
                        update(14, extras: ["business_connection_id": "synthetic-business"])]
        let service = client([.json(bot), .json(webhook), updates(rejected), updates([update(15)])])
        _ = try await service.prepare()
        #expect(try await service.pair(challenge) == binding)
        let requests = TelegramHTTPProtocol.state.requests()
        #expect(requests.map(\.method) == ["getMe", "getWebhookInfo", "getUpdates", "getUpdates"])
        let body = try #require(try JSONSerialization.jsonObject(with: requests[3].body) as? [String: Any])
        #expect(body["offset"] as? Int == 15)
        #expect(body["timeout"] as? Int ?? 0 > 0)
        #expect(body["allowed_updates"] == nil)
        await service.close()
    }

    @Test func acceptsExactCodeTextButNotAnExpiredChallenge() async throws {
        let service = client([.json(bot), .json(webhook), updates([update(text: "synthetic_fresh_pairing_code")])])
        _ = try await service.prepare()
        #expect(try await service.pair(challenge) == binding)
        await service.close()
        let expired = client([], time: 1_600)
        await #expect(throws: BotChannelFailure.expired) { try await expired.pair(challenge) }
        #expect(TelegramHTTPProtocol.state.requests().isEmpty)
        await expired.close()
    }

    @Test func authorizationRequiresSavedIdentityAndNeverSends() async throws {
        let service = client([.json(bot)])
        try await service.checkAuthorization(binding)
        #expect(TelegramHTTPProtocol.state.requests().map(\.method) == ["getMe"])
        await service.close()
        let changed = client([.json(bot.replacingOccurrences(of: "9001", with: "9002"))])
        await #expect(throws: BotChannelFailure.identityMismatch) { try await changed.checkAuthorization(binding) }
        await changed.close()
    }

    // Refs: US-06, AC-06.01, AC-06.02, AC-06.05: one escaped HTML message to the exact saved private chat.
    @Test func sendsTheBoundedNoticeToExactSavedPrivateChat() async throws {
        let service = client([.json(bot), receipt()])
        let result = try await service.sendCompletion(snapshot(), binding: binding)
        #expect(result == BotMessageReceipt(messageID: "21", chatID: "42"))
        let requests = TelegramHTTPProtocol.state.requests()
        #expect(requests.map(\.method) == ["getMe", "sendMessage"])
        let body = try #require(try JSONSerialization.jsonObject(with: requests[1].body) as? [String: Any])
        #expect(String(describing: body["chat_id"]!) == "42")
        #expect(body["parse_mode"] as? String == "HTML" && body["reply_markup"] == nil)
        let text = try #require(body["text"] as? String)
        #expect(text.hasPrefix("<b>Codex succeeded</b> · Project\n<i>Synthetic task</i>"))
        #expect(text.hasSuffix("\n\nCompleted the synthetic task.") && !text.contains("Approvals stay"))
        #expect(text.utf16.count <= 4_096)
        await service.close()
    }

    @Test(arguments: ["recipient", "bot", "group", "message"])
    func mismatchedReceiptsAreUncertainAndNeverRetried(_ mismatch: String) async throws {
        let reply = receipt(chat: mismatch == "recipient" ? 43 : 42, botID: mismatch == "bot" ? 9002 : 9001,
                            type: mismatch == "group" ? "group" : "private", messageID: mismatch == "message" ? 0 : 21)
        let service = client([.json(bot), reply])
        await #expect(throws: BotChannelFailure.deliveryUncertain) { try await service.sendCompletion(snapshot(), binding: binding) }
        #expect(TelegramHTTPProtocol.state.requests().map(\.method) == ["getMe", "sendMessage"])
        await service.close()
    }

    @Test func uncertainNetworkSendIsNotRetried() async {
        let service = client([.json(bot), .lost])
        await #expect(throws: BotChannelFailure.deliveryUncertain) { try await service.sendCompletion(snapshot(), binding: binding) }
        #expect(TelegramHTTPProtocol.state.requests().map(\.method) == ["getMe", "sendMessage"])
        await service.close()
    }

    @Test func refusesRetargetedBindingBeforeSending() async {
        let service = client([])
        let retargeted = BotBinding(channel: .telegram, botID: "9001", botName: "SyntheticLunletBot", ownerID: "42", chatID: "43")
        await #expect(throws: BotChannelFailure.identityMismatch) { try await service.sendCompletion(snapshot(), binding: retargeted) }
        #expect(TelegramHTTPProtocol.state.requests().isEmpty)
        await service.close()
    }

    @Test(arguments: [401, 403, 429])
    func providerFailuresStayTypedAndNeverExposeProviderText(_ code: Int) async {
        let service = client([.json("{\"ok\":false,\"error_code\":\(code),\"description\":\"synthetic private provider detail\"}")])
        let expected: BotChannelFailure = code == 401 ? .unauthorized : code == 403 ? .permissionDenied : .rateLimited
        await #expect(throws: expected) { try await service.prepare() }
        #expect(TelegramHTTPProtocol.state.requests().count == 1)
        await service.close()
    }

    @Test func oversizedUpdatePageFailsWithoutBinding() async throws {
        let service = client([.json(bot), .json(webhook), updates((1...101).map { update($0) })])
        _ = try await service.prepare()
        await #expect(throws: BotChannelFailure.invalidResponse) { try await service.pair(challenge) }
        await service.close()
    }

    @Test func staleReplayedUpdateCannotPairAfterOffsetAdvance() async throws {
        let service = client([.json(bot), .json(webhook), updates([update(8, text: "unrelated")]),
                              updates([update(8)]), .lost])
        _ = try await service.prepare()
        await #expect(throws: BotChannelFailure.invalidResponse) { try await service.pair(challenge) }
        #expect(TelegramHTTPProtocol.state.requests().count == 4)
        await service.close()
    }

    @Test func idlePairingExpiryCancelsHeldRequestWithoutBinding() async throws {
        let service = client([.json(bot), .json(webhook), .held], time: 1_599.8)
        _ = try await service.prepare()
        let outcome = TelegramPairingOutcome()
        let task = Task {
            do {
                _ = try await service.pair(challenge)
                Issue.record("An expired synthetic challenge unexpectedly bound an owner")
            } catch {
                outcome.record((error as? BotChannelFailure) ?? .invalidResponse)
            }
        }
        try await waitForRequests(3)
        for _ in 0..<1_000 {
            if outcome.result() != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(outcome.result() == .expired)
        try await expectStoppedPolling()
        await service.close()
        await task.value
        await service.close()
        #expect(TelegramHTTPProtocol.state.requests().map(\.method) == ["getMe", "getWebhookInfo", "getUpdates"])
    }

    @Test func closeCancelsHeldPairingAndPreventsLaterActivation() async throws {
        let service = client([.json(bot), .json(webhook), .held])
        _ = try await service.prepare()
        let task = Task { try await service.pair(challenge) }
        try await waitForRequests(3)
        await service.close()
        await #expect(throws: BotChannelFailure.canceled) { try await task.value }
        try await expectStoppedPolling()
        await #expect(throws: BotChannelFailure.canceled) { try await service.prepare() }
        #expect(TelegramHTTPProtocol.state.requests().count == 3)
    }

    @Test func taskCancellationCancelsHeldPolling() async throws {
        let service = client([.json(bot), .json(webhook), .held])
        _ = try await service.prepare()
        let task = Task { try await service.pair(challenge) }
        try await waitForRequests(3)
        task.cancel()
        await #expect(throws: BotChannelFailure.canceled) { try await task.value }
        try await expectStoppedPolling()
        await service.close()
    }

    // Only the paired owner's fresh reply to one of the bot's own messages is handed over; every other update is
    // consumed, the offset advances past all of them, and the poll asks for messages only.
    @Test func receivesOnlyTheOwnersRepliesToTheBotsMessages() async throws {
        let parent: [String: Any] = ["message_id": 21, "date": 1_000, "from": ["id": 9001, "is_bot": true, "first_name": "Synthetic"],
                                     "chat": ["id": 42, "type": "private", "first_name": "Synthetic Owner"], "text": "notice"]
        let humanParent: [String: Any] = ["message_id": 22, "date": 1_000, "from": ["id": 42, "is_bot": false, "first_name": "Synthetic Owner"],
                                          "chat": ["id": 42, "type": "private", "first_name": "Synthetic Owner"], "text": "mine"]
        let client = client([.json(bot), .json(webhook), updates([
            update(30, text: "Run the tests", extras: ["message_id": 31, "reply_to_message": parent]),
            update(31, text: "no reply target", extras: ["message_id": 32]),
            update(32, text: "stranger", user: 99, extras: ["message_id": 33, "reply_to_message": parent]),
            update(33, text: "to a human message", extras: ["message_id": 34, "reply_to_message": humanParent]),
            update(34, text: "forwarded", extras: ["message_id": 35, "reply_to_message": parent, "forward_date": 999]),
            update(35, text: "stale", date: 1, extras: ["message_id": 36, "reply_to_message": parent]),
            ["update_id": 36, "callback_query": ["id": "cb1", "data": "reply", "from": ["id": 42, "is_bot": false, "first_name": "Synthetic Owner"], "message": parent]],
            ["update_id": 37, "callback_query": ["id": "cb2", "data": "reply", "from": ["id": 99, "is_bot": false, "first_name": "Stranger"], "message": parent]],
            ["update_id": 38, "callback_query": ["id": "cb3", "data": "other", "from": ["id": 42, "is_bot": false, "first_name": "Synthetic Owner"], "message": parent]],
        ]), .held])
        let received = ReceivedReplies()
        let task = Task { try await client.receiveReplies(binding: binding) { received.append($0) } }
        try await waitForRequests(4)
        task.cancel()
        _ = await task.result
        #expect(received.values == [.reply(BotReply(messageID: "31", repliedTo: "21", text: "Run the tests", sentAt: Date(timeIntervalSince1970: 1_001))),
                                    .replyRequested(messageID: "21", callbackID: "cb1")])
        let polls = TelegramHTTPProtocol.state.requests().filter { $0.method == "getUpdates" }
        let second = try JSONSerialization.jsonObject(with: try #require(polls.last).body) as? [String: Any]
        #expect(polls.count == 2 && second?["offset"] as? Int == 39 && second?["allowed_updates"] as? [String] == ["message", "callback_query"])
        try await expectStoppedPolling()
    }

    // The reply button is answered by opening a reply box on a prompt, or by an alert when the notice is closed.
    @Test func answersTheReplyButtonWithAPromptOrAnAlert() async throws {
        let client = client([.json(bot), .json(#"{"ok":true,"result":true}"#), receipt(messageID: 30)])
        let prompt = try await client.promptReply(callbackID: "cb1", agent: "Codex", refusal: nil, binding: binding)
        #expect(prompt == "30")
        let requests = TelegramHTTPProtocol.state.requests()
        #expect(requests.map(\.method) == ["getMe", "answerCallbackQuery", "sendMessage"])
        let sent = try JSONSerialization.jsonObject(with: requests[2].body) as? [String: Any]
        #expect(sent?["text"] as? String == "Reply to this message to continue Codex.")
        #expect((sent?["reply_markup"] as? [String: Any])?["force_reply"] as? Bool == true)
        let refusing = self.client([.json(bot), .json(#"{"ok":true,"result":true}"#)])
        #expect(try await refusing.promptReply(callbackID: "cb2", agent: "Codex", refusal: "Not sent.", binding: binding) == nil)
        let answer = try JSONSerialization.jsonObject(with: try #require(TelegramHTTPProtocol.state.requests().last).body) as? [String: Any]
        #expect(answer?["text"] as? String == "Not sent." && answer?["show_alert"] as? Bool == true)
    }

    // A notice is edited in place in the saved private chat; an answer naming another message is uncertain.
    @Test func editsTheNoticeInPlaceForTheSavedChat() async throws {
        let client = client([.json(bot), receipt(messageID: 21)])
        try await client.updateCompletion(snapshot(), binding: binding, messageID: "21", reply: .finished(.delivered, "Go"))
        let edit = try #require(TelegramHTTPProtocol.state.requests().last)
        let body = try JSONSerialization.jsonObject(with: edit.body) as? [String: Any]
        #expect(edit.method == "editMessageText" && body?["message_id"] as? Int == 21 && body?["chat_id"] as? String == "42")
        #expect((body?["text"] as? String)?.contains("<b>Delivered</b> · Codex is continuing on your Mac") == true)
        let other = self.client([.json(bot), receipt(messageID: 22)])
        await #expect(throws: BotChannelFailure.deliveryUncertain) {
            try await other.updateCompletion(snapshot(), binding: binding, messageID: "21", reply: .open)
        }
    }
}
