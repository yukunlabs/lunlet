// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-07, AC-07.02, AC-07.03, AC-07.04; US-08, AC-08.01, AC-08.03.
// Refs: US-09, AC-09.02; US-10, AC-10.01, AC-10.02, AC-10.03, AC-10.04.
// Refs: US-11, AC-11.02, AC-11.03, AC-11.04, AC-11.05; US-12, AC-12.01, AC-12.02, AC-12.03.
// Refs: US-05, AC-05.08, AC-05.09.
import Foundation
import Testing
import LunletCore
@testable import LunletFeishu

private final class CardTestTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

struct CardActionRouterTests {
    private let sessionID = UUID()
    private let cliConnection = UUID()
    private let feishuConnection = UUID()
    private let form = CardForm.followup(field: "followup")
    private let access = MobileAccess(owner: CardCallbackFixture.owner, connected: true, awayMode: true, inputEnabled: true)
    private let receipt = FeishuMessageReceipt(messageID: "om_synthetic", chatID: "oc_synthetic",
                                               applicationID: "cli_synthetic", ownerID: "ou_owner", tenantID: "tenant_synthetic")

    private func observation(_ phase: SessionPhase = .idle(completedTurnID: "turn_synthetic")) -> ObservedSession {
        ObservedSession(sessionID: sessionID, connectionID: cliConnection, liveness: .alive, phase: phase)
    }

    private func ready(clock: CardTestTime = CardTestTime(), phase: SessionPhase = .idle(completedTurnID: "turn_synthetic")) async -> CardActionRouter {
        let router = CardActionRouter(elapsed: { clock.now() }, wallTime: { CardCallbackFixture.date })
        await router.setAccess(access, connectionID: feishuConnection)
        await router.observe(observation(phase))
        return router
    }

    private func issue(_ router: CardActionRouter, form: CardForm? = nil) async throws -> ContinuationControl {
        let control = try #require(await router.prepare(sessionID: sessionID, form: form ?? self.form))
        #expect(await router.bind(controlID: control.id, receipt: receipt))
        return control
    }

    private func accepted(_ result: CardActionResult) throws -> AuthorizedContinuation {
        guard case .received(let action) = result else {
            Issue.record("Expected one exactly bound received continuation")
            throw CardCallbackFailure.malformed
        }
        return action
    }

    private func unavailable(_ result: CardActionResult) -> Bool {
        if case .unavailable = result { return true }; return false
    }

    /// The accurate reason given to the verified owner, and whether this tap is the first report.
    private func refused(_ result: CardActionResult) -> (ContinuationRefusal, reported: Bool)? {
        if case .refused(let reason, let report) = result {
            #expect(report == nil || report?.reason == reason && report?.sessionID == sessionID)
            return (reason, report != nil)
        }
        return nil
    }

    @Test func aBoundOwnerCardProducesOnlyAReceivedActionForTheOriginalSession() async throws {
        let router = await ready()
        let control = try await issue(router)
        let payload = try CardCallbackFixture.data(control: control.id, values: ["followup": "Continue café ✓\nwith context"])
        let result = await router.handle(payload, connectionID: feishuConnection)
        let action = try accepted(result)
        #expect(action.session == observation())
        #expect(action.input == .followup("Continue café ✓\nwith context"))
        #expect(action.receipt.status == .received)
        let reply = try JSONSerialization.jsonObject(with: result.responseJSON()) as! [String: [String: String]]
        #expect(reply["toast"]?["content"] == "Received. Waiting for Codex confirmation.")
        #expect(reply["toast"]?["type"] == "info")
    }

    @Test func repeatedCallbacksReturnTheSameReceiptWithoutAnotherDispatchableAction() async throws {
        let router = await ready()
        let control = try await issue(router)
        let payload = try CardCallbackFixture.data(control: control.id)
        let action = try accepted(await router.handle(payload, connectionID: feishuConnection))
        for event in ["event_synthetic", "event_repeated_tap"] {
            let repeated = try CardCallbackFixture.data(control: control.id, event: event)
            let result = await router.handle(repeated, connectionID: feishuConnection)
            guard case .duplicate(let receipt) = result else { Issue.record("Repeated taps must not dispatch"); continue }
            #expect(receipt.id == action.receipt.id)
        }
        await router.updateReceipt(action.receipt.id, status: .uncertain)
        let result = await router.handle(payload, connectionID: feishuConnection)
        guard case .duplicate(let receipt) = result else { Issue.record("An uncertain action remains consumed"); return }
        #expect(receipt.status == .uncertain)
        let reply = try JSONSerialization.jsonObject(with: result.responseJSON()) as! [String: [String: String]]
        #expect(reply["toast"]?["content"] == "Submission outcome is unknown. Check your Mac before trying again.")
    }

