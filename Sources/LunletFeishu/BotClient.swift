// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-22, AC-22.01, AC-22.02.
// Refs: US-14, AC-14.01, AC-14.02, AC-14.03, AC-14.06.
// Refs: US-01, AC-01.02, AC-01.04, AC-01.05; US-06, AC-06.01, AC-06.05.
// Refs: US-10, AC-10.01, AC-10.03, AC-10.04; US-12, AC-12.02, AC-12.04.
import Foundation
import LunletCore

public enum FeishuBotFailure: Error, Equatable, Sendable {
    case disconnected, invalidRequest, invalidResponse, authenticationRejected
    case permissionDenied, rateLimited, unavailable, deliveryUncertain
    case providerRejected(Int)
}

/// One immutable card and provider deduplication identity. It grants no local access.
public struct FeishuCardDelivery: Sendable, CustomStringConvertible {
    public let id: UUID
    let content: String
    public var description: String { "Feishu card delivery (redacted)" }

    public init(cardJSON: Data) throws {
        guard !cardJSON.isEmpty, cardJSON.count <= 28_000,
              let object = try? JSONSerialization.jsonObject(with: cardJSON),
              let card = object as? [String: Any], !card.isEmpty,
              let text = String(data: cardJSON, encoding: .utf8) else {
            throw FeishuBotFailure.invalidRequest
        }
        id = UUID()
        content = text
    }
}

/// A provider send receipt, not evidence of callback readiness or Codex processing.
public struct FeishuMessageReceipt: Equatable, Sendable {
    public let messageID: String
    public let chatID: String
    public let applicationID: String
    public let ownerID: String
    public let tenantID: String
}

