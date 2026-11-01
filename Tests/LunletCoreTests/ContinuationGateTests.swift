// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-07, AC-07.02, AC-07.03, AC-07.04; US-08, AC-08.03;
// US-09, AC-09.02; US-10, AC-10.01, AC-10.02, AC-10.03, AC-10.04;
// US-11, AC-11.02, AC-11.03, AC-11.04, AC-11.05, AC-11.06;
// US-12, AC-12.01, AC-12.02, AC-12.03.
import Foundation
import Testing
import LunletCore

private let sessionID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
private let connectionID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
private let owner = FeishuOwner(applicationID: "test-app", tenantID: "test-tenant", userID: "test-owner")
private let now = TimeInterval(1_000)
private let idle = ObservedSession(sessionID: sessionID, connectionID: connectionID,
                                   liveness: .alive, phase: .idle(completedTurnID: "turn-1"))

private func configuredGate(_ session: ObservedSession = idle) -> ContinuationGate {
    let gate = ContinuationGate()
    gate.setAccess(MobileAccess(owner: owner, connected: true, awayMode: true, inputEnabled: true))
    gate.observe(session)
    return gate
}

private func submit(_ gate: ContinuationGate, _ control: ContinuationControl,
                    callbackID: String = "callback-1", as identity: FeishuOwner = owner,
                    input: ContinuationInput = .followup("Continue the unfinished task"),
                    at date: TimeInterval = now) -> ContinuationDecision {
    gate.submit(controlID: control.id, callbackID: callbackID, owner: identity, input: input, now: date)
}

private func requiredControl(_ gate: ContinuationGate) throws -> ContinuationControl {
    let issued = gate.issueControl(for: sessionID, now: now)
    return try #require(issued)
}

@Test func acceptsOnlyTheExactCurrentSessionAndCompletedTurn() throws {
    let gate = configuredGate()
    let control = try requiredControl(gate)
    guard case .accepted(let action) = submit(gate, control) else {
        Issue.record("A verified idle session should accept one follow-up")
        return
    }
    #expect(action.session == idle)
    #expect(action.input == .followup("Continue the unfinished task"))
    #expect(action.receipt.sessionID == sessionID)
    #expect(action.receipt.status == .received)
}

@Test func rejectsUnverifiedOrEndedCLIWithoutTrustingLoadedState() {
    for liveness in [CLILiveness.unverified, .ended] {
        let session = ObservedSession(sessionID: sessionID, connectionID: connectionID,
                                      liveness: liveness, phase: .idle(completedTurnID: "turn-1"))
        let gate = configuredGate(session)
        let issued1 = gate.issueControl(for: sessionID, now: now)
        #expect(issued1 == nil)
    }
}

@Test func rejectsDifferentOwnerApplicationAndTenant() throws {
    let gate = configuredGate()
    let control = try requiredControl(gate)
    for identity in [
        FeishuOwner(applicationID: "other-app", tenantID: "test-tenant", userID: "test-owner"),
        FeishuOwner(applicationID: "test-app", tenantID: "other-tenant", userID: "test-owner"),
        FeishuOwner(applicationID: "test-app", tenantID: "test-tenant", userID: "other-owner"),
    ] {
        #expect(submit(gate, control, as: identity) == .rejected)
    }
    guard case .accepted = submit(gate, control) else {
        Issue.record("Unauthorized submissions must not consume the owner's control")
        return
    }
}

@Test func rejectsStaleControlAfterRunningApprovalExitOrRestore() throws {
    for phase in [SessionPhase.running, .approval, .ended, .unknown, .idle(completedTurnID: "turn-2")] {
        let gate = configuredGate()
        let control = try requiredControl(gate)
        gate.observe(ObservedSession(sessionID: sessionID, connectionID: connectionID,
                                     liveness: .alive, phase: phase))
        #expect(submit(gate, control, input: .followup("yes")) == .rejected)
    }
    let gate = configuredGate()
    let control = try requiredControl(gate)
    gate.observe(ObservedSession(sessionID: sessionID, connectionID: UUID(),
                                 liveness: .alive, phase: idle.phase))
    #expect(submit(gate, control) == .rejected)
}

