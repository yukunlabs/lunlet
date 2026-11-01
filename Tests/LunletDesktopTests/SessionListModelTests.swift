// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-02, AC-02.02, AC-02.03, AC-02.05; US-03, AC-03.01, AC-03.03, AC-03.04.
// Refs: US-13, AC-13.01, AC-13.02, AC-13.03, AC-13.04, AC-13.05, AC-13.06; US-12, AC-12.04.
// Refs: US-11, AC-11.03; US-13, AC-13.07, AC-13.09.
// Refs: US-15, AC-15.01, AC-15.02, AC-15.03, AC-15.04.
import Combine
import Foundation
import Testing
import LunletCore
@testable import LunletDesktop

@MainActor private final class CueSink: TaskCuePresenting {
    var visible: [TaskCue] = []
    func show(_ cues: [TaskCue]) { visible = cues }
    func hide() { visible = [] }
}

@MainActor private final class CueEnvironment {
    var now: TimeInterval = 0
    var available = false
}

/// The waiting count that the menu-bar and notch entries actually present.
@MainActor private func waiting(_ model: SessionListModel) -> Int? { model.compactStatus.waiting }

@MainActor struct SessionListModelTests {
    @Test func compactStatusCountsCurrentConversationsDespiteEndedRowsAndChildTasks() {
        // AC-02.03, AC-02.05: an ended row or child task cannot make the waiting count permanently unknown.
        func snapshot(_ liveness: CLILiveness, _ phase: SessionPhase, parent: UUID? = nil) -> SessionSnapshot {
            .init(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: liveness, phase: phase),
                  project: "Synthetic", title: "Session", activityConfirmed: true, parentSessionID: parent)
        }
        let ended = snapshot(.ended, .ended), waiting = snapshot(.alive, .approval), running = snapshot(.alive, .running)
        let child = snapshot(.unverified, .unknown, parent: UUID())
        let status = CompactSessionStatus(snapshots: [ended, waiting, running, child], available: true, partial: false)
        #expect(status.waiting == 1 && status.running == 1 && status.badge == "1")
        #expect(status.description == "Codex · 1 waiting · 1 running")
        let uncertain = snapshot(.unverified, .unknown)
        #expect(CompactSessionStatus(snapshots: [ended, waiting, uncertain], available: true, partial: false).waiting == nil)
        #expect(CompactSessionStatus(snapshots: [ended, waiting], available: true, partial: true).waiting == nil)
        #expect(CompactSessionStatus(snapshots: [ended], available: false, partial: false).waiting == nil)
        #expect(CompactSessionStatus(snapshots: [ended], available: true, partial: false).badge == "")
    }
    @Test func compactStatusAndAvailabilityPublishOnlyWhenTheyChange() {
        // AC-02.03, AC-02.06: repeated snapshots without a status change do not wake either entry.
        let model = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: CueSink())
        defer { model.shutdown() }
        var statuses: [CompactSessionStatus] = [], availability: [Bool] = []
        let observations = [model.$compactStatus.sink { statuses.append($0) }, model.$monitoringAvailable.sink { availability.append($0) }]
        model.monitoringConnected(partial: false)
        let id = UUID(), connection = UUID()
        for turn in ["one", "two", "three"] {
            model.receive(.init(observation: .init(sessionID: id, connectionID: connection, liveness: .alive, phase: .running),
                                project: "Synthetic", turnID: turn), origin: .snapshot)
        }
        model.receive(.init(observation: .init(sessionID: id, connectionID: connection, liveness: .alive, phase: .approval),
                            project: "Synthetic", turnID: "three"), origin: .snapshot)
        #expect(statuses.map(\.waiting) == [nil, 0, 0, 1])
        #expect(statuses.map(\.running) == [nil, 0, 1, 0])
        #expect(availability == [false, true])
        withExtendedLifetime(observations) {}
    }
    @Test func verifiedChildSessionsAreObservedButNotDisplayedOrAnnouncedAsConversations() {
        let sink = CueSink(), model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: sink)
        defer { model.shutdown() }
        let parent = UUID(), child = UUID()
        let snapshot = SessionSnapshot(observation: .init(sessionID: child, connectionID: UUID(), liveness: .unverified, phase: .running),
            project: "Synthetic", title: "Child", turnID: "one", activityConfirmed: true, localPreview: "Synthetic task", parentSessionID: parent)
        model.receive(snapshot, origin: .liveTransition)
        #expect(model.sessions.count == 1 && model.displayedSessions.isEmpty)
        #expect(sink.visible.isEmpty)
        model.monitoringUnavailable()
        #expect(model.sessions.first?.parentSessionID == parent && model.displayedSessions.isEmpty)
    }
    @Test func unidentifiableUnknownSessionsStayHiddenUntilUsefulEvidenceArrives() {
        let model = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: CueSink())
        defer { model.shutdown() }
        let id = UUID(), connection = UUID()
        func snapshot(phase: SessionPhase = .unknown, preview: String? = nil, navigation: Bool = false, confirmed: Bool = false) -> SessionSnapshot {
            .init(observation: .init(sessionID: id, connectionID: connection, liveness: .unverified, phase: phase),
                  project: "Synthetic", activityConfirmed: confirmed,
                  navigation: navigation ? .init() : nil, localPreview: preview)
        }
        model.receive(snapshot(), origin: .snapshot)
        #expect(model.displayedSessions.isEmpty && model.sessions.count == 1)
        model.receive(snapshot(preview: "Fix the layout"), origin: .snapshot)
        #expect(model.displayedSessions.count == 1)
        model.monitoringUnavailable()
        #expect(model.displayedSessions.first?.localPreview == "Fix the layout")
        model.clearDisplayedSessions()
        model.receive(snapshot(preview: "Fix the layout"), origin: .snapshot)
        #expect(model.displayedSessions.isEmpty && model.history.count == 1)
        model.receive(snapshot(phase: .running, preview: "Fix the layout", confirmed: true), origin: .liveTransition)
        #expect(model.displayedSessions.count == 1 && model.history.isEmpty)
    }
    @Test func identifiableOrPreviouslyVerifiedSessionsRemainVisible() {
        let model = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: CueSink())
        defer { model.shutdown() }
        let id = UUID(), connection = UUID()
        let navigable = SessionSnapshot(observation: .init(sessionID: id, connectionID: connection, liveness: .unverified, phase: .unknown),
            project: "Synthetic", navigation: .init())
        model.receive(navigable, origin: .snapshot)
        #expect(model.displayedSessions == [navigable])
        let other = UUID()
        let active = SessionSnapshot(observation: .init(sessionID: other, connectionID: UUID(), liveness: .alive, phase: .running),
            project: "Synthetic", turnID: "one")
        model.receive(active, origin: .snapshot)
        model.monitoringUnavailable()
        #expect(model.displayedSessions.count == 2)
    }
    private func value(id: UUID = UUID(), connection: UUID = UUID(), phase: SessionPhase,
                       liveness: CLILiveness = .alive, turn: String? = nil) -> SessionSnapshot {
        .init(observation: .init(sessionID: id, connectionID: connection, liveness: liveness, phase: phase),
              project: "Same project", title: "Build", turnID: turn)
    }

    @Test func readOnlyRuntimeActivityKeepsClearHistoryAndCuesWithoutOriginalTerminalNavigation() async {
        let sink = CueSink(), model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: sink)
        let id = UUID(), connection = UUID()
        func runtime(_ turn: String, phase: SessionPhase) -> SessionSnapshot {
            .init(observation: .init(sessionID: id, connectionID: connection, liveness: .unverified, phase: phase),
                  project: "Runtime", title: "Session", turnID: turn, activityConfirmed: true)
        }
        model.receive(runtime("one", phase: .running), origin: .snapshot)
        #expect(model.monitoringAvailable && model.displayedSessions.count == 1)
        model.clearDisplayedSessions()
        model.receive(runtime("one", phase: .running), origin: .snapshot)
        #expect(model.displayedSessions.isEmpty)
        model.restoreAfterExplicitRefresh([id: connection])
        #expect(model.displayedSessions.count == 1)
        model.receive(runtime("one", phase: .idle(completedTurnID: "one")), origin: .liveTransition)
        #expect(model.displayedSessions.count == 1 && model.history.isEmpty)
        model.receive(runtime("two", phase: .running), origin: .liveTransition)
        #expect(model.displayedSessions.count == 1 && model.history.isEmpty)
        #expect(sink.visible.contains { $0.turnID == "two" })
        var navigated = false
        model.navigationAction = { _, _ in navigated = true; return true }
        #expect(!model.canRequestReturn(id))
        await model.returnToSession(id)
        #expect(!navigated && model.navigationUnavailableFor != nil)
        model.shutdown()
    }

    @Test func completedTurnsRemainActiveUntilClearedAndNewWorkRestoresThem() {
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: CueSink())
        let id = UUID(), connection = UUID()
        let finished = value(id: id, connection: connection, phase: .idle(completedTurnID: "done"), turn: "done")
        model.receive(finished, origin: .snapshot)
        #expect(model.displayedSessions == [finished] && model.history.isEmpty)
        model.clearDisplayedSessions()
        #expect(model.displayedSessions.isEmpty && model.history == [finished])
        model.receive(finished, origin: .snapshot)
        #expect(model.displayedSessions.isEmpty)
        let started = value(id: id, connection: connection, phase: .running, turn: "next")
        model.receive(started, origin: .liveTransition)
        #expect(model.displayedSessions == [started] && model.history.isEmpty)
        model.receive(value(id: id, connection: connection, phase: .idle(completedTurnID: "next"), turn: "next"), origin: .liveTransition)
        #expect(model.displayedSessions.count == 1 && model.history.isEmpty)
        model.shutdown()
    }

    @Test func localPreviewSurvivesClearMonitoringLossAndExit() {
        let model = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: CueSink())
        defer { model.shutdown() }
        let id = UUID(), connection = UUID()
        let snapshot = SessionSnapshot(observation: .init(sessionID: id, connectionID: connection, liveness: .alive, phase: .running),
            project: "Synthetic", title: "Session", turnID: "one", localPreview: "Improve the layout")
        model.receive(snapshot, origin: .snapshot)
        model.clearDisplayedSessions()
        model.monitoringUnavailable()
        #expect(model.history.first?.localPreview == "Improve the layout")
        let ended = SessionSnapshot(observation: .init(sessionID: id, connectionID: connection, liveness: .ended, phase: .ended),
            project: "Synthetic", title: "Session")
        model.receive(ended, origin: .snapshot)
        #expect(model.history.first?.localPreview == "Improve the layout")
        #expect(model.displayedSessions.isEmpty)
    }

    @Test func sameTurnInputRestoresClearedWorkAndShowsANewCue() {
        let sink = CueSink(), model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: sink)
        let id = UUID(), connection = UUID()
        func activity(_ input: String) -> SessionSnapshot {
            .init(observation: .init(sessionID: id, connectionID: connection, liveness: .alive, phase: .running),
                project: "Synthetic", title: "Build", turnID: "same-turn", inputActivityID: input)
        }
        model.receive(activity("first-input"), origin: .snapshot)
        model.clearDisplayedSessions()
        model.receive(activity("second-input"), origin: .liveTransition)
        #expect(model.history.isEmpty && model.displayedSessions.count == 1)
        #expect(sink.visible.first?.inputActivityID == "second-input")
        let secondContext = sink.visible.first?.context
        #expect(sink.visible.first?.title == "Synthetic" && secondContext?.isEmpty == false)
        model.clearDisplayedSessions()
        model.receive(activity("second-input"), origin: .snapshot)
        #expect(model.displayedSessions.isEmpty)
        // Recovery with a distinct verified input is new work, even if the
        // lifecycle snapshot is conservative about transient cue provenance.
        model.receive(activity("third-input"), origin: .liveTransition)
        #expect(model.displayedSessions.count == 1)
        #expect(sink.visible.first?.context != secondContext)
        // A live new input has distinct display context without exposing its body.
        model.receive(activity("fourth-input"), origin: .liveTransition)
        #expect(sink.visible.first?.context != secondContext)
        model.shutdown()
    }
    @Test func taskCueShowsLocalConversationPreview() {
        let sink = CueSink(), model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: sink)
        defer { model.shutdown() }
        let snapshot = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive, phase: .running),
            project: "Synthetic", title: "Session", turnID: "one", localPreview: "Improve the layout")
        model.receive(snapshot, origin: .liveTransition)
        #expect(sink.visible.first?.title == "Synthetic")
        #expect(sink.visible.first?.context == "Improve the layout")
    }

    // AC-13.09: opening the panel while a cue shows, or within the grace period after, focuses that cue's conversation
    // once; a later opening keeps the page last shown.
    @Test func openingSoonAfterACueFocusesItsConversationOnce() {
        let clock = CueEnvironment()
        let model = SessionListModel(displayAvailable: { true }, elapsed: { clock.now }, presenter: CueSink())
        defer { model.shutdown() }
        let id = UUID()
        model.receive(SessionSnapshot(observation: .init(sessionID: id, connectionID: UUID(), liveness: .alive, phase: .running),
                                      project: "Synthetic", title: "Session", turnID: "one", provider: .claude), origin: .liveTransition)
        clock.now = CuePresentation.displayDuration + SessionListModel.cueFocusGrace - 1
        model.applyCueFocus()
        #expect(model.cueFocus?.sessionID == id && model.cueFocus?.provider == .claude && model.selectedID == id)
        // Consumed once: opening again does not move the page.
        let first = model.cueFocus
        model.applyCueFocus()
        #expect(model.cueFocus == first)
        // After the grace period a cue no longer steers the opening.
        let late = UUID()
        model.receive(SessionSnapshot(observation: .init(sessionID: late, connectionID: UUID(), liveness: .alive, phase: .running),
                                      project: "Synthetic", title: "Other", turnID: "two", provider: .codex), origin: .liveTransition)
        clock.now += CuePresentation.displayDuration + SessionListModel.cueFocusGrace + 1
        model.applyCueFocus()
        #expect(model.cueFocus == first && model.selectedID == id)
    }

    // AC-13.07: Retained input metadata must not suppress a genuinely new turn.
    @Test func retainedInputAcrossTurnsStillShowsDistinctCuesWithoutAssignmentDuplicates() {
        let clock = CueEnvironment(), sink = CueSink()
        let model = SessionListModel(displayAvailable: { true }, elapsed: { clock.now }, presenter: sink)
        defer { model.shutdown() }
        let id = UUID(), connection = UUID()
        func activity(_ turn: String, input: String = "retained-input", pending: Bool = false) -> SessionSnapshot {
            .init(observation: .init(sessionID: id, connectionID: connection, liveness: .alive, phase: .running),
                project: "Synthetic", title: "Build", turnID: turn, inputActivityID: input, inputPending: pending)
        }
        model.receive(activity("one"), origin: .snapshot)
        model.receive(activity("two"), origin: .liveTransition)
        #expect(sink.visible.first?.turnID == "two")
        let secondContext = sink.visible.first?.context
        model.receive(activity("three"), origin: .liveTransition)
        #expect(sink.visible.first?.turnID == "three" && sink.visible.first?.context != secondContext)
        clock.now = CuePresentation.displayDuration; model.refreshPresentation()
        model.receive(activity("three"), origin: .liveTransition)
        #expect(sink.visible.isEmpty)
        model.receive(activity("three", input: "new-input", pending: true), origin: .liveTransition)
        #expect(sink.visible.first?.inputActivityID == "new-input")
        let pendingContext = sink.visible.first?.context
        clock.now = 2 * CuePresentation.displayDuration; model.refreshPresentation()
        model.receive(activity("four", input: "new-input"), origin: .liveTransition)
        model.receive(activity("four", input: "new-input"), origin: .liveTransition)
        #expect(sink.visible.isEmpty)
        let finished = SessionSnapshot(observation: .init(sessionID: id, connectionID: connection,
            liveness: .alive, phase: .idle(completedTurnID: "four")), project: "Synthetic", title: "Build",
            turnID: "four", inputActivityID: "new-input")
        model.receive(finished, origin: .liveTransition)
        #expect(sink.visible.first?.context == pendingContext)
    }

    @Test func sameProjectSessionsKeepIndependentSelectionStateAndWaitingCounts() {
        let sink = CueSink(), model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: sink)
        let first = value(phase: .running), second = value(phase: .approval)
        model.receive(first, origin: .snapshot); model.receive(second, origin: .snapshot)
        #expect(model.sessions.count == 2 && waiting(model) == 1)
        model.select(second.observation.sessionID)
        #expect(model.selected?.observation == second.observation)
        #expect(sink.visible.isEmpty)
        model.shutdown()
    }

    @Test func onlyLiveTransitionsShowCuesAndDuplicateEventsCannotExtendTheirDeadline() {
        let environment = CueEnvironment()
        let sink = CueSink(), model = SessionListModel(displayAvailable: { true }, elapsed: { environment.now }, presenter: sink)
        let first = value(phase: .running, turn: "turn")
        model.receive(first, origin: .snapshot)
        #expect(sink.visible.isEmpty)
        let second = value(phase: .running, turn: "another")
        model.receive(second, origin: .liveTransition)
        #expect(sink.visible.count == 1)
        environment.now = CuePresentation.displayDuration - 1
        model.receive(second, origin: .liveTransition)
        environment.now = CuePresentation.displayDuration
        model.refreshPresentation()
        #expect(sink.visible.isEmpty)
        model.shutdown()
    }

    @Test func unavailableDisplayConsumesEventsWithoutReplayingAfterUnlock() {
        let environment = CueEnvironment()
        let sink = CueSink(), model = SessionListModel(displayAvailable: { environment.available }, elapsed: { 0 }, presenter: sink)
        let hidden = value(phase: .idle(completedTurnID: "turn"))
        model.receive(hidden, origin: .liveTransition)
        #expect(sink.visible.isEmpty)
        environment.available = true
        model.refreshDisplayState()
        model.receive(hidden, origin: .liveTransition)
        #expect(sink.visible.isEmpty)
        model.receive(value(phase: .running, turn: "fresh"), origin: .liveTransition)
        #expect(sink.visible.count == 1)
        environment.available = false
        model.refreshDisplayState()
        #expect(sink.visible.isEmpty)
        model.shutdown()
    }

    // AC-02.05 / AC-15.04: losing monitoring must not keep stale questions or navigation evidence.
    @Test func losingMonitoringDropsPendingQuestionsAndNavigationEvidence() {
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: CueSink())
        defer { model.shutdown() }
        let id = UUID()
        let question = SessionSnapshot(
            observation: .init(sessionID: id, connectionID: UUID(), liveness: .alive,
                               phase: .question(turnID: "turn", requestID: "request", itemID: "item",
                                                questionIDs: ["q"], purpose: .ordinary)),
            project: "Synthetic", questions: [.init(id: "q", prompt: "Which branch?", kind: .text)],
            turnID: "turn", navigation: .init(applicationName: "Synthetic Terminal"))
        model.receive(question, origin: .snapshot)
        #expect(model.sessions.first?.questions.count == 1 && model.sessions.first?.navigationAvailable == true)
        model.monitoringUnavailable()
        let degraded = model.sessions.first
        #expect(degraded?.observation.liveness == .unverified && degraded?.observation.phase == .unknown)
        #expect(degraded?.questions.isEmpty == true && degraded?.navigationAvailable == false)
        #expect(!model.canRequestReturn(id))
    }

    @Test func endingTheLastVerifiedConnectionClearsItsWaitingPresentation() {
        let sink = CueSink(), model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: sink)
        let id = UUID(), connection = UUID()
        model.receive(value(id: id, connection: connection, phase: .approval), origin: .snapshot)
        #expect(model.monitoringAvailable && waiting(model) == 1)
        model.receive(value(id: id, connection: connection, phase: .ended, liveness: .ended), origin: .snapshot)
        #expect(model.displayedSessions.count == 1 && model.displayedSessions.first?.observation.phase == .ended)
        #expect(!model.monitoringAvailable && waiting(model) == nil)
        model.shutdown()
    }

    @Test func anEndedConnectionCannotReappearAndLosingMonitoringDoesNotInventActiveSessions() {
        let sink = CueSink(), model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: sink)
        let id = UUID(), connection = UUID()
        model.receive(value(id: id, connection: connection, phase: .ended, liveness: .ended), origin: .snapshot)
        model.receive(value(id: id, connection: connection, phase: .running), origin: .snapshot)
        #expect(model.displayedSessions.count == 1 && model.displayedSessions.first?.observation.phase == .ended)
        model.receive(value(id: id, phase: .approval), origin: .snapshot)
        #expect(waiting(model) == 1)
        model.monitoringUnavailable()
        #expect(!model.monitoringAvailable && waiting(model) == nil)
        #expect(model.sessions.first?.observation.liveness == .unverified)
        model.shutdown()
        #expect(sink.visible.isEmpty)
    }

    // AC-15.01: Removing presentation must not remove live observations or waiting work.
    @Test func clearingMovesVisibleSessionsToHistoryWithoutChangingObservation() {
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: CueSink())
        let first = value(phase: .running, turn: "first"), second = value(phase: .approval)
        model.receive(first, origin: .snapshot); model.receive(second, origin: .snapshot)
        model.select(first.observation.sessionID)
        model.clearDisplayedSessions()
        #expect(model.displayedSessions.isEmpty)
        #expect(model.history == [first, second])
        #expect(model.sessions == [first, second])
        #expect(waiting(model) == 1 && model.monitoringAvailable)
        #expect(model.selected == nil)
        model.clearDisplayedSessions()
        #expect(model.history.count == 2)
        model.shutdown()
    }

    // AC-15.02: Repeated events, metadata, and baseline state changes do not undo clearing.
    @Test func duplicatesMetadataAndBaselineRefreshStayInHistory() {
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: CueSink())
        let original = value(phase: .running, turn: "first")
        model.receive(original, origin: .snapshot); model.clearDisplayedSessions()
        model.receive(original, origin: .liveTransition)
        let renamed = SessionSnapshot(observation: original.observation, project: "Same project", title: "Renamed", turnID: "first")
        model.receive(renamed, origin: .liveTransition)
        #expect(model.displayedSessions.isEmpty)
        #expect(model.history.first?.title == "Renamed")
        let baseline = value(id: original.observation.sessionID, connection: original.observation.connectionID,
                             phase: .idle(completedTurnID: "first"))
        model.receive(baseline, origin: .snapshot)
        model.receive(baseline, origin: .liveTransition)
        #expect(model.displayedSessions.isEmpty)
        #expect(model.history.first?.observation.phase == .idle(completedTurnID: "first"))
        model.shutdown()
    }

    // AC-15.02: Verified phase, turn, connection, and question request transitions restore presentation.
    @Test func verifiedActivityRestoresTheRightConversation() {
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: CueSink())
        let id = UUID(), connection = UUID()
        var current = value(id: id, connection: connection, phase: .running, turn: "first")
        let other = value(phase: .approval)
        model.receive(current, origin: .snapshot); model.receive(other, origin: .snapshot)
        let transitions = [
            value(id: id, connection: connection, phase: .running, turn: "second"),
            value(id: id, connection: connection,
                  phase: .question(turnID: "second", requestID: "request-one", itemID: "item", questionIDs: ["question"], purpose: .ordinary)),
            value(id: id, connection: connection,
                  phase: .question(turnID: "second", requestID: "request-two", itemID: "item", questionIDs: ["question"], purpose: .ordinary)),
            value(id: id, connection: UUID(), phase: .running, turn: "third")
        ]
        for next in transitions {
            model.clearDisplayedSessions()
            model.receive(current, origin: .liveTransition)
            #expect(model.displayedSessions.isEmpty)
            model.receive(next, origin: .liveTransition)
            #expect(model.displayedSessions == [next])
            #expect(model.history == [other])
            current = next
        }
        model.shutdown()
    }

    // AC-15.03: Explicit restore exposes only a still-live observed conversation.
    @Test func historySummaryAndExplicitRestoreUseTheExistingObservation() {
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: CueSink())
        let observation = ObservedSession(sessionID: UUID(), connectionID: UUID(), liveness: .alive,
                                          phase: .idle(completedTurnID: "done"))
        let snapshot = SessionSnapshot(observation: observation, project: "Project", title: "Build",
                                       publicConclusion: "The synthetic build passed.", outcome: .succeeded)
        model.receive(snapshot, origin: .snapshot); model.clearDisplayedSessions()
        #expect(model.history == [snapshot] && model.displayedSessions.isEmpty)
        model.select(observation.sessionID)
        #expect(model.selected == snapshot)
        #expect(model.selected.map { SessionNotice.prepare($0).summary.contains("The synthetic build passed.") } == true)
        model.restore(sessionID: observation.sessionID)
        #expect(model.displayedSessions.isEmpty && model.history == [snapshot])
        #expect(model.sessions == [snapshot])
        model.shutdown()
    }

    // AC-15.03, AC-15.04: Ending preserves inspection, but delayed updates and restore cannot revive its binding.
    @Test func endedHistoryCannotRestoreOrReviveFromDelayedActivity() {
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: CueSink())
        let original = value(phase: .running, turn: "first")
        let ended = value(id: original.observation.sessionID, connection: original.observation.connectionID,
                          phase: .ended, liveness: .ended)
        model.receive(original, origin: .snapshot)
        model.clearDisplayedSessions()
        model.receive(ended, origin: .liveTransition)
        model.select(original.observation.sessionID)
        #expect(model.selected == ended && model.history == [ended])
        model.restore(sessionID: original.observation.sessionID)
        model.receive(original, origin: .liveTransition)
        #expect(model.displayedSessions.isEmpty && model.sessions.first?.observation.liveness == .ended)
        #expect(model.history == [ended])
        model.monitoringUnavailable()
        #expect(model.history == [ended])
        model.shutdown()
    }

    @Test func endingPreservesTheAvailableSummaryForVisibleAndClearedSessions() {
        for cleared in [false, true] {
            let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: CueSink())
            let observation = ObservedSession(sessionID: UUID(), connectionID: UUID(), liveness: .alive, phase: .running)
            let original = SessionSnapshot(observation: observation, project: "Project", title: "Build",
                                           publicConclusion: "Synthetic checkpoint.", limitations: ["Tests pending."])
            model.receive(original, origin: .snapshot)
            if cleared { model.clearDisplayedSessions() }
            model.receive(value(id: observation.sessionID, connection: observation.connectionID,
                                phase: .ended, liveness: .ended), origin: .liveTransition)
            let retained = cleared ? model.history.first : model.displayedSessions.first
            #expect(retained?.publicConclusion == "Synthetic checkpoint.")
            #expect(retained?.limitations == ["Tests pending."])
            #expect(retained?.observation.liveness == .ended)
            #expect(retained?.questions.isEmpty == true)
            model.restore(sessionID: observation.sessionID)
            #expect(model.displayedSessions.count == (cleared ? 0 : 1))
            model.shutdown()
        }
    }

    // AC-15.02, AC-15.04: Lost monitoring retains a truthful summary and does not count recovery as activity.
    @Test func monitoringLossPreservesHistoryAsUnconfirmedUntilNewActivity() {
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: CueSink())
        let observation = ObservedSession(sessionID: UUID(), connectionID: UUID(), liveness: .alive, phase: .running)
        let original = SessionSnapshot(observation: observation, project: "Project", title: "Build",
                                       publicConclusion: "A synthetic checkpoint is available.", turnID: "first")
        model.receive(original, origin: .snapshot); model.clearDisplayedSessions()
        model.monitoringUnavailable()
        #expect(!model.monitoringAvailable && model.displayedSessions.isEmpty)
        #expect(model.history.first?.observation.liveness == .unverified)
        #expect(model.history.first?.observation.phase == .unknown)
        #expect(model.history.first?.publicConclusion == "A synthetic checkpoint is available.")
        model.restore(sessionID: observation.sessionID)
        #expect(model.displayedSessions.isEmpty)
        model.receive(original, origin: .liveTransition)
        #expect(model.displayedSessions.isEmpty && model.history.count == 1)
        model.receive(value(id: observation.sessionID, connection: observation.connectionID,
                            phase: .running, turn: "second"), origin: .liveTransition)
        #expect(model.displayedSessions.count == 1 && model.history.isEmpty)
        model.shutdown()
    }
}

