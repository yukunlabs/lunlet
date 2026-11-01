// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.01, AC-01.02, AC-01.03, AC-01.04, AC-01.05, AC-01.07.
import Foundation
import Testing
import zlib
@testable import LunletFeishu

private let challenge = Data(#"{"device_code":"synthetic-device-code","verification_uri_complete":"https://open.feishu.cn/page/launcher?user_code=synthetic-user-code","interval":5,"expires_in":3600}"#.utf8)
private let enrollment = Data(#"{"client_id":"cli_synthetic","client_secret":"synthetic-secret","user_info":{"open_id":"ou_synthetic","tenant_brand":"feishu"}}"#.utf8)

private func readyFlow() -> RegistrationFlow {
    let flow = RegistrationFlow()
    let request = flow.begin(now: 1_000)
    flow.receive(challenge, status: 200, requestID: request.id, now: 1_000)
    return flow
}

private func form(_ request: URLRequest) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
    return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

@Test func beginRequestsOnlyOfficialDeviceRegistrationAndOwnerIdentity() {
    let flow = RegistrationFlow()
    let request = flow.begin(now: 1_000).urlRequest
    #expect(request.url?.absoluteString == "https://accounts.feishu.cn/oauth/v1/app/registration")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    #expect(form(request) == ["action": "begin", "archetype": "PersonalAgent", "auth_method": "client_secret", "request_user_info": "open_id"])
}

@Test func verificationURLCarriesOnlyTheMinimalBotManifest() throws {
    let flow = readyFlow()
    guard case .awaitingAuthorization(let code) = flow.state else {
        Issue.record("A valid official challenge should be presented")
        return
    }
    let parts = try #require(URLComponents(url: code.verificationURL, resolvingAgainstBaseURL: false))
    let query = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    #expect(parts.host == "open.feishu.cn")
    #expect(query["createOnly"] == nil)
    #expect(query["user_code"] == "synthetic-user-code")
    let encoded = try #require(query["addons"])
    var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    let compressed = try #require(Data(base64Encoded: base64))
    var stream = z_stream()
    #expect(inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { inflateEnd(&stream) }
    var output = [UInt8](repeating: 0, count: 4_096)
    let result = compressed.withUnsafeBytes { input in
        output.withUnsafeMutableBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(input.count)
            stream.next_out = bytes.bindMemory(to: UInt8.self).baseAddress
            stream.avail_out = uInt(bytes.count)
            return inflate(&stream, Z_FINISH)
        }
    }
    #expect(result == Z_STREAM_END)
    let manifest = try #require(JSONSerialization.jsonObject(with: Data(output.prefix(Int(stream.total_out)))) as? NSDictionary)
    let expected: NSDictionary = ["preset": false, "scopes": ["tenant": ["im:message:send_as_bot"]], "callbacks": ["items": ["card.action.trigger"]]]
    #expect(manifest == expected)
    #expect(code.expiresAtUptime == 4_600)
    #expect(!String(describing: code).contains("synthetic-user-code"))
}


@Test func verificationURLAllowsExistingAppSelectionWithoutLosingTheChallenge() throws {
    let original = URL(string: "https://open.feishu.cn/page/launcher?user_code=synthetic&createOnly=true&createOnly=true")!
    let prepared = try RegistrationManifest.verificationURL(original)
    let items = try #require(URLComponents(url: prepared, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(!items.contains { $0.name == "createOnly" })
    #expect(items.filter { $0.name == "user_code" } == [URLQueryItem(name: "user_code", value: "synthetic")])
}

@Test func pollingHonorsProviderIntervalAndSlowdown() throws {
    let flow = readyFlow()
    #expect(flow.poll(now: 1_004) == nil)
    let request = try #require(flow.poll(now: 1_005))
    #expect(form(request.urlRequest) == ["action": "poll", "device_code": "synthetic-device-code"])
    #expect(flow.poll(now: 1_010) == nil)
    flow.receive(Data(#"{"error":"slow_down"}"#.utf8), status: 400, requestID: request.id, now: 1_005)
    #expect(flow.poll(now: 1_014) == nil)
    let slower = flow.poll(now: 1_015)
    #expect(slower != nil)
}

@Test func authorizationRetainsVerifiedOwnerWithoutExposingTheSecret() throws {
    let flow = readyFlow()
    let request = try #require(flow.poll(now: 1_005))
    flow.receive(enrollment, status: 200, requestID: request.id, now: 1_005)
    guard case .authorized(let result) = flow.state else {
        Issue.record("A provider response with an owner should complete registration")
        return
    }
    #expect(result.applicationID == "cli_synthetic")
    #expect(result.scannedOwnerID == "ou_synthetic")
    #expect(!String(describing: result).contains("synthetic-secret"))
    #expect(flow.poll(now: 1_010) == nil)
}

@Test func missingOwnerCannotAuthorizeMobileAccess() throws {
    let flow = readyFlow()
    let request = try #require(flow.poll(now: 1_005))
    flow.receive(Data(#"{"client_id":"cli_synthetic","client_secret":"synthetic-secret"}"#.utf8), status: 200, requestID: request.id, now: 1_005)
    #expect(flow.state == .failed(.unverifiedOwner))
}

@Test func deniedOrExpiredRegistrationDoesNotKeepPolling() throws {
    for (error, expected) in [("access_denied", RegistrationFailure.denied), ("expired_token", .expired)] {
        let flow = readyFlow()
        let request = try #require(flow.poll(now: 1_005))
        let data = try JSONSerialization.data(withJSONObject: ["error": error])
        flow.receive(data, status: 400, requestID: request.id, now: 1_005)
        #expect(flow.state == .failed(expected))
        #expect(flow.poll(now: 1_010) == nil)
    }
    let flow = readyFlow()
    #expect(flow.poll(now: 4_600) == nil)
    #expect(flow.state == .failed(.expired))
}

@Test func cancellationAndSupersededAttemptsIgnoreLateReplies() {
    let flow = RegistrationFlow()
    let old = flow.begin(now: 1_000)
    flow.cancel()
    flow.receive(challenge, status: 200, requestID: old.id, now: 1_001)
    #expect(flow.state == .cancelled)
    let fresh = flow.begin(now: 1_002)
    flow.receive(challenge, status: 200, requestID: old.id, now: 1_003)
    #expect(flow.state == .requestingCode)
    flow.receive(challenge, status: 200, requestID: fresh.id, now: 1_003)
    guard case .awaitingAuthorization = flow.state else {
        Issue.record("The current request should still complete")
        return
    }
}

@Test func untrustedVerificationLocationsAndMalformedLifetimesAreRejected() throws {
    for (url, expires) in [
        ("https://attacker.invalid/authorize", 3600),
        ("http://open.feishu.cn/page/launcher", 3600),
        ("https://credentials@open.feishu.cn/page/launcher", 3600),
        ("https://open.feishu.cn/page/launcher", 0),
    ] {
        let flow = RegistrationFlow()
        let request = flow.begin(now: 1_000)
        let data = try JSONSerialization.data(withJSONObject: ["device_code": "synthetic-device-code", "verification_uri_complete": url, "interval": 5, "expires_in": expires])
        flow.receive(data, status: 200, requestID: request.id, now: 1_000)
        #expect(flow.state == .failed(.invalidResponse))
    }
}

@Test func larkDetectionChangesOnlyToTheOfficialPollingOrigin() throws {
    let flow = readyFlow()
    let request = try #require(flow.poll(now: 1_005))
    flow.receive(Data(#"{"error":"authorization_pending","user_info":{"tenant_brand":"lark"}}"#.utf8),
                 status: 400, requestID: request.id, now: 1_005)
    let switched = try #require(flow.poll(now: 1_005))
    #expect(switched.urlRequest.url?.host == "accounts.larksuite.com")
    flow.receive(Data(#"{"client_id":"cli_synthetic","client_secret":"synthetic-secret","user_info":{"open_id":"ou_synthetic","tenant_brand":"lark"}}"#.utf8),
                 status: 200, requestID: switched.id, now: 1_006)
    guard case .authorized(let result) = flow.state else {
        Issue.record("The official domain switch should finish registration")
        return
    }
    #expect(result.isLark)
}

@Test func opaqueDeviceCodesCannotCreateAdditionalFormParameters() throws {
    let flow = RegistrationFlow()
    let request = flow.begin(now: 1_000)
    let response = try JSONSerialization.data(withJSONObject: [
        "device_code": "synthetic+device/code==&x",
        "verification_uri_complete": "https://open.feishu.cn/page/launcher?user_code=synthetic",
        "interval": 5, "expires_in": 3600,
    ])
    flow.receive(response, status: 200, requestID: request.id, now: 1_000)
    let poll = try #require(flow.poll(now: 1_005))
    let body = try #require(String(data: poll.urlRequest.httpBody ?? Data(), encoding: .utf8))
    #expect(body == "action=poll&device_code=synthetic%2Bdevice%2Fcode%3D%3D%26x")
}
