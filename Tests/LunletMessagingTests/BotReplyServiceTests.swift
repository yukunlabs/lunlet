// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.02; US-36, AC-36.01, AC-36.02, AC-36.03, AC-36.04; US-05, AC-05.09; US-08, AC-08.03, AC-08.04; US-10, AC-10.01, AC-10.02, AC-10.04.
// A synthetic channel client stands in for the provider; no network, credentials or Codex input.
import Foundation
import Testing
import LunletCore
@testable import LunletMessaging

/// Records what the service sends, edits and receives; `deliver` plays the owner's reply into the running listener.
private actor SyntheticReplyClient: ChannelReplyClient {
    private(set) var sent: [NoticeReplyState?] = []
    private(set) var updates: [(messageID: String, reply: NoticeReplyState)] = []
    private(set) var texts: [String] = []
    private(set) var listeners = 0
    private(set) var prompts: [(callbackID: String, refusal: String?)] = []
    private var handler: (@Sendable (BotReplyEvent) async -> Void)?
    private var updatesFail = false
    /// Listener attempts that fail before one connects, and every attempt made.
    private var listenerFailures = 0
    private(set) var attempts = 0
    private var dropped = false
    /// Whether a connected listener says so, as the Slack and Telegram transports do.
    private var announces = false
    func announceConnections() { announces = true }
    func failUpdates() { updatesFail = true }
    func failListeners(_ count: Int) { listenerFailures = count }
    /// Ends the running listener as a lost connection.
    func dropListener() { dropped = true }
    func prepare() -> BotIdentity { .init(channel: .telegram, id: "9001", name: "SyntheticLunletBot") }
    func pair(_ challenge: PairingChallenge) throws -> BotBinding { throw BotChannelFailure.unavailable }
    func checkAuthorization(_ binding: BotBinding) {}
    func close() {}
    func sendCompletion(_ snapshot: SessionSnapshot, binding: BotBinding, reply: NoticeReplyState?) -> BotMessageReceipt {
        sent.append(reply)
        return BotMessageReceipt(messageID: "m\(sent.count)", chatID: binding.chatID)
    }
    func updateCompletion(_ snapshot: SessionSnapshot, binding: BotBinding, messageID: String, reply: NoticeReplyState) throws {
        guard !updatesFail else { throw BotChannelFailure.unavailable }
        updates.append((messageID, reply))
    }
    func promptReply(callbackID: String, agent: String, refusal: String?, binding: BotBinding) -> String? {
        prompts.append((callbackID, refusal))
        return refusal == nil ? "p\(prompts.count)" : nil
    }
    func receiveReplies(binding: BotBinding, onEvent: @escaping @Sendable (BotReplyEvent) async -> Void) async throws {
        attempts += 1
        if listenerFailures > 0 { listenerFailures -= 1; throw BotChannelFailure.unavailable }
        handler = onEvent; listeners += 1; dropped = false
        defer { handler = nil; listeners -= 1 }
        if announces { await onEvent(.listening) }
        while !dropped {
            do { try await Task.sleep(for: .milliseconds(2)) } catch { throw BotChannelFailure.canceled }
        }
        throw BotChannelFailure.unavailable
    }
    func sendText(_ text: String, binding: BotBinding) { texts.append(text) }
    func deliver(_ reply: BotReply) async -> Bool { await deliver(.reply(reply)) }
    func deliver(_ event: BotReplyEvent) async -> Bool {
        guard let handler else { return false }
        await handler(event)
        return true
    }
}

/// A monotonic clock the tests advance by hand.
private final class SyntheticClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private final class DispatchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ text: String) { lock.withLock { values.append(text) } }
    var texts: [String] { lock.withLock { values } }
}

struct BotReplyServiceTests {
    private let binding = BotBinding(channel: .telegram, botID: "9001", botName: "SyntheticLunletBot", ownerID: "42", chatID: "42")

    private func snapshot(_ turn: String = "turn_a", provider: SessionProvider = .codex, phase: SessionPhase? = nil,
                          session: UUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                          inputPath: SessionInputPath? = nil, liveness: CLILiveness = .alive) -> SessionSnapshot {
        SessionSnapshot(observation: .init(sessionID: session, connectionID: session, liveness: liveness,
                                           phase: phase ?? .idle(completedTurnID: turn)),
                        project: "reply-project", title: "Synthetic task", publicConclusion: "Done.", provider: provider,
                        inputPath: inputPath)
    }

