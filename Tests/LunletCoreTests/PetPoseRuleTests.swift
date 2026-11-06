// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-39, AC-39.03, AC-39.04, AC-39.07; US-13, AC-13.02, AC-13.04.
import Foundation
import Testing
@testable import LunletCore

struct PetPoseRuleTests {
    private func snapshot(_ phase: SessionPhase, id: UUID = UUID(), provider: SessionProvider = .codex, ended: Bool = false,
                          parent: UUID? = nil, confirmed: Bool = true) -> SessionSnapshot {
        SessionSnapshot(observation: .init(sessionID: id, connectionID: UUID(), liveness: ended ? .ended : confirmed ? .alive : .unverified, phase: phase),
                        project: "lunlet", activityConfirmed: confirmed, parentSessionID: parent, provider: provider)
    }
    private func cue(for snapshot: SessionSnapshot, outcome: TaskCue.Outcome = .succeeded) -> TaskCue {
        TaskCue(sessionID: snapshot.observation.sessionID.uuidString, connectionID: snapshot.observation.connectionID.uuidString,
                turnID: "t", title: "lunlet", phase: .finished(outcome))
    }

    @Test func posesFollowPrecedenceOverCurrentConversations() {
        let waiting = snapshot(.approval), running = snapshot(.running, provider: .claude), idle = snapshot(.idle(completedTurnID: "t"))
        let all = [idle, running, waiting]
        let state = PetPoseRule.state(sessions: all, cue: cue(for: idle), monitoringAvailable: true)
        #expect(state.pose == .waiting && state.sessionID == waiting.observation.sessionID)
        #expect(state.sessionCount == 3 && state.waitingCount == 1 && state.runningCount == 1)
        #expect(state.summary == "lunlet · Codex · Approval needed")
        let done = PetPoseRule.state(sessions: [idle, running], cue: cue(for: idle), monitoringAvailable: true)
        #expect(done.pose == .done && done.sessionID == idle.observation.sessionID && done.pose.bubble == "✓")
        let working = PetPoseRule.state(sessions: [idle, running], cue: nil, monitoringAvailable: true)
        #expect(working.pose == .working && working.summary == "lunlet · Claude · Working" && working.pose.bubble == nil)
        #expect(PetPoseRule.state(sessions: [idle], cue: nil, monitoringAvailable: true).pose == .idle)
        #expect(PetPoseRule.state(sessions: [], cue: nil, monitoringAvailable: true).pose == .asleep)
        #expect(PetPoseRule.state(sessions: [], cue: nil, monitoringAvailable: false).summary == "Monitoring unavailable")
        #expect(PetPose.waiting.bubble == "?")
    }

    @Test func childTasksEndedSessionsAndFailedCuesDoNotDriveThePose() {
        let parent = snapshot(.idle(completedTurnID: "t"))
        let child = snapshot(.approval, parent: parent.observation.sessionID)
        let ended = snapshot(.ended, ended: true)
        let unconfirmed = snapshot(.running, confirmed: false)
        let state = PetPoseRule.state(sessions: [parent, child, ended, unconfirmed], cue: nil, monitoringAvailable: true)
        #expect(state.pose == .idle && state.sessionCount == 1 && state.waitingCount == 0)
        // A failed or stopped turn is not a Done pose, and a cue for an unknown session is ignored.
        #expect(PetPoseRule.state(sessions: [parent], cue: cue(for: parent, outcome: .failed), monitoringAvailable: true).pose == .idle)
        #expect(PetPoseRule.state(sessions: [parent], cue: cue(for: ended), monitoringAvailable: true).pose == .idle)
    }

    @Test func accessibilityLabelNamesCountsInWords() {
        #expect(PetState(pose: .waiting, sessionID: nil, sessionCount: 2, waitingCount: 1, runningCount: 1, summary: nil).accessibilityLabel
                == "Lunlet: two sessions, one waiting for you")
        #expect(PetState(pose: .working, sessionID: nil, sessionCount: 1, waitingCount: 0, runningCount: 1, summary: nil).accessibilityLabel
                == "Lunlet: one session, one working")
        #expect(PetState(pose: .done, sessionID: nil, sessionCount: 3, waitingCount: 0, runningCount: 0, summary: nil).accessibilityLabel
                == "Lunlet: three sessions, one just finished")
        #expect(PetState(pose: .asleep, sessionID: nil, sessionCount: 0, waitingCount: 0, runningCount: 0, summary: nil).accessibilityLabel
                == "Lunlet: no sessions")
    }
}
