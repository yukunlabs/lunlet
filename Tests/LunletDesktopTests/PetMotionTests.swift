// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-39, AC-39.02, AC-39.03, AC-39.06, AC-39.08.
import Combine
import Foundation
import Testing
import LunletCore
@testable import LunletDesktop

struct PetMotionTests {
    /// The gap from a frame at `t` to the next one.
    private func step(after t: TimeInterval, _ input: PetMotionInput, sprite: PetSpriteVersion? = nil) -> TimeInterval {
        PetFrameClock.nextFrame(after: t, input: input, sprite: sprite) - t
    }
    /// A second at which nothing quick happens to an idle dog and none starts within half a second.
    private func calmTime() -> TimeInterval {
        var idle = PetMotionInput(); idle.pose = .idle
        var t: TimeInterval = 1000
        while PetMotion.lively(at: t, input: idle) || (PetMotion.nextLivelyMoment(after: t).map { $0 - t < 0.5 } ?? false) {
            t += 0.05
        }
        return t
    }

    @Test func loopsFrameTwelveTimesASecondAndAttentionThirty() {
        let calm = calmTime()
        var input = PetMotionInput(); input.pose = .idle
        #expect(abs(step(after: calm, input) - PetMotion.calmInterval) < 0.001)
        input.hovered = true
        #expect(abs(step(after: calm, input) - PetMotion.livelyInterval) < 0.001)
        input.hovered = false; input.gaze = CGPoint(x: 0.4, y: 0)
        #expect(abs(step(after: calm, input) - PetMotion.livelyInterval) < 0.001)
        input.gaze = nil; input.panelOpen = true
        #expect(abs(step(after: calm, input) - PetMotion.livelyInterval) < 0.001)
    }

    @Test func aCalmFrameLandsOnTheNextBlinkAndStaysQuickThroughIt() throws {
        var input = PetMotionInput(); input.pose = .idle
        let t = calmTime()
        let blink = try #require(PetMotion.nextLivelyMoment(after: t))
        var dates: [TimeInterval] = [t]
        while let last = dates.last, last <= blink + PetMotion.blinkDuration {
            dates.append(PetFrameClock.nextFrame(after: last, input: input, sprite: nil))
        }
        dates.removeLast()
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
        // A Failed dog has no hop and holds its tail still, so nothing quick happens between blinks (AC-39.06).
        var failed = done; failed.pose = .failed
        #expect(!PetMotion.lively(at: calm, input: failed))
        let blinks = PetMotion.blinkMoments(inSegmentOf: 800)
        #expect((1...2).contains(blinks.count) && blinks.allSatisfy { $0 >= 800 && $0 < 804 })
        #expect(PetMotion.blink(at: blinks[0] + PetMotion.blinkDuration / 2) > 0.99)
        #expect(PetMotion.blink(at: blinks[0] - 0.01) == 0)
    }

    /// A time with no ear flick within half a second before or after it, for a dog whose eyes are closed.
    private func restfulTime() -> TimeInterval {
        var t: TimeInterval = 1000
        func clear(_ moment: TimeInterval?) -> Bool { moment.map { $0 < t - 0.5 || $0 > t + 0.7 } ?? true }
        while !clear(PetMotion.twitchMoment(inSegmentOf: t)) || !clear(PetMotion.twitchMoment(inSegmentOf: t + 6)) { t += 0.05 }
        return t
    }

    @Test func aSleepingPetSkipsBlinkBurstsAndRestsAtSixFramesASecond() throws {
        var asleep = PetMotionInput(); asleep.pose = .asleep
        var awake = asleep; awake.pose = .idle
        let blink = PetMotion.blinkMoments(inSegmentOf: 1000)[0] + 0.05
        #expect(PetMotion.lively(at: blink, input: awake))
        // Closed eyes do not blink, so nothing quick happens that would need thirty frames.
        #expect(!PetMotion.lively(at: blink, input: asleep))
        for sprite in [nil, PetSpriteVersion.v1] {
            // Breathing and the drifting sleep marks need half the awake dog's calm rate.
            #expect(abs(step(after: restfulTime(), asleep, sprite: sprite) - PetMotion.restfulInterval) < 0.001, "\(String(describing: sprite))")
        }
    }

    @Test func aPackAtRestIsNotFramedThirtyTimesASecondWhenAttended() {
        var input = PetMotionInput(); input.pose = .idle; input.gaze = CGPoint(x: 0.4, y: 0)
        // The look cell stands still until the pointer moves, which the host redraws on its own.
        #expect(abs(step(after: 1000, input, sprite: .v2) - PetMotion.restingInterval) < 0.001)
    }

    @Test func aPackPopsItsBubbleQuicklyThenFollowsItsFrameBoundaries() {
        var input = PetMotionInput(); input.pose = .waiting; input.poseChangedAt = 1000
        #expect(abs(step(after: 1000.05, input, sprite: .v1) - PetMotion.livelyInterval) < 0.001)
        // Waiting frames hold 150 or 260 ms: one frame per boundary over a loop, not thirty a second.
        var frames: [TimeInterval] = [1002]
        while let last = frames.last, last < 1002 + PetSpriteRow.waiting.duration {
            frames.append(PetFrameClock.nextFrame(after: last, input: input, sprite: .v1))
        }
        #expect((5...8).contains(frames.count), "\(frames.count)")
    }

    @MainActor @Test func theClockShowsAFrameAtOnceAndNoneWhileStopped() {
        var at: TimeInterval = 1000
        let clock = PetFrameClock(now: { at })
        clock.input.pose = .idle
        #expect(clock.frame == nil && !clock.isRunning)
        clock.start()
        #expect(clock.frame == 1000 && clock.isRunning)
        at = 1000.5; clock.start()
        #expect(clock.frame == 1000.5)
        clock.stop()
        #expect(clock.frame == nil && !clock.isRunning)
    }

    @MainActor @Test func theClockFramesAnIdleDogAboutTwelveTimesASecond() {
        let clock = PetFrameClock()
        clock.input.pose = .idle
        var frames: [TimeInterval] = []
        let observation = clock.$frame.compactMap { $0 }.sink { frames.append($0) }
        defer { observation.cancel(); clock.stop() }
        clock.start()
        let deadline = Date(timeIntervalSinceNow: 2)
        while frames.count < 6, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        #expect(frames.count >= 6, "\(frames.count) frames in two seconds")
        // Frames come at most thirty times a second and the calm ones twelve.
        let gaps = zip(frames, frames.dropFirst()).map { $0.1 - $0.0 }
        #expect(gaps.allSatisfy { $0 >= PetMotion.livelyInterval - 0.001 && $0 <= PetMotion.calmInterval + 0.001 }, "\(gaps)")
    }

    @Test func theHiddenBubbleIsNotPartOfTheDogWhileThePanelIsOpen() {
        let bubble = CGPoint(x: 150, y: 10)
        #expect(PetDrawing.silhouette(pose: .waiting).contains(bubble))
        #expect(!PetDrawing.silhouette(pose: .waiting, bubbleShown: false).contains(bubble))
        #expect(PetDrawing.silhouette(pose: .waiting, bubbleShown: false).contains(CGPoint(x: 110, y: 80)))
    }
}
