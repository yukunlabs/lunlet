// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-14, AC-14.01, AC-14.02, AC-14.03, AC-14.06.
// Refs: US-07, AC-07.02, AC-07.03, AC-07.04; US-08, AC-08.03;
// US-09, AC-09.02; US-10, AC-10.01, AC-10.02, AC-10.03, AC-10.04;
// US-11, AC-11.02, AC-11.03, AC-11.04, AC-11.05, AC-11.06;
// US-12, AC-12.01, AC-12.02, AC-12.03.
// Refs: US-05, AC-05.09.
import Foundation

/// Issues single-use controls only for current, verified continuation contexts.
/// Confine this reference to one executor; it deliberately is not Sendable.
/// Times use monotonic elapsed time, never a device or callback wall clock. The only
/// wall-clock check is the provider's callback response window in `CardCallback`,
/// applied before an action reaches this gate.
public final class ContinuationGate {
    private struct Target: Hashable {
        let sessionID: UUID
        let turnID: String
        let requestID: String?
        let itemID: String?
    }

    private struct Binding: Hashable {
        let sessionID: UUID
        let connectionID: UUID
    }

    private struct ControlRecord {
        let control: ContinuationControl
        let issuedAt: TimeInterval
        let session: ObservedSession
        var receiptID: UUID?
    }

    private struct ReceiptRecord {
        var receipt: ActionReceipt
        let diagnostic = DiagnosticOperation()
    }

    private var access: MobileAccess?
    private var sessions: [UUID: ObservedSession] = [:]
    private var controls: [UUID: ControlRecord] = [:]
    private var receipts: [UUID: ReceiptRecord] = [:]
    private var callbacks: [String: UUID] = [:]
    // These three sets are never pruned: dropping a reservation would let a target dispatch
    // twice, and dropping an ended entry would let a stale binding revive. Growth is one small
    // entry per submitted target or ended binding for the gate's lifetime (one enrollment).
    private var reservations: Set<Target> = []
    private var endedConnections: Set<UUID> = []
    private var endedBindings: Set<Binding> = []

    /// Monotonic validity of an issued control; a closed reply window ends it sooner (AC-05.09).
    public static let controlLifetime: TimeInterval = 600

    public init() {}

    public func setAccess(_ access: MobileAccess) {
        guard self.access != access else { return }
        self.access = access
        invalidateAll()
    }

    /// Invalidates every issued control and observation even when access is unchanged,
    /// for example after a transport replacement. Target reservations are kept.
    public func invalidateAll() {
        controls.removeAll()
        callbacks.removeAll()
        sessions.removeAll()
    }

    public func observe(_ session: ObservedSession) {
        let binding = Binding(sessionID: session.sessionID, connectionID: session.connectionID)
        if session.liveness == .ended {
            endedConnections.insert(session.connectionID)
        }
        if session.phase == .ended {
            endedBindings.insert(binding)
        } else if endedConnections.contains(session.connectionID) || endedBindings.contains(binding) {
            return
        }
        sessions[session.sessionID] = session
        controls = controls.filter { _, record in
            record.receiptID != nil || record.session.sessionID != session.sessionID || record.session == session
        }
    }

    public func issueControl(for sessionID: UUID, now: TimeInterval) -> ContinuationControl? {
        guard now.isFinite, now >= 0 else { return nil }
        prune(at: now)
        guard accessIsReady, let session = sessions[sessionID], let target = target(for: session),
              !reservations.contains(target) else { return nil }
        let control = ContinuationControl(id: UUID(), expiresAt: now + Self.controlLifetime)
        guard control.expiresAt.isFinite else { return nil }
        controls[control.id] = ControlRecord(control: control, issuedAt: now, session: session)
        return control
    }

    /// Retires an issued control that never reached the owner, such as a card rendered without
    /// its reply input or a failed send. A control that already authorized an action keeps its
    /// receipt and its target reservation.
    public func withdraw(controlID: UUID) {
        guard let record = controls[controlID], record.receiptID == nil else { return }
        controls.removeValue(forKey: controlID)
    }

    /// Whether an action for this observation's exact target was already accepted.
    public func hasSubmitted(for session: ObservedSession) -> Bool {
        target(for: session).map(reservations.contains) ?? false
    }

