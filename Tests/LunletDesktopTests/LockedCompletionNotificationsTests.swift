// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-22, AC-22.01, AC-22.02, AC-22.03.
// Refs: US-05, AC-05.04, AC-05.05, AC-05.06; US-06, AC-06.01, AC-06.05; US-12, AC-12.02, AC-12.04.
// Refs: US-33, AC-33.05.
import Foundation
import Testing
import LunletCore
@testable import LunletDesktop

private actor CompletionSender: CompletionNotificationSending {
    private(set) var received: [SessionSnapshot] = []
    private(set) var closed = false
    private(set) var authorizationChecks = 0
    var fails = false
    func setFailure() { fails = true }
    func send(_ snapshot: SessionSnapshot) async throws {
        if fails { throw CancellationError() }
        received.append(snapshot)
    }
    func checkAuthorization() { authorizationChecks += 1 }
    func close() { closed = true }
}
private actor DelayedCompletionSender: CompletionNotificationSending {
    private(set) var started = false
    private(set) var cancelled = false
    private(set) var delivered = false
    func send(_ snapshot: SessionSnapshot) async throws {
        started = true
        do { try await Task.sleep(for: .seconds(10)); delivered = true }
        catch { cancelled = true; throw error }
    }
    func checkAuthorization() {}
    func close() {}
}
private actor HeldAuthorizationSender: CompletionNotificationSending {
    private(set) var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func checkAuthorization() async {
        started = true
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
    func send(_ snapshot: SessionSnapshot) {}
    func close() { release() }
}
private final class CompletionPower: IdleSleepControlling {
    var enabled = false
    func setEnabled(_ enabled: Bool) { self.enabled = enabled }
}
/// A main-actor lock reading that the test can change after the subject captures it.
@MainActor private final class LockState {
    var value: Bool?
    init(_ value: Bool?) { self.value = value }
}

@MainActor struct LockedCompletionNotificationsTests {
    private func snapshot(_ turn: String, session: UUID, connection: UUID, alive: Bool = true) -> SessionSnapshot {
        .init(observation: .init(sessionID: session, connectionID: connection,
            liveness: alive ? .alive : .unverified, phase: .idle(completedTurnID: turn)),
            project: "Synthetic", title: "Task", publicConclusion: "Checks completed.", turnID: turn)
    }
    @Test func runtimeCompletionCanNotifyWithoutClaimingOriginalCLIInput() async throws {
        let sender = CompletionSender(), subject = LockedCompletionNotifications(isLocked: { true }, power: CompletionPower())
        subject.configure(sender: sender)
        let id = UUID(), connection = UUID()
        let value = SessionSnapshot(observation: .init(sessionID: id, connectionID: connection, liveness: .unverified,
                  phase: .idle(completedTurnID: "runtime")), project: "Synthetic", title: "Runtime",
                  turnID: "runtime", activityConfirmed: true)
        subject.receive(value, baseline: false)
        let deadline = ContinuousClock.now + .seconds(2)
        while subject.status != .delivered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await sender.received == [value])
        #expect(!SessionNotice.prepare(value).allowsFollowup)
        await subject.shutdown()
    }

    // Refs: US-33, AC-33.05.
    @Test func claudeCompletionsAfterTheBaselineAreSentOnceAndIdentifyClaude() async throws {
        let sender = CompletionSender(), subject = LockedCompletionNotifications(isLocked: { true }, power: CompletionPower())
        subject.configure(sender: sender)
        let id = UUID(), connection = UUID()
        func claude(_ turn: String) -> SessionSnapshot {
            .init(observation: .init(sessionID: id, connectionID: connection, liveness: .unverified, phase: .idle(completedTurnID: turn)),
                  project: "Synthetic", turnID: turn, activityConfirmed: true, provider: .claude)
        }
        // Discovery and recovery snapshots are current state, never new completions.
        subject.receive(claude("earlier"), baseline: true)
        subject.receive(claude("earlier"), baseline: false)
        subject.receive(claude("live"), baseline: false)
        subject.receive(claude("live"), baseline: false)
        let deadline = ContinuousClock.now + .seconds(2)
        while subject.status != .delivered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await sender.received.map(\.turnID) == ["live"])
        let notice = SessionNotice.prepare(claude("live"))
        #expect(notice.agent == "Claude Code" && !notice.allowsFollowup && notice.questions.isEmpty)
        await subject.shutdown()
    }

    // A newly configured sender is checked once on its own, so saved or new credentials never sit unchecked;
    // nothing is sent and nothing retries.
    @Test func aConfiguredSenderIsCheckedOnceWithoutSendingAnything() async throws {
        let sender = CompletionSender()
        let subject = LockedCompletionNotifications(isLocked: { false }, power: CompletionPower(), checksOnConfigure: true)
        subject.configure(sender: sender)
        let deadline = ContinuousClock.now + .seconds(2)
        while subject.authorizationCheck != .accepted, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(subject.authorizationCheck == .accepted)
        let checks = await sender.authorizationChecks, received = await sender.received
        #expect(checks == 1 && received.isEmpty)
        subject.configure(sender: nil)
        #expect(subject.authorizationCheck == .unavailable)
        await subject.shutdown()
    }

    @Test func unlockDoesNotInvalidateAnIndependentAuthorizationCheck() async throws {
        let locked = LockState(true)
        let sender = HeldAuthorizationSender()
        let subject = LockedCompletionNotifications(isLocked: { locked.value }, power: CompletionPower())
        subject.configure(sender: sender)
        subject.checkAuthorization()
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await sender.started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await sender.started)
        locked.value = false; subject.refreshLockState()
        await sender.release()
        while subject.authorizationCheck == .checking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(subject.authorizationCheck == .accepted)
        #expect(subject.status == .ready)
        await subject.shutdown()
    }

    @Test func disconnectIgnoresAnAuthorizationResultFromThePreviousSender() async throws {
        let sender = HeldAuthorizationSender()
        let subject = LockedCompletionNotifications(isLocked: { false }, power: CompletionPower())
        subject.configure(sender: sender)
        subject.checkAuthorization()
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await sender.started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await sender.started)
        subject.configure(sender: nil)
        await subject.shutdown()
        #expect(subject.authorizationCheck == .unavailable)
        #expect(subject.status == .unavailable)
    }

    @Test func authorizationRecoveryNeverReplaysUncertainDeliveryOrClaimsItSucceeded() async throws {
        let sender = CompletionSender(); await sender.setFailure()
        let subject = LockedCompletionNotifications(isLocked: { true }, power: CompletionPower())
        subject.configure(sender: sender)
        let completion = snapshot("unconfirmed", session: UUID(), connection: UUID())
        subject.receive(completion, baseline: false)
        let deadline = ContinuousClock.now + .seconds(2)
        while subject.status != .failed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        subject.checkAuthorization()
        subject.checkAuthorization()
        while subject.authorizationCheck == .checking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(subject.authorizationCheck == .accepted)
        #expect(await sender.authorizationChecks == 1)
        #expect(subject.status == .failed)
        subject.receive(completion, baseline: false)
        #expect(await sender.received.isEmpty)
        subject.configure(sender: nil)
        #expect(subject.authorizationCheck == .unavailable)
        await subject.shutdown()
        subject.checkAuthorization()
        #expect(await sender.authorizationChecks == 1)
    }

    @Test func lockGatesNewCompletionWithoutReplayAndDisconnectReleasesPower() async throws {
        let locked = LockState(false)
        let sender = CompletionSender(), power = CompletionPower()
        let subject = LockedCompletionNotifications(isLocked: { locked.value }, power: power)
        subject.configure(sender: sender)
        let session = UUID(), connection = UUID()
        subject.receive(snapshot("unlocked", session: session, connection: connection), baseline: false)
        locked.value = true; subject.refreshLockState()
        #expect(power.enabled)
        subject.receive(snapshot("baseline", session: session, connection: connection), baseline: true)
        subject.receive(snapshot("baseline", session: session, connection: connection), baseline: false)
        subject.receive(snapshot("unknown", session: session, connection: connection, alive: false), baseline: false)
        let completion = snapshot("live", session: session, connection: connection)
        subject.receive(completion, baseline: false); subject.receive(completion, baseline: false)
        let deadline = ContinuousClock.now + .seconds(2)
        while subject.status != .delivered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await sender.received == [completion])
        locked.value = nil; subject.refreshLockState(); #expect(!power.enabled)
        subject.receive(snapshot("uncertain-lock", session: session, connection: connection), baseline: false)
        subject.configure(sender: nil)
        #expect(subject.status == .unavailable && !power.enabled)
        await subject.shutdown()
        #expect(await sender.closed)
    }
    @Test func unlockingCancelsPendingDeliveryAndDoesNotLeaveSendingState() async throws {
        let locked = LockState(true)
        let sender = DelayedCompletionSender()
        let subject = LockedCompletionNotifications(isLocked: { locked.value }, power: CompletionPower())
        subject.configure(sender: sender)
        let completion = snapshot("pending", session: UUID(), connection: UUID())
        subject.receive(completion, baseline: false)
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await sender.started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        locked.value = false; subject.refreshLockState()
        while !(await sender.cancelled), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await sender.cancelled)
        #expect(await !sender.delivered)
        #expect(subject.status == .ready)
        locked.value = true
        subject.receive(completion, baseline: false)
        #expect(subject.status == .ready)
        await subject.shutdown()
    }
    @Test func unlockBeforeDeliveryTaskStartsRestoresReadyWithoutSending() async throws {
        let locked = LockState(true)
        let sender = CompletionSender()
        let subject = LockedCompletionNotifications(isLocked: { locked.value }, power: CompletionPower())
        subject.configure(sender: sender)
        subject.receive(snapshot("scheduled", session: UUID(), connection: UUID()), baseline: false)
        locked.value = false
        let deadline = ContinuousClock.now + .seconds(2)
        while subject.status == .sending, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(subject.status == .ready)
        #expect(await sender.received.isEmpty)
        await subject.shutdown()
    }
    // AC-06.05, AC-12.04: long sessions keep bounded duplicate memory without resending recent work.
    @Test func completionMemoryStaysBoundedWithoutResendingRecentWork() async throws {
        let sender = CompletionSender()
        let subject = LockedCompletionNotifications(isLocked: { true }, power: CompletionPower())
        subject.configure(sender: sender)
        let session = UUID(), connection = UUID()
        for index in 0..<1_100 {
            subject.receive(snapshot("turn-\(index)", session: session, connection: connection), baseline: true)
        }
        #expect(subject.retainedCompletionCount == 1_024)
        subject.receive(snapshot("turn-1099", session: session, connection: connection), baseline: false)
        let fresh = snapshot("fresh", session: session, connection: connection)
        subject.receive(fresh, baseline: false); subject.receive(fresh, baseline: false)
        let deadline = ContinuousClock.now + .seconds(2)
        while subject.status != .delivered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await sender.received == [fresh])
        await subject.shutdown()
    }
    @Test func finishedSenderCleanupIsReleasedBeforeShutdown() async throws {
        let first = CompletionSender(), second = CompletionSender()
        let subject = LockedCompletionNotifications(isLocked: { false }, power: CompletionPower())
        subject.configure(sender: first); subject.configure(sender: second)
        let deadline = ContinuousClock.now + .seconds(2)
        while subject.pendingCleanupCount > 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(subject.pendingCleanupCount == 0)
        #expect(await first.closed)
        #expect(await !second.closed)
        await subject.shutdown()
        #expect(await second.closed)
    }
    @Test func failuresAreVisibleAndNeverAutomaticallyResent() async throws {
        let sender = CompletionSender(); await sender.setFailure()
        let subject = LockedCompletionNotifications(isLocked: { true }, power: CompletionPower())
        subject.configure(sender: sender)
        let completion = snapshot("failed", session: UUID(), connection: UUID())
        subject.receive(completion, baseline: false)
        let deadline = ContinuousClock.now + .seconds(2)
        while subject.status != .failed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(subject.status == .failed)
        subject.receive(completion, baseline: false)
        #expect(subject.status == .failed)
        await subject.shutdown()
    }
}