@Test func duplicateCallbacksAndRepeatedTapsCannotExecuteAgain() throws {
    let gate = configuredGate()
    let control = try requiredControl(gate)
    guard case .accepted(let action) = submit(gate, control) else {
        Issue.record("First action was not accepted")
        return
    }
    #expect(submit(gate, control) == .duplicate(action.receipt))
    #expect(submit(gate, control, callbackID: "different-tap") == .duplicate(action.receipt))
}

@Test func twoControlsForOneCompletedTurnCannotBothExecute() throws {
    let gate = configuredGate()
    let first = try requiredControl(gate)
    let second = try requiredControl(gate)
    guard case .accepted = submit(gate, first) else {
        Issue.record("First action was not accepted")
        return
    }
    #expect(submit(gate, second, callbackID: "callback-2") == .rejected)
    let issued2 = gate.issueControl(for: sessionID, now: now)
    #expect(issued2 == nil)
}

@Test func expiredControlsCannotExecuteEvenAtTheExactDeadline() throws {
    let gate = configuredGate()
    let control = try requiredControl(gate)
    #expect(submit(gate, control, at: control.expiresAt) == .rejected)
}

@Test func accessChangesPermanentlyInvalidateOldControls() throws {
    for disabled in [
        MobileAccess(owner: owner, connected: true, awayMode: false, inputEnabled: true),
        MobileAccess(owner: owner, connected: false, awayMode: true, inputEnabled: true),
        MobileAccess(owner: owner, connected: true, awayMode: true, inputEnabled: false),
        MobileAccess(owner: nil, connected: true, awayMode: true, inputEnabled: true),
    ] {
        let gate = configuredGate()
        let old = try requiredControl(gate)
        gate.setAccess(disabled)
        gate.setAccess(MobileAccess(owner: owner, connected: true, awayMode: true, inputEnabled: true))
        #expect(submit(gate, old) == .rejected)
        let beforeRevalidation = gate.issueControl(for: sessionID, now: now)
        #expect(beforeRevalidation == nil)
        gate.observe(idle)
        let fresh = try requiredControl(gate)
        guard case .accepted = submit(gate, fresh) else {
            Issue.record("A fresh revalidated control should be usable")
            return
        }
    }
}

@Test func repeatedConnectionStatusDoesNotInvalidateFreshControls() throws {
    let gate = configuredGate()
    let control = try requiredControl(gate)
    gate.setAccess(MobileAccess(owner: owner, connected: true, awayMode: true, inputEnabled: true))
    guard case .accepted = submit(gate, control) else {
        Issue.record("An unchanged access observation must not revoke a valid control")
        return
    }
}

@Test func anotherInstallationOrRestartCannotRecoverOldControls() throws {
    let original = configuredGate()
    let control = try requiredControl(original)
    let restarted = configuredGate()
    #expect(submit(restarted, control) == .rejected)
}

@Test func ordinaryQuestionsBindTurnRequestItemAndQuestionIDs() throws {
    let phase = SessionPhase.question(turnID: "turn-q", requestID: "request-q", itemID: "item-q",
                                      questionIDs: ["color"], purpose: .ordinary)
    let session = ObservedSession(sessionID: sessionID, connectionID: connectionID,
                                  liveness: .alive, phase: phase)
    let gate = configuredGate(session)
    let control = try requiredControl(gate)
    #expect(submit(gate, control, input: .answer(["another-question": ["Blue"]])) == .rejected)
    guard case .accepted(let action) = submit(gate, control, input: .answer(["color": ["Blue"]])) else {
        Issue.record("A bound ordinary answer should be accepted")
        return
    }
    #expect(action.session == session)
    #expect(action.input == .answer(["color": ["Blue"]]))
}

