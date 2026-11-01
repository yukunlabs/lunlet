// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-22, AC-22.01, AC-22.02; US-24, AC-24.02.
// Refs: US-01, AC-01.05, AC-01.08; US-05, AC-05.04, AC-05.05, AC-05.06.
// Refs: US-06, AC-06.01, AC-06.02, AC-06.05; US-12, AC-12.02, AC-12.04; US-14, AC-14.01, AC-14.03.
// Refs: US-05, AC-05.09.
import Combine
import Foundation
import LunletCore

/// A provider-neutral delivery seam; each provider supplies its own sender.
protocol CompletionNotificationSending: Sendable {
    func checkAuthorization() async throws
    func send(_ snapshot: SessionSnapshot) async throws
    func close() async
    /// Every received snapshot, in observation order, for a sender whose cards may carry reply controls.
    func observe(_ snapshot: SessionSnapshot)
    /// The confirmed lock state when the sender is configured and whenever it changes (AC-05.09).
    func lockChanged(_ locked: Bool)
}
extension CompletionNotificationSending {
    func observe(_ snapshot: SessionSnapshot) {}
    func lockChanged(_ locked: Bool) {}
}

enum CompletionAuthorizationCheck: Equatable {
    case unavailable, notChecked, checking, accepted, failed
    var explanation: String {
        switch self {
        case .unavailable: "Authorization check unavailable"
        case .notChecked: "Saved credentials have not been checked"
        case .checking: "Checking authorization…"
        case .accepted: "Credentials accepted · Delivery still requires a receipt"
        case .failed: "Check internet access and bot permissions, then try again"
        }
    }
}

enum CompletionDeliveryStatus: Equatable {
    case unavailable, ready, sending, delivered, failed
    var symbol: String {
        switch self {
        case .unavailable: "link.badge.plus"
        case .ready: "bell"
        case .sending: "arrow.triangle.2.circlepath"
        case .delivered: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }
    var explanation: String {
        switch self {
        case .unavailable: "Connect your bot"
        case .ready: "Authorized · Completion notifications ready when locked"
        case .sending: "Sending notification"
        case .delivered: "Last notification delivered · Mobile input unavailable"
        case .failed: "Notification failed or delivery is unconfirmed · Check connection and authorization"
        }
    }
}

/// Notification wiring. It grants no callback or local-input authority itself: a sender whose
/// cards can carry reply controls receives observations and lock changes in order and enforces
/// its own gates. Views observe delivery and authorization state directly for the selected channel.
@MainActor final class LockedCompletionNotifications: ObservableObject {
    private struct Completion: Hashable { let session: UUID; let connection: UUID; let turn: String }
    /// Completions are only ever the latest turn of an incrementally read binding,
    /// so remembering the most recent ones is enough to suppress duplicates.
    private static let retainedCompletions = 1024
    private let isLocked: @MainActor () -> Bool?
    private let power: any IdleSleepControlling
    private var sender: (any CompletionNotificationSending)?
    private var seen: Set<Completion> = []
    private var seenOrder: [Completion] = []
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var cleanup: [UUID: Task<Void, Never>] = [:]
    private var checking: Task<Void, Never>?
    private var senderRevision = UUID()
    @Published private(set) var authorizationCheck: CompletionAuthorizationCheck = .unavailable
    private var generation = UUID()
    /// The lock state last reported to the current sender.
    private var reportedLock: Bool?
    private var closed = false
    private var monitor: DisplayStateMonitor?
    @Published private(set) var status: CompletionDeliveryStatus = .unavailable

