// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-14, AC-14.01, AC-14.02, AC-14.03, AC-14.06.
// Refs: US-07, AC-07.02, AC-07.03, AC-07.04; US-08, AC-08.01, AC-08.03.
// Refs: US-09, AC-09.02; US-10, AC-10.01, AC-10.02, AC-10.03, AC-10.04.
// Refs: US-11, AC-11.02, AC-11.03, AC-11.05; US-12, AC-12.01, AC-12.02, AC-12.03.
// Refs: US-05, AC-05.08, AC-05.09.
import Foundation
import LunletCore

/// A refused submission from the verified owner on a card bound to one session. It is reported
/// once per card so a receipt can name that session; it authorizes nothing.
public struct FeishuCardRefusal: Equatable, Sendable, CustomStringConvertible {
    public let sessionID: UUID
    public let reason: ContinuationRefusal
    /// The refused card's control, so its reply box can show the reason in place.
    public var controlID: UUID? = nil
    public var description: String { "Feishu card refusal (redacted)" }
}

public enum CardActionResult: Sendable, CustomStringConvertible {
    case received(AuthorizedContinuation), duplicate(ActionReceipt), unavailable, invalidInput
    /// The verified owner's bound card cannot be used; `report` is set the first time only.
    case refused(ContinuationRefusal, report: FeishuCardRefusal?)
    public var description: String { "Card action result (redacted)" }

    public func responseJSON() throws -> Data {
        let type: String
        let text: String
        switch self {
        case .received:
            type = "info"
            text = "Received. Waiting for Codex confirmation."
        case .duplicate(let receipt):
            type = receipt.status == .uncertain || receipt.status == .failed ? "warning" : "info"
            switch receipt.status {
            case .received: text = "Already received. Waiting for Codex confirmation."
            case .submitted: text = "Already submitted to Codex."
            case .processing: text = "Codex is processing this action."
            case .failed: text = "The earlier submission failed. Check your Mac."
            case .uncertain: text = "Submission outcome is unknown. Check your Mac before trying again."
            }
        case .unavailable:
            type = "warning"
            text = "This card is unavailable. Open a fresh card or return to your Mac."
        case .invalidInput:
            type = "error"
            text = "Check your input and submit again."
        case .refused(let reason, _):
            type = "warning"
            text = reason.explanation
        }
        return try JSONSerialization.data(withJSONObject: ["toast": ["type": type, "content": text]])
    }
}

