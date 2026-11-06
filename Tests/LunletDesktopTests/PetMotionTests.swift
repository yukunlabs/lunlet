// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-39, AC-39.02, AC-39.03, AC-39.06, AC-39.08.
import Foundation
import Testing
import LunletCore
@testable import LunletDesktop

struct PetMotionTests {
    /// A second at which nothing quick happens to a dog at rest and none starts within half a second.
    private func calmTime() -> TimeInterval {
        var t: TimeInterval = 1000
        while PetMotion.lively(at: t, input: PetMotionInput()) || (PetMotion.nextLivelyMoment(after: t).map { $0 - t < 0.5 } ?? false) {
            t += 0.05
        }
        return t
    }

    @Test func loopsFrameTwelveTimesASecondAndAttentionThirty() throws {
        let tempo = PetTempo()
        var input = PetMotionInput(); input.pose = .idle
        tempo.input = input
        var entries = PetTempoSchedule(tempo: tempo).entries(from: Date(timeIntervalSinceReferenceDate: calmTime()), mode: .normal).makeIterator()
        func take() throws -> Date { let next = entries.next(); return try #require(next) }
        let first = try take(), second = try take()
        #expect(abs(second.timeIntervalSince(first) - PetMotion.calmInterval) < 0.001)
        input.hovered = true; tempo.input = input
        let third = try take(), fourth = try take()
        #expect(abs(fourth.timeIntervalSince(third) - PetMotion.livelyInterval) < 0.001)
        input.hovered = false; input.gaze = CGPoint(x: 0.4, y: 0); tempo.input = input
        let fifth = try take(), sixth = try take()
        #expect(abs(sixth.timeIntervalSince(fifth) - PetMotion.livelyInterval) < 0.001)
        input.gaze = nil; input.panelOpen = true; tempo.input = input
        let seventh = try take(), eighth = try take()
        #expect(abs(eighth.timeIntervalSince(seventh) - PetMotion.livelyInterval) < 0.001)
    }

    @Test func aCalmFrameLandsOnTheNextBlinkAndStaysQuickThroughIt() throws {
        let tempo = PetTempo()
        var input = PetMotionInput(); input.pose = .idle
        tempo.input = input
        let t = calmTime()
        let blink = try #require(PetMotion.nextLivelyMoment(after: t))
        var entries = PetTempoSchedule(tempo: tempo).entries(from: Date(timeIntervalSinceReferenceDate: t), mode: .normal).makeIterator()
        var dates: [TimeInterval] = []
        while let next = entries.next(), next.timeIntervalSinceReferenceDate <= blink + PetMotion.blinkDuration {
            dates.append(next.timeIntervalSinceReferenceDate)
        }
        // A calm frame never crosses the padded start of the blink by more than one quick frame.
        let landing = try #require(dates.first { $0 >= blink - 0.0001 })
        #expect(landing - blink <= PetMotion.livelyInterval + 0.0001)
        let steps = zip(dates, dates.dropFirst()).map { (at: $0.0, step: $0.1 - $0.0) }
        #expect(steps.allSatisfy { $0.step <= PetMotion.calmInterval + 0.0001 && $0.step >= PetMotion.livelyInterval - 0.0001 })
        let during = steps.filter { $0.at >= landing }
        #expect(!during.isEmpty && during.allSatisfy { abs($0.step - PetMotion.livelyInterval) < 0.001 })
    }

    @Test func transitionsBouncesAndTheDoneHopAreQuickAndBlinksAreScheduled() {
        let calm = calmTime()
        var input = PetMotionInput(); input.pose = .working; input.poseChangedAt = calm - 100
        #expect(!PetMotion.lively(at: calm, input: input))
        input.poseChangedAt = calm - 0.2
        #expect(PetMotion.lively(at: calm, input: input))
        input.poseChangedAt = calm - 100; input.impulseAt = calm - 0.3
        #expect(PetMotion.lively(at: calm, input: input))
        input.impulseAt = calm - PetMotion.impulseDuration - 0.1
        #expect(!PetMotion.lively(at: calm, input: input))
        var done = PetMotionInput(); done.pose = .done; done.poseChangedAt = calm - 100
        #expect(PetMotion.lively(at: calm, input: done))
        let blinks = PetMotion.blinkMoments(inSegmentOf: 800)
        #expect((1...2).contains(blinks.count) && blinks.allSatisfy { $0 >= 800 && $0 < 804 })
        #expect(PetMotion.blink(at: blinks[0] + PetMotion.blinkDuration / 2) > 0.99)
        #expect(PetMotion.blink(at: blinks[0] - 0.01) == 0)
    }

    @Test func theHiddenBubbleIsNotPartOfTheDogWhileThePanelIsOpen() {
        let bubble = CGPoint(x: 150, y: 10)
        #expect(PetDrawing.silhouette(pose: .waiting).contains(bubble))
        #expect(!PetDrawing.silhouette(pose: .waiting, bubbleShown: false).contains(bubble))
        #expect(PetDrawing.silhouette(pose: .waiting, bubbleShown: false).contains(CGPoint(x: 110, y: 80)))
    }
}
