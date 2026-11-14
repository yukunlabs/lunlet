// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-39, AC-39.03, AC-39.04, AC-39.06, AC-39.08; US-24, AC-24.02; US-40, AC-40.03, AC-40.04.
import Foundation
import LunletCore
import SwiftUI

/// What makes the dog move besides its pose: the pointer, the panel, the last click and when the pose changed.
/// Everything the drawing derives from these and the time is deterministic, so a frame is a pure function.
struct PetMotionInput: Equatable {
    var pose: PetPose = .asleep
    var previousPose: PetPose?
    /// Reference-date seconds of the last pose change; the transition between poses runs from here.
    var poseChangedAt: TimeInterval = 0
    var hovered = false
    /// Where the dog looks, as a unit offset (x right, y down) toward the pointer or the open panel; nil wanders.
    var gaze: CGPoint?
    /// Reference-date seconds of the last click, for the little bounce.
    var impulseAt: TimeInterval?
    /// The companion panel is open beside the dog: it looks up at it and keeps its own bubble away.
    var panelOpen = false
    /// A drag in progress and when it started; a pack plays running-left or running-right meanwhile (AC-40.03).
    var drag: PetDragDirection?
    var dragStartedAt: TimeInterval = 0
}

/// The dog's life between state changes: blinks, a wandering gaze, ear twitches and the loops of each pose, all
/// derived from the time so that they need no stored state and repeat nowhere.
enum PetMotion {
    static let transitionDuration: TimeInterval = 0.4
    static let bubbleDuration: TimeInterval = 0.28
    static let impulseDuration: TimeInterval = 0.6
    static let blinkDuration: TimeInterval = 0.14
    static let twitchDuration: TimeInterval = 0.22
    /// The loops run at twelve frames a second (AC-39.08); a blink, a flick, a transition, a bounce and every moment
    /// the pointer or the panel holds the dog's attention run at thirty, so that the quick things read.
    static let calmInterval: TimeInterval = 1.0 / 12.0
    static let livelyInterval: TimeInterval = 1.0 / 30.0
    /// Asleep, only breathing and the drifting sleep marks move: six frames a second carry them.
    static let restfulInterval: TimeInterval = 1.0 / 6.0
    /// A pack holding a look cell is checked twice a second for something new; the pointer moving redraws it sooner.
    static let restingInterval: TimeInterval = 0.5

