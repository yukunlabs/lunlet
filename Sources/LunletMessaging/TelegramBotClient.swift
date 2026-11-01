// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.03, AC-20.04, AC-20.05, AC-20.06; US-12, AC-12.02, AC-12.04.
// Refs: US-06, AC-06.01, AC-06.02, AC-06.03, AC-06.05; US-10, AC-10.03, AC-10.04; US-33, AC-33.05.
// Refs: US-36, AC-36.01, AC-36.02, AC-36.03, AC-36.04.
import Foundation
import LunletCore

/// Telegram transport for the paired private chat: notices, in-place edits and, while a notice can take a reply,
/// long polling for the owner's replies to the bot's own messages. Polling never runs alongside pairing.
/// Protocol reference: https://core.telegram.org/bots/api (getMe/getWebhookInfo/getUpdates/sendMessage/editMessageText).
public actor TelegramBotClient: ChannelReplyClient {
    static let host = "api.telegram.org"
    private let credentials: BotCredentials
    private let http: ChannelHTTPClient
    private let now: @Sendable () -> Date
    private var identity: BotIdentity?
    private var closed = false
    private var pairing = false
    private var receiving = false
    private var lastUpdateID: Int64?
    private var usedChallenges = Set<String>()

    public init(credentials: BotCredentials) {
        self.init(credentials: credentials, http: ChannelHTTPClient(allowedHosts: [Self.host]))
    }
    init(credentials: BotCredentials, http: ChannelHTTPClient, now: @escaping @Sendable () -> Date = Date.init) {
        self.credentials = credentials; self.http = http; self.now = now
    }

    public func prepare() async throws -> BotIdentity {
        try ensureOpen()
        let user: User = try await call("getMe", body: [:])
        guard user.isBot, user.id > 0, let username = user.username,
              username.range(of: #"\A[A-Za-z0-9_]{1,64}\z"#, options: .regularExpression) != nil else {
            throw BotChannelFailure.invalidResponse
        }
        guard String(user.id) == credentials.botToken.split(separator: ":", maxSplits: 1).first.map(String.init) else {
            throw BotChannelFailure.identityMismatch
        }
        let value = BotIdentity(channel: .telegram, id: String(user.id), name: username)
        guard identity == nil || identity == value else { throw BotChannelFailure.identityMismatch }
        identity = value
        return value
    }

    public func pair(_ challenge: PairingChallenge) async throws -> BotBinding {
        try ensureOpen()
        guard challenge.isValid(at: now()) else { throw BotChannelFailure.expired }
        guard !pairing, !usedChallenges.contains(challenge.code),
              challenge.code.range(of: #"\A[A-Za-z0-9_-]{1,64}\z"#, options: .regularExpression) != nil else {
            throw BotChannelFailure.invalidResponse
        }
        pairing = true
        defer { pairing = false }
        let remaining = min(600, challenge.expiresAt.timeIntervalSince(now()))
        let deadline = ContinuousClock.now.advanced(by: .seconds(remaining))
        do {
            return try await withThrowingTaskGroup(of: BotBinding.self) { group in
                group.addTask { try await self.pollPairing(challenge, deadline: deadline) }
                group.addTask {
                    do { try await Task.sleep(for: .seconds(remaining)) }
                    catch { throw BotChannelFailure.canceled }
                    throw BotChannelFailure.expired
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw BotChannelFailure.canceled }
                return result
            }
        } catch {
            // The task group cancels and joins the losing child before this boundary.
            if closed || Task.isCancelled { throw BotChannelFailure.canceled }
            if error as? BotChannelFailure == .expired {
                closed = true; identity = nil
                await http.close()
                throw BotChannelFailure.expired
            }
            throw error
        }
    }

    private func pollPairing(_ challenge: PairingChallenge, deadline: ContinuousClock.Instant) async throws -> BotBinding {
        let bot: BotIdentity
        if let identity { bot = identity } else { bot = try await prepare() }
        let webhook: Webhook = try await call("getWebhookInfo", body: [:])
        guard webhook.url.isEmpty else { throw BotChannelFailure.webhookInUse }
        var observed = 0
        while true {
            try ensureOpen()
            guard challenge.isValid(at: now()), ContinuousClock.now < deadline else { throw BotChannelFailure.expired }
            let remaining = max(1, Int(ceil(challenge.expiresAt.timeIntervalSince(now()))))
            var body: [String: Any] = ["limit": 100, "timeout": min(30, remaining)]
            if let lastUpdateID { body["offset"] = lastUpdateID + 1 }
            // Omitting allowed_updates preserves the bot's existing global subscription setting.
            let updates: [Update] = try await call("getUpdates", body: body)
            guard updates.count <= 100 else { throw BotChannelFailure.invalidResponse }
            observed += updates.count
            guard observed <= 10_000 else { throw BotChannelFailure.unavailable }
            guard challenge.isValid(at: now()), ContinuousClock.now < deadline else { throw BotChannelFailure.expired }
            for update in updates {
                guard update.updateID >= 0, update.updateID < Int64.max,
                      lastUpdateID.map({ update.updateID > $0 }) ?? true else { throw BotChannelFailure.invalidResponse }
                lastUpdateID = update.updateID
                guard let message = update.message, validPairing(message, challenge: challenge) else { continue }
                try ensureOpen()
                usedChallenges.insert(challenge.code)
                return BotBinding(channel: .telegram, botID: bot.id, botName: bot.name,
                                  ownerID: String(message.from!.id), chatID: String(message.chat.id))
            }
            // Telegram normally holds an empty poll; restrain a provider returning immediately.
            if updates.isEmpty {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { throw BotChannelFailure.canceled }
            }
        }
    }

    public func checkAuthorization(_ binding: BotBinding) async throws {
        try validate(binding)
        let current = try await prepare()
        guard current.id == binding.botID, current.name == binding.botName else { throw BotChannelFailure.identityMismatch }
    }

    public func sendCompletion(_ snapshot: SessionSnapshot, binding: BotBinding, reply: NoticeReplyState?) async throws -> BotMessageReceipt {
        try validate(binding)
        let bot = try await identity(for: binding)
        let text = TelegramNoticeMessage.html(SessionNotice.prepare(snapshot), reply: reply)
        guard text.utf16.count <= TelegramNoticeMessage.limit else { throw BotChannelFailure.invalidResponse }
        var body: [String: Any] = ["chat_id": binding.chatID, "text": text, "parse_mode": "HTML", "link_preview_options": ["is_disabled": true]]
        if let markup = TelegramNoticeMessage.replyMarkup(reply) { body["reply_markup"] = markup }
        let sent: Message = try await call("sendMessage", body: body, mutation: true)
        try verifyOwn(sent, binding: binding, bot: bot)
        return BotMessageReceipt(messageID: String(sent.messageID), chatID: String(sent.chat.id))
    }

    /// Rewrites a sent notice with the reply's state; Telegram edits a bot's own message in place.
    public func updateCompletion(_ snapshot: SessionSnapshot, binding: BotBinding, messageID: String, reply: NoticeReplyState) async throws {
        try validate(binding)
        let bot = try await identity(for: binding)
        guard let id = Int64(messageID), id > 0, String(id) == messageID else { throw BotChannelFailure.invalidResponse }
        let text = TelegramNoticeMessage.html(SessionNotice.prepare(snapshot), reply: reply)
        guard text.utf16.count <= TelegramNoticeMessage.limit else { throw BotChannelFailure.invalidResponse }
        var body: [String: Any] = ["chat_id": binding.chatID, "message_id": id, "text": text, "parse_mode": "HTML",
                                   "link_preview_options": ["is_disabled": true]]
        if let markup = TelegramNoticeMessage.replyMarkup(reply) { body["reply_markup"] = markup }
        let edited: Message = try await call("editMessageText", body: body, mutation: true)
        guard edited.messageID == id else { throw BotChannelFailure.deliveryUncertain }
        try verifyOwn(edited, binding: binding, bot: bot)
    }

    public func sendText(_ text: String, binding: BotBinding) async throws {
        try validate(binding)
        let bot = try await identity(for: binding)
        guard !text.isEmpty, text.utf16.count <= TelegramNoticeMessage.limit else { throw BotChannelFailure.invalidResponse }
        let sent: Message = try await call("sendMessage", body: ["chat_id": binding.chatID, "text": text,
            "link_preview_options": ["is_disabled": true]], mutation: true)
        try verifyOwn(sent, binding: binding, bot: bot)
    }

    /// Answers a tap on the reply button: opens the owner's reply box with a prompt they answer, or shows the
    /// refusal as an alert. Only a callback from the paired owner reaches here.
    public func promptReply(callbackID: String, agent: String, refusal: String?, binding: BotBinding) async throws -> String? {
        try validate(binding)
        let bot = try await identity(for: binding)
        guard !callbackID.isEmpty, callbackID.utf8.count <= 128 else { throw BotChannelFailure.invalidResponse }
        var answer: [String: Any] = ["callback_query_id": callbackID]
        if let refusal { answer["text"] = refusal; answer["show_alert"] = true }
        let _: Bool = try await call("answerCallbackQuery", body: answer)
        guard refusal == nil else { return nil }
        let sent: Message = try await call("sendMessage", body: [
            "chat_id": binding.chatID, "text": NoticeReplyText.prompt(agent: agent),
            "reply_markup": ["force_reply": true, "selective": true, "input_field_placeholder": NoticeReplyText.placeholder(agent: agent)],
        ], mutation: true)
        try verifyOwn(sent, binding: binding, bot: bot)
        return String(sent.messageID)
    }

    /// Long-polls the bot's updates and hands over the paired owner's replies to the bot's own messages and taps
    /// on its reply buttons; every other update is consumed and ignored. It runs until cancelled or closed, and
    /// never alongside pairing.
    public func receiveReplies(binding: BotBinding, onEvent: @escaping @Sendable (BotReplyEvent) async -> Void) async throws {
        try validate(binding)
        guard !pairing, !receiving else { throw BotChannelFailure.unavailable }
        receiving = true
        defer { receiving = false }
        let bot = try await identity(for: binding)
        let webhook: Webhook = try await call("getWebhookInfo", body: [:])
        guard webhook.url.isEmpty else { throw BotChannelFailure.webhookInUse }
        while true {
            try ensureOpen()
            var body: [String: Any] = ["limit": 100, "timeout": 25, "allowed_updates": ["message", "callback_query"]]
            if let lastUpdateID { body["offset"] = lastUpdateID + 1 }
            let updates: [Update] = try await call("getUpdates", body: body)
            guard updates.count <= 100 else { throw BotChannelFailure.invalidResponse }
            for update in updates {
                guard update.updateID >= 0, update.updateID < Int64.max,
                      lastUpdateID.map({ update.updateID > $0 }) ?? true else { throw BotChannelFailure.invalidResponse }
                lastUpdateID = update.updateID
                let event: BotReplyEvent
                if let message = update.message, let reply = ownerReply(message, binding: binding, bot: bot) {
                    event = .reply(reply)
                } else if let tap = update.callbackQuery, let request = ownerRequest(tap, binding: binding, bot: bot) {
                    event = request
                } else { continue }
                try ensureOpen()
                await onEvent(event)
            }
            if updates.isEmpty {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { throw BotChannelFailure.canceled }
            }
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true; identity = nil
        await http.close()
    }

    private func ensureOpen() throws {
        guard !closed, !Task.isCancelled else { throw BotChannelFailure.canceled }
    }
    /// The bot's verified identity, which must be the one the binding was made with.
    private func identity(for binding: BotBinding) async throws -> BotIdentity {
        let bot: BotIdentity
        if let identity { bot = identity } else { bot = try await prepare() }
        guard bot.id == binding.botID, bot.name == binding.botName else { throw BotChannelFailure.identityMismatch }
        return bot
    }
    /// A message the bot itself sent or edited in the paired private chat.
    private func verifyOwn(_ message: Message, binding: BotBinding, bot: BotIdentity) throws {
        guard message.messageID > 0, message.chat.type == "private", String(message.chat.id) == binding.chatID,
              message.from?.isBot == true, message.from.map({ String($0.id) == bot.id }) == true,
              message.senderChat == nil, message.businessConnectionID == nil, message.guestQueryID == nil else {
            throw BotChannelFailure.deliveryUncertain
        }
    }
    /// The paired owner's tap on the reply button of one of the bot's own messages in the paired chat.
    private func ownerRequest(_ tap: CallbackQuery, binding: BotBinding, bot: BotIdentity) -> BotReplyEvent? {
        guard !tap.id.isEmpty, tap.id.utf8.count <= 128, tap.data == "reply", !tap.from.isBot,
              String(tap.from.id) == binding.ownerID, let message = tap.message, message.messageID > 0,
              message.chat.type == "private", String(message.chat.id) == binding.chatID,
              message.from?.isBot == true, message.from.map({ String($0.id) == bot.id }) == true else { return nil }
        return .replyRequested(messageID: String(message.messageID), callbackID: tap.id)
    }

    /// The paired owner's fresh, ordinary reply to one of the bot's own messages; anything else is nil.
    private func ownerReply(_ message: Message, binding: BotBinding, bot: BotIdentity) -> BotReply? {
        guard message.messageID > 0, message.chat.type == "private", String(message.chat.id) == binding.chatID,
              let sender = message.from, !sender.isBot, String(sender.id) == binding.ownerID,
              message.forwardOrigin == nil, message.forwardFrom == nil, message.forwardFromChat == nil,
              message.forwardSenderName == nil, message.forwardDate == nil, message.editDate == nil,
              message.senderChat == nil, message.businessConnectionID == nil, message.guestQueryID == nil,
              message.isAutomaticForward == nil, message.senderBusinessBot == nil,
              let parent = message.replyToMessage, parent.messageID > 0, parent.from?.isBot == true,
              parent.from.map({ String($0.id) == bot.id }) == true,
              let text = message.text, !text.isEmpty else { return nil }
        let current = now().timeIntervalSince1970, sent = TimeInterval(message.date)
        guard sent <= current + 60, sent >= current - ContinuationGate.controlLifetime - 60 else { return nil }
        return BotReply(messageID: String(message.messageID), repliedTo: String(parent.messageID), text: text,
                        sentAt: Date(timeIntervalSince1970: sent))
    }
    private func validate(_ binding: BotBinding) throws {
        try ensureOpen()
        guard binding.channel == .telegram, binding.workspaceID == nil, binding.applicationID == nil,
              let owner = Int64(binding.ownerID), owner > 0, String(owner) == binding.ownerID,
              binding.chatID == binding.ownerID, let botID = Int64(binding.botID), botID > 0,
              String(botID) == binding.botID, !binding.botName.isEmpty else { throw BotChannelFailure.identityMismatch }
    }
    private func validPairing(_ message: Message, challenge: PairingChallenge) -> Bool {
        guard message.messageID > 0, message.chat.type == "private", message.chat.id > 0,
              let sender = message.from, !sender.isBot, sender.id == message.chat.id,
              message.date >= Int64(floor(challenge.createdAt.timeIntervalSince1970)),
              message.date <= Int64(floor(now().timeIntervalSince1970)),
              message.date < Int64(ceil(challenge.expiresAt.timeIntervalSince1970)),
              message.forwardOrigin == nil, message.forwardFrom == nil, message.forwardFromChat == nil,
              message.forwardSenderName == nil, message.forwardDate == nil, message.editDate == nil,
              message.senderChat == nil, message.businessConnectionID == nil, message.guestQueryID == nil,
              message.isAutomaticForward == nil, message.senderBusinessBot == nil,
              let text = message.text else { return false }
        return text == challenge.code || text == "/start " + challenge.code
    }

    private func call<Value: Decodable & Sendable>(_ method: String, body: [String: Any], mutation: Bool = false) async throws -> Value {
        try ensureOpen()
        guard credentials.channel == .telegram, credentials.appToken == nil,
              credentials.botToken.range(of: #"\A[1-9][0-9]{0,18}:[A-Za-z0-9_-]{1,256}\z"#, options: .regularExpression) != nil,
              let endpoint = URL(string: "https://\(Self.host)/bot\(credentials.botToken)/\(method)") else {
            throw BotChannelFailure.invalidCredentials
        }
        let data: Data
        // getUpdates long-polls for up to 30 seconds; other methods answer promptly.
        let timeout: TimeInterval = method == "getUpdates" ? 35 : 15
        do { data = try await http.post(endpoint, body: JSONSerialization.data(withJSONObject: body), timeout: timeout) }
        catch {
            try ensureOpen()
            let failure = (error as? BotChannelFailure) ?? .unavailable
            if mutation && ![BotChannelFailure.unauthorized, .permissionDenied, .rateLimited, .canceled, .invalidCredentials].contains(failure) {
                throw BotChannelFailure.deliveryUncertain
            }
            throw failure
        }
        try ensureOpen()
        let envelope: Envelope<Value>
        do { envelope = try JSONDecoder().decode(Envelope<Value>.self, from: data) }
        catch { throw mutation ? BotChannelFailure.deliveryUncertain : .invalidResponse }
        if !envelope.ok {
            switch envelope.errorCode {
            case 401: throw BotChannelFailure.unauthorized
            case 403: throw BotChannelFailure.permissionDenied
            case 429: throw BotChannelFailure.rateLimited
            case 409 where method == "getUpdates": throw BotChannelFailure.webhookInUse
            default: throw mutation ? BotChannelFailure.deliveryUncertain : .unavailable
            }
        }
        guard let value = envelope.result else { throw mutation ? BotChannelFailure.deliveryUncertain : .invalidResponse }
        return value
    }
}

private struct Envelope<Value: Decodable & Sendable>: Decodable, Sendable {
    let ok: Bool
    let result: Value?
    let errorCode: Int?
    enum CodingKeys: String, CodingKey { case ok, result; case errorCode = "error_code" }
}
private struct User: Decodable, Sendable {
    let id: Int64
    let isBot: Bool
    let username: String?
    enum CodingKeys: String, CodingKey { case id, username; case isBot = "is_bot" }
}
private struct Webhook: Decodable, Sendable { let url: String }
private struct Chat: Decodable, Sendable { let id: Int64; let type: String }
private struct Update: Decodable, Sendable {
    let updateID: Int64
    let message: Message?
    let callbackQuery: CallbackQuery?
    enum CodingKeys: String, CodingKey { case message; case updateID = "update_id", callbackQuery = "callback_query" }
}
/// A tap on an inline button; only the bot's own message it belongs to and the sender matter.
private struct CallbackQuery: Decodable, Sendable {
    let id: String
    let from: User
    let message: RepliedMessage?
    let data: String?
}
/// Presence alone rejects nonordinary message contexts without retaining their contents.
private struct Presence: Decodable, Sendable { init(from decoder: any Decoder) throws {} }
/// A message a reply or a tap refers to; only its identity, chat and sender matter.
private struct RepliedMessage: Decodable, Sendable {
    let messageID: Int64
    let from: User?
    let chat: Chat
    enum CodingKeys: String, CodingKey { case from, chat; case messageID = "message_id" }
}
private struct Message: Decodable, Sendable {
    let messageID: Int64
    let date: Int64
    let from: User?
    let chat: Chat
    let text: String?
    let replyToMessage: RepliedMessage?
    let forwardOrigin: Presence?
    let forwardFrom: Presence?
    let forwardFromChat: Presence?
    let forwardSenderName: Presence?
    let forwardDate: Presence?
    let editDate: Presence?
    let senderChat: Presence?
    let businessConnectionID: Presence?
    let guestQueryID: Presence?
    let isAutomaticForward: Presence?
    let senderBusinessBot: Presence?
    enum CodingKeys: String, CodingKey {
        case from, chat, text
        case messageID = "message_id", date, replyToMessage = "reply_to_message"
        case forwardOrigin = "forward_origin", forwardFrom = "forward_from", forwardFromChat = "forward_from_chat"
        case forwardSenderName = "forward_sender_name", forwardDate = "forward_date", editDate = "edit_date"
        case senderChat = "sender_chat", businessConnectionID = "business_connection_id", guestQueryID = "guest_query_id"
        case isAutomaticForward = "is_automatic_forward", senderBusinessBot = "sender_business_bot"
    }
}
