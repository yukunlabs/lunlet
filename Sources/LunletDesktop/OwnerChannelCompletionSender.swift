// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.03, AC-20.05, AC-20.06; US-12, AC-12.02, AC-12.04.
// Refs: US-14, AC-14.01, AC-14.03; US-36, AC-36.01, AC-36.02, AC-36.03, AC-36.04; US-05, AC-05.09.
import LunletCore
import LunletMessaging

/// The notification coordinator owns this sender. With an input adapter, eligible Codex completions carry a
/// reply affordance and the reply service takes the owner's replies through the continuation gates; without
/// one, every notice is notification-only and grants no session-input authority.
actor OwnerChannelCompletionSender: CompletionNotificationSending {
    private let enrollment: BotEnrollment
    private let client: any ChannelReplyClient
    private let replies: BotReplyService?
    private var closed = false
    init(enrollment: BotEnrollment, client: (any ChannelReplyClient)? = nil, dispatch: BotReplyDispatch? = nil) {
        self.enrollment = enrollment
        let client = client ?? BotClientFactory.client(enrollment.credentials)
        self.client = client
        replies = dispatch.map { BotReplyService(client: client, binding: enrollment.binding, dispatch: $0) }
    }
    func checkAuthorization() async throws {
        guard !closed else { throw BotChannelFailure.canceled }
        let operation = DiagnosticOperation()
        DiagnosticLog.record(.authentication, component: component, outcome: .started, operation: operation)
        do {
            try await client.checkAuthorization(enrollment.binding)
            guard !closed else { throw BotChannelFailure.canceled }
            DiagnosticLog.record(.authentication, component: component, outcome: .completed, operation: operation)
        } catch {
            failure(.authentication, operation: operation, error: error)
            throw error
        }
    }
    func send(_ snapshot: SessionSnapshot) async throws {
        guard !closed else { throw BotChannelFailure.canceled }
        let operation = DiagnosticOperation()
        DiagnosticLog.record(.cardDelivery, component: component, outcome: .started, operation: operation)
        let control = await replies?.prepareReply(for: snapshot)
        do {
            let receipt = try await client.sendCompletion(snapshot, binding: enrollment.binding, reply: control.map { _ in .open })
            guard !closed else { throw BotChannelFailure.canceled }
            if let control { await replies?.bindReply(control, receipt: receipt, snapshot: snapshot) }
            DiagnosticLog.record(.cardDelivery, component: component, outcome: .completed, operation: operation)
        } catch {
            // An unsent or uncertain notice never keeps a usable control.
            if let control { await replies?.withdrawReply(control) }
            failure(.cardDelivery, operation: operation, error: error)
            throw error
        }
    }
    /// Observations and lock changes reach the reply service in caller order; a task per call could reorder them.
    nonisolated func observe(_ snapshot: SessionSnapshot) {
        guard snapshot.provider == .codex, snapshot.parentSessionID == nil else { return }
        replies?.observe(snapshot)
    }
    /// The reply window follows the lock state (AC-05.09).
    nonisolated func lockChanged(_ locked: Bool) { replies?.setReplyWindow(locked) }
    func close() async {
        guard !closed else { return }
        closed = true
        await replies?.close()
        await client.close()
    }
    private var component: DiagnosticComponent { enrollment.binding.channel == .slack ? .slack : .telegram }
    private func failure(_ event: DiagnosticEvent, operation: DiagnosticOperation, error: any Error) {
        let reason: DiagnosticReason
        switch error as? BotChannelFailure {
        case .unauthorized: reason = .authentication
        case .permissionDenied: reason = .permission
        case .rateLimited: reason = .rateLimit
        case .invalidResponse, .identityMismatch: reason = .invalidResponse
        default: reason = .network
        }
        DiagnosticLog.record(event, component: component,
            outcome: closed || Task.isCancelled ? .cancelled : .failed, operation: operation, reason: reason)
    }
}
