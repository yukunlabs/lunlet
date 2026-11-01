// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-05, AC-05.09; US-07, AC-07.05; US-08, AC-08.01, AC-08.03, AC-08.04, AC-08.05.
// Refs: US-09, AC-09.02; US-10, AC-10.01, AC-10.02, AC-10.03, AC-10.04; US-11, AC-11.02, AC-11.03; US-12, AC-12.04.
import Foundation
import Testing
import LunletCore
@testable import LunletFeishu

private final class ReplyTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

/// Owner-bound sends; every card and its recipient are recorded, nothing leaves the process.
private actor SyntheticCards: FeishuCardSending {
    private(set) var sent: [(content: String, owner: FeishuOwner)] = []
    private(set) var closed = false
    func sendCard(_ delivery: FeishuCardDelivery, owner: FeishuOwner) async throws -> FeishuMessageReceipt {
        sent.append((delivery.content, owner))
        return FeishuMessageReceipt(messageID: "om_receipt_\(sent.count)", chatID: "oc_synthetic", applicationID: owner.applicationID,
                                    ownerID: owner.userID, tenantID: owner.tenantID)
    }
    func close() { closed = true }
}

/// Stands in for the long-connection socket: it opens immediately, then passes provider
/// callbacks through the real router exactly as the receive loop does.
private final class SyntheticConnection: FeishuCallbackConnecting, @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private let failure: FeishuBotFailure?
    private var router: CardActionRouter?
    private var onAction: (@Sendable (FeishuSocketAction) -> Void)?
    private var onRefusal: (@Sendable (FeishuCardRefusal) -> Void)?
    private var active = false
    init(failure: FeishuBotFailure?) { self.failure = failure }
    var isActive: Bool { lock.withLock { active } }

    func run(router: CardActionRouter, onState: @escaping @Sendable (FeishuTransportState) async -> Void,
             onAction: @escaping @Sendable (FeishuSocketAction) -> Void,
             onRefusal: @escaping @Sendable (FeishuCardRefusal) -> Void) async throws {
        if let failure { throw failure }
        lock.withLock { self.router = router; self.onAction = onAction; self.onRefusal = onRefusal; active = true }
        defer { lock.withLock { active = false } }
        await onState(.connecting)
        await onState(.socketOpen(id))
        do { try await Task.sleep(for: .seconds(3_600)) } catch {}
        await router.connectionClosed(id)
        throw CancellationError()
    }

    func deliver(_ data: Data) async -> CardActionResult {
        let (router, onAction, onRefusal) = lock.withLock { (self.router!, self.onAction!, self.onRefusal!) }
        let result = await router.handle(data, connectionID: id)
        if case .refused(_, let report?) = result { onRefusal(report) }
        if case .received(let action) = result { onAction(FeishuSocketAction(connectionID: id, continuation: action)) }
        return result
    }
}

private final class SyntheticConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [SyntheticConnection] = []
    private var failure: FeishuBotFailure?
    func failNext(_ value: FeishuBotFailure) { lock.withLock { failure = value } }
    func make() -> any FeishuCallbackConnecting {
        lock.withLock { let run = SyntheticConnection(failure: failure); runs.append(run); return run }
    }
    var started: Int { lock.withLock { runs.count } }
    var active: Int { lock.withLock { runs.filter(\.isActive).count } }
    var latest: SyntheticConnection? { lock.withLock { runs.last } }
}

private actor SyntheticDispatch {
    private(set) var actions: [AuthorizedContinuation] = []
    private(set) var rechecks: [ContinuationRefusal?] = []
    private var outcome: ContinuationOutcome = .delivered
    private var held = false
    private var waiter: CheckedContinuation<Void, Never>?
    func set(_ value: ContinuationOutcome) { outcome = value }
    func hold() { held = true }
    func release() { held = false; waiter?.resume(); waiter = nil }
    func run(_ action: AuthorizedContinuation, _ progress: ContinuationProgress) async -> ContinuationOutcome {
        actions.append(action)
        if held { await withCheckedContinuation { waiter = $0 } }
        let reason = await progress.recheck()
        rechecks.append(reason)
        if let reason { return .refused(reason) }
        if outcome == .delivered || outcome == .notConfirmed { await progress.submitted() }
        return outcome
    }
}

