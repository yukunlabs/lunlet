// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-36, AC-36.01, AC-36.02, AC-36.03, AC-36.04; US-05, AC-05.09; US-08, AC-08.03, AC-08.04; US-10, AC-10.01, AC-10.02, AC-10.04.
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
    func failUpdates() { updatesFail = true }
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
        handler = onEvent; listeners += 1
        defer { handler = nil; listeners -= 1 }
        do { try await Task.sleep(for: .seconds(3_600)) } catch { throw BotChannelFailure.canceled }
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
                          session: UUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!) -> SessionSnapshot {
        SessionSnapshot(observation: .init(sessionID: session, connectionID: session, liveness: .alive,
                                           phase: phase ?? .idle(completedTurnID: turn)),
                        project: "reply-project", title: "Synthetic task", publicConclusion: "Done.", provider: provider)
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
                         outcome: ContinuationOutcome = .delivered) -> BotReplyService {
        BotReplyService(client: client, binding: binding, dispatch: { action, progress in
            if case .followup(let text) = action.input { log.append(text) }
            await progress.submitted()
            return outcome
        }, elapsed: { clock.now }, checkInterval: .milliseconds(20))
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
        #expect(await client.deliver(reply("r2", to: "m1", text: "Again")))
        try await Task.sleep(for: .milliseconds(30))
        let texts = await client.texts, count = await client.updates.count
        #expect(log.texts == ["Run the tests"] && texts.isEmpty && count == 3)
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

    // No control without a locked Mac, for another agent, a child task, a running turn or a stale snapshot.
    @Test func controlsAreIssuedOnlyForCurrentIdleCodexTurnsWhileLocked() async throws {
        let client = SyntheticReplyClient(), clock = SyntheticClock(), log = DispatchLog()
        let service = service(client, clock: clock, log: log)
        service.observe(snapshot())
        #expect(await service.prepareReply(for: snapshot()) == nil)
        service.setReplyWindow(true)
        #expect(await service.prepareReply(for: snapshot(provider: .claude)) == nil)
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