    private func reply(_ id: String, to message: String, text: String = "Run the tests") -> BotReply {
        BotReply(messageID: id, repliedTo: message, text: text, sentAt: Date())
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < end else { Issue.record("The reply service did not reach the expected state"); throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func service(_ client: SyntheticReplyClient, clock: SyntheticClock, log: DispatchLog,
                         outcome: ContinuationOutcome = .delivered, retries: DispatchLog? = nil) -> BotReplyService {
        BotReplyService(client: client, binding: binding, dispatch: { action, progress in
            if case .followup(let text) = action.input { log.append(text) }
            await progress.submitted()
            return outcome
        }, elapsed: { clock.now }, checkInterval: .milliseconds(20), retryDelay: { failures in
            retries?.append(String(failures))
            return .milliseconds(2)
        })
    }

    // Refs: US-36, AC-36.02; US-05, AC-05.09; US-10, AC-10.04. A notice's ten minutes keep running while the Mac
    // sleeps: the window is measured on the clock that counts time asleep, as the Feishu router's is. On a Mac that
    // has never slept since it started the two clocks read the same.
    @Test func theWindowClockCountsTimeAsleep() {
        let continuous = TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
        #expect(abs(BotReplyService.windowClock() - continuous) < 1)
    }

    // Refs: US-36, AC-36.02, AC-36.04. A lost network outlasts five attempts; the listener keeps trying, with its
    // backoff, for as long as a notice can still take a reply.
    @Test func theListenerKeepsRetryingWhileANoticeIsInItsWindow() async throws {
        let client = SyntheticReplyClient(), clock = SyntheticClock(), log = DispatchLog(), retries = DispatchLog()
        let service = service(client, clock: clock, log: log, retries: retries)
        await client.failListeners(7)
        service.setReplyWindow(true)
        service.observe(snapshot())
        let control = try #require(await service.prepareReply(for: snapshot()))
        await service.bindReply(control, receipt: .init(messageID: "m1", chatID: "42"), snapshot: snapshot())
        try await waitUntil { await client.listeners == 1 }
        #expect(await client.attempts == 8)
        #expect(retries.texts == ["1", "2", "3", "4", "5", "6", "7"])
        // The shipped waits double from two seconds to a minute, within a provider's connection rate limit.
        #expect([1, 2, 5, 6, 40].map(BotReplyService.listenerBackoff) == [.seconds(2), .seconds(4), .seconds(32), .seconds(60), .seconds(60)])
        // The reply that arrives after the outage still continues the session.
        #expect(await client.deliver(reply("r1", to: "m1")))
        try await waitUntil { log.texts == ["Run the tests"] }
        await service.close()
    }

    // Refs: US-36, AC-36.04. A connection the provider accepted ends the outage: a later loss backs off from the start.
    @Test func anAcceptedConnectionStartsTheListenersBackoffAgain() async throws {
        let client = SyntheticReplyClient(), clock = SyntheticClock(), log = DispatchLog(), retries = DispatchLog()
        let service = service(client, clock: clock, log: log, retries: retries)
        await client.announceConnections()
        await client.failListeners(2)
        service.setReplyWindow(true)
        service.observe(snapshot())
        let control = try #require(await service.prepareReply(for: snapshot()))
        await service.bindReply(control, receipt: .init(messageID: "m1", chatID: "42"), snapshot: snapshot())
        try await waitUntil { await client.listeners == 1 }
        #expect(retries.texts == ["1", "2"])
        await client.dropListener()
        try await waitUntil { retries.texts.count == 3 }
        #expect(retries.texts == ["1", "2", "1"])
        await service.close()
    }

    // Refs: US-36, AC-36.04. A new notice starts the listener's backoff again, so an earlier outage does not slow
    // the replies to a later notice.
    @Test func aNewNoticeStartsTheListenersBackoffAgain() async throws {
        let client = SyntheticReplyClient(), clock = SyntheticClock(), log = DispatchLog(), retries = DispatchLog()
        let service = service(client, clock: clock, log: log, retries: retries)
        await client.failListeners(2)
        service.setReplyWindow(true)
        service.observe(snapshot())
        let first = try #require(await service.prepareReply(for: snapshot()))
        await service.bindReply(first, receipt: .init(messageID: "m1", chatID: "42"), snapshot: snapshot())
        try await waitUntil { await client.listeners == 1 }
        #expect(retries.texts == ["1", "2"])
        service.observe(snapshot("turn_b"))
        let second = try #require(await service.prepareReply(for: snapshot("turn_b")))
        await service.bindReply(second, receipt: .init(messageID: "m2", chatID: "42"), snapshot: snapshot("turn_b"))
        await client.dropListener()
        try await waitUntil { retries.texts.count == 3 }
        #expect(retries.texts == ["1", "2", "1"])
        await service.close()
    }

    // One reply to the notice continues the session once; the notice shows received, sent and delivered in place,
    // and a second reply to the same notice is never dispatched again.
    @Test func aReplyToTheNoticeContinuesTheSessionAndTheNoticeShowsEachStep() async throws {
        let client = SyntheticReplyClient(), clock = SyntheticClock(), log = DispatchLog()
        let service = service(client, clock: clock, log: log)
        service.setReplyWindow(true)
        service.observe(snapshot())
        let control = try #require(await service.prepareReply(for: snapshot()))
        await service.bindReply(control, receipt: .init(messageID: "m1", chatID: "42"), snapshot: snapshot())
        try await waitUntil { await client.listeners == 1 }
        #expect(await client.deliver(reply("r1", to: "m1")))
        try await waitUntil { await client.updates.count == 3 }
        let updates = await client.updates
        #expect(updates.map(\.messageID) == ["m1", "m1", "m1"])
        #expect(updates.map(\.reply) == [.received("Run the tests"), .submitted("Run the tests"), .finished(.delivered, "Run the tests")])
        #expect(log.texts == ["Run the tests"])
        // A provider's redelivery of the same message is not a second reply and is answered with nothing.
        #expect(await client.deliver(reply("r1", to: "m1")))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await client.texts.isEmpty)
        // AC-36.02: a repeated reply to a known notice is answered with the reason, and the notice keeps its outcome.
        #expect(await client.deliver(reply("r2", to: "m1", text: "Again")))
        try await waitUntil { await client.texts.count == 1 }
        let texts = await client.texts, count = await client.updates.count
        #expect(texts == ["Not sent. " + ContinuationRefusal.alreadySent.explanation])
        #expect(log.texts == ["Run the tests"] && count == 3)
        await service.close()
        #expect(await client.listeners == 0)
    }

    // Replies to other messages are ignored; after unlocking the notice closes in place and a late reply is answered
    // with the reason in a plain line, never forwarded.
    @Test func repliesToOtherMessagesOrAfterUnlockAreNeverForwarded() async throws {
        let client = SyntheticReplyClient(), clock = SyntheticClock(), log = DispatchLog()
        let service = service(client, clock: clock, log: log)
        service.setReplyWindow(true)
        service.observe(snapshot())
        let control = try #require(await service.prepareReply(for: snapshot()))
        await service.bindReply(control, receipt: .init(messageID: "m1", chatID: "42"), snapshot: snapshot())
        try await waitUntil { await client.listeners == 1 }
        #expect(await client.deliver(reply("r0", to: "other")))
        try await Task.sleep(for: .milliseconds(30))
        let ignoredUpdates = await client.updates, ignoredTexts = await client.texts
        #expect(log.texts.isEmpty && ignoredUpdates.isEmpty && ignoredTexts.isEmpty)
        service.setReplyWindow(false)
        try await waitUntil { await client.updates.count == 1 }
        #expect(await client.updates.first?.reply == .closed(.replyWindowClosed))
        // The notice stays within its validity period, so the listener still answers a late reply.
        #expect(await client.deliver(reply("r1", to: "m1")))
        try await waitUntil { await client.texts.count == 1 }
        #expect(await client.texts == ["Not sent. " + ContinuationRefusal.replyWindowClosed.explanation])
        #expect(log.texts.isEmpty)
        await service.close()
    }

    // Refs: US-36, AC-36.02; US-10, AC-10.01, AC-10.04. One scan that cannot confirm the session retires the notice's
    // control; when the same idle turn is observed again, a reply is refused as unconfirmed, never as "already sent":
    // nothing was sent.
    @Test func aReplyAfterAnUnconfirmedScanIsNotCalledAlreadySent() async throws {
        let client = SyntheticReplyClient(), clock = SyntheticClock(), log = DispatchLog()
        let service = service(client, clock: clock, log: log)
        service.setReplyWindow(true)
        service.observe(snapshot())
        let control = try #require(await service.prepareReply(for: snapshot()))
        await service.bindReply(control, receipt: .init(messageID: "m1", chatID: "42"), snapshot: snapshot())
        try await waitUntil { await client.listeners == 1 }
        service.observe(snapshot(liveness: .unverified))
        service.observe(snapshot())
        // Asking for a control applies both observations first; a running turn gets none.
        #expect(await service.prepareReply(for: snapshot(phase: .running)) == nil)
        #expect(await client.deliver(reply("r1", to: "m1")))
        try await waitUntil { await client.updates.count == 1 }
        #expect(await client.updates.first?.reply == .closed(.unverified))
        #expect(log.texts.isEmpty)
        await service.close()
    }

    // Refs: US-36, AC-36.03; US-05, AC-05.09. A control can die while its notice is being sent: the Mac is unlocked,
    // or the session starts another turn. The notice is then closed in place as soon as it is bound, with the
    // reason, instead of inviting a reply for its ten minutes.
    @Test func aNoticeBoundAfterItsControlDiedIsClosedAtOnce() async throws {
        let client = SyntheticReplyClient(), clock = SyntheticClock(), log = DispatchLog()
        let service = service(client, clock: clock, log: log)
        service.setReplyWindow(true)
        service.observe(snapshot())
        let unlocked = try #require(await service.prepareReply(for: snapshot()))
        service.setReplyWindow(false)
        // Asking again applies the unlock first; a closed window issues nothing.
        #expect(await service.prepareReply(for: snapshot()) == nil)
        await service.bindReply(unlocked, receipt: .init(messageID: "m1", chatID: "42"), snapshot: snapshot())
        try await waitUntil { await client.updates.count == 1 }
        #expect(await client.updates.first?.reply == .closed(.replyWindowClosed))

        service.setReplyWindow(true)
        let second = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        service.observe(snapshot(session: second))
        let moved = try #require(await service.prepareReply(for: snapshot(session: second)))
        service.observe(snapshot(phase: .running, session: second))
        #expect(await service.prepareReply(for: snapshot(phase: .running, session: second)) == nil)
        await service.bindReply(moved, receipt: .init(messageID: "m2", chatID: "42"), snapshot: snapshot(session: second))
        try await waitUntil { await client.updates.count == 2 }
        let last = await client.updates.last
        #expect(last?.messageID == "m2" && last?.reply == .closed(.sessionRunning))
        #expect(log.texts.isEmpty)
        await service.close()
    }

    // Refs: US-36, AC-36.01; US-05, AC-05.09. The monitor may observe one idle turn twice with a different title,
    // preview or activity time. The control follows the turn, so the notice prepared from the earlier observation
    // still gets it; an observation that withdraws the input path does not.
    @Test func aCosmeticReobservationOfTheSameTurnStillGetsItsControl() async throws {
        let client = SyntheticReplyClient(), clock = SyntheticClock(), log = DispatchLog()
        let service = service(client, clock: clock, log: log)
        service.setReplyWindow(true)
        service.observe(snapshot())
        let renamed = SessionSnapshot(observation: snapshot().observation, project: "reply-project", title: "Renamed since",
                                      publicConclusion: "Done.", lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000),
                                      localPreview: "A later preview")
        #expect(renamed != snapshot())
        service.observe(renamed)
        let control = try #require(await service.prepareReply(for: snapshot()))
        await service.bindReply(control, receipt: .init(messageID: "m1", chatID: "42"), snapshot: snapshot())
        try await waitUntil { await client.listeners == 1 }
        #expect(await client.deliver(reply("r1", to: "m1")))
        try await waitUntil { log.texts == ["Run the tests"] }
        // The newest observation of another session names no input path: the earlier one cannot be used for it.
        let other = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        service.observe(snapshot(provider: .claude, session: other, inputPath: .claudeHook))
        service.observe(snapshot(provider: .claude, session: other))
        #expect(await service.prepareReply(for: snapshot(provider: .claude, session: other, inputPath: .claudeHook)) == nil)
        await service.close()
    }

    // No control without a locked Mac, for another agent, a child task, a running turn or a stale snapshot.
    @Test func controlsAreIssuedOnlyForCurrentIdleCodexTurnsWhileLocked() async throws {
        let client = SyntheticReplyClient(), clock = SyntheticClock(), log = DispatchLog()
        let service = service(client, clock: clock, log: log)
        service.observe(snapshot())
        #expect(await service.prepareReply(for: snapshot()) == nil)
        service.setReplyWindow(true)
        #expect(await service.prepareReply(for: snapshot(provider: .claude)) == nil)
        // A Claude session takes replies only while Lunlet's hook holds its turn (US-38, AC-38.02).
        let claude = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let linked = snapshot(provider: .claude, session: claude, inputPath: .claudeHook)
        service.observe(linked)
        #expect(await service.prepareReply(for: linked) != nil)
        #expect(await service.prepareReply(for: snapshot(phase: .running)) == nil)
        #expect(await service.prepareReply(for: snapshot("turn_b")) == nil)
        #expect(await service.prepareReply(for: snapshot()) != nil)
        #expect(await client.listeners == 0)
        await service.close()
    }

    // The listener runs only while a notice is valid; an expired open notice says so and the listener stops.
    @Test func theListenerFollowsTheNoticesValidityAndExpiryClosesAnOpenNotice() async throws {
        let client = SyntheticReplyClient(), clock = SyntheticClock(), log = DispatchLog()
        let service = service(client, clock: clock, log: log)
        service.setReplyWindow(true)
        service.observe(snapshot())
        let control = try #require(await service.prepareReply(for: snapshot()))
        await service.bindReply(control, receipt: .init(messageID: "m1", chatID: "42"), snapshot: snapshot())
        try await waitUntil { await client.listeners == 1 }
        clock.advance(ContinuationGate.controlLifetime + 1)
        try await waitUntil { await client.updates.count == 1 }
        #expect(await client.updates.first?.reply == .closed(.expired))
        try await waitUntil { await client.listeners == 0 }
        await service.close()
    }

    // A newer notice for the same session closes the older open one; a refused edit falls back to a plain line.
    @Test func aNewerNoticeSupersedesTheOlderAndARefusedEditFallsBackToText() async throws {
        let client = SyntheticReplyClient(), clock = SyntheticClock(), log = DispatchLog()
        let service = service(client, clock: clock, log: log)
        service.setReplyWindow(true)
        service.observe(snapshot())
        let first = try #require(await service.prepareReply(for: snapshot()))
        await service.bindReply(first, receipt: .init(messageID: "m1", chatID: "42"), snapshot: snapshot())
        service.observe(snapshot("turn_b"))
        let second = try #require(await service.prepareReply(for: snapshot("turn_b")))
        await service.bindReply(second, receipt: .init(messageID: "m2", chatID: "42"), snapshot: snapshot("turn_b"))
        try await waitUntil { await client.updates.count == 1 }
        let superseded = await client.updates.first
        #expect(superseded?.messageID == "m1" && superseded?.reply == .closed(.superseded))
        await client.failUpdates()
        try await waitUntil { await client.listeners == 1 }
        #expect(await client.deliver(reply("r1", to: "m2")))
        try await waitUntil { await client.texts.count == 1 }
        #expect(await client.texts == ["Delivered. Codex is continuing on your Mac"])
        #expect(log.texts == ["Run the tests"])
        await service.close()
    }

    // The reply button opens a prompt while the notice is open; the answer to that prompt continues the session,
    // and a tap on a closed notice is answered with the reason instead.
    @Test func theReplyButtonOpensAPromptWhoseAnswerContinuesTheSession() async throws {
        let client = SyntheticReplyClient(), clock = SyntheticClock(), log = DispatchLog()
        let service = service(client, clock: clock, log: log)
        service.setReplyWindow(true)
        service.observe(snapshot())
        let control = try #require(await service.prepareReply(for: snapshot()))
        await service.bindReply(control, receipt: .init(messageID: "m1", chatID: "42"), snapshot: snapshot())
        try await waitUntil { await client.listeners == 1 }
        #expect(await client.deliver(.replyRequested(messageID: "m1", callbackID: "cb1")))
        try await waitUntil { await client.prompts.count == 1 }
        let opened = await client.prompts.first
        #expect(opened?.callbackID == "cb1" && opened?.refusal == nil)
        #expect(await client.deliver(reply("r1", to: "p1")))
        try await waitUntil { log.texts == ["Run the tests"] }
        try await waitUntil { await client.updates.count == 3 }
        #expect(await client.deliver(.replyRequested(messageID: "m1", callbackID: "cb2")))
        try await waitUntil { await client.prompts.count == 2 }
        let refused = await client.prompts.last
        #expect(refused?.refusal == "Not sent. " + ContinuationRefusal.alreadySent.explanation)
        #expect(await client.deliver(.replyRequested(messageID: "other", callbackID: "cb3")))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await client.prompts.count == 2)
        await service.close()
    }

    /// A dispatch that rechecks like the Codex adapter: on entry, then again after the test releases it.
    private actor RecheckingDispatch {
        private(set) var results: [ContinuationRefusal?] = []
        private var release: CheckedContinuation<Void, Never>?
        private var released = false
        func record(_ result: ContinuationRefusal?) { results.append(result) }
        func wait() async { if !released { await withCheckedContinuation { release = $0 } } }
        func go() { released = true; release?.resume(); release = nil }
    }

    // The adapter's recheck sees an unchanged session as current, never as a refusal, and names the new state of a
    // session that changed while the reply was being handed over.
    @Test func theRecheckPassesForAnUnchangedSessionAndNamesAChangedOne() async throws {
        let client = SyntheticReplyClient(), clock = SyntheticClock(), checks = RecheckingDispatch()
        let service = BotReplyService(client: client, binding: binding, dispatch: { _, progress in
            let first = await progress.recheck()
            await checks.record(first)
            if let first { return .refused(first) }
            await checks.wait()
            let second = await progress.recheck()
            await checks.record(second)
            if let second { return .refused(second) }
            await progress.submitted()
            return .delivered
        }, elapsed: { clock.now }, checkInterval: .milliseconds(20))
        service.setReplyWindow(true)
        service.observe(snapshot())
        let control = try #require(await service.prepareReply(for: snapshot()))
        await service.bindReply(control, receipt: .init(messageID: "m1", chatID: "42"), snapshot: snapshot())
        try await waitUntil { await client.listeners == 1 }
        #expect(await client.deliver(reply("r1", to: "m1")))
        try await waitUntil { await checks.results.count == 1 }
        #expect(await checks.results == [nil])
        service.observe(snapshot(phase: .running))
        #expect(await service.prepareReply(for: snapshot(phase: .running)) == nil)
        await checks.go()
        try await waitUntil { await client.updates.count == 2 }
        #expect(await checks.results == [nil, .sessionRunning])
        #expect(await client.updates.map(\.reply) == [.received("Run the tests"), .finished(.refused(.sessionRunning), "Run the tests")])
        await service.close()
    }

    // Replies that cannot travel as one CLI argument are refused with a plain line and never dispatched.
    @Test func unforwardableTextIsRefusedWithoutDispatch() async throws {
        let client = SyntheticReplyClient(), clock = SyntheticClock(), log = DispatchLog()
        let service = service(client, clock: clock, log: log)
        service.setReplyWindow(true)
        service.observe(snapshot())
        let control = try #require(await service.prepareReply(for: snapshot()))
        await service.bindReply(control, receipt: .init(messageID: "m1", chatID: "42"), snapshot: snapshot())
        try await waitUntil { await client.listeners == 1 }
        #expect(await client.deliver(reply("r1", to: "m1", text: String(repeating: "x", count: 1_001))))
        try await waitUntil { await client.texts.count == 1 }
        let refusal = await client.texts.first
        #expect(refusal?.hasPrefix("Not sent. Keep a reply under 1000 characters") == true && log.texts.isEmpty)
        // The control is still usable by a proper reply.
        #expect(await client.deliver(reply("r2", to: "m1")))
        try await waitUntil { log.texts == ["Run the tests"] }
        await service.close()
    }
}