    @Test(arguments: ["direct", "synchronize", "removed"])
    func queuedActionsRemainRevokedAfterTheirOriginalObservationReturns(_ path: String) async throws {
        let router = await ready(), control = try await issue(router)
        let payload = try CardCallbackFixture.data(control: control.id)
        let action = try accepted(await router.handle(payload, connectionID: feishuConnection))
        let unknown = ObservedSession(sessionID: sessionID, connectionID: cliConnection, liveness: .unverified, phase: .unknown)
        if path == "direct" {
            await router.observe(unknown)
            await router.observe(observation())
        } else {
            await router.synchronize(revision: 1, access: access, connectionID: feishuConnection,
                                     observations: path == "removed" ? [] : [unknown])
            await router.synchronize(revision: 2, access: access, connectionID: feishuConnection, observations: [observation()])
        }
        #expect(await router.claim(action, connectionID: feishuConnection) == false)
        guard case .duplicate(let receipt) = await router.handle(payload, connectionID: feishuConnection) else {
            Issue.record("The consumed card must retain its failed receipt"); return
        }
        #expect(receipt.status == .failed)
        #expect(await router.prepare(sessionID: sessionID, form: form) == nil)
        await router.observe(observation(.idle(completedTurnID: "fresh_turn")))
        #expect(await router.prepare(sessionID: sessionID, form: form) != nil)
    }

    @Test func aCallbackMustMatchItsBoundMessageAndCurrentLongConnection() async throws {
        let router = await ready()
        let control = try #require(await router.prepare(sessionID: sessionID, form: form))
        let payload = try CardCallbackFixture.data(control: control.id)
        #expect(unavailable(await router.handle(payload, connectionID: feishuConnection)))
        #expect(await router.bind(controlID: control.id, receipt: receipt))
        #expect(unavailable(await router.handle(payload, connectionID: UUID())))
        for context in [["open_message_id": "om_forwarded", "open_chat_id": "oc_synthetic"],
                        ["open_message_id": "om_synthetic", "open_chat_id": "oc_forwarded"]] {
            var body = CardCallbackFixture.body(control: control.id)
            var event = body["event"] as! [String: Any]
            event["context"] = context
            body["event"] = event
            let forwarded = try JSONSerialization.data(withJSONObject: body)
            #expect(unavailable(await router.handle(forwarded, connectionID: feishuConnection)))
        }
        _ = try accepted(await router.handle(payload, connectionID: feishuConnection))
    }

    @Test func sendReceiptsCannotBindAnotherOwnerOrBeReboundToAnotherMessage() async throws {
        let router = await ready()
        let control = try #require(await router.prepare(sessionID: sessionID, form: form))
        let foreign = FeishuMessageReceipt(messageID: "om_synthetic", chatID: "oc_synthetic",
                                            applicationID: "cli_other", ownerID: "ou_other", tenantID: "tenant_other")
        #expect(!(await router.bind(controlID: control.id, receipt: foreign)))
        #expect(await router.bind(controlID: control.id, receipt: receipt))
        let otherMessage = FeishuMessageReceipt(messageID: "om_other", chatID: "oc_synthetic",
                                                 applicationID: "cli_synthetic", ownerID: "ou_owner", tenantID: "tenant_synthetic")
        #expect(!(await router.bind(controlID: control.id, receipt: otherMessage)))
        #expect(await router.bind(controlID: control.id, receipt: receipt))
    }

    @Test func extraOrEmptyFieldsDoNotConsumeTheValidControl() async throws {
        let router = await ready()
        let control = try await issue(router)
        for fields in [["followup": "Continue", "session": "untrusted"], ["followup": " \n"], ["other": "Continue"]] {
            let payload = try CardCallbackFixture.data(control: control.id, values: fields)
            let result = await router.handle(payload, connectionID: feishuConnection)
            guard case .invalidInput = result else { Issue.record("Unexpected or empty fields must fail validation"); continue }
        }
        let valid = try CardCallbackFixture.data(control: control.id)
        _ = try accepted(await router.handle(valid, connectionID: feishuConnection))
    }