/// Serializes local authorization; it never dispatches Codex or waits for network work.
public actor CardActionRouter {
    private struct Issued {
        let control: ContinuationControl
        let form: CardForm
        /// The exact observation the control was issued for.
        let session: ObservedSession
        var receipt: FeishuMessageReceipt?
        /// Set once the control can no longer authorize anything; a delivered card keeps its
        /// reason for a while so a later tap receives an accurate answer (AC-05.09).
        var revoked: ContinuationRefusal?
        var accepted: ActionReceipt?
        var reported = false
    }
    /// How long a revoked, delivered card keeps answering with its reason after its validity ends.
    private static let refusalRetention: TimeInterval = 600
    private static let retainedCards = 256
    private let gate = ContinuationGate()
    private let elapsed: @Sendable () -> TimeInterval
    private let wallTime: @Sendable () -> Date
    private var access: MobileAccess?
    private var connectionID: UUID?
    private var observations: [UUID: ObservedSession] = [:]
    private var issued: [UUID: Issued] = [:]
    private var synchronizedRevision: UInt64 = 0
    private struct PendingAction {
        let controlID: UUID
        let action: AuthorizedContinuation
    }
    private var pendingActions: [UUID: PendingAction] = [:]

    public init() {
        let origin = ContinuousClock.now
        self.init(elapsed: {
            let duration = origin.duration(to: ContinuousClock.now).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }, wallTime: { Date() })
    }

    init(elapsed: @escaping @Sendable () -> TimeInterval, wallTime: @escaping @Sendable () -> Date) {
        self.elapsed = elapsed
        self.wallTime = wallTime
    }

    /// Internal: production state arrives only through `synchronize`, whose revision
    /// ordering prevents a delayed call from restoring older access.
    func setAccess(_ access: MobileAccess, connectionID: UUID?) {
        let connection = access.connected ? connectionID : nil
        guard self.access != access || self.connectionID != connection else { return }
        let reason = Self.revocation(from: self.access, self.connectionID, to: access, connection)
        self.access = access
        self.connectionID = connection
        // Every issued control stops working; delivered cards remember why.
        for id in Array(issued.keys) where issued[id]?.revoked == nil { issued[id]?.revoked = reason }
        for id in Array(pendingActions.keys) { mark(id, .failed) }
        pendingActions.removeAll()
        observations.removeAll()
        // A replaced transport must invalidate the gate even if the flags are unchanged.
        gate.setAccess(access)
        gate.invalidateAll()
    }

    func observe(_ session: ObservedSession) {
        if observations[session.sessionID] != session { invalidatePending(sessionID: session.sessionID) }
        observations[session.sessionID] = session
        gate.observe(session)
    }

    /// One coordinator owns this revision sequence. Apply its complete state atomically;
    /// delayed cross-actor calls must never restore older access or observations.
    @discardableResult public func synchronize(revision: UInt64, access: MobileAccess, connectionID: UUID?,
                                               observations: [ObservedSession]) -> Bool {
        guard revision > synchronizedRevision,
              Set(observations.map(\.sessionID)).count == observations.count else { return false }
        synchronizedRevision = revision
        setAccess(access, connectionID: connectionID)
        let retained = Set(observations.map(\.sessionID))
        for old in self.observations.values where !retained.contains(old.sessionID) {
            invalidatePending(sessionID: old.sessionID)
            gate.observe(.init(sessionID: old.sessionID, connectionID: old.connectionID, liveness: .unverified, phase: .unknown))
        }
        for observation in observations { observe(observation) }
        self.observations = self.observations.filter { retained.contains($0.key) }
        return true
    }

    /// Claim an authenticated received action once, immediately before handing it to
    /// the session adapter. Access changes must invalidate queued socket actions too.
    public func claim(_ action: AuthorizedContinuation, connectionID: UUID) -> Bool {
        guard prune(at: elapsed()), self.connectionID == connectionID, access?.allowsRemoteInput == true,
              let pending = pendingActions[action.receipt.id], pending.action == action,
              let record = issued[pending.controlID], record.revoked == nil,
              observations[action.session.sessionID] == action.session else { return false }
        pendingActions.removeValue(forKey: action.receipt.id)
        return true
    }

    public func prepare(sessionID: UUID, form: CardForm) -> ContinuationControl? {
        let time = elapsed()
        guard prune(at: time), connectionID != nil, let observation = observations[sessionID],
              form.matches(observation.phase), let control = gate.issueControl(for: sessionID, now: time) else { return nil }
        issued[control.id] = Issued(control: control, form: form, session: observation)
        return control
    }

    /// Binds a delivered card to its authenticated send receipt and reports whether it can take
    /// replies. A control revoked while its card was in flight keeps the receipt only so a later
    /// tap receives an accurate refusal; it never becomes usable.
    public func bind(controlID: UUID, receipt: FeishuMessageReceipt) -> Bool {
        guard prune(at: elapsed()), let owner = access?.owner, var record = issued[controlID],
              receipt.applicationID == owner.applicationID, receipt.ownerID == owner.userID,
              receipt.tenantID == owner.tenantID, !receipt.messageID.isEmpty, !receipt.chatID.isEmpty,
              record.receipt == nil || record.receipt == receipt else { return false }
        record.receipt = receipt
        issued[controlID] = record
        return record.revoked == nil
    }

    /// Retires a control whose card never reached the owner or carried no reply input.
    public func withdraw(controlID: UUID) {
        guard let record = issued[controlID], record.receipt == nil, record.accepted == nil else { return }
        issued.removeValue(forKey: controlID)
        gate.withdraw(controlID: controlID)
    }

    /// Delivered cards still within their validity period, including revoked ones that should
    /// still receive an accurate refusal while the callback connection remains open.
    public func outstandingCards() -> Int {
        let time = elapsed()
        guard prune(at: time) else { return 0 }
        return issued.values.filter { $0.receipt != nil && time < $0.control.expiresAt }.count
    }

    public func handle(_ data: Data, connectionID: UUID) -> CardActionResult {
        let time = elapsed()
        guard prune(at: time), self.connectionID == connectionID, let access, let owner = access.owner,
              owner.isComplete else { return rejected() }
        let callback: CardCallback
        do { callback = try CardCallback.decodeFromLongConnection(data, owner: owner, now: wallTime()) }
        catch { return rejected((error as? CardCallbackFailure)?.diagnosticReason ?? .protocolViolation) }
        // Only the verified owner, on the exact message and chat this control was delivered in,
        // learns anything about it.
        guard let record = issued[callback.controlID], let receipt = record.receipt,
              callback.messageID == receipt.messageID, callback.chatID == receipt.chatID else { return rejected() }
        if record.revoked != nil {
            if let accepted = record.accepted { return .duplicate(accepted) }
            return refusal(for: callback.controlID)
        }
        guard access.allowsRemoteInput else { return rejected() }
        guard let input = record.form.input(from: callback.values) else {
            DiagnosticLog.record(.cardAction, component: .feishu, outcome: .rejected,
                                 operation: DiagnosticOperation(), reason: .invalidInput)
            return .invalidInput
        }
        switch gate.submit(controlID: callback.controlID, callbackID: callback.eventID,
                           owner: owner, input: input, now: time) {
        case .accepted(let action):
            pendingActions[action.receipt.id] = PendingAction(controlID: callback.controlID, action: action)
            issued[callback.controlID]?.accepted = action.receipt
            return .received(action)
        case .duplicate(let receipt): return .duplicate(receipt)
        case .rejected:
            let current = observations[record.session.sessionID]
            if current != record.session {
                issued[callback.controlID]?.revoked = ContinuationRefusal.classify(issued: record.session, current: current)
            } else if gate.hasSubmitted(for: record.session) {
                issued[callback.controlID]?.revoked = .alreadySent
            } else {
                // For example a provider event ID reused for another card: nothing to explain.
                return rejected()
            }
            return refusal(for: callback.controlID)
        }
    }

    /// Unauthenticated, malformed, foreign or unbound submissions all answer the same
    /// unavailable toast; only a fixed reason is logged.
    private func rejected(_ reason: DiagnosticReason? = nil) -> CardActionResult {
        DiagnosticLog.record(.cardAction, component: .feishu, outcome: .rejected, operation: DiagnosticOperation(),
                             reason: reason)
        return .unavailable
    }

    private func refusal(for controlID: UUID) -> CardActionResult {
        guard var record = issued[controlID], let reason = record.revoked else { return rejected() }
        let report = record.reported ? nil : FeishuCardRefusal(sessionID: record.session.sessionID, reason: reason,
                                                               controlID: controlID)
        record.reported = true
        issued[controlID] = record
        DiagnosticLog.record(.cardAction, component: .feishu, outcome: .rejected, operation: DiagnosticOperation(),
                             reason: reason == .sessionEnded ? .ended : reason == .expired ? .timeout : nil)
        return .refused(reason, report: report)
    }

    /// The control of the card whose reply was accepted as `receiptID`.
    public func controlID(forReceipt receiptID: UUID) -> UUID? {
        issued.first { $0.value.accepted?.id == receiptID }?.key
    }

    /// Why a delivered card's control can no longer authorize a reply, or nil while it still can.
    public func revocation(controlID: UUID) -> ContinuationRefusal? { issued[controlID]?.revoked }

    public func updateReceipt(_ id: UUID, status: ActionStatus) {
        mark(id, status)
        if status != .received { pendingActions.removeValue(forKey: id) }
    }

    public func connectionClosed(_ id: UUID) {
        guard connectionID == id, var access else { return }
        access.connected = false
        setAccess(access, connectionID: nil)
    }

    /// Updates the gate's receipt and the card's copy used for answers after revocation.
    private func mark(_ id: UUID, _ status: ActionStatus) {
        gate.updateReceipt(id, status: status)
        for (controlID, record) in issued where record.accepted?.id == id {
            if record.accepted?.status.canTransition(to: status) == true { issued[controlID]?.accepted?.status = status }
        }
    }

    private func invalidatePending(sessionID: UUID) {
        let receipts = pendingActions.filter { $0.value.action.session.sessionID == sessionID }.map(\.key)
        for id in receipts {
            // Not yet claimed means no adapter handoff occurred. Preserve the
            // consumed target reservation, but never revive this queued action.
            mark(id, .failed)
            pendingActions.removeValue(forKey: id)
        }
    }

    private static func revocation(from old: MobileAccess?, _ oldConnection: UUID?,
                                   to new: MobileAccess, _ newConnection: UUID?) -> ContinuationRefusal {
        guard let old, old.owner == new.owner else { return .unverified }
        if old.awayMode && !new.awayMode { return .replyWindowClosed }
        if old.inputEnabled && !new.inputEnabled { return .repliesTurnedOff }
        if oldConnection != newConnection { return .connectionReplaced }
        return .unverified
    }

    private func prune(at time: TimeInterval) -> Bool {
        guard time.isFinite, time >= 0 else { return false }
        for (id, record) in issued where record.revoked == nil && time >= record.control.expiresAt {
            issued[id]?.revoked = .expired
        }
        issued = issued.filter { _, record in
            time < record.control.expiresAt + (record.receipt == nil ? 0 : Self.refusalRetention)
        }
        if issued.count > Self.retainedCards {
            // Live controls stay; the oldest refusal records go first.
            let oldest = issued.filter { $0.value.revoked != nil }
                .sorted { $0.value.control.expiresAt < $1.value.control.expiresAt }
                .prefix(issued.count - Self.retainedCards).map(\.key)
            for id in oldest { issued.removeValue(forKey: id) }
        }
        for (id, pending) in pendingActions where issued[pending.controlID].map({ $0.revoked != nil }) ?? true {
            mark(id, .failed)
            pendingActions.removeValue(forKey: id)
        }
        return true
    }
}
