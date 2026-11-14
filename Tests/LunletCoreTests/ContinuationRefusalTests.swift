// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-08, AC-08.01, AC-08.03; US-09, AC-09.01, AC-09.02; US-10, AC-10.01, AC-10.02, AC-10.04.
// Refs: US-11, AC-11.03, AC-11.04; US-05, AC-05.09.
import Foundation
import Testing
import LunletCore

private let session = UUID(uuidString: "40000000-0000-4000-8000-000000000004")!
private let binding = UUID(uuidString: "50000000-0000-4000-8000-000000000005")!
private let owner = FeishuOwner(applicationID: "test-app", tenantID: "test-tenant", userID: "test-owner")

private func observed(_ phase: SessionPhase, liveness: CLILiveness = .alive, connection: UUID = binding) -> ObservedSession {
    ObservedSession(sessionID: session, connectionID: connection, liveness: liveness, phase: phase)
}

struct ContinuationRefusalTests {
    private let issued = observed(.idle(completedTurnID: "turn-1"))

    @Test func laterObservationsNameTheReasonAnIssuedControlCannotBeUsed() {
        let cases: [(ObservedSession?, ContinuationRefusal)] = [
            (observed(.running), .sessionRunning),
            (observed(.approval), .awaitingApproval),
            (observed(.idle(completedTurnID: "turn-2")), .superseded),
            (observed(.question(turnID: "turn-2", requestID: "r", itemID: "i", questionIDs: ["q"], purpose: .ordinary)), .superseded),
            // The same observation again proves nothing was sent: the control was dropped while the session
            // could not be confirmed, and only an accepted reply makes it "already sent" (below).
            (observed(.idle(completedTurnID: "turn-1")), .unverified),
            (observed(.ended, liveness: .ended), .sessionEnded),
            (observed(.idle(completedTurnID: "turn-1"), liveness: .ended), .sessionEnded),
            // A restored session is a new binding; old controls never revive.
            (observed(.idle(completedTurnID: "turn-1"), connection: UUID()), .sessionEnded),
            (observed(.idle(completedTurnID: "turn-1"), liveness: .unverified), .unverified),
            (observed(.unknown), .unverified),
            (nil, .unverified),
            (ObservedSession(sessionID: UUID(), connectionID: binding, liveness: .alive, phase: .running), .unverified),
        ]
        for (current, expected) in cases {
            #expect(ContinuationRefusal.classify(issued: issued, current: current) == expected)
        }
    }

    // Refs: US-10, AC-10.01, AC-10.04. "Already sent" is said only when a reply for this exact turn was accepted;
    // the fact never overrides what a changed session says.
    @Test func alreadySentNeedsAnAcceptedReplyForTheUnchangedTurn() {
        #expect(ContinuationRefusal.classify(issued: issued, current: issued, submitted: true) == .alreadySent)
        #expect(ContinuationRefusal.classify(issued: issued, current: issued, submitted: false) == .unverified)
        #expect(ContinuationRefusal.classify(issued: issued, current: observed(.running), submitted: true) == .sessionRunning)
        #expect(ContinuationRefusal.classify(issued: issued, current: observed(.idle(completedTurnID: "turn-2")), submitted: true) == .superseded)
        #expect(ContinuationRefusal.classify(issued: issued, current: nil, submitted: true) == .unverified)
    }

    @Test func followupTextMustBeOneUnambiguousPrintableArgument() {
        for text in ["Continue", "Fix it - then test", "café ✓\nnext line\twith tab\r\n", "👨‍👩‍👧 family emoji keeps its joiners",
                     "Use <b> tags, then report >", "<b>bold</b> is fine inside a sentence",
                     String(repeating: "a", count: ContinuationText.maximumBytes)] {
            #expect(ContinuationText.isForwardable(text))
        }
        for text in ["", " \n\t", "-", "--dangerously-bypass-approvals-and-sandbox", "-h",
                     "nul\u{0}", "escape \u{1B}[2J", "bell \u{7}", "c1 \u{85}", "delete \u{7F}",
                     "override \u{202E}", "isolate \u{2066}", " <environment_context>x</environment_context>\n",
                     String(repeating: "a", count: ContinuationText.maximumBytes + 1)] {
            #expect(!ContinuationText.isForwardable(text))
        }
    }

    @Test func normalizationComposesAndCollapsesWhitespaceOnly() {
        #expect(ContinuationText.normalized(" Cafe\u{301}\n\n  next\tstep ") == "Café next step")
        #expect(ContinuationText.normalized("A b") != ContinuationText.normalized("a b"))
    }