    public func submit(controlID: UUID, callbackID: String, owner: FeishuOwner,
                       input: ContinuationInput, now: TimeInterval) -> ContinuationDecision {
        guard now.isFinite, now >= 0 else { return .rejected }
        prune(at: now)
        guard accessIsReady, owner == access?.owner,
              !callbackID.isEmpty, callbackID.utf8.count <= 256,
              var record = controls[controlID], now >= record.issuedAt,
              now < record.control.expiresAt else { return .rejected }
        if let priorControlID = callbacks[callbackID], priorControlID != controlID { return .rejected }
        if let receiptID = record.receiptID, let receipt = receipts[receiptID] {
            callbacks[callbackID] = controlID
            DiagnosticLog.record(.cardAction, component: .continuation, outcome: .duplicate, operation: receipt.diagnostic)
            return .duplicate(receipt.receipt)
        }
        guard sessions[record.session.sessionID] == record.session,
              let target = target(for: record.session), !reservations.contains(target),
              inputMatches(input, phase: record.session.phase) else { return .rejected }

        let receipt = ActionReceipt(id: UUID(), sessionID: target.sessionID, status: .received)
        // Reserve before returning a dispatchable action. Neither a retry nor a
        // second card for this target can dispatch again, even after a timeout.
        reservations.insert(target)
        record.receiptID = receipt.id
        controls[controlID] = record
        let receiptRecord = ReceiptRecord(receipt: receipt)
        receipts[receipt.id] = receiptRecord
        DiagnosticLog.record(.cardAction, component: .continuation, outcome: .received, operation: receiptRecord.diagnostic)
        callbacks[callbackID] = controlID
        return .accepted(AuthorizedContinuation(receipt: receipt, session: record.session, input: input))
    }

    public func updateReceipt(_ id: UUID, status: ActionStatus) {
        guard var record = receipts[id], record.receipt.status.canTransition(to: status) else { return }
        record.receipt.status = status
        receipts[id] = record
        let outcome: DiagnosticOutcome
        switch status {
        case .received: outcome = .received
        case .submitted: outcome = .submitted
        case .processing: outcome = .processing
        case .failed: outcome = .failed
        case .uncertain: outcome = .uncertain
        }
        DiagnosticLog.record(.receipt, component: .continuation, outcome: outcome, operation: record.diagnostic)
    }

    private var accessIsReady: Bool { access?.allowsRemoteInput == true }

    private func target(for session: ObservedSession) -> Target? {
        let binding = Binding(sessionID: session.sessionID, connectionID: session.connectionID)
        guard session.liveness == .alive, !endedConnections.contains(session.connectionID),
              !endedBindings.contains(binding) else { return nil }
        switch session.phase {
        case .idle(let turnID) where !turnID.isEmpty:
            return Target(sessionID: session.sessionID, turnID: turnID, requestID: nil, itemID: nil)
        case .question(let turnID, let requestID, let itemID, let questionIDs, .ordinary)
            where !turnID.isEmpty && !requestID.isEmpty && !itemID.isEmpty
                && !questionIDs.isEmpty && questionIDs.allSatisfy({ !$0.isEmpty })
                && Set(questionIDs).count == questionIDs.count:
            return Target(sessionID: session.sessionID, turnID: turnID, requestID: requestID, itemID: itemID)
        default:
            return nil
        }
    }

    private func inputMatches(_ input: ContinuationInput, phase: SessionPhase) -> Bool {
        switch (phase, input) {
        case (.idle, .followup(let text)):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 8_192
        case (.question(_, _, _, let questionIDs, .ordinary), .answer(let answers)):
            return Set(answers.keys) == Set(questionIDs) && answers.values.allSatisfy { values in
                !values.isEmpty && values.allSatisfy {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 8_192
                }
            }
        default:
            return false
        }
    }

    private func prune(at now: TimeInterval) {
        controls = controls.filter { now < $0.value.control.expiresAt }
        let activeReceiptIDs = Set(controls.values.compactMap(\.receiptID))
        receipts = receipts.filter { activeReceiptIDs.contains($0.key) }
        callbacks = callbacks.filter { controls[$0.value] != nil }
    }
}
