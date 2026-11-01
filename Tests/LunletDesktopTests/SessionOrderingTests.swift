// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-15, AC-15.06.
// Refs: US-23, AC-23.01, AC-23.02; US-15, AC-15.01, AC-15.03.
import Foundation
import Testing
import LunletCore
@testable import LunletDesktop

struct SessionOrderingTests {
    // Refs: US-02, AC-02.02, AC-02.08.
    @Test func visibleIdentitiesDistinguishSessionsWithSharedPrefixAndSuffix() {
        let ids = ["01A1814B-0000-7000-8000-000000000001", "01A1814B-0001-7000-8000-000000000001", "01A1814B-0000-7000-8000-000000000002"].map { UUID(uuidString: $0)! }
        let labels = SessionIdentityLabels(ids: ids)
        #expect(Set(ids.map { labels.label(for: $0) }).count == ids.count)
        #expect(labels.label(for: ids[0]) == SessionIdentityLabels(ids: ids.reversed()).label(for: ids[0]))
    }
    private func sample(_ id: String, project: String = "Same project", phase: SessionPhase = .running,
                        liveness: CLILiveness = .alive, inputPending: Bool = false, at: Date? = nil) -> SessionSnapshot {
        .init(observation: .init(sessionID: UUID(uuidString: id)!, connectionID: UUID(), liveness: liveness, phase: phase),
              project: project, title: "Build", turnID: "turn", inputPending: inputPending, lastActivityAt: at)
    }
    private let first = "11111111-1111-1111-1111-111111111111"
    private let second = "22222222-2222-2222-2222-222222222222"

    @Test func historyUsesSourceRecencyBeforeStateOrProjectAndUnknownIsNotNow() {
        let older = sample(first, project: "A", phase: .approval, at: Date(timeIntervalSince1970: 10))
        let newer = sample(second, project: "Z", phase: .idle(completedTurnID: "done"), at: Date(timeIntervalSince1970: 20))
        let unknown = sample("33333333-3333-3333-3333-333333333333", phase: .approval)
        #expect(SessionOrdering().apply(to: [unknown, older, newer], recentFirst: true) == [newer, older, unknown])
        let firstTie = sample(first, project: "Z", at: Date(timeIntervalSince1970: 20))
        let secondTie = sample(second, project: "A", at: Date(timeIntervalSince1970: 20))
        #expect(SessionOrdering().apply(to: [secondTie, firstTie], recentFirst: true) == [firstTie, secondTie])
        #expect(SessionOrdering().apply(to: [newer, older]) == [older, newer])
    }

    @MainActor @Test func exitAndRecoveryRetainSourceActivityWithoutAssigningArrivalTime() {
        let model = SessionListModel(displayAvailable: { false }, elapsed: { 999 }, presenter: OrderingCueSink())
        defer { model.shutdown() }
        let completed = sample(first, phase: .idle(completedTurnID: "done"), at: Date(timeIntervalSince1970: 10))
        model.receive(completed, origin: .snapshot)
        model.monitoringUnavailable()
        #expect(model.displayedSessions.first?.lastActivityAt == completed.lastActivityAt)
        let ended = SessionSnapshot(observation: .init(sessionID: completed.observation.sessionID,
            connectionID: completed.observation.connectionID, liveness: .ended, phase: .ended), project: completed.project, title: completed.title)
        model.receive(ended, origin: .snapshot)
        #expect(model.displayedSessions.first?.lastActivityAt == completed.lastActivityAt)
        model.receive(ended, origin: .snapshot)
        #expect(model.displayedSessions.count == 1 && model.displayedSessions.first?.lastActivityAt == completed.lastActivityAt)
    }

    @Test func waitingPrecedesRunningWithStableIdentityTiesAndUnknownDoesNotBecomeRunning() {
        let running = sample(first), waiting = sample(second, phase: .approval)
        let unknown = sample("33333333-3333-3333-3333-333333333333", phase: .running, liveness: .unverified)
        #expect(SessionOrdering().apply(to: [unknown, running, waiting]) == [waiting, running, unknown])
        #expect(SessionOrdering().apply(to: [sample(second), running]).map(\.observation.sessionID) == [UUID(uuidString: first)!, UUID(uuidString: second)!])
    }
    @MainActor @Test func orderingDoesNotChangeClearOrNewActivityRestoration() {
        let model = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: OrderingCueSink())
        defer { model.shutdown() }
        let value = sample(first)
        model.receive(value, origin: .snapshot)
        let ordering = SessionOrdering()
        model.clearDisplayedSessions()
        #expect(ordering.apply(to: model.displayedSessions).isEmpty)
        #expect(ordering.apply(to: model.history) == [value])
        let next = SessionSnapshot(observation: value.observation, project: value.project, title: value.title, turnID: "next")
        model.receive(next, origin: .liveTransition)
        #expect(ordering.apply(to: model.displayedSessions) == [next])
        #expect(model.history.isEmpty)
        #expect(model.sessions.first?.observation.connectionID == value.observation.connectionID)
    }
}

@MainActor private final class OrderingCueSink: TaskCuePresenting {
    func show(_ cues: [TaskCue]) {}
    func hide() {}
}