    convenience init() {
        self.init(isLocked: { SystemDisplayState.isLocked }, power: IdleSleepAssertion(reason: "Lunlet locked completion notifications"),
                  checksOnConfigure: true)
        monitor = DisplayStateMonitor { [weak self] in self?.refreshLockState() }
    }
    /// Validates a newly configured sender once, so saved or new credentials never sit unchecked.
    private let checksOnConfigure: Bool
    init(isLocked: @escaping @MainActor () -> Bool?, power: any IdleSleepControlling, checksOnConfigure: Bool = false) {
        self.isLocked = isLocked; self.power = power; self.checksOnConfigure = checksOnConfigure
    }
    func configure(sender next: (any CompletionNotificationSending)?) {
        guard !closed else { return }
        generation = UUID()
        senderRevision = UUID()
        let previousCheck = checking
        previousCheck?.cancel(); checking = nil
        for task in pending.values { task.cancel() }
        if let sender {
            let work = Array(pending.values), id = UUID()
            // Finished cleanup removes itself; shutdown still awaits any that remain.
            cleanup[id] = Task { [weak self] in
                await sender.close(); await previousCheck?.value; for task in work { await task.value }
                self?.cleanup.removeValue(forKey: id)
            }
        }
        pending.removeAll(); sender = next; reportedLock = nil
        authorizationCheck = next == nil ? .unavailable : .notChecked
        status = next == nil ? .unavailable : .ready
        refreshLockState()
        // One identity check, no message and no retry: right after authorizing, at launch and on channel changes.
        if checksOnConfigure, next != nil { checkAuthorization() }
    }
    func checkAuthorization() {
        guard !closed, checking == nil, let sender else { return }
        let current = senderRevision
        authorizationCheck = .checking
        checking = Task { [weak self] in
            guard let self else { return }
            defer { if self.senderRevision == current { self.checking = nil } }
            do {
                try await sender.checkAuthorization()
                guard !self.closed, self.senderRevision == current, !Task.isCancelled else { return }
                self.authorizationCheck = .accepted
            } catch {
                guard !self.closed, self.senderRevision == current, !Task.isCancelled else { return }
                self.authorizationCheck = .failed
            }
        }
    }

    /// Reads the lock state once, applies it, and returns whether the Mac is confirmed locked.
    @discardableResult func refreshLockState() -> Bool {
        guard !closed else { return false }
        let locked = isLocked() == true
        // Unlocking ends every card's reply window; unknown lock state never opens one.
        if reportedLock != locked, let sender { reportedLock = locked; sender.lockChanged(locked) }
        if !locked {
            generation = UUID()
            for task in pending.values { task.cancel() }
            if status == .sending { status = sender == nil ? .unavailable : .ready }
        }
        do { try power.setEnabled(sender != nil && locked) }
        catch { status = .failed }
        return locked
    }
    func receive(_ snapshot: SessionSnapshot, baseline: Bool) {
        guard !closed else { return }
        let locked = refreshLockState()
        // Ordered before any send this snapshot schedules, so a reply check sees it first.
        sender?.observe(snapshot)
        guard snapshot.hasConfirmedActivity,
              case .idle(let turn) = snapshot.observation.phase, !turn.isEmpty else { return }
        let key = Completion(session: snapshot.observation.sessionID, connection: snapshot.observation.connectionID, turn: turn)
        guard markSeen(key), !baseline, locked, let sender else { return }
        let id = UUID(), current = generation
        status = .sending
        pending[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.pending.removeValue(forKey: id) }
            // The lock may change before the task starts; read it again before sending.
            let locked = self.refreshLockState()
            guard !self.closed, self.generation == current, locked, !Task.isCancelled else { return }
            do {
                try await sender.send(snapshot)
                guard !self.closed, self.generation == current, !Task.isCancelled else { return }
                self.status = .delivered
            } catch {
                guard !self.closed, self.generation == current, !Task.isCancelled else { return }
                self.status = .failed
                // Provider senders log allowlisted details; an uncertain mutation
                // is never retried automatically and no snapshot is logged here.
            }
        }
    }
    /// Records a completion as handled, including baseline and unlocked ones, so it is never sent later.
    private func markSeen(_ key: Completion) -> Bool {
        guard seen.insert(key).inserted else { return false }
        seenOrder.append(key)
        if seenOrder.count > Self.retainedCompletions {
            let evicted = seenOrder.count - Self.retainedCompletions
            for old in seenOrder.prefix(evicted) { seen.remove(old) }
            seenOrder.removeFirst(evicted)
        }
        return true
    }
    /// Resource bounds for long-running sessions; neither count is user-facing state.
    var retainedCompletionCount: Int { seen.count }
    var pendingCleanupCount: Int { cleanup.count }
    func shutdown() async {
        guard !closed else { return }
        configure(sender: nil)
        closed = true; monitor = nil
        for task in Array(cleanup.values) { await task.value }
        cleanup.removeAll(); seen.removeAll(); seenOrder.removeAll()
    }
}