    @Test func answerFieldsAreBoundToQuestionIDsAndPermittedOptions() async throws {
        let phase = SessionPhase.question(turnID: "turn_question", requestID: "request_synthetic", itemID: "item_synthetic",
                                          questionIDs: ["q_text", "q_one", "q_many"], purpose: .ordinary)
        let router = await ready(phase: phase)
        let fields = [CardAnswerField(name: "answer_0", questionID: "q_text", kind: .text),
                      CardAnswerField(name: "answer_1", questionID: "q_one", kind: .singleChoice(["a", "b"])),
                      CardAnswerField(name: "answer_2", questionID: "q_many", kind: .multipleChoice(["x", "y"]))]
        let control = try await issue(router, form: .answers(fields))
        let invalid = try CardCallbackFixture.data(control: control.id, values: ["answer_0": "Details", "answer_1": "unknown", "answer_2": ["x"]])
        guard case .invalidInput = await router.handle(invalid, connectionID: feishuConnection) else {
            Issue.record("An invented choice cannot answer the question"); return
        }
        let valid = try CardCallbackFixture.data(control: control.id, values: ["answer_0": "Details", "answer_1": "b", "answer_2": ["y", "x"]])
        let action = try accepted(await router.handle(valid, connectionID: feishuConnection))
        #expect(action.session == observation(phase))
        #expect(action.input == .answer(["q_text": ["Details"], "q_one": ["b"], "q_many": ["y", "x"]]))
    }

