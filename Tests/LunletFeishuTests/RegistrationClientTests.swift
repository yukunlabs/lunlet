// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.01, AC-01.02, AC-01.04, AC-01.05; US-14, AC-14.01, AC-14.03.
import Foundation
import Testing
import LunletCore
@testable import LunletFeishu

private final class HTTPReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Data)] = []
    private var time: TimeInterval = 1_000

    func set(_ replies: [(Int, Data)]) { lock.withLock { values = replies; time = 1_000 } }
    func next() -> (Int, Data)? { lock.withLock { values.isEmpty ? nil : values.removeFirst() } }
    func now() -> TimeInterval { lock.withLock { time } }
    func advance() { lock.withLock { time += 5 } }
}

private final class RegistrationHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let replies = HTTPReplies()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (status, data) = Self.replies.next(), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct RegistrationClientTests {
    private func client(_ replies: [(Int, Data)]) -> RegistrationClient {
        RegistrationHTTPProtocol.replies.set(replies)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RegistrationHTTPProtocol.self]
        return RegistrationClient(configuration: config, uptime: { RegistrationHTTPProtocol.replies.now() })
    }

    private let challenge = Data(#"{"device_code":"synthetic-device-code","verification_uri_complete":"https://open.feishu.cn/page/launcher?user_code=synthetic","interval":5,"expires_in":3600}"#.utf8)

    @Test func nativeHTTPReturnsTheValidatedOfficialChallenge() async throws {
        let service = client([(200, challenge)])
        let code = try await service.requestCode()
        #expect(code.verificationURL.host == "open.feishu.cn")
        #expect(code.expiresAtUptime == 4_600)
        #expect(await service.pollingDelay() == 5)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_DIAGNOSTICS"] == "1"))
    func localExpiryIsLoggedOnceWithoutUnchangedPollTrafficOrChallengeContents() async throws {
        let capture = try NativeDiagnosticCapture()
        let brief = Data(#"{"device_code":"synthetic-device-secret","verification_uri_complete":"https://open.feishu.cn/page/launcher?user_code=synthetic-secret","interval":5,"expires_in":5}"#.utf8)
        let service = client([(200, brief)])
        _ = try await service.requestCode()
        RegistrationHTTPProtocol.replies.advance()
        #expect(try await service.pollAuthorization() == .failed(.expired))
        #expect(try await service.pollAuthorization() == .failed(.expired))
        let entries = try await capture.read(until: "reason=timeout").filter { $0.contains("event=registration") }
        #expect(entries.filter { $0.contains("outcome=failed") && $0.contains("reason=timeout") }.count == 1)
        #expect(!entries.contains { $0.contains("synthetic-device-secret") || $0.contains("synthetic-secret") || $0.contains("https:") })
    }

    @Test func http400DenialIsARecoverableProviderOutcome() async throws {
        let service = client([(200, challenge), (400, Data(#"{"error":"access_denied"}"#.utf8))])
        _ = try await service.requestCode()
        RegistrationHTTPProtocol.replies.advance()
        #expect(try await service.pollAuthorization() == .failed(.denied))
        #expect(await service.pollingDelay() == nil)
    }

    @Test func oversizedResponsesCannotProduceAnAuthorizationCode() async {
        let service = client([(200, Data(repeating: 32, count: 65_537))])
        do {
            _ = try await service.requestCode()
            Issue.record("An oversized provider response must be rejected")
        } catch {
            #expect(error as? RegistrationFailure == .invalidResponse)
        }
    }

    @Test func networkErrorsHaveNoProviderPayloadOrCredentialDetails() async {
        let service = client([])
        do {
            _ = try await service.requestCode()
            Issue.record("An unavailable connection must not report authorization")
        } catch {
            #expect(error as? RegistrationFailure == .networkUnavailable)
        }
    }

    @Test func registrationCredentialsAreNotForwardedByRedirects() async throws {
        let policy = RedirectBlocker()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://accounts.feishu.cn/oauth/v1/app/registration")!)
        let destination = URLRequest(url: URL(string: "https://attacker.invalid/capture")!)
        let response = try #require(HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 307,
                                                   httpVersion: "HTTP/1.1", headerFields: nil))
        let forwarded = await withCheckedContinuation { continuation in
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                              newRequest: destination) { continuation.resume(returning: $0) }
        }
        #expect(forwarded == nil)
    }

    @Test func anAlreadyCancelledCallerCannotReplaceTheCurrentRegistration() async throws {
        let service = client([(200, challenge)])
        _ = try await service.requestCode()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await service.requestCode()
                Issue.record("An already cancelled caller must not begin another attempt")
            } catch {
                #expect(error is CancellationError)
            }
        }
        await cancelled.value
        #expect(await service.pollingDelay() == 5)
    }
}
