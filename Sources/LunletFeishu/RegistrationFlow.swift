// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.01, AC-01.02, AC-01.03, AC-01.04, AC-01.05, AC-01.08.
import Foundation
import CoreFoundation

public enum RegistrationFailure: Error, Equatable, Sendable {
    case invalidResponse, unverifiedOwner, denied, expired, networkUnavailable
}

public struct RegistrationCode: Equatable, Sendable, CustomStringConvertible {
    public let verificationURL: URL
    public let expiresAtUptime: TimeInterval
    public var description: String { "Feishu registration code (redacted)" }
}

public struct FeishuEnrollment: Equatable, Sendable, CustomStringConvertible {
    public let applicationID: String
    public let scannedOwnerID: String
    let secret: String
    public let isLark: Bool
    public var description: String { "Feishu enrollment (redacted)" }
}

public enum RegistrationState: Equatable, Sendable {
    case idle, requestingCode, cancelled
    case awaitingAuthorization(RegistrationCode)
    case authorized(FeishuEnrollment)
    case failed(RegistrationFailure)
}

public struct RegistrationRequest: Sendable, CustomStringConvertible {
    public let id: UUID
    public let urlRequest: URLRequest
    public var description: String { "Feishu registration request (redacted)" }
}

/// An in-memory protocol state machine confined to its owning executor.
/// Authorization is registration only, not a ready mobile-control connection.
public final class RegistrationFlow {
    private enum RequestKind { case begin, poll }
    private struct Outstanding {
        let id: UUID
        let kind: RequestKind
        let startedAt: TimeInterval
    }
    private struct Pending {
        let deviceCode: String
        let code: RegistrationCode
        var interval: TimeInterval
        var nextPollAt: TimeInterval
        var isLark = false
    }

    public private(set) var state: RegistrationState = .idle
    private(set) var attemptID = UUID()
    private var outstanding: Outstanding?
    private var pending: Pending?

    public init() {}

    public func begin(now: TimeInterval) -> RegistrationRequest {
        attemptID = UUID()
        pending = nil
        state = .requestingCode
        return request(kind: .begin, now: now, isLark: false, fields: [
            "action": "begin", "archetype": "PersonalAgent",
            "auth_method": "client_secret", "request_user_info": "open_id",
        ])
    }

    public func poll(now: TimeInterval) -> RegistrationRequest? {
        guard let pending, case .awaitingAuthorization = state else { return nil }
        guard now.isFinite, now >= 0 else { fail(.invalidResponse); return nil }
        guard now < pending.code.expiresAtUptime else { fail(.expired); return nil }
        guard outstanding == nil, now >= pending.nextPollAt else { return nil }
        return request(kind: .poll, now: now, isLark: pending.isLark,
                       fields: ["action": "poll", "device_code": pending.deviceCode])
    }