// Refs: US-03, AC-03.02, AC-03.03; US-12, AC-12.04.
@MainActor struct SessionNavigationTests {
    @Test func separatelyVerifiedNavigationDoesNotGrantOriginalClientAuthority() async {
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: CueSink())
        defer { model.shutdown() }
        var calls: [(UUID, UUID)] = []
        model.navigationAction = { session, connection in calls.append((session, connection)); return true }
        let id = UUID(), connection = UUID()
        let snapshot = SessionSnapshot(observation: .init(sessionID: id, connectionID: connection,
            liveness: .unverified, phase: .running), project: "Synthetic", title: "Inherited source", turnID: "turn",
            activityConfirmed: true, navigation: .init())
        model.receive(snapshot, origin: .snapshot)
        #expect(model.canRequestReturn(id))
        await model.returnToSession(id)
        #expect(calls.count == 1 && calls.first?.0 == id && calls.first?.1 == connection)
        #expect(model.sessions.first?.observation.liveness == .unverified)
        model.monitoringUnavailable()
        #expect(!model.canRequestReturn(id))
        await model.returnToSession(id)
        #expect(calls.count == 1)
    }

    @Test func returnUsesTheExactLiveConnectionAndNeverGuessesAfterAnOutageOrExit() async {
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: CueSink())
        var calls: [(UUID, UUID)] = []
        model.navigationAction = { session, connection in calls.append((session, connection)); return false }
        let id = UUID(), connection = UUID()
        let snapshot = SessionSnapshot(observation: .init(sessionID: id, connectionID: connection,
            liveness: .alive, phase: .running), project: "Synthetic", title: "Task", turnID: "turn", navigation: .init())
        model.receive(snapshot, origin: .snapshot)
        #expect(model.canRequestReturn(id))
        await model.returnToSession(id)
        #expect(calls.count == 1 && calls.first?.0 == id && calls.first?.1 == connection)
        #expect(model.navigationUnavailableFor == id)
        model.select(id)
        #expect(model.navigationUnavailableFor == nil)
        model.monitoringUnavailable()
        #expect(!model.canRequestReturn(id))
        await model.returnToSession(id)
        #expect(calls.count == 1)
        model.shutdown()
        await model.returnToSession(id)
        #expect(calls.count == 1)
    }

    @Test func liveSessionWithoutAnExactDestinationDoesNotAdvertiseReturn() async {
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: CueSink())
        defer { model.shutdown() }
        var opened = false
        model.navigationAction = { _, _ in opened = true; return true }
        let id = UUID()
        for liveness: CLILiveness in [.alive, .unverified] {
            model.receive(SessionSnapshot(observation: .init(sessionID: id, connectionID: UUID(), liveness: liveness, phase: .running),
                project: "Synthetic", title: "Observed only", activityConfirmed: true), origin: .snapshot)
            #expect(!model.canRequestReturn(id))
            await model.returnToSession(id)
            #expect(!opened && model.navigationUnavailableFor == id)
        }
    }

    @Test func successfulReturnDoesNotPresentAnUnavailableAlertOrDiscardTheSession() async {
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: CueSink())
        model.navigationAction = { _, _ in true }
        let snapshot = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(),
            liveness: .alive, phase: .idle(completedTurnID: "turn")), project: "Synthetic", title: "Task", navigation: .init())
        model.receive(snapshot, origin: .snapshot)
        await model.returnToSession(snapshot.observation.sessionID)
        #expect(model.navigationUnavailableFor == nil && model.sessions == [snapshot])
        model.shutdown()
    }
}


