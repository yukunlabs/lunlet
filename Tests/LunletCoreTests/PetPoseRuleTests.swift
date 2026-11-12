// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-39, AC-39.03, AC-39.04, AC-39.07; US-13, AC-13.02, AC-13.04.
import Foundation
import Testing
@testable import LunletCore

struct PetPoseRuleTests {
    private func snapshot(_ phase: SessionPhase, id: UUID = UUID(), provider: SessionProvider = .codex, ended: Bool = false,
                          parent: UUID? = nil, confirmed: Bool = true, outcome: TaskCue.Outcome = .unknown) -> SessionSnapshot {
        SessionSnapshot(observation: .init(sessionID: id, connectionID: UUID(), liveness: ended ? .ended : confirmed ? .alive : .unverified, phase: phase),
                        project: "lunlet", outcome: outcome, activityConfirmed: confirmed, parentSessionID: parent, provider: provider)
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

    @Test func aFailedTurnShowsFailedBelowWaitingAndAboveDoneForTheCueDuration() {
        // AC-39.03: Waiting over Failed over Done over Working; the Failed cue lasts as long as it is presented (AC-13.02).
        let failed = snapshot(.idle(completedTurnID: "t"), outcome: .failed), running = snapshot(.running, provider: .claude), waiting = snapshot(.approval)
        let state = PetPoseRule.state(sessions: [failed, running], cue: cue(for: failed, outcome: .failed), monitoringAvailable: true)
        #expect(state.pose == .failed && state.sessionID == failed.observation.sessionID)
        #expect(state.pose.bubble == "!" && state.pose.title == "Failed" && state.summary == "lunlet · Codex · Failed")
        #expect(state.sessionCount == 2 && state.waitingCount == 0 && state.runningCount == 1)
        #expect(PetPoseRule.state(sessions: [failed, running, waiting], cue: cue(for: failed, outcome: .failed), monitoringAvailable: true).pose == .waiting)
        // Without the cue the failed session is idle again; a stopped turn is neither Done nor Failed.
        #expect(PetPoseRule.state(sessions: [failed], cue: nil, monitoringAvailable: true).pose == .idle)
        #expect(PetPoseRule.state(sessions: [failed], cue: cue(for: failed, outcome: .stopped), monitoringAvailable: true).pose == .idle)
    }

    @Test func childTasksEndedSessionsAndStoppedCuesDoNotDriveThePose() {
        let parent = snapshot(.idle(completedTurnID: "t"))
        let child = snapshot(.approval, parent: parent.observation.sessionID)
        let ended = snapshot(.ended, ended: true)
        let unconfirmed = snapshot(.running, confirmed: false)
        let state = PetPoseRule.state(sessions: [parent, child, ended, unconfirmed], cue: nil, monitoringAvailable: true)
        #expect(state.pose == .idle && state.sessionCount == 1 && state.waitingCount == 0)
        // A stopped turn is not a Done pose, and a cue for an unknown or ended session is ignored, failed or not.
        #expect(PetPoseRule.state(sessions: [parent], cue: cue(for: parent, outcome: .stopped), monitoringAvailable: true).pose == .idle)
        #expect(PetPoseRule.state(sessions: [parent], cue: cue(for: ended), monitoringAvailable: true).pose == .idle)
        #expect(PetPoseRule.state(sessions: [parent], cue: cue(for: ended, outcome: .failed), monitoringAvailable: true).pose == .idle)
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
        // AC-39.07: a failed turn is named too.
        #expect(PetState(pose: .failed, sessionID: nil, sessionCount: 2, waitingCount: 0, runningCount: 1, summary: nil).accessibilityLabel
                == "Lunlet: two sessions, one turn failed")
    }
}