    @discardableResult
    public func receive(_ data: Data, status: Int, requestID: UUID, now: TimeInterval) -> Bool {
        guard let current = outstanding, current.id == requestID else { return false }
        outstanding = nil
        guard now.isFinite, now >= current.startedAt, data.count <= 65_536,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fail(.invalidResponse)
            return true
        }
        if status >= 500 { fail(.networkUnavailable); return true }
        if current.kind == .poll, let pending, now >= pending.code.expiresAtUptime {
            fail(.expired)
            return true
        }
        if current.kind == .poll, status == 200 || status == 400,
           let userInfo = body["user_info"] as? [String: Any], userInfo["tenant_brand"] as? String == "lark",
           var pending, !pending.isLark {
            pending.isLark = true
            pending.nextPollAt = now
            self.pending = pending
            return true
        }
        if let error = body["error"] as? String {
            switch error {
            case "access_denied": fail(.denied)
            case "expired_token": fail(.expired)
            case "authorization_pending" where current.kind == .poll:
                reschedule(now: now, slowDown: false)
            case "slow_down" where current.kind == .poll:
                reschedule(now: now, slowDown: true)
            default: fail(.invalidResponse)
            }
            return true
        }
        guard status == 200 else { fail(status == 403 ? .denied : .invalidResponse); return true }
        switch current.kind {
        case .begin:
            receiveChallenge(body, startedAt: current.startedAt, now: now)
        case .poll:
            receiveEnrollment(body, now: now)
        }
        return true
    }

    public func transportFailed(requestID: UUID, failure: RegistrationFailure = .networkUnavailable) {
        guard outstanding?.id == requestID else { return }
        fail(failure)
    }

    public func cancel() {
        attemptID = UUID()
        outstanding = nil
        pending = nil
        state = .cancelled
    }

    func pollingDelay(now: TimeInterval) -> TimeInterval? {
        guard let pending, case .awaitingAuthorization = state else { return nil }
        return max(0, min(pending.nextPollAt, pending.code.expiresAtUptime) - now)
    }

    private func request(kind: RequestKind, now: TimeInterval, isLark: Bool,
                         fields: [String: String]) -> RegistrationRequest {
        let host = isLark ? "accounts.larksuite.com" : "accounts.feishu.cn"
        var request = URLRequest(url: URL(string: "https://\(host)/oauth/v1/app/registration")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields.sorted { $0.key < $1.key }.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed)!
            return key + "=" + encoded.replacingOccurrences(of: "%20", with: "+")
        }.joined(separator: "&")
        request.httpBody = Data(body.utf8)
        let id = UUID()
        outstanding = Outstanding(id: id, kind: kind, startedAt: now)
        return RegistrationRequest(id: id, urlRequest: request)
    }

    private func receiveChallenge(_ body: [String: Any], startedAt: TimeInterval, now: TimeInterval) {
        guard let deviceCode = body["device_code"] as? String, !deviceCode.isEmpty,
              let location = body["verification_uri_complete"] as? String, let url = URL(string: location),
              let lifetime = integer(body["expires_in"]), lifetime > 0, lifetime <= 86_400,
              let interval = integer(body["interval"]), interval >= 1, interval <= lifetime,
              let verification = try? RegistrationManifest.verificationURL(url) else {
            fail(.invalidResponse)
            return
        }
        let deadline = startedAt + lifetime
        guard deadline.isFinite, now < deadline else { fail(.expired); return }
        let code = RegistrationCode(verificationURL: verification, expiresAtUptime: deadline)
        pending = Pending(deviceCode: deviceCode, code: code, interval: interval, nextPollAt: now + interval)
        state = .awaitingAuthorization(code)
    }

    private func receiveEnrollment(_ body: [String: Any], now: TimeInterval) {
        guard let pending else { fail(.invalidResponse); return }
        guard now < pending.code.expiresAtUptime else { fail(.expired); return }
        let userInfo = body["user_info"] as? [String: Any]
        guard let id = body["client_id"] as? String, !id.isEmpty,
              let secret = body["client_secret"] as? String, !secret.isEmpty else {
            fail(.invalidResponse)
            return
        }
        guard let owner = userInfo?["open_id"] as? String, !owner.isEmpty else {
            fail(.unverifiedOwner)
            return
        }
        state = .authorized(FeishuEnrollment(applicationID: id, scannedOwnerID: owner,
                                             secret: secret, isLark: pending.isLark))
        self.pending = nil
    }

    private func reschedule(now: TimeInterval, slowDown: Bool) {
        guard var pending else { fail(.invalidResponse); return }
        guard now < pending.code.expiresAtUptime else { fail(.expired); return }
        if slowDown { pending.interval += 5 }
        pending.nextPollAt = now + pending.interval
        self.pending = pending
    }

    private func integer(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        return number.isFinite && number.rounded(.towardZero) == number ? number : nil
    }

    private func fail(_ error: RegistrationFailure) {
        outstanding = nil
        pending = nil
        state = .failed(error)
    }
}