@Test func supersededQuestionsCannotAnswerTheNextRequest() throws {
    let old = SessionPhase.question(turnID: "turn-q", requestID: "request-old", itemID: "item-old",
                                    questionIDs: ["color"], purpose: .ordinary)
    let gate = configuredGate(ObservedSession(sessionID: sessionID, connectionID: connectionID,
                                              liveness: .alive, phase: old))
    let control = try requiredControl(gate)
    gate.observe(ObservedSession(sessionID: sessionID, connectionID: connectionID, liveness: .alive,
                                 phase: .question(turnID: "turn-q", requestID: "request-new", itemID: "item-new",
                                                  questionIDs: ["color"], purpose: .ordinary)))
    #expect(submit(gate, control, input: .answer(["color": ["Blue"]])) == .rejected)
}

@Test func protocolUserInputDoesNotAuthorizeAnUnknownOrPermissionQuestion() {
    for purpose in [QuestionPurpose.authorization, .unknown] {
        let gate = configuredGate(ObservedSession(sessionID: sessionID, connectionID: connectionID, liveness: .alive,
                                                  phase: .question(turnID: "turn-q", requestID: "request-q", itemID: "item-q",
                                                                   questionIDs: ["confirm"], purpose: purpose)))
        let issued3 = gate.issueControl(for: sessionID, now: now)
        #expect(issued3 == nil)
    }
    let gate = configuredGate(ObservedSession(sessionID: sessionID, connectionID: connectionID,
                                              liveness: .alive, phase: .approval))
    let issued4 = gate.issueControl(for: sessionID, now: now)
    #expect(issued4 == nil)
}

@Test func uncertainSubmissionCannotBeBlindlyResubmitted() throws {
    let gate = configuredGate()
    let control = try requiredControl(gate)
    guard case .accepted(let action) = submit(gate, control) else {
        Issue.record("First action was not accepted")
        return
    }
    gate.updateReceipt(action.receipt.id, status: .uncertain)
    var expected = action.receipt
    expected.status = .uncertain
    #expect(submit(gate, control) == .duplicate(expected))
    gate.observe(idle)
    let issued5 = gate.issueControl(for: sessionID, now: now)
    #expect(issued5 == nil)
    gate.observe(ObservedSession(sessionID: sessionID, connectionID: connectionID,
                                 liveness: .alive, phase: .idle(completedTurnID: "turn-2")))
    let issued6 = gate.issueControl(for: sessionID, now: now)
    #expect(issued6 != nil)
}

@Test func processingReceiptCannotRegressToTransportSuccess() throws {
    let gate = configuredGate()
    let control = try requiredControl(gate)
    guard case .accepted(let action) = submit(gate, control) else {
        Issue.record("First action was not accepted")
        return
    }
    gate.updateReceipt(action.receipt.id, status: .processing)
    gate.updateReceipt(action.receipt.id, status: .submitted)
    var expected = action.receipt
    expected.status = .processing
    #expect(submit(gate, control) == .duplicate(expected))
}

@Test func rejectsMismatchedInputKindsAndEmptyInstructions() throws {
    let gate = configuredGate()
    let control = try requiredControl(gate)
    #expect(submit(gate, control, input: .answer(["color": ["Blue"]])) == .rejected)
    #expect(submit(gate, control, input: .followup(" \n\t")) == .rejected)
    #expect(submit(gate, control, callbackID: "") == .rejected)
}

@Test func endedCLIConnectionCannotBeRevivedByRetainedIdleMetadata() throws {
    let gate = configuredGate()
    let old = try requiredControl(gate)
    gate.observe(ObservedSession(sessionID: sessionID, connectionID: connectionID,
                                 liveness: .ended, phase: .ended))
    gate.observe(idle)
    let retained = gate.issueControl(for: sessionID, now: now)
    #expect(retained == nil)
    #expect(submit(gate, old) == .rejected)

    gate.observe(ObservedSession(sessionID: sessionID, connectionID: UUID(),
                                 liveness: .alive, phase: idle.phase))
    let restored = gate.issueControl(for: sessionID, now: now)
    #expect(restored != nil)
}