    /// A stable pseudo-random value in 0…1 for an integer segment of time.
    static func noise(_ segment: Int, _ salt: Int = 0) -> Double {
        var x = UInt64(bitPattern: Int64(segment)) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(bitPattern: Int64(salt)) &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 31; x = x &* 0x94D0_49BB_1331_11EB; x ^= x >> 29
        return Double(x % 1_000_000) / 1_000_000
    }
    static func easeInOut(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
    static func easeOutBack(_ x: Double) -> Double { let c = min(1, max(0, x)) - 1; return 1 + c * c * (2.7 * c + 1.7) }

    /// 0 while a blink keeps the eyes open, up to 1 at the closed middle of a blink. Every four seconds a blink
    /// lands at a different moment, sometimes twice.
    static func blink(at t: TimeInterval) -> Double {
        blinkMoments(inSegmentOf: t).map { closing(t - $0) }.max() ?? 0
    }
    /// When the blinks of the four-second segment holding `t` start.
    static func blinkMoments(inSegmentOf t: TimeInterval) -> [TimeInterval] {
        let period = 4.0, segment = Int(floor(t / period)), start = Double(segment) * period
        let first = start + 0.6 + noise(segment, 1) * 3.0
        return noise(segment, 2) < 0.28 ? [first, first + 0.26] : [first]
    }
    private static func closing(_ dt: TimeInterval) -> Double {
        guard dt >= 0, dt <= blinkDuration else { return 0 }
        return sin(.pi * dt / blinkDuration)
    }

    /// Where the eyes rest when nothing holds them: a new target every three and a half seconds, reached smoothly,
    /// and the center more often than anywhere else.
    static func wander(at t: TimeInterval) -> CGPoint {
        let period = 3.5, segment = Int(floor(t / period)), start = Double(segment) * period
        func target(_ s: Int) -> CGPoint {
            guard noise(s, 3) > 0.35 else { return .zero }
            return CGPoint(x: noise(s, 4) * 1.6 - 0.8, y: noise(s, 5) * 0.9 - 0.45)
        }
        let from = target(segment - 1), to = target(segment)
        let p = easeInOut((t - start) / 0.6)
        return CGPoint(x: from.x + (to.x - from.x) * p, y: from.y + (to.y - from.y) * p)
    }

    /// An ear flick now and then: which ear and how far, 0 when still.
    static func earTwitch(at t: TimeInterval) -> (left: Double, right: Double) {
        guard let at = twitchMoment(inSegmentOf: t) else { return (0, 0) }
        let dt = t - at
        guard dt >= 0, dt <= twitchDuration else { return (0, 0) }
        let amount = sin(.pi * dt / twitchDuration)
        let segment = Int(floor(t / 6.0))
        return noise(segment, 8) < 0.5 ? (amount, 0) : (0, amount)
    }
    /// When the ear flick of the six-second segment holding `t` starts, if it has one.
    static func twitchMoment(inSegmentOf t: TimeInterval) -> TimeInterval? {
        let period = 6.0, segment = Int(floor(t / period)), start = Double(segment) * period
        guard noise(segment, 6) < 0.55 else { return nil }
        return start + 0.5 + noise(segment, 7) * 4.5
    }

    /// A slow head tilt that never settles.
    static func tilt(at t: TimeInterval) -> Double { 2.5 * sin(2 * .pi * t / 5.3) + 1.2 * sin(2 * .pi * t / 2.1 + 1) }

    /// A squash-and-stretch bounce after a click: positive stretches up, negative squashes.
    static func impulse(at t: TimeInterval, since impulseAt: TimeInterval?) -> Double {
        guard let impulseAt else { return 0 }
        let dt = t - impulseAt
        guard dt >= 0, dt <= impulseDuration else { return 0 }
        return exp(-4.5 * dt) * sin(2 * .pi * dt / 0.3)
    }

    /// How far a pose transition has come, eased, from the moment it started.
    static func transition(at t: TimeInterval, since changedAt: TimeInterval) -> Double {
        easeInOut((t - changedAt) / transitionDuration)
    }
    /// The bubble's scale as it pops in after the pose changed.
    static func bubbleScale(at t: TimeInterval, since changedAt: TimeInterval) -> Double {
        easeOutBack((t - changedAt) / bubbleDuration)
    }

    // MARK: Tempo

    /// Whether something quick is happening at `t`: attention from the pointer or the panel, a pose transition, a
    /// bounce, the Done hop, a blink or an ear flick, each padded by one lively frame on both sides. Closed eyes do
    /// not blink, so a sleeping dog has no blink moments.
    static func lively(at t: TimeInterval, input: PetMotionInput) -> Bool {
        if input.hovered || input.panelOpen || input.gaze != nil || input.pose == .done { return true }
        if t - input.poseChangedAt < transitionDuration + livelyInterval { return true }
        if let impulseAt = input.impulseAt, t - impulseAt < impulseDuration + livelyInterval { return true }
        return moments(near: t, blinking: input.pose != .asleep)
            .contains { t >= $0.start - livelyInterval && t <= $0.start + $0.duration + livelyInterval }
    }
    /// The next quick moment that starts after `t`, if one lies within the segments around it.
    static func nextLivelyMoment(after t: TimeInterval, blinking: Bool = true) -> TimeInterval? {
        moments(near: t, blinking: blinking).map { $0.start - livelyInterval }.filter { $0 > t }.min()
    }
    private static func moments(near t: TimeInterval, blinking: Bool) -> [(start: TimeInterval, duration: TimeInterval)] {
        var found: [(start: TimeInterval, duration: TimeInterval)] = []
        if blinking { for offset in [0.0, 4.0] { found += blinkMoments(inSegmentOf: t + offset).map { ($0, blinkDuration) } } }
        for offset in [0.0, 6.0] { if let at = twitchMoment(inSegmentOf: t + offset) { found.append((at, twitchDuration)) } }
        return found
    }
}

/// The pet's frame clock. It publishes the time of each frame at the tempo of what is happening: twelve a second
/// for the loops, six while asleep, thirty while something quick happens, and a pack's own frame boundaries; nothing
/// runs between frames. A timer armed for the next frame costs a fraction of a SwiftUI timeline, whose display link
/// keeps waking at the screen's rate however few frames it draws (AC-39.08).
@MainActor final class PetFrameClock: ObservableObject {
    /// The time the current frame shows; nil while the pet stands still.
    @Published private(set) var frame: TimeInterval?
    var input = PetMotionInput()
    /// The pack's layout while a pack is the pet; nil for the dog.
    var sprite: PetSpriteVersion?
    private var timer: Timer?
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) { self.now = now }
    var isRunning: Bool { timer != nil }

    /// Shows a frame now and keeps framing until `stop()`; called again, it shows the latest input at once.
    func start() { show(at: now()) }
    func stop() {
        timer?.invalidate(); timer = nil
        if frame != nil { frame = nil }
    }
    private func show(at t: TimeInterval) {
        frame = t
        timer?.invalidate()
        let next = Self.nextFrame(after: t, input: input, sprite: sprite)
        let timer = Timer(fire: Date(timeIntervalSinceReferenceDate: next), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A frame that comes late, as after the Mac slept, shows the present rather than catching up.
                let current = self.now()
                self.show(at: current - next > PetMotion.livelyInterval ? current : next)
            }
        }
        timer.tolerance = min(0.008, (next - t) * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The moment of the frame after one at `t`. The dog's loops are framed twelve times a second, six while
    /// asleep, thirty while something quick happens, landing exactly on the start of the next blink or flick so that
    /// a calm frame never skips over one. A pack changes cells at its own frame durations; only Lunlet's bubble
    /// popping in needs quick frames, and a look cell stands still until the pointer moves, which the host redraws.
    nonisolated static func nextFrame(after t: TimeInterval, input: PetMotionInput, sprite: PetSpriteVersion?) -> TimeInterval {
        var step: TimeInterval
        if let version = sprite {
            let popping = input.pose.bubble != nil && !input.panelOpen
                && t - input.poseChangedAt < PetMotion.bubbleDuration + PetMotion.livelyInterval
            step = popping ? PetMotion.livelyInterval : input.pose == .asleep ? PetMotion.restfulInterval : PetMotion.restingInterval
            if let change = PetSpriteRule.nextChange(after: t, cue: PetSpriteDrawing.cue(from: input, version: version)), change - t < step {
                step = Swift.max(change - t, 0.004)
            }
        } else {
            let rest = input.pose == .asleep ? PetMotion.restfulInterval : PetMotion.calmInterval
            step = PetMotion.lively(at: t, input: input) ? PetMotion.livelyInterval : rest
            if step > PetMotion.livelyInterval, let soon = PetMotion.nextLivelyMoment(after: t, blinking: input.pose != .asleep),
               soon - t < step {
                step = Swift.max(soon - t, PetMotion.livelyInterval)
            }
        }
        return t + step
    }
}