public actor FeishuBotClient {
    private struct Token: Sendable {
        let id = UUID()
        let value: String
        let refreshAt: ContinuousClock.Instant
    }
    private struct Authentication {
        let id: UUID
        let task: Task<Token, Error>
    }
    private let enrollment: FeishuEnrollment
    private let session: URLSession
    private let now: @Sendable () -> ContinuousClock.Instant
    private var token: Token?
    private var authentication: Authentication?
    private var tenantID: String?
    private var closed = false
    private static let scope = "im:message:send_as_bot"

    public init(enrollment: FeishuEnrollment) {
        self.init(enrollment: enrollment, configuration: .ephemeral,
                  now: { ContinuousClock.now })
    }

    init(enrollment: FeishuEnrollment, configuration: URLSessionConfiguration,
         now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.enrollment = enrollment
        self.now = now
        session = HardenedHTTP.session(configuration: configuration, requestTimeout: 15, resourceTimeout: 15)
    }

    deinit {
        authentication?.task.cancel()
        session.invalidateAndCancel()
    }

    func requestConnectionEndpoint() async throws -> FeishuConnectionEndpoint {
        let operation = DiagnosticOperation()
        DiagnosticLog.record(.endpointDiscovery, component: .feishu, outcome: .started, operation: operation)
        do {
            let endpoint = try await discoverEndpoint()
            DiagnosticLog.record(.endpointDiscovery, component: .feishu, outcome: .completed, operation: operation)
            return endpoint
        } catch {
            FeishuDiagnostics.failure(.endpointDiscovery, operation: operation, error: error)
            throw error
        }
    }

    private func discoverEndpoint() async throws -> FeishuConnectionEndpoint {
        try Task.checkCancellation()
        guard !closed else { throw FeishuBotFailure.disconnected }
        let host = enrollment.isLark ? "open.larksuite.com" : "open.feishu.cn"
        let request = try Self.request("https://\(host)/callback/ws/endpoint", body: [
            "AppID": enrollment.applicationID, "AppSecret": enrollment.secret,
        ])
        let data = try await Self.perform(request, session: session)
        guard !closed else { throw FeishuBotFailure.disconnected }
        return try FeishuConnectionEndpoint.decode(data, applicationID: enrollment.applicationID)
    }

    /// Explicit credential recovery only: no message, owner receipt or callback claim.
    public func checkAuthorization() async throws {
        try Task.checkCancellation()
        guard !closed else { throw FeishuBotFailure.disconnected }
        token = nil
        _ = try await accessToken()
    }

    public func sendCard(_ delivery: FeishuCardDelivery) async throws -> FeishuMessageReceipt {
        let operation = DiagnosticOperation()
        DiagnosticLog.record(.cardDelivery, component: .feishu, outcome: .started, operation: operation)
        do {
            let receipt = try await sendOwnedCard(delivery)
            DiagnosticLog.record(.cardDelivery, component: .feishu, outcome: .completed, operation: operation)
            return receipt
        } catch {
            FeishuDiagnostics.failure(.cardDelivery, operation: operation, error: error)
            throw error
        }
    }

    public func sendCard(_ delivery: FeishuCardDelivery, owner: FeishuOwner) async throws -> FeishuMessageReceipt {
        guard owner.applicationID == enrollment.applicationID, owner.userID == enrollment.scannedOwnerID,
              let tenantID, tenantID == owner.tenantID else { throw FeishuBotFailure.invalidRequest }
        return try await sendCard(delivery)
    }

    /// Replaces the content of a card this application sent to the verified owner, such as a reply box that
    /// now shows its reply's progress. Only cards marked shared (`update_multi`) can be updated.
    public func updateCard(_ delivery: FeishuCardDelivery, messageID: String, owner: FeishuOwner) async throws {
        let operation = DiagnosticOperation()
        DiagnosticLog.record(.cardUpdate, component: .feishu, outcome: .started, operation: operation)
        do {
            guard owner.applicationID == enrollment.applicationID, owner.userID == enrollment.scannedOwnerID,
                  let tenantID, tenantID == owner.tenantID, Self.validMessageID(messageID) else {
                throw FeishuBotFailure.invalidRequest
            }
            try Task.checkCancellation()
            guard !closed else { throw FeishuBotFailure.disconnected }
            let access = try await accessToken()
            let host = enrollment.isLark ? "open.larksuite.com" : "open.feishu.cn"
            var request = try Self.request("https://\(host)/open-apis/im/v1/messages/\(messageID)",
                                           body: ["content": delivery.content], method: "PATCH")
            request.setValue("Bearer \(access.value)", forHTTPHeaderField: "Authorization")
            _ = try await Self.perform(request, session: session)
            DiagnosticLog.record(.cardUpdate, component: .feishu, outcome: .completed, operation: operation)
        } catch {
            FeishuDiagnostics.failure(.cardUpdate, operation: operation, error: error)
            throw error
        }
    }

    private func sendOwnedCard(_ delivery: FeishuCardDelivery) async throws -> FeishuMessageReceipt {
        try Task.checkCancellation()
        guard !closed else { throw FeishuBotFailure.disconnected }
        let access = try await accessToken()
        try Task.checkCancellation()
        guard !closed else { throw FeishuBotFailure.disconnected }
        let host = enrollment.isLark ? "open.larksuite.com" : "open.feishu.cn"
        var request = try Self.request("https://\(host)/open-apis/im/v1/messages?receive_id_type=open_id", body: [
            "receive_id": enrollment.scannedOwnerID, "msg_type": "interactive",
            "content": delivery.content, "uuid": delivery.id.uuidString,
        ])
        request.setValue("Bearer \(access.value)", forHTTPHeaderField: "Authorization")
        do {
            let data = try await Self.perform(request, session: session)
            guard !closed else { throw FeishuBotFailure.deliveryUncertain }
            let sent = try JSONDecoder().decode(MessageReply.self, from: data).data
            guard let sent, Self.validIdentifier(sent.message_id), Self.validIdentifier(sent.chat_id),
                  let sender = sent.sender, sender.id == enrollment.applicationID,
                  sender.id_type == "app_id", sender.sender_type == "app",
                  let tenant = sender.tenant_key, Self.validIdentifier(tenant),
                  tenantID == nil || tenantID == tenant else { throw FeishuBotFailure.deliveryUncertain }
            tenantID = tenant
            return FeishuMessageReceipt(messageID: sent.message_id!, chatID: sent.chat_id!,
                                        applicationID: enrollment.applicationID,
                                        ownerID: enrollment.scannedOwnerID, tenantID: tenant)
        } catch let failure as FeishuBotFailure {
            switch failure {
            case .authenticationRejected, .providerRejected(99991663), .providerRejected(99991665):
                // A delayed rejection must not discard a newer authentication result.
                if token?.id == access.id { token = nil }
                throw failure
            case .providerRejected, .permissionDenied, .rateLimited: throw failure
            default: throw FeishuBotFailure.deliveryUncertain
            }
        } catch { throw FeishuBotFailure.deliveryUncertain }
    }

    public func close() async {
        closed = true
        token = nil
        let pending = authentication?.task
        authentication = nil
        pending?.cancel()
        session.invalidateAndCancel()
        _ = await pending?.result
    }

    private func accessToken() async throws -> Token {
        let startedAt = now()
        if let token, startedAt < token.refreshAt { return token }
        let pending: Authentication
        if let authentication { pending = authentication }
        else {
            let enrollment = enrollment, session = session, now = now
            pending = Authentication(id: UUID(), task: Task {
                try await Self.fetchToken(enrollment: enrollment, session: session, now: now)
            })
            authentication = pending
        }
        defer { if authentication?.id == pending.id { authentication = nil } }
        let result = try await pending.task.value
        try Task.checkCancellation()
        guard !closed else { throw FeishuBotFailure.disconnected }
        let receivedAt = now()
        guard receivedAt >= startedAt, receivedAt < result.refreshAt else {
            throw FeishuBotFailure.invalidResponse
        }
        token = result
        return result
    }

    private static func fetchToken(enrollment: FeishuEnrollment, session: URLSession,
                                   now: @Sendable () -> ContinuousClock.Instant) async throws -> Token {
        guard validIdentifier(enrollment.applicationID), validIdentifier(enrollment.scannedOwnerID),
              !enrollment.secret.isEmpty else { throw FeishuBotFailure.invalidRequest }
        let operation = DiagnosticOperation()
        DiagnosticLog.record(.authentication, component: .feishu, outcome: .started, operation: operation)
        do {
            let token = try await fetchOwnedToken(enrollment: enrollment, session: session, now: now)
            DiagnosticLog.record(.authentication, component: .feishu, outcome: .completed, operation: operation)
            return token
        } catch {
            FeishuDiagnostics.failure(.authentication, operation: operation, error: error)
            throw error
        }
    }

    private static func fetchOwnedToken(enrollment: FeishuEnrollment, session: URLSession,
                                        now: @Sendable () -> ContinuousClock.Instant) async throws -> Token {
        let request: URLRequest
        if enrollment.isLark {
            request = try Self.request("https://open.larksuite.com/open-apis/auth/v3/tenant_access_token/internal",
                                       body: ["app_id": enrollment.applicationID, "app_secret": enrollment.secret])
        } else {
            request = try Self.request("https://accounts.feishu.cn/oauth/v3/token", body: [
                "grant_type": "client_credentials", "client_id": enrollment.applicationID,
                "client_secret": enrollment.secret, "scope": scope,
            ])
        }
        let startedAt = now()
        let data = try await perform(request, session: session)
        guard let reply = try? JSONDecoder().decode(TokenReply.self, from: data) else {
            throw FeishuBotFailure.invalidResponse
        }
        if !enrollment.isLark {
            guard reply.token_type == "Bearer", let scopes = reply.scope else {
                throw FeishuBotFailure.invalidResponse
            }
            guard scopes.split(separator: " ").map(String.init) == [scope] else {
                throw FeishuBotFailure.permissionDenied
            }
        }
        let value = enrollment.isLark ? reply.tenant_access_token : reply.access_token
        let duration = enrollment.isLark ? reply.expire : reply.expires_in
        guard let value, !value.isEmpty, value.utf8.count <= 16_384,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                  || Array("-._~+/=".utf8).contains($0) }),
              let duration, duration > 0, duration <= 7_200 else { throw FeishuBotFailure.invalidResponse }
        let lifetime = TimeInterval(duration)
        return Token(value: value, refreshAt: startedAt.advanced(by: .seconds(lifetime - min(60, lifetime / 10))))
    }

    private static func validIdentifier(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.utf8.count <= 512 else { return false }
        return value.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0)
            && !CharacterSet.controlCharacters.contains($0) }
    }

    /// Provider message IDs are path segments, so only their documented characters are accepted.
    static func validMessageID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }

    private static func request(_ url: String, body: [String: String], method: String = "POST") throws -> URLRequest {
        guard let target = URL(string: url) else { throw FeishuBotFailure.invalidRequest }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func perform(_ request: URLRequest, session: URLSession) async throws -> Data {
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw FeishuBotFailure.invalidResponse }
            if response.statusCode == 401 { throw FeishuBotFailure.authenticationRejected }
            if response.statusCode == 403 { throw FeishuBotFailure.permissionDenied }
            if response.statusCode == 429 { throw FeishuBotFailure.rateLimited }
            guard (200..<300).contains(response.statusCode) || (400..<500).contains(response.statusCode) else {
                throw FeishuBotFailure.unavailable
            }
            let data = try await HardenedHTTP.body(bytes, limit: 65_536, overflow: FeishuBotFailure.invalidResponse)
            try Task.checkCancellation()
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                throw FeishuBotFailure.invalidResponse
            }
            guard envelope.code == 0 else { throw FeishuBotFailure.providerRejected(envelope.code) }
            guard (200..<300).contains(response.statusCode) else { throw FeishuBotFailure.invalidResponse }
            return data
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw (error as? FeishuBotFailure) ?? .unavailable
        }
    }

    private struct Envelope: Decodable { let code: Int }
    private struct TokenReply: Decodable {
        let access_token: String?
        let expires_in: Int?
        let token_type: String?
        let scope: String?
        let tenant_access_token: String?
        let expire: Int?
    }
    private struct MessageReply: Decodable {
        let data: Message?
        struct Message: Decodable {
            let message_id: String?
            let chat_id: String?
            let sender: Sender?
        }
        struct Sender: Decodable {
            let id: String?
            let id_type: String?
            let sender_type: String?
            let tenant_key: String?
        }
    }
}