// Refs: US-15, AC-15.01, AC-15.02, AC-15.04, AC-15.05.
@MainActor struct ExplicitSessionRefreshTests {
    @Test func explicitRefreshRestoresOnlyFreshlyVerifiedExactConnections() {
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: CueSink())
        let live = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive,
            phase: .running), project: "Synthetic", title: "Live", turnID: "turn")
        let other = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive,
            phase: .running), project: "Synthetic", title: "Other", turnID: "turn")
        model.receive(live, origin: .snapshot); model.receive(other, origin: .snapshot)
        model.clearDisplayedSessions()
        model.restoreAfterExplicitRefresh([:])
        #expect(model.displayedSessions.isEmpty)
        model.restoreAfterExplicitRefresh([other.observation.sessionID: UUID()])
        #expect(model.displayedSessions.isEmpty)
        model.restoreAfterExplicitRefresh([live.observation.sessionID: live.observation.connectionID])
        #expect(model.displayedSessions == [live] && model.history == [other])
        model.receive(.init(observation: .init(sessionID: other.observation.sessionID,
            connectionID: other.observation.connectionID, liveness: .ended, phase: .ended),
            project: "Synthetic", title: "Other"), origin: .snapshot)
        model.restoreAfterExplicitRefresh([other.observation.sessionID: other.observation.connectionID])
        #expect(model.history.count == 1 && model.history.first?.observation.liveness == .ended)
        model.shutdown()
    }
}
