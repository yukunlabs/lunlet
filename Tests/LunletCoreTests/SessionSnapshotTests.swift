// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-02, AC-02.05; US-03, AC-03.03; US-15, AC-15.03; US-07, AC-07.04.
import Foundation
import Testing
import LunletCore

struct SessionSnapshotTests {
    private let id = UUID(), connection = UUID(), parent = UUID()
    private var verified: SessionSnapshot {
        SessionSnapshot(observation: .init(sessionID: id, connectionID: connection, liveness: .alive,
                                           phase: .question(turnID: "turn", requestID: "request", itemID: "item",
                                                            questionIDs: ["q"], purpose: .ordinary)),
                        project: "Synthetic", title: "Fix the build", publicConclusion: "Done.", limitations: ["Partial."],
                        questions: [.init(id: "q", prompt: "Which branch?", kind: .text)], outcome: .succeeded, turnID: "turn",
                        inputActivityID: "input", inputPending: true, activityConfirmed: true,
                        navigation: .init(applicationName: "Synthetic Terminal"), lastActivityAt: Date(timeIntervalSince1970: 1),
                        localPreview: "Fix the build", parentSessionID: parent)
    }

    @Test func degradedVerificationClearsQuestionsNavigationAndActivityButKeepsTheSummary() {
        let degraded = verified.degraded(liveness: .unverified, phase: .unknown)
        #expect(degraded.observation == verified.observation.replacing(liveness: .unverified, phase: .unknown))
        #expect(degraded.questions.isEmpty && !degraded.navigationAvailable && degraded.navigationApplicationName == nil)
        #expect(!degraded.activityConfirmed && !degraded.hasConfirmedActivity && !degraded.awaitsUser)
        #expect(degraded.publicConclusion == "Done." && degraded.limitations == ["Partial."] && degraded.outcome == .succeeded)
        #expect(degraded.turnID == "turn" && degraded.inputActivityID == "input" && degraded.inputPending)
        #expect(degraded.lastActivityAt == verified.lastActivityAt && degraded.localPreview == "Fix the build")
        #expect(degraded.title == "Fix the build" && degraded.parentSessionID == verified.parentSessionID)
        #expect(verified.degraded(liveness: .ended, phase: .ended).isEnded)
    }

    @Test func anEndedExitKeepsThePreviousSummaryOnlyWhereItCarriedNone() {
        let exit = SessionSnapshot(observation: verified.observation.replacing(liveness: .ended, phase: .ended),
                                   project: "Synthetic", outcome: .stopped, navigation: .init())
        let retained = exit.retainingSummary(of: verified)
        #expect(retained.isEnded && retained.outcome == .stopped && retained.title == SessionSnapshot.placeholderTitle(for: id))
        #expect(retained.publicConclusion == "Done." && retained.limitations == ["Partial."])
        #expect(retained.lastActivityAt == verified.lastActivityAt && retained.localPreview == "Fix the build")
        #expect(retained.parentSessionID == verified.parentSessionID)
        #expect(retained.questions.isEmpty && !retained.navigationAvailable && !retained.activityConfirmed)
        let ownSummary = SessionSnapshot(observation: exit.observation, project: "Synthetic", publicConclusion: "Exited.",
                                         limitations: ["Own."])
        #expect(ownSummary.retainingSummary(of: verified).publicConclusion == "Exited.")
        #expect(ownSummary.retainingSummary(of: verified).limitations == ["Own."])
        #expect(exit.retainingSummary(of: nil) == exit.degraded(liveness: .ended, phase: .ended))
    }

    @Test func placeholderTitlesAreIdentifiedWithoutComparingText() {
        let unnamed = SessionSnapshot(observation: .init(sessionID: id, connectionID: connection, liveness: .alive, phase: .running),
                                      project: "Synthetic")
        #expect(unnamed.sourceTitle == nil && unnamed.title == "Session " + id.uuidString.prefix(8))
        #expect(SessionNotice.prepare(unnamed).titleIsPlaceholder)
        #expect(!SessionNotice.prepare(verified).titleIsPlaceholder)
        let unsafe = SessionSnapshot(observation: unnamed.observation, project: "Synthetic", title: "See https://example.invalid")
        #expect(SessionNotice.prepare(unsafe).titleIsPlaceholder)
        #expect(SessionNotice.prepare(unsafe).title == SessionSnapshot.placeholderTitle(for: id))
    }
}