@Test func callbackForAnEarlierTurnCannotSubmitALaterControl() throws {
    let gate = configuredGate()
    let first = try requiredControl(gate)
    guard case .accepted = submit(gate, first) else {
        Issue.record("First action was not accepted")
        return
    }
    gate.observe(ObservedSession(sessionID: sessionID, connectionID: connectionID,
                                 liveness: .alive, phase: .idle(completedTurnID: "turn-2")))
    let next = try requiredControl(gate)
    #expect(submit(gate, next) == .rejected)
    guard case .accepted = submit(gate, next, callbackID: "callback-2") else {
        Issue.record("The fresh callback should target the later turn")
        return
    }
}

@Test func previouslyReservedTargetStaysBlockedAcrossLaterTurns() throws {
    let gate = configuredGate()
    let first = try requiredControl(gate)
    guard case .accepted(let action) = submit(gate, first) else {
        Issue.record("First action was not accepted")
        return
    }
    gate.updateReceipt(action.receipt.id, status: .uncertain)
    gate.observe(ObservedSession(sessionID: sessionID, connectionID: connectionID,
                                 liveness: .alive, phase: .idle(completedTurnID: "turn-2")))
    let later = try requiredControl(gate)
    guard case .accepted = submit(gate, later, callbackID: "callback-2") else {
        Issue.record("The later turn was not accepted")
        return
    }
    gate.observe(ObservedSession(sessionID: sessionID, connectionID: UUID(),
                                 liveness: .alive, phase: idle.phase))
    let recurring = gate.issueControl(for: sessionID, now: now)
    #expect(recurring == nil)
}

@Test func endedSessionBindingDoesNotReviveOrEndAnotherSession() throws {
    let gate = configuredGate()
    gate.observe(ObservedSession(sessionID: sessionID, connectionID: connectionID,
                                 liveness: .alive, phase: .ended))
    gate.observe(idle)
    let retained = gate.issueControl(for: sessionID, now: now)
    #expect(retained == nil)

    let otherID = UUID(uuidString: "30000000-0000-4000-8000-000000000003")!
    gate.observe(ObservedSession(sessionID: otherID, connectionID: connectionID,
                                 liveness: .alive, phase: .idle(completedTurnID: "turn-1")))
    let other = gate.issueControl(for: otherID, now: now)
    #expect(other != nil)

    gate.observe(ObservedSession(sessionID: sessionID, connectionID: UUID(),
                                 liveness: .alive, phase: idle.phase))
    let restored = gate.issueControl(for: sessionID, now: now)
    #expect(restored != nil)
}

// AC-12.01, AC-12.03: one readiness rule, and explicit invalidation keeps consumed targets.
@Test func remoteInputReadinessRequiresEveryFactAndACompleteOwner() {
    let ready = MobileAccess(owner: owner, connected: true, awayMode: true, inputEnabled: true)
    #expect(ready.allowsRemoteInput)
    var missing = Array(repeating: ready, count: 5)
    missing[0].owner = nil
    missing[1].owner = FeishuOwner(applicationID: "test-app", tenantID: "", userID: "test-owner")
    missing[2].connected = false
    missing[3].awayMode = false
    missing[4].inputEnabled = false
    for access in missing { #expect(!access.allowsRemoteInput) }
}

@Test func invalidateAllRejectsIssuedControlsWithoutReopeningConsumedTargets() throws {
    let gate = configuredGate()
    let stale = try requiredControl(gate)
    gate.invalidateAll()
    #expect(submit(gate, stale) == .rejected)

    gate.observe(idle)
    let fresh = try requiredControl(gate)
    guard case .accepted = submit(gate, fresh, callbackID: "callback-2") else {
        Issue.record("A fresh control for an unconsumed target should be accepted")
        return
    }
    gate.invalidateAll()
    gate.observe(idle)
    #expect(gate.issueControl(for: sessionID, now: now) == nil)
}
