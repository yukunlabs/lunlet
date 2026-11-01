// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.03, AC-20.04, AC-20.05, AC-20.06; US-12, AC-12.02; US-33, AC-33.05.
// Refs: US-06, AC-06.01, AC-06.02, AC-06.05; US-36, AC-36.01, AC-36.02, AC-36.03, AC-36.04.
import Foundation
import CoreFoundation
import LunletCore

/// Own-bot transport for the paired direct message. Bot scopes: users:read, chat:write, im:history; Socket Mode
/// requires an app-level token with connections:write and message.im events. Socket events prove pairing
/// possession and carry the owner's thread replies to a notice; they never dispatch anything themselves.
public actor SlackBotClient: ChannelReplyClient {
    private struct Prepared: Sendable {
        let identity: BotIdentity
        let userID: String
        func matches(_ other: Self) -> Bool {
            identity.id == other.identity.id && userID == other.userID
                && identity.workspaceID == other.identity.workspaceID && identity.applicationID == other.identity.applicationID
        }
    }
    private let credentials: BotCredentials
    private let http: ChannelHTTPClient
    private let socketFactory: (@Sendable (URL) async throws -> any ChannelSocket)?
    private let now: @Sendable () -> Date
    private var prepared: Prepared?
    private var closed = false
    private var pairingID: UUID?
    private var pairingSocket: (any ChannelSocket)?
    private var pairingExpired = false
    private var listening = false
    private var replySocket: (any ChannelSocket)?

    public init(credentials: BotCredentials) {
        self.credentials = credentials; http = ChannelHTTPClient(allowedHosts: ["slack.com"]); socketFactory = nil; now = Date.init
    }
    init(credentials: BotCredentials, http: ChannelHTTPClient,
         socketFactory: (@Sendable (URL) async throws -> any ChannelSocket)? = nil,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.credentials = credentials; self.http = http; self.socketFactory = socketFactory; self.now = now
    }

    public func prepare() async throws -> BotIdentity {
        try ensureOpen()
        guard credentials.channel == .slack, Self.validToken(credentials.botToken, prefix: "xoxb-"),
              let appToken = credentials.appToken, Self.validToken(appToken, prefix: "xapp-") else {
            throw BotChannelFailure.invalidCredentials
        }
        // A failed call is logged with its step: 1 auth.test, 2 bots.info, 3 apps.connections.open; a response whose
        // shape is not the documented one logs the step's check as 11–13, 21–26 or 31.
        let auth = try await call("auth.test", token: credentials.botToken, step: 1)
        guard let botID = auth["bot_id"] as? String, Self.validID(botID, prefixes: "B") else { throw note(.invalidResponse, step: 11) }
        guard let teamID = auth["team_id"] as? String, Self.validID(teamID, prefixes: "T") else { throw note(.invalidResponse, step: 12) }
        guard let userID = auth["user_id"] as? String, Self.validID(userID, prefixes: "UW") else { throw note(.invalidResponse, step: 13) }
        // Slack documents form encoding for every method and JSON only for some; this read method is sent as a form.
        let info = try await call("bots.info", token: credentials.botToken, body: ["bot": botID], form: true, step: 2)
        guard let bot = info["bot"] as? [String: Any] else { throw note(.invalidResponse, step: 21) }
        guard bot["id"] as? String == botID else { throw note(.invalidResponse, step: 22) }
        guard bot["user_id"] as? String == userID else { throw note(.invalidResponse, step: 23) }
        guard bot["deleted"].map({ Self.boolean($0) == false }) ?? true else { throw note(.invalidResponse, step: 24) }
        guard let appID = bot["app_id"] as? String, Self.validID(appID, prefixes: "A") else { throw note(.invalidResponse, step: 25) }
        guard let name = bot["name"] as? String, !name.isEmpty, name.utf8.count <= 160,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw note(.invalidResponse, step: 26)
        }
        try ensureOpen()
        let candidate = Prepared(identity: .init(channel: .slack, id: botID, name: name, workspaceID: teamID,
                                                  applicationID: appID), userID: userID)
        if let prepared, !prepared.matches(candidate) { throw BotChannelFailure.identityMismatch }
        prepared = candidate
        return candidate.identity
    }

    public func checkAuthorization(_ binding: BotBinding) async throws {
        _ = try await prepare()
        guard let prepared else { throw BotChannelFailure.invalidResponse }
        try validate(binding, against: prepared)
    }

    public func pair(_ challenge: PairingChallenge) async throws -> BotBinding {
        try ensureOpen()
        guard challenge.isValid(at: now()), challenge.code.utf8.count <= 128,
              challenge.code.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else {
            throw BotChannelFailure.expired
        }
        guard pairingID == nil else { throw BotChannelFailure.unavailable }
        let id = UUID(); pairingID = id; pairingExpired = false
        defer { if pairingID == id { pairingID = nil; pairingSocket = nil } }
        if prepared == nil { _ = try await prepare() }
        try ensureOpen()
        guard let identity = prepared else { throw BotChannelFailure.invalidResponse }
        do {
            // Caller cancellation reaches the pairing directly; close() ends it by closing
            // the socket and invalidating the HTTP session.
            let binding = try await runPairing(challenge, identity: identity, id: id)
            try ensureOpen()
            return binding
        } catch {
            if closed || Task.isCancelled { throw BotChannelFailure.canceled }
            if pairingExpired { throw BotChannelFailure.expired }
            throw (error as? BotChannelFailure) ?? .unavailable
        }
    }

    private func runPairing(_ challenge: PairingChallenge, identity: Prepared, id: UUID) async throws -> BotBinding {
        let remaining = min(600, challenge.expiresAt.timeIntervalSince(now()))
        guard remaining > 0 else { throw BotChannelFailure.expired }
        do {
            let binding = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: BotBinding.self) { group in
                    group.addTask { try await self.receivePairing(challenge, identity: identity, id: id) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(remaining))
                        await self.expirePairing(id)
                        throw BotChannelFailure.expired
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else { throw BotChannelFailure.canceled }
                    return result
                }
            } onCancel: {
                Task { await self.closePairingSocket(id) }
            }
            await closePairingSocket(id)
            return binding
        } catch {
            await closePairingSocket(id)
            if Task.isCancelled || closed { throw BotChannelFailure.canceled }
            if pairingExpired { throw BotChannelFailure.expired }
            throw (error as? BotChannelFailure) ?? .unavailable
        }
    }

    private func receivePairing(_ challenge: PairingChallenge, identity: Prepared, id: UUID) async throws -> BotBinding {
        var seenEnvelopes = Set<String>()
        // Refreshes are exceptional during a ten-minute setup. Bound them and avoid a reconnect spin.
        for connection in 0..<4 {
            try ensurePairing(challenge, id: id)
            if connection > 0 { try await Task.sleep(for: .milliseconds(250)) }
            let response = try await call("apps.connections.open", token: credentials.appToken!, step: 3)
            guard let address = response["url"] as? String, address.utf8.count <= 8192,
                  let endpoint = URL(string: address), Self.validSocketEndpoint(endpoint) else {
                throw note(.invalidResponse, step: 31)
            }
            let socket: any ChannelSocket
            if let socketFactory { socket = try await socketFactory(endpoint) }
            else { socket = try await http.openSocket(endpoint) }
            pairingSocket = socket
            try ensurePairing(challenge, id: id)
            let hello = try Self.object(await socket.receive())
            guard hello["type"] as? String == "hello",
                  (hello["connection_info"] as? [String: Any])?["app_id"] as? String == identity.identity.applicationID else {
                throw BotChannelFailure.identityMismatch
            }
            while true {
                try ensurePairing(challenge, id: id)
                let frame = try Self.object(await socket.receive())
                try ensurePairing(challenge, id: id)
                if frame["type"] as? String == "disconnect" {
                    guard let reason = frame["reason"] as? String,
                          ["warning", "refresh_requested"].contains(reason) else { throw BotChannelFailure.unavailable }
                    await closePairingSocket(id)
                    break
                }
                guard let envelope = frame["envelope_id"] as? String, !envelope.isEmpty, envelope.utf8.count <= 256,
                      !envelope.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw BotChannelFailure.invalidResponse
                }
                // Never include response payloads, provider actions, or any session input in acknowledgments.
                try await socket.send(JSONSerialization.data(withJSONObject: ["envelope_id": envelope]))
                guard !seenEnvelopes.contains(envelope) else { continue }
                guard seenEnvelopes.count < 4096 else { throw BotChannelFailure.unavailable }
                seenEnvelopes.insert(envelope)
                guard frame["type"] as? String == "events_api",
                      let payload = frame["payload"] as? [String: Any], payload["type"] as? String == "event_callback",
                      payload["team_id"] as? String == identity.identity.workspaceID,
                      payload["api_app_id"] as? String == identity.identity.applicationID,
                      let event = payload["event"] as? [String: Any], event["type"] as? String == "message",
                      event["channel_type"] as? String == "im", event["subtype"] == nil,
                      event["bot_id"] == nil, event["edited"] == nil, event["message"] == nil,
                      event["attachments"] == nil, event["files"] == nil,
                      let user = event["user"] as? String, Self.validID(user, prefixes: "UW"), user != identity.userID,
                      let channel = event["channel"] as? String, Self.validID(channel, prefixes: "D"),
                      event["text"] as? String == "lunlet " + challenge.code,
                      let timestamp = event["ts"] as? String, let seconds = Self.timestamp(timestamp),
                      seconds >= floor(challenge.createdAt.timeIntervalSince1970), seconds <= now().timeIntervalSince1970 else { continue }
                try ensurePairing(challenge, id: id)
                return BotBinding(channel: .slack, botID: identity.identity.id, botName: identity.identity.name,
                                  ownerID: user, chatID: channel, workspaceID: identity.identity.workspaceID,
                                  applicationID: identity.identity.applicationID)
            }
        }
        throw BotChannelFailure.unavailable
    }

    public func sendCompletion(_ snapshot: SessionSnapshot, binding: BotBinding, reply: NoticeReplyState?) async throws -> BotMessageReceipt {
        let prepared = try await prepared(for: binding)
        let body = SlackNoticeMessage.body(SessionNotice.prepare(snapshot), channel: binding.chatID, reply: reply)
        let response = try await post("chat.postMessage", body: body)
        guard response["channel"] as? String == binding.chatID,
              let ts = response["ts"] as? String, Self.timestamp(ts) != nil,
              let message = response["message"] as? [String: Any], message["ts"] as? String == ts,
              message["bot_id"] as? String == prepared.identity.id,
              message["user"].map({ $0 as? String == prepared.userID }) ?? true,
              message["team"].map({ $0 as? String == prepared.identity.workspaceID }) ?? true,
              message["app_id"].map({ $0 as? String == prepared.identity.applicationID }) ?? true else {
            throw BotChannelFailure.deliveryUncertain
        }
        return BotMessageReceipt(messageID: ts, chatID: binding.chatID)
    }

    /// Rewrites a sent notice with the reply's state through `chat.update` on the bot's own message.
    public func updateCompletion(_ snapshot: SessionSnapshot, binding: BotBinding, messageID: String, reply: NoticeReplyState) async throws {
        _ = try await prepared(for: binding)
        guard Self.timestamp(messageID) != nil else { throw BotChannelFailure.invalidResponse }
        var body = SlackNoticeMessage.body(SessionNotice.prepare(snapshot), channel: binding.chatID, reply: reply)
        body["ts"] = messageID
        let response = try await post("chat.update", body: body)
        guard response["channel"] as? String == binding.chatID, response["ts"] as? String == messageID else {
            throw BotChannelFailure.deliveryUncertain
        }
    }

    public func sendText(_ text: String, binding: BotBinding) async throws {
        _ = try await prepared(for: binding)
        guard !text.isEmpty, text.utf16.count <= SlackNoticeMessage.sectionLimit else { throw BotChannelFailure.invalidResponse }
        let response = try await post("chat.postMessage", body: ["channel": binding.chatID, "text": SlackNoticeMessage.escape(text),
            "mrkdwn": false, "parse": "none", "unfurl_links": false, "unfurl_media": false])
        guard response["channel"] as? String == binding.chatID, response["ts"] is String else { throw BotChannelFailure.deliveryUncertain }
    }

    /// Receives the paired owner's replies in a notice's thread over Socket Mode until cancelled or closed. Every
    /// envelope is acknowledged; disconnect notices reconnect; nothing else is dispatched from the socket.
    /// Slack notices take a reply in their thread, so a reply request never arrives and nothing is prompted.
    public func promptReply(callbackID: String, agent: String, refusal: String?, binding: BotBinding) async throws -> String? { nil }

    public func receiveReplies(binding: BotBinding, onEvent: @escaping @Sendable (BotReplyEvent) async -> Void) async throws {
        try ensureOpen()
        guard pairingID == nil, !listening else { throw BotChannelFailure.unavailable }
        listening = true
        defer { listening = false }
        let identity = try await prepared(for: binding)
        var seenEnvelopes = Set<String>(), attempt = 0
        while true {
            try ensureOpen()
            if attempt > 0 {
                do { try await Task.sleep(for: .milliseconds(min(5_000, 250 * attempt))) } catch { throw BotChannelFailure.canceled }
            }
            attempt += 1
            let response = try await call("apps.connections.open", token: credentials.appToken!, step: 3)
            guard let address = response["url"] as? String, address.utf8.count <= 8192,
                  let endpoint = URL(string: address), Self.validSocketEndpoint(endpoint) else {
                throw note(.invalidResponse, step: 31)
            }
            let socket: any ChannelSocket
            if let socketFactory { socket = try await socketFactory(endpoint) }
            else { socket = try await http.openSocket(endpoint) }
            replySocket = socket
            do {
                // Cancellation closes the socket, which ends a pending receive.
                try await withTaskCancellationHandler {
                    try await listen(on: socket, binding: binding, identity: identity, seen: &seenEnvelopes, onEvent: onEvent)
                } onCancel: {
                    Task { await self.closeReplySocket() }
                }
                attempt = 0
            } catch {
                await socket.close(); replySocket = nil
                if closed || Task.isCancelled { throw BotChannelFailure.canceled }
                throw (error as? BotChannelFailure) ?? .unavailable
            }
            await socket.close(); replySocket = nil
        }
    }

    /// One Socket Mode connection: the hello, then every frame until the provider asks to reconnect.
    private func listen(on socket: any ChannelSocket, binding: BotBinding, identity: Prepared, seen: inout Set<String>,
                        onEvent: @escaping @Sendable (BotReplyEvent) async -> Void) async throws {
        let hello = try Self.object(await socket.receive())
        guard hello["type"] as? String == "hello",
              (hello["connection_info"] as? [String: Any])?["app_id"] as? String == identity.identity.applicationID else {
            throw BotChannelFailure.identityMismatch
        }
        while true {
            try ensureOpen()
            let frame = try Self.object(await socket.receive())
            try ensureOpen()
            if frame["type"] as? String == "disconnect" {
                guard let reason = frame["reason"] as? String,
                      ["warning", "refresh_requested"].contains(reason) else { throw BotChannelFailure.unavailable }
                return
            }
            guard let envelope = frame["envelope_id"] as? String, !envelope.isEmpty, envelope.utf8.count <= 256,
                  !envelope.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw BotChannelFailure.invalidResponse
            }
            // Never include response payloads, provider actions, or any session input in acknowledgments.
            try await socket.send(JSONSerialization.data(withJSONObject: ["envelope_id": envelope]))
            guard !seen.contains(envelope) else { continue }
            if seen.count >= 4096 { seen.removeAll() }
            seen.insert(envelope)
            guard let reply = ownerReply(frame, binding: binding, identity: identity) else { continue }
            await onEvent(.reply(reply))
        }
    }

    private func closeReplySocket() async {
        let socket = replySocket; replySocket = nil
        await socket?.close()
    }

    /// The owner's fresh, ordinary message in the paired direct message that answers a notice's thread.
    private func ownerReply(_ frame: [String: Any], binding: BotBinding, identity: Prepared) -> BotReply? {
        guard frame["type"] as? String == "events_api",
              let payload = frame["payload"] as? [String: Any], payload["type"] as? String == "event_callback",
              payload["team_id"] as? String == identity.identity.workspaceID,
              payload["api_app_id"] as? String == identity.identity.applicationID,
              let event = payload["event"] as? [String: Any], event["type"] as? String == "message",
              event["channel_type"] as? String == "im", event["subtype"] == nil,
              event["bot_id"] == nil, event["edited"] == nil, event["message"] == nil,
              event["attachments"] == nil, event["files"] == nil,
              event["user"] as? String == binding.ownerID, event["channel"] as? String == binding.chatID,
              let text = event["text"] as? String, !text.isEmpty,
              let ts = event["ts"] as? String, let seconds = Self.timestamp(ts),
              let thread = event["thread_ts"] as? String, Self.timestamp(thread) != nil, thread != ts else { return nil }
        let current = now().timeIntervalSince1970
        guard seconds <= current + 60, seconds >= current - ContinuationGate.controlLifetime - 60 else { return nil }
        return BotReply(messageID: ts, repliedTo: thread, text: text, sentAt: Date(timeIntervalSince1970: seconds))
    }

    private func prepared(for binding: BotBinding) async throws -> Prepared {
        try ensureOpen()
        if prepared == nil { _ = try await prepare() }
        guard let prepared else { throw BotChannelFailure.invalidResponse }
        try validate(binding, against: prepared)
        return prepared
    }

    /// A message send or edit; provider and network failures that leave the result unknown are uncertain.
    private func post(_ method: String, body: [String: Any]) async throws -> [String: Any] {
        let response: [String: Any]
        do { response = try await call(method, token: credentials.botToken, body: body) }
        catch {
            if closed || Task.isCancelled { throw BotChannelFailure.canceled }
            switch error as? BotChannelFailure {
            case .unauthorized: throw BotChannelFailure.unauthorized
            case .permissionDenied: throw BotChannelFailure.permissionDenied
            case .rateLimited: throw BotChannelFailure.rateLimited
            default: throw BotChannelFailure.deliveryUncertain
            }
        }
        try ensureOpen()
        return response
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        // Invalidating the session fails in-flight requests; closing the socket ends a pending receive.
        await pairingSocket?.close()
        await replySocket?.close()
        await http.close()
        pairingSocket = nil; replySocket = nil
    }

    private func call(_ method: String, token: String, body: [String: Any] = [:], form: Bool = false,
                      step: Int? = nil) async throws -> [String: Any] {
        try ensureOpen()
        let payload: Data, contentType: String
        if form {
            var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
            payload = Data(body.keys.sorted().map { key in
                key + "=" + ((body[key] as? String ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
            }.joined(separator: "&").utf8)
            contentType = "application/x-www-form-urlencoded; charset=utf-8"
        } else {
            payload = try JSONSerialization.data(withJSONObject: body)
            contentType = "application/json; charset=utf-8"
        }
        let endpoint = URL(string: "https://slack.com/api/" + method)!
        let data: Data
        do { data = try await http.post(endpoint, bearer: token, body: payload, contentType: contentType) }
        catch {
            if closed || Task.isCancelled { throw BotChannelFailure.canceled }
            // The transport maps HTTP statuses itself; anything else is the network.
            let failure = (error as? BotChannelFailure) ?? .unavailable
            throw note(failure, step: step, reason: failure == .unavailable ? .network : nil)
        }
        try ensureOpen()
        let response = try Self.object(data)
        guard Self.boolean(response["ok"]) == true else {
            switch response["error"] as? String {
            case "invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive": throw note(.unauthorized, step: step)
            case "missing_scope", "no_permission", "not_allowed_token_type", "access_denied", "not_in_channel", "channel_not_found": throw note(.permissionDenied, step: step)
            case "ratelimited", "rate_limited": throw note(.rateLimited, step: step)
            case nil: throw note(.invalidResponse, step: step)
            // Slack named an error this client does not map; the name itself is never logged.
            default: throw note(.unavailable, step: step, reason: .provider)
            }
        }
        return response
    }

    /// Logs a failed setup or socket step by number and allowlisted reason, then returns the failure to throw.
    private func note(_ failure: BotChannelFailure, step: Int?, reason: DiagnosticReason? = nil) -> BotChannelFailure {
        if let step {
            DiagnosticLog.record(.connection, component: .slack, outcome: .failed, operation: DiagnosticOperation(),
                                 reason: reason ?? DiagnosticReason(failure), code: step)
        }
        return failure
    }

    private func validate(_ binding: BotBinding, against prepared: Prepared) throws {
        try ensureOpen()
        guard binding.channel == .slack, binding.botID == prepared.identity.id,
              binding.workspaceID == prepared.identity.workspaceID, binding.applicationID == prepared.identity.applicationID,
              Self.validID(binding.ownerID, prefixes: "UW"), binding.ownerID != prepared.userID,
              Self.validID(binding.chatID, prefixes: "D") else { throw BotChannelFailure.identityMismatch }
    }
    private func ensureOpen() throws {
        if closed || Task.isCancelled { throw BotChannelFailure.canceled }
    }
    private func ensurePairing(_ challenge: PairingChallenge, id: UUID) throws {
        try ensureOpen()
        guard pairingID == id else { throw BotChannelFailure.canceled }
        guard !pairingExpired, challenge.isValid(at: now()) else { throw BotChannelFailure.expired }
    }
    private func expirePairing(_ id: UUID) async {
        guard pairingID == id else { return }
        pairingExpired = true
        await pairingSocket?.close()
    }
    private func closePairingSocket(_ id: UUID) async {
        guard pairingID == id else { return }
        let socket = pairingSocket; pairingSocket = nil
        await socket?.close()
    }
    /// Socket Mode URLs are issued only for `wss*.slack.com` hosts.
    static func validSocketEndpoint(_ endpoint: URL) -> Bool {
        guard endpoint.scheme == "wss", let host = endpoint.host?.lowercased(),
              host.hasSuffix(".slack.com"), host.hasPrefix("wss"),
              host.split(separator: ".").count == 3,
              endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              endpoint.port == nil || endpoint.port == 443 else { return false }
        return true
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576, let object = try? JSONSerialization.jsonObject(with: data),
              let value = object as? [String: Any] else { throw BotChannelFailure.invalidResponse }
        return value
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func validToken(_ token: String, prefix: String) -> Bool {
        token.hasPrefix(prefix) && token.count > prefix.count && token.utf8.count <= 4096 && !token.contains(where: \.isWhitespace)
            && !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func validID(_ id: String, prefixes: String) -> Bool {
        guard let first = id.first, prefixes.contains(first), (2...64).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }
    private static func timestamp(_ value: String) -> TimeInterval? {
        guard value.utf8.count <= 32, value.range(of: #"^[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
              let number = Double(value), number.isFinite, number >= 0 else { return nil }
        return number
    }
}