    @Test func approvalsAndUnknownQuestionsCannotIssueMobileControls() async {
        let phases: [SessionPhase] = [.approval, .running, .unknown,
            .question(turnID: "t", requestID: "r", itemID: "i", questionIDs: ["q"], purpose: .authorization),
            .question(turnID: "t", requestID: "r", itemID: "i", questionIDs: ["q"], purpose: .unknown)]
        for phase in phases {
            let router = await ready(phase: phase)
            #expect(await router.prepare(sessionID: sessionID, form: form) == nil)
            #expect(await router.prepare(sessionID: sessionID, form: .answers([
                CardAnswerField(name: "answer_0", questionID: "q", kind: .text)])) == nil)
        }
    }

    @Test func aPreviouslyIssuedFollowupCannotAuthorizeAnApproval() async throws {
        let router = await ready()
        let control = try await issue(router)
        await router.observe(observation(.approval))
        let yes = try CardCallbackFixture.data(control: control.id, values: ["followup": "yes"])
        let first = refused(await router.handle(yes, connectionID: feishuConnection))
        #expect(first?.0 == .awaitingApproval && first?.reported == true)
        // Repeated taps keep the reason without another report.
        let again = refused(await router.handle(yes, connectionID: feishuConnection))
        #expect(again?.0 == .awaitingApproval && again?.reported == false)
    }

    @Test func changedConnectionsAndDisableReenableRequireFreshObservationsAndControls() async throws {
        let router = await ready()
        let control = try await issue(router)
        let payload = try CardCallbackFixture.data(control: control.id)
        let nextConnection = UUID()
        await router.setAccess(access, connectionID: nextConnection)
        #expect(await router.prepare(sessionID: sessionID, form: form) == nil)
        #expect(refused(await router.handle(payload, connectionID: nextConnection))?.0 == .connectionReplaced)
        await router.observe(observation())
        let next = try await issue(router)
        var disabled = access
        disabled.awayMode = false
        await router.setAccess(disabled, connectionID: nextConnection)
        await router.setAccess(access, connectionID: nextConnection)
        #expect(await router.prepare(sessionID: sessionID, form: form) == nil)
        let old = try CardCallbackFixture.data(control: next.id)
        // Re-enabling never revives a card issued before the reply window closed.
        #expect(refused(await router.handle(old, connectionID: nextConnection))?.0 == .replyWindowClosed)
    }

    @Test func monotonicControlExpiryStillAppliesWhenTheCallbackTimestampIsFresh() async throws {
        let clock = CardTestTime()
        let router = await ready(clock: clock)
        let control = try await issue(router)
        clock.advance(600)
        let payload = try CardCallbackFixture.data(control: control.id)
        #expect(refused(await router.handle(payload, connectionID: feishuConnection))?.0 == .expired)
    }

    @Test func oneProviderEventCannotBeReusedForAnotherSessionOrRequest() async throws {
        let router = await ready()
        let first = try await issue(router)
        _ = try accepted(await router.handle(CardCallbackFixture.data(control: first.id), connectionID: feishuConnection))
        await router.observe(observation(.idle(completedTurnID: "turn_next")))
        let next = try await issue(router)
        let collision = try CardCallbackFixture.data(control: next.id)
        #expect(unavailable(await router.handle(collision, connectionID: feishuConnection)))
        let fresh = try CardCallbackFixture.data(control: next.id, event: "event_next")
        _ = try accepted(await router.handle(fresh, connectionID: feishuConnection))
    }

    @Test func duplicateFieldNamesAndMissingQuestionMappingsCannotIssueAnAnswerForm() async throws {
        let phase = SessionPhase.question(turnID: "t", requestID: "r", itemID: "i", questionIDs: ["q1", "q2"], purpose: .ordinary)
        let router = await ready(phase: phase)
        let invalid: [[CardAnswerField]] = [
            [CardAnswerField(name: "answer_0", questionID: "q1", kind: .text)],
            [CardAnswerField(name: "answer_0", questionID: "q1", kind: .text),
             CardAnswerField(name: "answer_0", questionID: "q2", kind: .text)],
            [CardAnswerField(name: "answer_0", questionID: "q1", kind: .text),
             CardAnswerField(name: "answer_1", questionID: "q1", kind: .text)],
            [CardAnswerField(name: "answer_0", questionID: "q1", kind: .singleChoice([])),
             CardAnswerField(name: "answer_1", questionID: "q2", kind: .text)],
        ]
        for fields in invalid { #expect(await router.prepare(sessionID: sessionID, form: .answers(fields)) == nil) }
        _ = try await issue(router, form: .answers([
            CardAnswerField(name: "answer_0", questionID: "q1", kind: .text),
            CardAnswerField(name: "answer_1", questionID: "q2", kind: .text),
        ]))
    }

    @Test func unchangedAccessDoesNotInvalidateAnAlreadyDeliveredControl() async throws {
        let router = await ready()
        let control = try await issue(router)
        await router.setAccess(access, connectionID: feishuConnection)
        let payload = try CardCallbackFixture.data(control: control.id)
        _ = try accepted(await router.handle(payload, connectionID: feishuConnection))
    }

    @Test func twoSessionsWithTheSameTurnNameKeepSeparateMessagesAndInputs() async throws {
        let router = await ready()
        let first = try await issue(router)
        let otherSession = ObservedSession(sessionID: UUID(), connectionID: UUID(), liveness: .alive,
                                            phase: .idle(completedTurnID: "turn_synthetic"))
        await router.observe(otherSession)
        let other = try #require(await router.prepare(sessionID: otherSession.sessionID, form: form))
        let otherReceipt = FeishuMessageReceipt(messageID: "om_other", chatID: "oc_synthetic",
                                                 applicationID: "cli_synthetic", ownerID: "ou_owner", tenantID: "tenant_synthetic")
        #expect(await router.bind(controlID: other.id, receipt: otherReceipt))
        let wrongMessage = try CardCallbackFixture.data(control: other.id, event: "event_other")
        #expect(unavailable(await router.handle(wrongMessage, connectionID: feishuConnection)))
        var body = CardCallbackFixture.body(control: other.id, event: "event_other", values: ["followup": "Other session input"])
        var event = body["event"] as! [String: Any]
        event["context"] = ["open_message_id": "om_other", "open_chat_id": "oc_synthetic"]
        body["event"] = event
        let action = try accepted(await router.handle(JSONSerialization.data(withJSONObject: body), connectionID: feishuConnection))
        #expect(action.session == otherSession)
        #expect(action.input == .followup("Other session input"))
        let original = try CardCallbackFixture.data(control: first.id)
        let firstAction = try accepted(await router.handle(original, connectionID: feishuConnection))
        #expect(firstAction.session == observation())
    }

    @Test func closingAnOlderConnectionCannotInvalidateItsReplacement() async throws {
        let router = await ready()
        let nextConnection = UUID()
        await router.setAccess(access, connectionID: nextConnection)
        await router.observe(observation())
        let control = try await issue(router)
        await router.connectionClosed(feishuConnection)
        let payload = try CardCallbackFixture.data(control: control.id)
        _ = try accepted(await router.handle(payload, connectionID: nextConnection))
        await router.connectionClosed(nextConnection)
        #expect(unavailable(await router.handle(payload, connectionID: nextConnection)))
        #expect(await router.prepare(sessionID: sessionID, form: form) == nil)
    }

    private func callback(_ control: UUID, event: String = "event_synthetic", message: String = "om_synthetic",
                          operatorID: String = "ou_owner", text: String = "Continue the synthetic task") throws -> Data {
        var body = CardCallbackFixture.body(control: control, event: event, values: ["followup": text])
        var event = body["event"] as! [String: Any]
        event["context"] = ["open_message_id": message, "open_chat_id": "oc_synthetic"]
        event["operator"] = ["tenant_key": "tenant_synthetic", "open_id": operatorID]
        body["event"] = event
        return try JSONSerialization.data(withJSONObject: body)
    }

    // Refs: US-05, AC-05.08, AC-05.09; US-12, AC-12.02.
    @Test(arguments: [true, false])
    func closingTheReplyWindowOrTurningRepliesOffAnswersOnlyTheVerifiedOwnerAccurately(_ unlock: Bool) async throws {
        let router = await ready()
        let control = try await issue(router)
        var next = access
        if unlock { next.awayMode = false } else { next.inputEnabled = false }
        await router.setAccess(next, connectionID: feishuConnection)
        let expected: ContinuationRefusal = unlock ? .replyWindowClosed : .repliesTurnedOff
        let result = await router.handle(try callback(control.id), connectionID: feishuConnection)
        let first = refused(result)
        #expect(first?.0 == expected && first?.reported == true)
        let reply = try JSONSerialization.jsonObject(with: result.responseJSON()) as! [String: [String: String]]
        #expect(reply["toast"]?["content"] == expected.explanation && reply["toast"]?["type"] == "warning")
        // Another operator, a forwarded copy or another connection learns nothing about the card.
        #expect(unavailable(await router.handle(try callback(control.id, event: "event_intruder", operatorID: "ou_intruder"),
                                                connectionID: feishuConnection)))
        #expect(unavailable(await router.handle(try callback(control.id, event: "event_forwarded", message: "om_forwarded"),
                                                connectionID: feishuConnection)))
        #expect(unavailable(await router.handle(try callback(control.id, event: "event_other"), connectionID: UUID())))
        #expect(refused(await router.handle(try callback(control.id, event: "event_again"), connectionID: feishuConnection))?.reported == false)
    }

    // Refs: US-08, AC-08.03; US-09, AC-09.02; US-11, AC-11.03, AC-11.04.
    @Test func laterSessionStatesExplainWhyAnOlderCardCannotSend() async throws {
        let later: [(ObservedSession, ContinuationRefusal)] = [
            (observation(.running), .sessionRunning),
            (observation(.approval), .awaitingApproval),
            (observation(.idle(completedTurnID: "turn_next")), .superseded),
            (ObservedSession(sessionID: sessionID, connectionID: cliConnection, liveness: .ended, phase: .ended), .sessionEnded),
            // A restored session has a new binding; the old card never revives (AC-11.04).
            (ObservedSession(sessionID: sessionID, connectionID: UUID(), liveness: .alive,
                             phase: .idle(completedTurnID: "turn_synthetic")), .sessionEnded),
            (ObservedSession(sessionID: sessionID, connectionID: cliConnection, liveness: .unverified, phase: .unknown), .unverified),
        ]
        for (state, reason) in later {
            let router = await ready()
            let control = try await issue(router)
            await router.observe(state)
            #expect(refused(await router.handle(try callback(control.id), connectionID: feishuConnection))?.0 == reason)
        }
    }

    // Refs: US-10, AC-10.02.
    @Test func aSecondCardForAnAcceptedTurnReportsThatTheReplyWasAlreadySent() async throws {
        let router = await ready()
        let first = try await issue(router)
        let second = try #require(await router.prepare(sessionID: sessionID, form: form))
        let secondReceipt = FeishuMessageReceipt(messageID: "om_second", chatID: "oc_synthetic", applicationID: "cli_synthetic",
                                                 ownerID: "ou_owner", tenantID: "tenant_synthetic")
        #expect(await router.bind(controlID: second.id, receipt: secondReceipt))
        _ = try accepted(await router.handle(try callback(first.id), connectionID: feishuConnection))
        let result = await router.handle(try callback(second.id, event: "event_second", message: "om_second"),
                                         connectionID: feishuConnection)
        #expect(refused(result)?.0 == .alreadySent)
    }

    // Refs: US-05, AC-05.09; US-10, AC-10.02.
    @Test func anAcceptedCardKeepsItsReceiptAfterTheWindowClosesAndAnInFlightCardNeverBecomesUsable() async throws {
        let router = await ready()
        let control = try await issue(router)
        let action = try accepted(await router.handle(try callback(control.id), connectionID: feishuConnection))
        #expect(await router.claim(action, connectionID: feishuConnection))
        await router.updateReceipt(action.receipt.id, status: .submitted)
        await router.observe(observation(.idle(completedTurnID: "turn_after")))
        let inFlight = try #require(await router.prepare(sessionID: sessionID, form: form))
        var unlocked = access
        unlocked.awayMode = false
        await router.setAccess(unlocked, connectionID: feishuConnection)
        guard case .duplicate(let receipt) = await router.handle(try callback(control.id, event: "event_again"),
                                                                 connectionID: feishuConnection) else {
            Issue.record("A consumed card keeps answering with its receipt"); return
        }
        #expect(receipt.status == .submitted)
        let late = FeishuMessageReceipt(messageID: "om_late", chatID: "oc_synthetic", applicationID: "cli_synthetic",
                                        ownerID: "ou_owner", tenantID: "tenant_synthetic")
        #expect(!(await router.bind(controlID: inFlight.id, receipt: late)))
        let result = await router.handle(try callback(inFlight.id, event: "event_late", message: "om_late"),
                                         connectionID: feishuConnection)
        #expect(refused(result)?.0 == .replyWindowClosed)
    }

    // Refs: US-05, AC-05.09; US-10, AC-10.04.
    @Test func withdrawnControlsAreUnknownAndRevokedCardsCountUntilTheirValidityEnds() async throws {
        let clock = CardTestTime()
        let router = await ready(clock: clock)
        let unsent = try #require(await router.prepare(sessionID: sessionID, form: form))
        #expect(await router.outstandingCards() == 0)
        await router.withdraw(controlID: unsent.id)
        #expect(!(await router.bind(controlID: unsent.id, receipt: receipt)))
        #expect(unavailable(await router.handle(try callback(unsent.id), connectionID: feishuConnection)))
        let sent = try await issue(router)
        #expect(await router.outstandingCards() == 1)
        var unlocked = access
        unlocked.awayMode = false
        await router.setAccess(unlocked, connectionID: feishuConnection)
        #expect(await router.outstandingCards() == 1)
        clock.advance(600)
        #expect(await router.outstandingCards() == 0)
        #expect(refused(await router.handle(try callback(sent.id, event: "event_after"), connectionID: feishuConnection))?.0
                == .replyWindowClosed)
        clock.advance(600)
        #expect(unavailable(await router.handle(try callback(sent.id, event: "event_forgotten"), connectionID: feishuConnection)))
    }

    // Refs: US-08, AC-08.01; US-10, AC-10.02.
    @Test func textTheCLICannotCarryUnambiguouslyIsRejectedWithoutConsumingTheCard() async throws {
        let router = await ready()
        let control = try await issue(router)
        for text in ["--help", "-h", "Clear \u{1B}[2J now", "Look \u{202E}fdp.exe", "Bell\u{7}"] {
            guard case .invalidInput = await router.handle(try callback(control.id, text: text), connectionID: feishuConnection) else {
                Issue.record("Option-like or control text must be corrected, not forwarded"); continue
            }
        }
        let action = try accepted(await router.handle(try callback(control.id, text: "Use - as a list marker ✓"),
                                                      connectionID: feishuConnection))
        #expect(action.input == .followup("Use - as a list marker ✓"))
    }
}