    @Test func receiptsOnlyMoveForward() {
        #expect(ActionStatus.received.canTransition(to: .submitted))
        #expect(ActionStatus.submitted.canTransition(to: .processing))
        #expect(ActionStatus.uncertain.canTransition(to: .processing))
        #expect(!ActionStatus.processing.canTransition(to: .submitted))
        #expect(!ActionStatus.failed.canTransition(to: .processing))
        #expect(!ActionStatus.submitted.canTransition(to: .submitted))
    }

    // Refs: US-05, AC-05.09; US-08, AC-08.01. A reply control follows the turn: two observations of one turn may
    // differ in presentation, but never in binding, phase, agent, input path or parent.
    @Test func twoObservationsAreTheSameTurnOnlyWhenBindingPhaseAgentAndInputPathAgree() {
        let base = SessionSnapshot(observation: issued, project: "p", title: "First title")
        let later = SessionSnapshot(observation: issued, project: "p", title: "Renamed", publicConclusion: "Done.",
                                    lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000), localPreview: "preview")
        #expect(base != later && base.observesSameTurn(as: later) && later.observesSameTurn(as: base))
        let others = [
            SessionSnapshot(observation: observed(.idle(completedTurnID: "turn-2")), project: "p"),
            SessionSnapshot(observation: observed(.running), project: "p"),
            SessionSnapshot(observation: observed(.idle(completedTurnID: "turn-1"), liveness: .unverified), project: "p"),
            SessionSnapshot(observation: observed(.idle(completedTurnID: "turn-1"), connection: UUID()), project: "p"),
            SessionSnapshot(observation: issued, project: "p", parentSessionID: UUID()),
            SessionSnapshot(observation: issued, project: "p", provider: .claude),
            SessionSnapshot(observation: issued, project: "p", provider: .claude, inputPath: .claudeHook),
        ]
        for other in others { #expect(!base.observesSameTurn(as: other)) }
    }

    // Refs: US-05, AC-05.09; US-10, AC-10.04. A sender asks whether the control it is about to bind can still take
    // its one reply; the answer follows exactly what `submit` would accept.
    @Test func aControlIsUsableOnlyWhileSubmitWouldAcceptIt() throws {
        let gate = ContinuationGate()
        let access = MobileAccess(owner: owner, connected: true, awayMode: true, inputEnabled: true)
        gate.setAccess(access)
        gate.observe(issued)
        let control = try #require(gate.issueControl(for: session, now: 1))
        #expect(gate.isUsable(controlID: control.id, now: 2))
        #expect(!gate.isUsable(controlID: UUID(), now: 2))
        #expect(!gate.isUsable(controlID: control.id, now: 1 + ContinuationGate.controlLifetime))
        // The session started another turn: the control is gone for good, even when the turn is seen idle again.
        gate.observe(observed(.running))
        gate.observe(issued)
        #expect(!gate.isUsable(controlID: control.id, now: 3))
        // A changed access (the Mac was unlocked) retires every control.
        let again = try #require(gate.issueControl(for: session, now: 4))
        gate.setAccess(MobileAccess(owner: owner, connected: true, awayMode: false, inputEnabled: true))
        #expect(!gate.isUsable(controlID: again.id, now: 5))
        // A used control takes no second reply.
        gate.setAccess(access)
        gate.observe(issued)
        let used = try #require(gate.issueControl(for: session, now: 6))
        guard case .accepted = gate.submit(controlID: used.id, callbackID: "c1", owner: owner, input: .followup("Go"), now: 7) else {
            Issue.record("A usable control must authorize once"); return
        }
        #expect(!gate.isUsable(controlID: used.id, now: 8))
    }

    @Test func aWithdrawnControlCannotAuthorizeAndAnAcceptedOneKeepsItsReservation() throws {
        let gate = ContinuationGate()
        gate.setAccess(MobileAccess(owner: owner, connected: true, awayMode: true, inputEnabled: true))
        gate.observe(issued)
        let unsent = try #require(gate.issueControl(for: session, now: 1))
        #expect(unsent.expiresAt == 1 + ContinuationGate.controlLifetime)
        gate.withdraw(controlID: unsent.id)
        #expect(gate.submit(controlID: unsent.id, callbackID: "c1", owner: owner, input: .followup("Go"), now: 2) == .rejected)
        #expect(!gate.hasSubmitted(for: issued))
        let sent = try #require(gate.issueControl(for: session, now: 3))
        guard case .accepted = gate.submit(controlID: sent.id, callbackID: "c2", owner: owner, input: .followup("Go"), now: 4) else {
            Issue.record("The delivered control must authorize once"); return
        }
        gate.withdraw(controlID: sent.id)
        #expect(gate.hasSubmitted(for: issued))
        guard case .duplicate = gate.submit(controlID: sent.id, callbackID: "c2", owner: owner, input: .followup("Go"), now: 5) else {
            Issue.record("Withdrawal cannot erase an accepted action"); return
        }
        #expect(gate.issueControl(for: session, now: 6) == nil)
    }
}
