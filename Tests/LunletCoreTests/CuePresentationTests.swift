// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-13, AC-13.01, AC-13.02, AC-13.03, AC-13.04, AC-13.05, AC-13.08.
import Testing
@testable import LunletCore

private func cue(session: String = "session-a", connection: String = "connection-a",
                 turn: String = "turn-a", phase: TaskCue.Phase = .started) -> TaskCue {
    TaskCue(sessionID: session, connectionID: connection, turnID: turn, title: "Synthetic project", phase: phase)
}
private let duration = CuePresentation.displayDuration

// AC-13.08: a cue stays about five seconds, then expires.
@Test func aCueStaysAboutFiveSeconds() {
    #expect(CuePresentation.displayDuration == 5)
    let panel = CuePresentation()
    panel.setDisplayAvailable(true)
    panel.receive(cue(), origin: .liveTransition, now: 10)
    panel.expire(now: 14.9)
    #expect(!panel.cues.isEmpty)
    panel.expire(now: 15)
    #expect(panel.cues.isEmpty)
}

@Test func baselineSnapshotsAndReconnectionDoNotCreateTaskCues() {
    let panel = CuePresentation()
    panel.setDisplayAvailable(true)
    panel.receive(cue(), origin: .snapshot, now: 10)
    #expect(panel.cues.isEmpty)
    panel.receive(cue(), origin: .liveTransition, now: 11)
    #expect(panel.cues.isEmpty)
    panel.receive(cue(turn: "turn-b"), origin: .liveTransition, now: 12)
    #expect(panel.cues.map(\.turnID) == ["turn-b"])
    panel.expire(now: 12 + duration)
    panel.receive(cue(connection: "reconnected", turn: "turn-b"), origin: .snapshot, now: 13 + duration)
    #expect(panel.cues.isEmpty)
}

@Test func duplicateTransitionsCannotExtendOrReplayTheTransientCue() {
    let panel = CuePresentation()
    panel.setDisplayAvailable(true)
    panel.receive(cue(), origin: .liveTransition, now: 10)
    #expect(!panel.cues.isEmpty)
    panel.receive(cue(), origin: .liveTransition, now: 13)
    panel.expire(now: 10 + duration)
    #expect(panel.cues.isEmpty)
    panel.receive(cue(), origin: .liveTransition, now: 11 + duration)
    #expect(panel.cues.isEmpty)
}

@Test func lockedOrSleepingTransitionsAreConsumedWithoutReplayOnReturn() {
    let panel = CuePresentation()
    panel.receive(cue(), origin: .liveTransition, now: 10)
    panel.setDisplayAvailable(true)
    #expect(panel.cues.isEmpty)
    panel.receive(cue(turn: "turn-b"), origin: .liveTransition, now: 11)
    #expect(!panel.cues.isEmpty)
    panel.setDisplayAvailable(false)
    #expect(panel.cues.isEmpty)
    let completion = cue(turn: "turn-b", phase: .finished(.succeeded))
    panel.receive(completion, origin: .liveTransition, now: 12)
    panel.setDisplayAvailable(true)
    panel.receive(completion, origin: .liveTransition, now: 13)
    #expect(panel.cues.isEmpty)
}

@Test func latestConcurrentEventImmediatelyReplacesThePreviousCue() {
    let panel = CuePresentation()
    panel.setDisplayAvailable(true)
    panel.receive(cue(), origin: .liveTransition, now: 10)
    let other = cue(session: "session-b", phase: .finished(.failed))
    panel.receive(other, origin: .liveTransition, now: 11)
    #expect(panel.cues == [other])
    let completed = cue(phase: .finished(.unknown))
    panel.receive(completed, origin: .liveTransition, now: 12)
    #expect(panel.cues == [completed])
    panel.expire(now: 12 + duration)
    #expect(panel.cues.isEmpty)
}

@Test func aLateStartCannotReplaceACompletedTurnCue() {
    let panel = CuePresentation()
    panel.setDisplayAvailable(true)
    let completed = cue(phase: .finished(.failed))
    panel.receive(completed, origin: .liveTransition, now: 10)
    panel.receive(cue(), origin: .liveTransition, now: 11)
    #expect(panel.cues == [completed])
    panel.expire(now: 10 + duration)
    #expect(panel.cues.isEmpty)
}

// Refs: US-13, AC-13.07; US-15, AC-15.02.
@Test func distinctInputsInOneTurnEachCreateACueButDuplicatesAndLateStartsDoNot() {
    let panel = CuePresentation(); panel.setDisplayAvailable(true)
    func input(_ id: String, phase: TaskCue.Phase = .started) -> TaskCue {
        .init(sessionID: "session", connectionID: "connection", turnID: "same-turn", title: "Synthetic", phase: phase, inputActivityID: id)
    }
    panel.receive(input("first"), origin: .snapshot, now: 0)
    panel.receive(input("second"), origin: .liveTransition, now: 1)
    #expect(panel.cues.first?.inputActivityID == "second")
    panel.expire(now: 1 + duration)
    #expect(panel.cues.isEmpty)
    panel.receive(input("second"), origin: .liveTransition, now: 2 + duration)
    #expect(panel.cues.isEmpty)
    panel.receive(input("third", phase: .finished(.unknown)), origin: .liveTransition, now: 3 + duration)
    panel.receive(input("third"), origin: .liveTransition, now: 4 + duration)
    #expect(panel.cues.first?.phase == .finished(.unknown))
    panel.expire(now: 3 + 2 * duration)
    #expect(panel.cues.isEmpty)
    panel.receive(input("fourth"), origin: .liveTransition, now: 4 + 2 * duration)
    #expect(panel.cues.first?.inputActivityID == "fourth")
}

// Refs: US-13, AC-13.04, AC-13.07.
@Test func pendingInputAndItsAssignedTurnShareOneStartCue() {
    let panel = CuePresentation(); panel.setDisplayAvailable(true)
    func started(_ turn: String) -> TaskCue {
        .init(sessionID: "session", connectionID: "connection", turnID: turn, title: "Synthetic", phase: .started, inputActivityID: "same-input")
    }
    panel.receive(started("previous-turn"), origin: .liveTransition, now: 0)
    panel.expire(now: duration)
    panel.receive(started("assigned-turn"), origin: .liveTransition, now: duration + 1)
    #expect(panel.cues.isEmpty)
}

// Refs: US-13, AC-13.04.
@Test func consumedTransitionsStayBoundedWithoutReplayingRecentWork() {
    let panel = CuePresentation(); panel.setDisplayAvailable(true)
    let limit = CuePresentation.retainedTransitions
    // Each completion consumes its own key and the matching start key.
    for index in 0..<limit {
        panel.receive(cue(turn: "turn-\(index)", phase: .finished(.succeeded)), origin: .snapshot, now: 0)
    }
    #expect(panel.consumedCount == limit)
    for index in (limit - 8)..<limit {
        panel.receive(cue(turn: "turn-\(index)", phase: .finished(.succeeded)), origin: .liveTransition, now: 1)
        panel.receive(cue(turn: "turn-\(index)"), origin: .liveTransition, now: 1)
    }
    #expect(panel.cues.isEmpty)
    panel.receive(cue(turn: "new", phase: .finished(.succeeded)), origin: .liveTransition, now: 2)
    #expect(panel.cues.first?.turnID == "new")
    #expect(panel.consumedCount == limit)
}