struct FeishuReplyServiceTests {
    private let session = UUID(), cli = UUID()
    private let owner = CardCallbackFixture.owner

    private func snapshot(_ phase: SessionPhase = .idle(completedTurnID: "turn_one"), provider: SessionProvider = .codex,
                          parent: UUID? = nil, liveness: CLILiveness = .alive) -> SessionSnapshot {
        SessionSnapshot(observation: .init(sessionID: session, connectionID: cli, liveness: liveness, phase: phase),
                        project: "Lunlet", title: "Synthetic task", parentSessionID: parent, provider: provider)
    }
    private func ownerReceipt(_ message: String = "om_card") -> FeishuMessageReceipt {
        FeishuMessageReceipt(messageID: message, chatID: "oc_synthetic", applicationID: owner.applicationID,
                             ownerID: owner.userID, tenantID: owner.tenantID)
    }
    private func service(_ cards: SyntheticCards, _ connections: SyntheticConnections, _ dispatch: SyntheticDispatch,
                         clock: ReplyTestClock = ReplyTestClock()) -> FeishuReplyService {
        FeishuReplyService(sender: cards, connect: { connections.make() }, dispatch: { await dispatch.run($0, $1) },
                           router: CardActionRouter(elapsed: { clock.now() }, wallTime: { CardCallbackFixture.date }),
                           openTimeout: .seconds(2), checkInterval: .milliseconds(10))
    }
    /// The first verified send establishes the owner; the window opens when the Mac is locked.
    private func ready(_ value: FeishuReplyService, observing current: SessionSnapshot? = nil) {
        value.recordOwner(from: ownerReceipt("om_first_notice"))
        value.setReplyWindow(true)
        value.observe(current ?? snapshot())
    }
    private func callback(_ token: UUID, event: String = "event_reply", message: String = "om_card",
                          operatorID: String = "ou_owner", text: String = "Continue with the next step") throws -> Data {
        var body = CardCallbackFixture.body(control: token, event: event, values: ["followup": text])
        var detail = body["event"] as! [String: Any]
        detail["context"] = ["open_message_id": message, "open_chat_id": "oc_synthetic"]
        detail["operator"] = ["tenant_key": owner.tenantID, "open_id": operatorID]
        body["event"] = detail
        return try JSONSerialization.data(withJSONObject: body)
    }
    private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("The synthetic reply flow did not reach the expected state")
        throw URLError(.timedOut)
    }
    private func message(_ card: String) throws -> (title: String, subtitle: String, text: String) {
        let json = try #require(JSONSerialization.jsonObject(with: Data(card.utf8)) as? [String: Any])
        let header = try #require(json["header"] as? [String: Any])
        let elements = try #require((json["body"] as? [String: Any])?["elements"] as? [[String: Any]])
        #expect(elements.count == 1 && elements[0]["tag"] as? String == "div")
        let title = try #require((header["title"] as? [String: String])?["content"])
        let subtitle = try #require((header["subtitle"] as? [String: String])?["content"])
        let text = try #require((elements[0]["text"] as? [String: String])?["content"])
        return (title, subtitle, text)
    }

    @Test func theCallbackConnectionRunsOnlyWhileAReplyCapableCardIsPreparedOrValid() async throws {
        let cards = SyntheticCards(), connections = SyntheticConnections(), dispatch = SyntheticDispatch()
        let clock = ReplyTestClock(), value = service(cards, connections, dispatch, clock: clock)
        ready(value)
        try await Task.sleep(for: .milliseconds(20))
        #expect(connections.started == 0)
        let withdrawn = try #require(await value.prepareReply(for: snapshot()))
        #expect(connections.active == 1 && withdrawn.sessionID == session && withdrawn.turnID == "turn_one")
        await value.withdrawReply(withdrawn)
        try await waitUntil { connections.active == 0 }
        let capability = try #require(await value.prepareReply(for: snapshot()))
        #expect(await value.bindReply(capability, receipt: ownerReceipt()))
        try await Task.sleep(for: .milliseconds(40))
        #expect(connections.active == 1)
        clock.advance(ContinuationGate.controlLifetime)
        try await waitUntil { connections.active == 0 }
        #expect(connections.started == 2)
        await value.close()
        #expect(await cards.closed)
    }

    @Test func oneBoundReplyIsDispatchedOnceForItsSessionAndTurnWithASessionNamedReceipt() async throws {
        let cards = SyntheticCards(), connections = SyntheticConnections(), dispatch = SyntheticDispatch()
        let value = service(cards, connections, dispatch)
        ready(value)
        let capability = try #require(await value.prepareReply(for: snapshot()))
        #expect(capability.callbackValue == ["lunlet_control": capability.token.uuidString])
        #expect(await value.bindReply(capability, receipt: ownerReceipt()))
        let connection = try #require(connections.latest)
        guard case .received = await connection.deliver(try callback(capability.token)) else {
            Issue.record("The owner's reply on the bound card must be received"); return
        }
        try await waitUntil { await cards.sent.count == 1 }
        let action = try #require(await dispatch.actions.first)
        #expect(action.session == snapshot().observation && action.input == .followup("Continue with the next step"))
        let receipt = try message(await cards.sent[0].content)
        #expect(receipt == ("Lunlet", "Codex · Synthetic task", "Delivered to Synthetic task · continuing on your Mac"))
        #expect(await cards.sent[0].owner == owner)
        // Repeated taps and a replayed provider event never dispatch again.
        for event in ["event_reply", "event_tap_again"] {
            guard case .duplicate(let status) = await connection.deliver(try callback(capability.token, event: event)) else {
                Issue.record("A used card answers with its receipt"); continue
            }
            #expect(status.status == .processing)
        }
        try await Task.sleep(for: .milliseconds(20))
        let dispatched = await dispatch.actions.count, sent = await cards.sent.count
        #expect(dispatched == 1 && sent == 1)
        await value.close()
    }

    @Test func foreignOperatorsForwardedCopiesAndUnboundCardsNeverDispatchOrReceiveReceipts() async throws {
        let cards = SyntheticCards(), connections = SyntheticConnections(), dispatch = SyntheticDispatch()
        let value = service(cards, connections, dispatch)
        ready(value)
        let unbound = try #require(await value.prepareReply(for: snapshot()))
        let connection = try #require(connections.latest)
        let attempts = [try callback(unbound.token),
                        try callback(unbound.token, event: "event_intruder", operatorID: "ou_intruder")]
        for data in attempts {
            guard case .unavailable = await connection.deliver(data) else { Issue.record("Unbound or foreign input must stay opaque"); continue }
        }
        #expect(await value.bindReply(unbound, receipt: ownerReceipt()))
        guard case .unavailable = await connection.deliver(try callback(unbound.token, event: "event_copy", message: "om_forwarded")) else {
            Issue.record("A forwarded copy of the card is not its bound message"); return
        }
        try await Task.sleep(for: .milliseconds(20))
        let dispatched = await dispatch.actions.count, sent = await cards.sent.count
        #expect(dispatched == 0 && sent == 0)
        await value.close()
    }

    @Test func unlockingRevokesIssuedRepliesAndExplainsItOnceWhileTheCardIsValid() async throws {
        let cards = SyntheticCards(), connections = SyntheticConnections(), dispatch = SyntheticDispatch()
        let value = service(cards, connections, dispatch)
        ready(value)
        let capability = try #require(await value.prepareReply(for: snapshot()))
        #expect(await value.bindReply(capability, receipt: ownerReceipt()))
        value.setReplyWindow(false)
        // Preparing applies every earlier ordered event first, and nothing is issued after unlock.
        #expect(await value.prepareReply(for: snapshot()) == nil)
        let connection = try #require(connections.latest)
        guard case .refused(.replyWindowClosed, _) = await connection.deliver(try callback(capability.token)) else {
            Issue.record("Unlocking must end the reply window"); return
        }
        try await waitUntil { await cards.sent.count == 1 }
        #expect(try message(await cards.sent[0].content).text
                == "Not sent to Synthetic task. Replies stopped when your Mac was unlocked. Continue on your Mac.")
        _ = await connection.deliver(try callback(capability.token, event: "event_later"))
        try await Task.sleep(for: .milliseconds(20))
        let sent = await cards.sent.count, dispatched = await dispatch.actions.count
        #expect(sent == 1 && dispatched == 0)
        // The connection stays for accurate answers until the card's validity ends.
        #expect(connections.active == 1)
        await value.close()
        #expect(connections.active == 0)
    }

    @Test func noReplyIsIssuedWithoutAVerifiedOwnerOutsideTheWindowOrForIneligibleSnapshots() async throws {
        let cards = SyntheticCards(), connections = SyntheticConnections(), dispatch = SyntheticDispatch()
        let value = service(cards, connections, dispatch)
        value.setReplyWindow(true)
        value.observe(snapshot())
        #expect(await value.prepareReply(for: snapshot()) == nil)
        value.recordOwner(from: ownerReceipt())
        value.setReplyWindow(false)
        #expect(await value.prepareReply(for: snapshot()) == nil)
        value.setReplyWindow(true)
        let ineligible = [snapshot(provider: .claude), snapshot(parent: UUID()), snapshot(.running),
                          snapshot(.approval), snapshot(liveness: .unverified)]
        for candidate in ineligible {
            value.observe(candidate)
            #expect(await value.prepareReply(for: candidate) == nil)
        }
        // An older completion is not the session's latest observation.
        value.observe(snapshot(.idle(completedTurnID: "turn_two")))
        #expect(await value.prepareReply(for: snapshot()) == nil)
        #expect(connections.started == 0)
        await value.close()
    }

    @Test(arguments: [ContinuationOutcome.notConfirmed, .failed, .refused(.sessionRunning)])
    func dispatchOutcomesAreReportedOnceWithoutRetry(_ outcome: ContinuationOutcome) async throws {
        let cards = SyntheticCards(), connections = SyntheticConnections(), dispatch = SyntheticDispatch()
        await dispatch.set(outcome)
        let value = service(cards, connections, dispatch)
        ready(value)
        let capability = try #require(await value.prepareReply(for: snapshot()))
        #expect(await value.bindReply(capability, receipt: ownerReceipt()))
        let connection = try #require(connections.latest)
        _ = await connection.deliver(try callback(capability.token))
        try await waitUntil { await cards.sent.count == 1 }
        let expected: String
        switch outcome {
        case .notConfirmed:
            expected = "Sent to Synthetic task, but delivery is not confirmed — check on your Mac. Lunlet will not send it again."
        case .failed: expected = "Not delivered to Synthetic task — continue on your Mac."
        default: expected = "Not sent to Synthetic task. The session is already working on another turn."
        }
        #expect(try message(await cards.sent[0].content).text == expected)
        guard case .duplicate(let receipt) = await connection.deliver(try callback(capability.token, event: "event_retry")) else {
            Issue.record("The consumed card must not dispatch again"); return
        }
        #expect(receipt.status == (outcome == .notConfirmed ? .uncertain : .failed))
        try await Task.sleep(for: .milliseconds(20))
        let dispatched = await dispatch.actions.count, sent = await cards.sent.count
        #expect(dispatched == 1 && sent == 1)
        await value.close()
    }

    @Test func theSubmissionBoundaryRechecksTheWindowAfterTheBindingCheck() async throws {
        let cards = SyntheticCards(), connections = SyntheticConnections(), dispatch = SyntheticDispatch()
        await dispatch.hold()
        let value = service(cards, connections, dispatch)
        ready(value)
        let capability = try #require(await value.prepareReply(for: snapshot()))
        #expect(await value.bindReply(capability, receipt: ownerReceipt()))
        _ = await try #require(connections.latest).deliver(try callback(capability.token))
        try await waitUntil { await dispatch.actions.count == 1 }
        value.setReplyWindow(false)
        #expect(await value.prepareReply(for: snapshot()) == nil)
        await dispatch.release()
        try await waitUntil { await cards.sent.count == 1 }
        #expect(await dispatch.rechecks == [.replyWindowClosed])
        #expect(try message(await cards.sent[0].content).text.hasSuffix(ContinuationRefusal.replyWindowClosed.explanation))
        await value.close()
    }

    @Test func aBlockedConnectionIsNotRestartedForLaterCards() async throws {
        let cards = SyntheticCards(), connections = SyntheticConnections(), dispatch = SyntheticDispatch()
        connections.failNext(.providerRejected(514))
        let value = service(cards, connections, dispatch)
        ready(value)
        #expect(await value.prepareReply(for: snapshot()) == nil)
        #expect(await value.prepareReply(for: snapshot()) == nil)
        #expect(connections.started == 1)
        await value.close()
    }

    @Test func closingCancelsInFlightInputAndSendsNothingFurther() async throws {
        let cards = SyntheticCards(), connections = SyntheticConnections(), dispatch = SyntheticDispatch()
        await dispatch.hold()
        let value = service(cards, connections, dispatch)
        ready(value)
        let capability = try #require(await value.prepareReply(for: snapshot()))
        #expect(await value.bindReply(capability, receipt: ownerReceipt()))
        _ = await try #require(connections.latest).deliver(try callback(capability.token))
        try await waitUntil { await dispatch.actions.count == 1 }
        let closing = Task { await value.close() }
        try await Task.sleep(for: .milliseconds(20))
        await dispatch.release()
        await closing.value
        let sent = await cards.sent.count, closed = await cards.closed
        #expect(connections.active == 0 && sent == 0 && closed)
    }
}

