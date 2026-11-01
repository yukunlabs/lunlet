// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-14, AC-14.01, AC-14.02, AC-14.03, AC-14.06.
import Foundation
import LunletCore

enum FeishuDiagnostics {
    static func failure(_ event: DiagnosticEvent, operation: DiagnosticOperation, error: any Error) {
        // Cancellation cannot prove that an already-started message was not delivered.
        if (error as? FeishuBotFailure) != .deliveryUncertain, error is CancellationError || Task.isCancelled {
            DiagnosticLog.record(event, component: .feishu, outcome: .cancelled, operation: operation)
            return
        }
        var reason: DiagnosticReason = .unknown
        var outcome: DiagnosticOutcome = .failed
        var code: Int?
        switch error {
        case let failure as FeishuBotFailure:
            switch failure {
            case .disconnected: reason = .ended
            case .invalidRequest: reason = .invalidInput
            case .invalidResponse: reason = .invalidResponse
            case .authenticationRejected: reason = .authentication
            case .permissionDenied: reason = .permission
            case .rateLimited: reason = .rateLimit
            case .unavailable: reason = .network
            case .deliveryUncertain: outcome = .uncertain
            case .providerRejected(let value): reason = .provider; code = value
            }
        case let failure as RegistrationFailure:
            switch failure {
            case .invalidResponse: reason = .invalidResponse
            case .unverifiedOwner: reason = .authentication
            case .denied: reason = .permission
            case .expired: reason = .timeout
            case .networkUnavailable: reason = .network
            }
        case let failure as FeishuSocketFailure:
            switch failure {
            case .closed: outcome = .stopped; reason = .ended
            case .unavailable: reason = .network
            case .invalidProtocol: reason = .protocolViolation
            }
        default: break // Never stringify an unknown error or provider body.
        }
        DiagnosticLog.record(event, component: .feishu, outcome: outcome,
                             operation: operation, reason: reason, code: code)
    }
}
