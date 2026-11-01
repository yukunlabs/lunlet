// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-05, AC-05.01, AC-05.02, AC-05.03; US-06, AC-06.01, AC-06.05.
// Refs: US-07, AC-07.02, AC-07.03, AC-07.04; US-08, AC-08.01, AC-08.03, AC-08.04.
// Refs: US-10, AC-10.01, AC-10.03, AC-10.04; US-11, AC-11.01, AC-11.02, AC-11.03.
// Refs: US-12, AC-12.01, AC-12.02, AC-12.03, AC-12.04.
// Refs: US-05, AC-05.08, AC-05.09; US-08, AC-08.05; US-09, AC-09.03.
import Foundation
import LunletCore

public protocol FeishuCardSending: Sendable {
    func sendCard(_ delivery: FeishuCardDelivery, owner: FeishuOwner) async throws -> FeishuMessageReceipt
    /// Replaces a sent card's content; a sender that cannot update cards throws, and callers fall back to a new card.
    func updateCard(_ delivery: FeishuCardDelivery, messageID: String, owner: FeishuOwner) async throws
    func close() async
}

public extension FeishuCardSending {
    func updateCard(_ delivery: FeishuCardDelivery, messageID: String, owner: FeishuOwner) async throws {
        throw FeishuBotFailure.unavailable
    }
}
extension FeishuBotClient: FeishuCardSending {}