struct ReplyReceiptCardTests {
    @Test func receiptsArePlainTextWithoutControlsAndNameOnlySafeSessionIdentity() throws {
        let session = UUID(uuidString: "abcdef12-0000-4000-8000-000000000000")!
        let unsafe = SessionSnapshot(observation: .init(sessionID: session, connectionID: UUID(), liveness: .alive,
                                                        phase: .idle(completedTurnID: "turn")),
                                     project: "/Users/someone/private", title: "token: hidden")
        let outcomes: [ContinuationOutcome] = [.delivered, .notConfirmed, .failed, .refused(.replyWindowClosed),
                                               .refused(.repliesTurnedOff), .refused(.expired), .refused(.connectionReplaced),
                                               .refused(.sessionRunning), .refused(.awaitingApproval), .refused(.sessionEnded),
                                               .refused(.superseded), .refused(.alreadySent), .refused(.unverified)]
        for outcome in outcomes {
            let card = try ReplyReceiptCard.render(outcome, for: unsafe).content
            for forbidden in ["form", "button", "behaviors", "lunlet_control", "markdown", "/Users", "hidden"] {
                #expect(!card.contains(forbidden))
            }
            #expect(card.contains("Session ABCDEF12") && card.contains("\"Project\""))
        }
        let unknown = try ReplyReceiptCard.render(.refused(.sessionEnded), for: nil).content
        #expect(unknown.contains("Not sent to this session. The session has ended. Lunlet does not restart sessions."))
    }
}
