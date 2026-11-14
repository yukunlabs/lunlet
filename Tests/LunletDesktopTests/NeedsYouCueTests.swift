// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-13, AC-13.04, AC-13.08, AC-13.10, AC-13.11; US-02, AC-02.03; US-33, AC-33.03.
import AppKit
import Foundation
import Testing
@testable import LunletCore
@testable import LunletDesktop

@MainActor private final class NeedsYouSink: TaskCuePresenting {
    var visible: [TaskCue] = []
    var shown: [TaskCue] = []
    func show(_ cues: [TaskCue]) { visible = cues; if let cue = cues.last, shown.last != cue { shown.append(cue) } }
    func hide() { visible = [] }
}

@MainActor struct NeedsYouCueTests {
    private func snapshot(_ session: UUID, _ connection: UUID, _ phase: SessionPhase) -> SessionSnapshot {
        .init(observation: .init(sessionID: session, connectionID: connection, liveness: .unverified, phase: phase),
              project: "Synthetic", title: "Session", turnID: "one", activityConfirmed: true, localPreview: "Refactor the panel")
    }
    private let question = SessionPhase.question(turnID: "one", requestID: "", itemID: "", questionIDs: [], purpose: .unknown)

    @Test func enteringAWaitingStateCuesNeedsYouOncePerEntry() {
        // AC-13.10: a cue when a session starts waiting, told apart as a question or an approval; the same record
        // again is not a new entry; leaving and waiting again cues again.
        var now: TimeInterval = 0
        let sink = NeedsYouSink(), model = SessionListModel(displayAvailable: { true }, elapsed: { now }, presenter: sink)
        defer { model.shutdown() }
        let session = UUID(), connection = UUID()
        model.receive(snapshot(session, connection, .running), origin: .liveTransition)
        model.receive(snapshot(session, connection, .approval), origin: .liveTransition)
        #expect(sink.visible.last?.phase == .waiting(.approval))
        #expect(sink.visible.last?.context == "Refactor the panel" && sink.visible.last?.title == "Synthetic")
        now = CuePresentation.displayDuration + 1
        model.receive(snapshot(session, connection, .approval), origin: .liveTransition)
        #expect(sink.visible.isEmpty, "the same waiting record is not a new entry")
        model.receive(snapshot(session, connection, .running), origin: .liveTransition)
        model.receive(snapshot(session, connection, question), origin: .liveTransition)
        #expect(sink.visible.last?.phase == .waiting(.question))
        #expect(sink.shown.map(\.phase) == [.started, .waiting(.approval), .waiting(.question)])
    }

    @Test func aSessionDiscoveredAlreadyWaitingShowsNoCue() {
        // AC-13.10 with AC-13.04: a baseline snapshot is not a transition, and the record replayed later is not one either.
        let sink = NeedsYouSink(), model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: sink)
        defer { model.shutdown() }
        let session = UUID(), connection = UUID()
        model.receive(snapshot(session, connection, .approval), origin: .snapshot)
        #expect(sink.visible.isEmpty)
        model.receive(snapshot(session, connection, .approval), origin: .liveTransition)
        #expect(sink.visible.isEmpty)
        #expect(model.compactStatus.waiting == 1, "the resting entry still counts the waiting session")
    }

    @Test func needsYouNamesTheKindBeforeThePreview() {
        // AC-13.10 on the island: the status word, the project, then the kind and the bounded preview.
        let approval = TaskCueText(cue: TaskCue(sessionID: "s", connectionID: "c", turnID: "t", title: "lunlet",
                                                phase: .waiting(.approval), context: "Run the tests"))
        #expect(approval.status == "Needs you" && approval.symbol == "hand.raised.fill")
        #expect(approval.context == "Approval on Mac · Run the tests")
        #expect(approval.accessibilityLabel == "Needs you, lunlet, Approval on Mac · Run the tests")
        let question = TaskCueText(cue: TaskCue(sessionID: "s", connectionID: "c", turnID: "turn-a1b2c3", title: "lunlet",
                                                phase: .waiting(.question)))
        #expect(question.symbol == "text.bubble.fill" && question.context == "Question · Task A1B2C3")
    }

    @Test func theNeedsYouSoundPlaysOncePerWaitingCueOnlyWhenChosen() {
        // AC-13.11: off by default; one sound per Needs you cue, none for starts or finishes, none for a refresh.
        var sounds = 0
        let router = CueRouter(island: TransientCuePanel(expanded: { true }), sound: { sounds += 1 })
        let waiting = TaskCue(sessionID: "s", connectionID: "c", turnID: "t", title: "lunlet", phase: .waiting(.question))
        router.show([waiting])
        #expect(sounds == 0)
        router.soundEnabled = true
        router.show([waiting])
        #expect(sounds == 1)
        router.show([waiting])
        #expect(sounds == 1, "a refresh of the same cue is silent")
        router.show([TaskCue(sessionID: "s", connectionID: "c", turnID: "u", title: "lunlet", phase: .started)])
        router.show([TaskCue(sessionID: "s", connectionID: "c", turnID: "u", title: "lunlet", phase: .finished(.succeeded))])
        #expect(sounds == 1)
        router.show([TaskCue(sessionID: "s", connectionID: "c", turnID: "u", title: "lunlet", phase: .waiting(.approval))])
        #expect(sounds == 2)
    }
}
