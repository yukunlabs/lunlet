// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-02, AC-02.01, AC-02.02, AC-02.04, AC-02.05; US-11, AC-11.03, AC-11.05.
// Refs: US-13, AC-13.01, AC-13.04; US-12, AC-12.04.
// Refs: US-33, AC-33.01, AC-33.02, AC-33.06; US-19, AC-19.01, AC-19.03.
import Foundation
import Testing
import LunletCodex
import LunletCore
@testable import LunletDesktop

private actor ObservationSource: CodexSessionObserving {
    let pair = AsyncStream<SessionUpdate>.makeStream()
    private(set) var starts = 0
    private(set) var stops = 0
    private var verified: [UUID: UUID] = [:]
    func setVerified(_ value: [UUID: UUID]) { verified = value }
    private var refreshSnapshot: SessionSnapshot?
    func setRefreshSnapshot(_ snapshot: SessionSnapshot) { refreshSnapshot = snapshot }
    func reconcile() async {
        if let refreshSnapshot { pair.continuation.yield(.snapshot(refreshSnapshot, baseline: true)) }
        pair.continuation.yield(.reconciled(verified))
    }
    func updates() -> AsyncStream<SessionUpdate> { starts += 1; return pair.stream }
    func refresh() {}
    private(set) var destinationRequests = 0
    func destination(sessionID: UUID, connectionID: UUID) -> CodexTerminalDestination? { destinationRequests += 1; return nil }
    func send(_ update: SessionUpdate) { pair.continuation.yield(update) }
    func shutdown() { stops += 1; pair.continuation.finish() }
}
private final class SilentCuePresenter: TaskCuePresenting {
    private(set) var shown = 0
    func show(_ cues: [TaskCue]) { shown += 1 }
    func hide() {}
}
@MainActor struct SessionObservationModelTests {
    @Test func childTasksAreNotForwardedAsConversationNotifications() async throws {
        let source = ObservationSource()
        let model = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: SilentCuePresenter())
        let owner = SessionObservationModel(model: model, source: source)
        var forwarded: [SessionSnapshot] = []
        owner.snapshotReceived = { snapshot, _ in forwarded.append(snapshot) }
        owner.start()
        let child = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .unverified, phase: .running),
            project: "Synthetic", title: "Child", activityConfirmed: true, parentSessionID: UUID())
        await source.send(.snapshot(child, baseline: false))
        let deadline = ContinuousClock.now + .seconds(2)
        while model.sessions.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.sessions.count == 1 && forwarded.isEmpty)
        await owner.shutdown(); model.shutdown()
    }
    @Test func streamPopulatesActualListAndRecoveryDoesNotReplayCues() async throws {
        let source = ObservationSource(), presenter = SilentCuePresenter()
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: presenter)
        let subject = SessionObservationModel(model:model,source:source)
        var forwarded: [(SessionSnapshot, Bool)] = []
        subject.snapshotReceived = { forwarded.append(($0, $1)) }
        subject.start(); subject.start()
        let end = ContinuousClock.now + .seconds(2)
        while await source.starts == 0, ContinuousClock.now < end { try await Task.sleep(for:.milliseconds(5)) }
        #expect(await source.starts == 1)
        let id=UUID(),connection=UUID()
        let snapshot=SessionSnapshot(observation:.init(sessionID:id,connectionID:connection,liveness:.alive,phase:.running),
                                     project:"Synthetic",title:"Task",turnID:"turn",localPreview:"Local only")
        await source.send(.snapshot(snapshot,baseline:true))
        while model.sessions.isEmpty, ContinuousClock.now < end { try await Task.sleep(for:.milliseconds(5)) }
        #expect(model.sessions.count == 1 && presenter.shown == 0)
        #expect(model.sessions.first?.localPreview == "Local only")
        // Refs: US-06, AC-06.02: the notification path receives the request preview for the owner's notice excerpt.
        #expect(forwarded.count == 1 && forwarded[0].0 == snapshot && forwarded[0].0.localPreview == "Local only" && forwarded[0].1)
        await source.send(.availability(connected:false,partial:true))
        while model.monitoringAvailable, ContinuousClock.now < end { try await Task.sleep(for:.milliseconds(5)) }
        #expect(model.sessions.first?.observation.liveness == .unverified)
        await source.send(.snapshot(snapshot,baseline:true))
        while !model.monitoringAvailable, ContinuousClock.now < end { try await Task.sleep(for:.milliseconds(5)) }
        #expect(model.monitoringAvailable && presenter.shown == 0)
        await subject.shutdown(); await subject.shutdown()
        #expect(await source.stops == 1)
        await source.send(.snapshot(snapshot,baseline:false))
        #expect(presenter.shown == 0)
        model.shutdown()
    }

    // Refs: US-15, AC-15.01, AC-15.02, AC-15.04, AC-15.05; US-04, AC-04.01.
    @Test func explicitRefreshRestoresVerifiedLiveHistoryButBackgroundBaselinesDoNot() async throws {
        let source = ObservationSource()
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: SilentCuePresenter())
        let owner = SessionObservationModel(model: model, source: source)
        owner.start()
        let snapshot = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive,
            phase: .running), project: "Synthetic", title: "Task", turnID: "turn")
        model.receive(snapshot, origin: .snapshot); model.clearDisplayedSessions()
        await source.send(.snapshot(snapshot, baseline: true))
        await source.setVerified([:])
        owner.refresh()
        let deadline = ContinuousClock.now + .seconds(2)
        while model.isRefreshing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.displayedSessions.isEmpty)
        await source.setVerified([snapshot.observation.sessionID: snapshot.observation.connectionID])
        owner.refresh()
        while model.isRefreshing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        while model.displayedSessions.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.displayedSessions == [snapshot] && model.history.isEmpty)
        // A resumed conversation can acquire a new connection while its old
        // cleared snapshot is still queued in the presentation owner.
        model.clearDisplayedSessions()
        let resumed = SessionSnapshot(observation: .init(sessionID: snapshot.observation.sessionID, connectionID: UUID(),
            liveness: .alive, phase: .running), project: "Synthetic", title: "Resumed", turnID: "next")
        await source.setRefreshSnapshot(resumed)
        await source.setVerified([resumed.observation.sessionID: resumed.observation.connectionID])
        owner.refresh()
        while model.displayedSessions != [resumed], ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.displayedSessions == [resumed] && model.history.isEmpty)
        await owner.shutdown(); model.shutdown()
    }

    private func row(_ provider: SessionProvider, phase: SessionPhase = .running, id: UUID = UUID()) -> SessionSnapshot {
        .init(observation: .init(sessionID: id, connectionID: UUID(), liveness: .unverified, phase: phase),
              project: "Synthetic", turnID: "turn", activityConfirmed: true, localPreview: "Synthetic", provider: provider)
    }
    private func until(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    // Refs: US-33, AC-33.01, AC-33.02; US-19, AC-19.03.
    @Test func providerStreamsMergeWithoutCrossTalk() async throws {
        let codex = ObservationSource(), claude = ObservationSource()
        let model = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: SilentCuePresenter())
        let owner = SessionObservationModel(model: model, providers: [.codex, .claude]) { $0 == .codex ? codex : claude }
        var forwarded: [SessionSnapshot] = []
        owner.snapshotReceived = { snapshot, _ in forwarded.append(snapshot) }
        owner.start()
        let codexRow = row(.codex), claudeRow = row(.claude, phase: .idle(completedTurnID: "turn"))
        await codex.send(.snapshot(codexRow, baseline: true))
        try await until { model.sessions.count == 1 }
        await claude.send(.snapshot(claudeRow, baseline: false))
        // A source cannot speak for another provider, and a session UUID keeps its first provider.
        await claude.send(.snapshot(row(.codex), baseline: false))
        await claude.send(.snapshot(row(.claude, phase: .idle(completedTurnID: "x"), id: codexRow.observation.sessionID), baseline: false))
        await claude.send(.availability(connected: true, partial: false))
        try await until { model.isMonitoringAvailable(for: .claude) }
        #expect(model.sessions.map(\.provider) == [.codex, .claude] && forwarded.map(\.provider) == [.codex, .claude])
        #expect(model.sessions.first?.observation.phase == .running)
        // Navigation is offered only through the Codex source's verified destinations.
        let opened = await model.navigationAction?(claudeRow.observation.sessionID, claudeRow.observation.connectionID)
        let claudeRequests = await claude.destinationRequests, codexRequests = await codex.destinationRequests
        #expect(opened == false && claudeRequests == 0 && codexRequests == 0)
        _ = await model.navigationAction?(codexRow.observation.sessionID, codexRow.observation.connectionID)
        #expect(await codex.destinationRequests == 1)
        // One provider's outage degrades only its own rows.
        await claude.send(.availability(connected: false, partial: true))
        try await until { !model.isMonitoringAvailable(for: .claude) }
        #expect(model.sessions.first { $0.provider == .codex }?.hasConfirmedActivity == true)
        #expect(model.sessions.first { $0.provider == .claude }?.hasConfirmedActivity == false)
        #expect(!model.monitoringAvailable && model.isMonitoringAvailable(for: .codex))
        await owner.shutdown(); model.shutdown()
        let stops = (await codex.stops, await claude.stops)
        #expect(stops == (1, 1))
    }

    // Refs: US-33, AC-33.02; US-15, AC-15.05; US-19, AC-19.01.
    @Test func refreshRestoresOnlyEachSourcesOwnSessionsAndDeselectionStopsTheSource() async throws {
        let codex = ObservationSource(), claude = ObservationSource()
        let model = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: SilentCuePresenter())
        let owner = SessionObservationModel(model: model, providers: [.codex, .claude]) { $0 == .codex ? codex : claude }
        owner.start()
        let codexRow = row(.codex), claudeRow = row(.claude)
        await codex.send(.snapshot(codexRow, baseline: true)); await claude.send(.snapshot(claudeRow, baseline: true))
        try await until { model.sessions.count == 2 }
        model.clearDisplayedSessions()
        // Claude's reconciliation cannot restore a Codex session even if it names that UUID.
        await claude.setVerified([codexRow.observation.sessionID: codexRow.observation.connectionID,
                                  claudeRow.observation.sessionID: claudeRow.observation.connectionID])
        owner.refresh()
        try await until { !model.isRefreshing && model.history.count == 1 }
        #expect(model.history.map(\.provider) == [.codex] && model.displayedSessions.map(\.provider) == [.claude])
        owner.setProviders([.codex])
        try await until { await claude.stops == 1 }
        #expect(model.sessions.allSatisfy { $0.provider == .codex } && model.monitoredProviders == [.codex])
        await owner.shutdown(); model.shutdown()
        let stops = (await codex.stops, await claude.stops)
        #expect(stops == (1, 1))
    }
}
