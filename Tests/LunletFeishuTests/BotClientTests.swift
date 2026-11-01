// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-22, AC-22.01, AC-22.02.
// Refs: US-01, AC-01.02, AC-01.04, AC-01.05; US-06, AC-06.01, AC-06.05.
// Refs: US-10, AC-10.01, AC-10.03, AC-10.04; US-12, AC-12.02, AC-12.04.
import Foundation
import Testing
import LunletCore
@testable import LunletFeishu

private final class BotHTTPState: @unchecked Sendable {
    enum Reply { case response(Int, Data), offline, held }
    struct Request {
        let url: URL
        let authorization: String?
        let body: [String: String]
    }
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var captured: [Request] = []
    private var held: BotHTTPProtocol?
    private var time: TimeInterval = 1_000

    func reset(_ values: [Reply]) {
        lock.withLock { replies = values; captured = []; held = nil; time = 1_000 }
    }
    func receive(_ request: URLRequest, source: BotHTTPProtocol) -> Reply {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
        return lock.withLock {
            captured.append(Request(url: request.url!, authorization: request.value(forHTTPHeaderField: "Authorization"),
                                    body: body))
            let reply = replies.isEmpty ? .offline : replies.removeFirst()
            if case .held = reply { held = source }
            return reply
        }
    }
    func release(status: Int = 200, _ data: Data) {
        let source = lock.withLock { let value = held; held = nil; return value }
        source?.respond(status: status, data: data)
    }
    func requests() -> [Request] { lock.withLock { captured } }
    func now() -> TimeInterval { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

private final class BotHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = BotHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch Self.state.receive(request, source: self) {
        case .response(let status, let data): respond(status: status, data: data)
        case .offline: client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .held: break
        }
    }
    func respond(status: Int, data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct BotClientTests {
    private let token = Data(#"{"code":0,"access_token":"synthetic-token","token_type":"Bearer","expires_in":7200,"scope":"im:message:send_as_bot"}"#.utf8)
    private let sent = Data(#"{"code":0,"msg":"ok","data":{"message_id":"om_synthetic","chat_id":"oc_synthetic","sender":{"id":"cli_synthetic","id_type":"app_id","sender_type":"app","tenant_key":"tenant_synthetic"}}}"#.utf8)
    private let card = Data(#"{"schema":"2.0","body":{"elements":[{"tag":"markdown","content":"Synthetic summary"}]}}"#.utf8)

    private func client(_ replies: [BotHTTPState.Reply], isLark: Bool = false) -> FeishuBotClient {
        BotHTTPProtocol.state.reset(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPProtocol.self]
        let enrollment = FeishuEnrollment(applicationID: "cli_synthetic", scannedOwnerID: "ou_owner",
                                          secret: "synthetic-secret", isLark: isLark)
        let origin = ContinuousClock.now
        return FeishuBotClient(enrollment: enrollment, configuration: configuration,
                               now: { origin.advanced(by: .seconds(BotHTTPProtocol.state.now() - 1_000)) })
    }

    private func waitForRequestCount(_ count: Int) async throws {
        for _ in 0..<1000 {
            if BotHTTPProtocol.state.requests().count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("The expected synthetic HTTP request was not made")
    }

    @Test func explicitAuthorizationChecksFreshCredentialsAndReportsRevokedScope() async throws {
        let revoked = Data(#"{"code":0,"access_token":"synthetic-token","token_type":"Bearer","expires_in":7200,"scope":"unrelated"}"#.utf8)
        let service = client([.response(200, token), .response(200, revoked)])
        try await service.checkAuthorization()
        await #expect(throws: FeishuBotFailure.permissionDenied) { try await service.checkAuthorization() }
        #expect(BotHTTPProtocol.state.requests().count == 2)
        #expect(BotHTTPProtocol.state.requests().allSatisfy { $0.url.path == "/oauth/v3/token" })
        await service.close()
    }

    @Test func explicitAuthorizationCheckDoesNotSendOrEstablishOwnerDelivery() async throws {
        let service = client([.response(200, token)])
        try await service.checkAuthorization()
        let requests = BotHTTPProtocol.state.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.url.path == "/oauth/v3/token")
        #expect(requests.first?.body["scope"] == "im:message:send_as_bot")
        let owner = FeishuOwner(applicationID: "cli_synthetic", tenantID: "tenant_synthetic", userID: "ou_owner")
        await #expect(throws: FeishuBotFailure.invalidRequest) {
            try await service.sendCard(FeishuCardDelivery(cardJSON: card), owner: owner)
        }
        #expect(BotHTTPProtocol.state.requests().count == 1)
        await service.close()
        await #expect(throws: FeishuBotFailure.disconnected) { try await service.checkAuthorization() }
    }

    @Test func sendsOnlyToTheScannedOwnerWithTheMinimalTokenScope() async throws {
        let service = client([.response(200, token), .response(200, sent)])
        let delivery = try FeishuCardDelivery(cardJSON: card)
        let receipt = try await service.sendCard(delivery)
        #expect(receipt == FeishuMessageReceipt(messageID: "om_synthetic", chatID: "oc_synthetic",
                                                applicationID: "cli_synthetic", ownerID: "ou_owner",
                                                tenantID: "tenant_synthetic"))
        let requests = BotHTTPProtocol.state.requests()
        #expect(requests.count == 2)
        let auth = try #require(requests.first)
        #expect(auth.url.absoluteString == "https://accounts.feishu.cn/oauth/v3/token")
        #expect(auth.authorization == nil)
        #expect(auth.body == ["grant_type": "client_credentials", "client_id": "cli_synthetic",
                              "client_secret": "synthetic-secret", "scope": "im:message:send_as_bot"])
        let send = try #require(requests.last)
        #expect(send.url.absoluteString == "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=open_id")
        #expect(send.authorization == "Bearer synthetic-token")
        #expect(send.body == ["receive_id": "ou_owner", "msg_type": "interactive",
                              "content": String(decoding: card, as: UTF8.self), "uuid": delivery.id.uuidString])
        await service.close()
    }

    @Test func coordinatorDeliveryRequiresTheSendersAlreadyVerifiedOwnerBeforeAnyHTTPRequest() async throws {
        let service = client([.response(200, token), .response(200, sent), .response(200, sent)])
        let delivery = try FeishuCardDelivery(cardJSON: card)
        let owner = FeishuOwner(applicationID: "cli_synthetic", tenantID: "tenant_synthetic", userID: "ou_owner")
        await #expect(throws: FeishuBotFailure.invalidRequest) { try await service.sendCard(delivery, owner: owner) }
        #expect(BotHTTPProtocol.state.requests().isEmpty)
        _ = try await service.sendCard(delivery)
        for mismatch in [
            FeishuOwner(applicationID: "cli_other", tenantID: owner.tenantID, userID: owner.userID),
            FeishuOwner(applicationID: owner.applicationID, tenantID: "tenant_other", userID: owner.userID),
            FeishuOwner(applicationID: owner.applicationID, tenantID: owner.tenantID, userID: "ou_other"),
        ] {
            await #expect(throws: FeishuBotFailure.invalidRequest) { try await service.sendCard(delivery, owner: mismatch) }
        }
        #expect(BotHTTPProtocol.state.requests().count == 2)
        let receipt = try await service.sendCard(delivery, owner: owner)
        #expect(receipt.ownerID == owner.userID && BotHTTPProtocol.state.requests().count == 3)
        await service.close()
    }

    @Test func larkUsesItsDocumentedAuthenticationProtocolWithoutDomainFallback() async throws {
        let legacyToken = Data(#"{"code":0,"tenant_access_token":"synthetic-lark-token","expire":7200}"#.utf8)
        let service = client([.response(200, legacyToken), .response(200, sent)], isLark: true)
        _ = try await service.sendCard(FeishuCardDelivery(cardJSON: card))
        let requests = BotHTTPProtocol.state.requests()
        #expect(requests.first?.url.absoluteString == "https://open.larksuite.com/open-apis/auth/v3/tenant_access_token/internal")
        #expect(requests.first?.body == ["app_id": "cli_synthetic", "app_secret": "synthetic-secret"])
        #expect(requests.last?.url.host == "open.larksuite.com")
        #expect(requests.last?.authorization == "Bearer synthetic-lark-token")
        await service.close()
    }

    @Test func reusesTokensAndRefreshesBeforeTheReportedMonotonicExpiry() async throws {
        let shortToken = Data(#"{"code":0,"access_token":"first-token","token_type":"Bearer","expires_in":100,"scope":"im:message:send_as_bot"}"#.utf8)
        let service = client([.response(200, shortToken), .response(200, sent), .response(200, sent),
                              .response(200, token), .response(200, sent)])
        let delivery = try FeishuCardDelivery(cardJSON: card)
        _ = try await service.sendCard(delivery)
        BotHTTPProtocol.state.advance(89)
        _ = try await service.sendCard(delivery)
        BotHTTPProtocol.state.advance(1)
        _ = try await service.sendCard(delivery)
        let requests = BotHTTPProtocol.state.requests()
        #expect(requests.count == 5)
        #expect(requests.filter { $0.url.host == "accounts.feishu.cn" }.count == 2)
        #expect(requests.last?.authorization == "Bearer synthetic-token")
        #expect(requests.filter { $0.body["msg_type"] != nil }.allSatisfy { $0.body["uuid"] == delivery.id.uuidString })
        await service.close()
    }

    @Test func concurrentDeliveriesShareOneAuthenticationExchange() async throws {
        let service = client([.held, .response(200, sent), .response(200, sent)])
        let delivery = try FeishuCardDelivery(cardJSON: card)
        let first = Task { try await service.sendCard(delivery) }
        try await waitForRequestCount(1)
        let second = Task { try await service.sendCard(delivery) }
        await Task.yield()
        BotHTTPProtocol.state.release(token)
        _ = try await first.value
        _ = try await second.value
        #expect(BotHTTPProtocol.state.requests().count == 3)
        await service.close()
    }

    @Test(arguments: [
        #"{"code":0,"data":{"message_id":"om_x","chat_id":"oc_x","sender":{"id":"cli_other","id_type":"app_id","sender_type":"app","tenant_key":"tenant_synthetic"}}}"#,
        #"{"code":0,"data":{"message_id":"om_x","chat_id":"oc_x","sender":{"id":"cli_synthetic","id_type":"open_id","sender_type":"user","tenant_key":"tenant_synthetic"}}}"#,
        #"{"code":0,"data":{"message_id":"om_x","chat_id":"oc_x","sender":{"id":"cli_synthetic","id_type":"app_id","sender_type":"app"}}}"#,
        #"{"code":0,"data":{"message_id":"","chat_id":"oc_x","sender":{"id":"cli_synthetic","id_type":"app_id","sender_type":"app","tenant_key":""}}}"#,
        #"{"code":false,"data":{}}"#,
    ]) func anUnverifiedSendResponseCannotEstablishATenantBinding(_ body: String) async throws {
        let service = client([.response(200, token), .response(200, Data(body.utf8))])
        let delivery = try FeishuCardDelivery(cardJSON: card)
        await #expect(throws: FeishuBotFailure.deliveryUncertain) { try await service.sendCard(delivery) }
        #expect(BotHTTPProtocol.state.requests().count == 2)
        await service.close()
    }

    @Test(arguments: [
        #"{"code":0,"access_token":"x","token_type":"Bearer","expires_in":true,"scope":"im:message:send_as_bot"}"#,
        #"{"code":0,"access_token":"x","token_type":"Bearer","expires_in":0,"scope":"im:message:send_as_bot"}"#,
        #"{"code":0,"access_token":"x","token_type":"Bearer","expires_in":7201,"scope":"im:message:send_as_bot"}"#,
        #"{"code":0,"access_token":"x\r\nHeader: invalid","token_type":"Bearer","expires_in":100,"scope":"im:message:send_as_bot"}"#,
        #"{"code":0,"access_token":"x","token_type":"Bearer","expires_in":100}"#,
    ]) func invalidTokenMetadataCannotReachTheMessagingAPI(_ body: String) async throws {
        let service = client([.response(200, Data(body.utf8))])
        let delivery = try FeishuCardDelivery(cardJSON: card)
        await #expect(throws: FeishuBotFailure.invalidResponse) { try await service.sendCard(delivery) }
        #expect(BotHTTPProtocol.state.requests().count == 1)
        await service.close()
    }

    @Test func providerRejectionIsSanitizedAndNeverAutomaticallyRetried() async throws {
        let response = Data(#"{"code":230006,"msg":"synthetic-secret must never escape"}"#.utf8)
        let service = client([.response(200, token), .response(400, response)])
        let delivery = try FeishuCardDelivery(cardJSON: card)
        await #expect(throws: FeishuBotFailure.providerRejected(230006)) { try await service.sendCard(delivery) }
        #expect(BotHTTPProtocol.state.requests().count == 2)
        await service.close()
    }

    @Test func sendTransportFailureIsUncertainWhileAuthenticationFailureIsNotSent() async throws {
        let delivery = try FeishuCardDelivery(cardJSON: card)
        let authFailure = client([.offline])
        await #expect(throws: FeishuBotFailure.unavailable) { try await authFailure.sendCard(delivery) }
        #expect(BotHTTPProtocol.state.requests().count == 1)
        await authFailure.close()
        let sendFailure = client([.response(200, token), .offline])
        await #expect(throws: FeishuBotFailure.deliveryUncertain) { try await sendFailure.sendCard(delivery) }
        #expect(BotHTTPProtocol.state.requests().count == 2)
        await sendFailure.close()
    }

    @Test func oversizedSendResponsesRemainUncertainAndAreNotRetried() async throws {
        let service = client([.response(200, token), .response(200, Data(repeating: 32, count: 65_537))])
        let delivery = try FeishuCardDelivery(cardJSON: card)
        await #expect(throws: FeishuBotFailure.deliveryUncertain) { try await service.sendCard(delivery) }
        #expect(BotHTTPProtocol.state.requests().count == 2)
        await service.close()
    }

    @Test func invalidCardsAreRejectedBeforeAnyCredentialsAreRequested() throws {
        for data in [Data("[]".utf8), Data("null".utf8), Data("invalid".utf8), Data(repeating: 32, count: 28_001)] {
            #expect(throws: FeishuBotFailure.invalidRequest) { try FeishuCardDelivery(cardJSON: data) }
        }
    }

    @Test func cancelledAuthenticationWaiterCannotSendACard() async throws {
        let service = client([.held])
        let delivery = try FeishuCardDelivery(cardJSON: card)
        let sending = Task { try await service.sendCard(delivery) }
        try await waitForRequestCount(1)
        sending.cancel()
        BotHTTPProtocol.state.release(token)
        await #expect(throws: CancellationError.self) { try await sending.value }
        #expect(BotHTTPProtocol.state.requests().count == 1)
        await service.close()
    }

    @Test func disconnectRejectsNewAndInFlightDeliveries() async throws {
        let service = client([.held])
        let delivery = try FeishuCardDelivery(cardJSON: card)
        let sending = Task { try await service.sendCard(delivery) }
        try await waitForRequestCount(1)
        await service.close()
        do {
            _ = try await sending.value
            Issue.record("Disconnected authentication must not deliver a card")
        } catch {}
        await #expect(throws: FeishuBotFailure.disconnected) { try await service.sendCard(delivery) }
        #expect(BotHTTPProtocol.state.requests().count == 1)
    }

    @Test func anEstablishedTenantCannotChangeOnALaterSend() async throws {
        let changed = Data(#"{"code":0,"data":{"message_id":"om_next","chat_id":"oc_synthetic","sender":{"id":"cli_synthetic","id_type":"app_id","sender_type":"app","tenant_key":"tenant_other"}}}"#.utf8)
        let service = client([.response(200, token), .response(200, sent), .response(200, changed)])
        let delivery = try FeishuCardDelivery(cardJSON: card)
        _ = try await service.sendCard(delivery)
        await #expect(throws: FeishuBotFailure.deliveryUncertain) { try await service.sendCard(delivery) }
        await service.close()
    }

    @Test func authenticationTimeCountsAgainstTheReportedTokenLifetime() async throws {
        let service = client([.held])
        let delivery = try FeishuCardDelivery(cardJSON: card)
        let sending = Task { try await service.sendCard(delivery) }
        try await waitForRequestCount(1)
        BotHTTPProtocol.state.advance(7_200)
        BotHTTPProtocol.state.release(token)
        await #expect(throws: FeishuBotFailure.invalidResponse) { try await sending.value }
        #expect(BotHTTPProtocol.state.requests().count == 1)
        await service.close()
    }

    @Test func jwtSizedTokensAreNotTruncatedAndRemainOpaque() async throws {
        let value = String(repeating: "a", count: 5_000)
        let response = try JSONSerialization.data(withJSONObject: [
            "code": 0, "access_token": value, "token_type": "Bearer", "expires_in": 7200,
            "scope": "im:message:send_as_bot",
        ])
        let service = client([.response(200, response), .response(200, sent)])
        _ = try await service.sendCard(FeishuCardDelivery(cardJSON: card))
        #expect(BotHTTPProtocol.state.requests().last?.authorization == "Bearer " + value)
        await service.close()
    }

    @Test func oversizedAuthenticationResponsesNeverReachMessaging() async throws {
        let service = client([.response(200, Data(repeating: 32, count: 65_537))])
        let delivery = try FeishuCardDelivery(cardJSON: card)
        await #expect(throws: FeishuBotFailure.invalidResponse) { try await service.sendCard(delivery) }
        #expect(BotHTTPProtocol.state.requests().count == 1)
        await service.close()
    }

    @Test(arguments: [
        (401, FeishuBotFailure.authenticationRejected), (403, .permissionDenied),
        (429, .rateLimited), (503, .deliveryUncertain), (307, .deliveryUncertain),
    ]) func httpFailuresDoNotAutomaticallyRefreshOrResend(_ status: Int, _ expected: FeishuBotFailure) async throws {
        let service = client([.response(200, token), .response(status, Data("untrusted synthetic details".utf8))])
        let delivery = try FeishuCardDelivery(cardJSON: card)
        await #expect(throws: expected) { try await service.sendCard(delivery) }
        #expect(BotHTTPProtocol.state.requests().count == 2)
        await service.close()
    }

    @Test(arguments: [false, true]) func cancellingOrDisconnectingAnInFlightSendLeavesAnUncertainOutcome(_ disconnect: Bool) async throws {
        let service = client([.response(200, token), .held])
        let delivery = try FeishuCardDelivery(cardJSON: card)
        let sending = Task { try await service.sendCard(delivery) }
        try await waitForRequestCount(2)
        if disconnect { await service.close() } else { sending.cancel() }
        await #expect(throws: FeishuBotFailure.deliveryUncertain) { try await sending.value }
        #expect(BotHTTPProtocol.state.requests().count == 2)
        await service.close()
    }

    @Test(arguments: [200, 400]) func rejectedApplicationTokensAreDiscardedWithoutResendingTheCard(_ status: Int) async throws {
        let rejected = Data(#"{"code":99991663,"msg":"synthetic details"}"#.utf8)
        let service = client([.response(200, token), .response(status, rejected),
                              .response(200, token), .response(200, sent)])
        let first = try FeishuCardDelivery(cardJSON: card)
        await #expect(throws: FeishuBotFailure.providerRejected(99991663)) { try await service.sendCard(first) }
        #expect(BotHTTPProtocol.state.requests().count == 2)
        let next = try FeishuCardDelivery(cardJSON: card)
        _ = try await service.sendCard(next)
        let requests = BotHTTPProtocol.state.requests()
        #expect(requests.count == 4)
        #expect(requests[2].url.host == "accounts.feishu.cn")
        #expect(requests.last?.body["uuid"] == next.id.uuidString)
        await service.close()
    }

    @Test(arguments: [401, 400]) func rejectionOfAnOlderTokenCannotDiscardANewerCachedToken(_ status: Int) async throws {
        let shortToken = Data(#"{"code":0,"access_token":"old-token","token_type":"Bearer","expires_in":100,"scope":"im:message:send_as_bot"}"#.utf8)
        let service = client([.response(200, shortToken), .response(200, sent), .held,
                              .response(200, token), .response(200, sent), .response(200, sent)])
        _ = try await service.sendCard(FeishuCardDelivery(cardJSON: card))
        let oldDelivery = try FeishuCardDelivery(cardJSON: card)
        let oldSend = Task { try await service.sendCard(oldDelivery) }
        try await waitForRequestCount(3)
        BotHTTPProtocol.state.advance(90)
        _ = try await service.sendCard(FeishuCardDelivery(cardJSON: card))
        // The held request has the old bearer; a later delivery has already refreshed it.
        let rejection = Data(#"{"code":99991663}"#.utf8)
        BotHTTPProtocol.state.release(status: status, rejection)
        do { _ = try await oldSend.value; Issue.record("The older request should fail") } catch {}
        _ = try await service.sendCard(FeishuCardDelivery(cardJSON: card))
        let requests = BotHTTPProtocol.state.requests()
        #expect(requests.count == 6)
        #expect(requests.last?.authorization == "Bearer synthetic-token")
        await service.close()
    }

    @Test func timeIncludingSystemSuspensionExpiresTheCachedToken() async throws {
        let shortToken = Data(#"{"code":0,"access_token":"old-token","token_type":"Bearer","expires_in":100,"scope":"im:message:send_as_bot"}"#.utf8)
        BotHTTPProtocol.state.reset([.response(200, shortToken), .response(200, sent),
                                     .response(200, token), .response(200, sent)])
        let origin = ContinuousClock.now
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPProtocol.self]
        let enrollment = FeishuEnrollment(applicationID: "cli_synthetic", scannedOwnerID: "ou_owner",
                                          secret: "synthetic-secret", isLark: false)
        let service = FeishuBotClient(enrollment: enrollment, configuration: configuration,
                                      now: { origin.advanced(by: .seconds(BotHTTPProtocol.state.now() - 1_000)) })
        _ = try await service.sendCard(FeishuCardDelivery(cardJSON: card))
        // Continuous time advances during sleep even when awake-time uptime does not.
        BotHTTPProtocol.state.advance(7_200)
        _ = try await service.sendCard(FeishuCardDelivery(cardJSON: card))
        let requests = BotHTTPProtocol.state.requests()
        #expect(requests.count == 4)
        #expect(requests.last?.authorization == "Bearer synthetic-token")
        await service.close()
    }

    @Test func discoversTheSocketOnlyFromTheAuthorizedOfficialApplicationHost() async throws {
        let endpoint = Data(#"{"code":0,"msg":"ok","data":{"URL":"wss://stream.synthetic.invalid/ws?device_id=d&service_id=42&ticket=synthetic","ClientConfig":{"PingInterval":120}}}"#.utf8)
        for isLark in [false, true] {
            let service = client([.response(200, endpoint)], isLark: isLark)
            let value = try await service.requestConnectionEndpoint()
            #expect(value.serviceID == 42)
            let requests = BotHTTPProtocol.state.requests()
            #expect(requests.count == 1)
            #expect(requests.first?.url.absoluteString == (isLark ? "https://open.larksuite.com/callback/ws/endpoint" : "https://open.feishu.cn/callback/ws/endpoint"))
            #expect(requests.first?.authorization == nil)
            #expect(requests.first?.body == ["AppID": "cli_synthetic", "AppSecret": "synthetic-secret"])
            await service.close()
            await #expect(throws: FeishuBotFailure.disconnected) { try await service.requestConnectionEndpoint() }
        }
    }
}