/// Publishes only verified current snapshots. Its caller must establish the owner,
/// callback configuration, and adapter readiness; an open socket alone is insufficient.
/// The reply window (a confirmed locked Mac, AC-05.09) accepts replies only on cards issued
/// through `prepareReply`; it never publishes state cards the way full Away Mode does.
public actor MobileCoordinator {
    private struct Binding: Hashable { let session: UUID; let connection: UUID }
    public let router: CardActionRouter
    public private(set) var awayMode = false
    public private(set) var replyWindow = false
    public private(set) var remoteInput = true
    public private(set) var canEnableAway = false
    private let sender: any FeishuCardSending
    private let onAction: @Sendable (FeishuSocketAction) -> Void
    private var owner: FeishuOwner?
    private var connectionID: UUID?
    private var callbacksVerified = false
    private var adapterAvailable = false
    private var closed = false
    private var revision: UInt64 = 0
    private var epoch = UUID()
    private var snapshots: [UUID: SessionSnapshot] = [:]
    // Never pruned for the coordinator's lifetime, so an ended binding cannot be republished;
    // growth is one entry per ended session or connection.
    private var endedBindings: Set<Binding> = []
    private var endedConnections: Set<UUID> = []
    private var validated: Set<UUID> = []
    private var lastPublished: [UUID: SessionSnapshot] = [:]
    private var publications: [UUID: Task<Void, Never>] = [:]
    private var latestPublication: [UUID: UUID] = [:]
    private var closing: Task<Void, Never>?

    public init(sender: any FeishuCardSending, onAction: @escaping @Sendable (FeishuSocketAction) -> Void) {
        self.sender = sender; self.onAction = onAction; router = CardActionRouter()
    }
    init(sender: any FeishuCardSending, router: CardActionRouter,
         onAction: @escaping @Sendable (FeishuSocketAction) -> Void) {
        self.sender = sender; self.router = router; self.onAction = onAction
    }

    public func configure(owner: FeishuOwner?, connectionID: UUID?, callbacksVerified: Bool, adapterAvailable: Bool) async {
        guard !closed, self.owner != owner || self.connectionID != connectionID
            || self.callbacksVerified != callbacksVerified || self.adapterAvailable != adapterAvailable else { return }
        self.owner = owner; self.connectionID = connectionID
        self.callbacksVerified = callbacksVerified; self.adapterAvailable = adapterAvailable
        canEnableAway = owner?.isComplete == true && connectionID != nil && callbacksVerified && adapterAvailable
        invalidate(revalidate: true)
        await synchronize()
    }

    @discardableResult public func setAwayMode(_ enabled: Bool) async -> Bool {
        guard !closed, !enabled || canEnableAway else { return false }
        guard awayMode != enabled else { return true }
        awayMode = enabled
        invalidate(revalidate: !enabled)
        let current = epoch
        await synchronize()
        guard epoch == current, !closed else { return false }
        if enabled { for snapshot in snapshots.values { schedule(snapshot) } }
        return true
    }

    public func setRemoteInput(_ enabled: Bool) async {
        guard !closed, remoteInput != enabled else { return }
        remoteInput = enabled
        invalidate(revalidate: true)
        await synchronize()
    }

    /// Opens while the Mac is confirmed locked and closes on unlock; closing revokes every issued
    /// reply control with an accurate reason (AC-05.09).
    public func setReplyWindow(_ open: Bool) async {
        guard !closed, replyWindow != open else { return }
        replyWindow = open
        invalidate(revalidate: !open)
        await synchronize()
    }

    /// Issues one single-use reply capability for this exact, latest, verified completed turn.
    public func prepareReply(for snapshot: SessionSnapshot) async -> FeishuReplyCapability? {
        let session = snapshot.observation.sessionID
        guard !closed, replyWindow, canEnableAway, remoteInput, adapterAvailable, validated.contains(session),
              snapshots[session] == snapshot, snapshot.observation.liveness == .alive, !snapshot.isEnded,
              case .idle(let turn) = snapshot.observation.phase, !turn.isEmpty,
              SessionNotice.prepare(snapshot).allowsFollowup else { return nil }
        let current = epoch
        guard let control = await router.prepare(sessionID: session, form: .followup(field: FeishuReplyCapability.fieldName))
        else { return nil }
        guard current == epoch, snapshots[session] == snapshot, !closed else {
            await router.withdraw(controlID: control.id)
            return nil
        }
        return FeishuReplyCapability(token: control.id, sessionID: session, turnID: turn,
                                     expiresAt: Date(timeIntervalSinceNow: ContinuationGate.controlLifetime))
    }

    /// Binds the delivered card to its authenticated send receipt; false means it takes no replies.
    public func bindReply(_ capability: FeishuReplyCapability, receipt: FeishuMessageReceipt) async -> Bool {
        guard !closed else { return false }
        return await router.bind(controlID: capability.token, receipt: receipt)
    }

    /// Retires a capability whose card was not sent or carried no reply input.
    public func withdrawReply(_ capability: FeishuReplyCapability) async {
        await router.withdraw(controlID: capability.token)
    }

    /// Why an accepted action may no longer be submitted, checked right before input is handed
    /// to the session; nil means access, connection and observation are all still current.
    public func recheck(_ action: FeishuSocketAction) -> ContinuationRefusal? {
        guard !closed else { return .unverified }
        guard awayMode || replyWindow else { return .replyWindowClosed }
        guard remoteInput else { return .repliesTurnedOff }
        guard canEnableAway, adapterAvailable, connectionID == action.connectionID else { return .connectionReplaced }
        let issued = action.continuation.session, current = snapshots[issued.sessionID]?.observation
        guard validated.contains(issued.sessionID), current == issued else {
            return current == issued ? .unverified : ContinuationRefusal.classify(issued: issued, current: current)
        }
        return nil
    }

    public func updateReceipt(_ id: UUID, status: ActionStatus) async {
        await router.updateReceipt(id, status: status)
    }

    public func observe(_ snapshot: SessionSnapshot) async {
        guard !closed else { return }
        let observation = snapshot.observation, id = observation.sessionID
        let binding = Binding(session: id, connection: observation.connectionID)
        let ended = observation.isEnded
        guard ended || (!endedBindings.contains(binding) && !endedConnections.contains(observation.connectionID)) else { return }
        if ended { endedBindings.insert(binding) }
        if observation.liveness == .ended { endedConnections.insert(observation.connectionID) }
        if snapshots[id] != snapshot, let previous = latestPublication.removeValue(forKey: id) { publications[previous]?.cancel() }
        snapshots[id] = snapshot
        if observation.liveness == .alive && !ended { validated.insert(id) } else { validated.remove(id) }
        revision += 1
        let current = epoch
        await synchronize()
        guard current == epoch, snapshots[id] == snapshot else { return }
        schedule(snapshot)
    }

    /// Called only for actions emitted by the authenticated socket. Claim and recheck
    /// before invoking the adapter; the adapter must also verify its live CLI binding.
    public func receive(_ action: FeishuSocketAction) async {
        if await claim(action) { onAction(action) }
    }

    /// Claims an action once for the caller's own handoff; false leaves nothing to dispatch.
    public func claim(_ action: FeishuSocketAction) async -> Bool {
        let current = epoch
        guard accepts(action), await router.claim(action.continuation, connectionID: action.connectionID) else { return false }
        guard current == epoch, accepts(action) else {
            await router.updateReceipt(action.continuation.receipt.id, status: .failed)
            return false
        }
        return true
    }

    public func close() async {
        if let closing { await closing.value; return }
        closed = true; awayMode = false; replyWindow = false; canEnableAway = false
        invalidate(revalidate: true)
        let router = router, sender = sender, pending = Array(publications.values), revision = revision
        let task = Task {
            await router.synchronize(revision: revision,
                access: .init(owner: nil, connected: false, awayMode: false, inputEnabled: false),
                connectionID: nil, observations: [])
            await sender.close()
            for item in pending { await item.value }
        }
        closing = task
        await task.value
    }

    private var access: MobileAccess {
        .init(owner: owner, connected: canEnableAway, awayMode: awayMode || replyWindow,
              inputEnabled: remoteInput && adapterAvailable)
    }
    private func synchronize() async {
        await router.synchronize(revision: revision, access: access, connectionID: connectionID,
            observations: snapshots.values.map {
                let observation = $0.observation
                if validated.contains(observation.sessionID) || observation.isEnded { return observation }
                return observation.replacing(liveness: .unverified, phase: .unknown)
            })
    }
    private func invalidate(revalidate: Bool) {
        revision += 1; epoch = UUID()
        if revalidate { validated.removeAll() }
        lastPublished.removeAll(); latestPublication.removeAll()
        for task in publications.values { task.cancel() }
    }
    private func accepts(_ action: FeishuSocketAction) -> Bool {
        !closed && access.allowsRemoteInput && connectionID == action.connectionID
            && validated.contains(action.continuation.session.sessionID)
            && snapshots[action.continuation.session.sessionID]?.observation == action.continuation.session
    }
    private func publishable(_ snapshot: SessionSnapshot) -> Bool {
        guard !closed, awayMode, canEnableAway, validated.contains(snapshot.observation.sessionID),
              snapshot.observation.liveness == .alive else { return false }
        switch snapshot.observation.phase {
        case .idle, .question, .approval: return true
        default: return false
        }
    }
    private func schedule(_ snapshot: SessionSnapshot) {
        let session = snapshot.observation.sessionID
        guard publishable(snapshot), lastPublished[session] != snapshot else { return }
        if let previous = latestPublication[session] { publications[previous]?.cancel() }
        let id = UUID(), current = epoch
        latestPublication[session] = id; lastPublished[session] = snapshot
        publications[id] = Task { await publish(snapshot, id: id, epoch: current) }
    }
    private func publish(_ snapshot: SessionSnapshot, id: UUID, epoch current: UUID) async {
        defer { publications.removeValue(forKey: id) }
        let session = snapshot.observation.sessionID
        guard current == epoch, publishable(snapshot), snapshots[session] == snapshot, !Task.isCancelled else { return }
        do {
            var control: ContinuationControl?
            if remoteInput, let form = SessionCard.form(for: snapshot) {
                control = await router.prepare(sessionID: session, form: form)
            }
            guard current == epoch, publishable(snapshot), snapshots[session] == snapshot, !Task.isCancelled else { return }
            let rendered = try SessionCard.render(snapshot, control: control)
            guard let owner else { return }
            let receipt = try await sender.sendCard(rendered.delivery, owner: owner)
            guard current == epoch, latestPublication[session] == id, publishable(snapshot),
                  snapshots[session] == snapshot, !Task.isCancelled else { return }
            if let controlID = rendered.controlID { _ = await router.bind(controlID: controlID, receipt: receipt) }
        } catch {
            if !Task.isCancelled { FeishuDiagnostics.failure(.cardDelivery, operation: DiagnosticOperation(), error: error) }
            // An uncertain mutating send is never retried automatically.
        }
    }
}
