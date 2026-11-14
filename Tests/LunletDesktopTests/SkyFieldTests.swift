// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.09; US-24, AC-24.04; US-25, AC-25.01.
import AppKit
import SwiftUI
import Testing
import LunletCore
@testable import LunletDesktop

/// The header's night sky: one still drawing at rest, and one streak of travel when a body is chosen that returns
/// to rest by itself and never moves under Reduce Motion (AC-19.09, AC-24.04).
struct SkyFieldTests {
    private let header = CGSize(width: 470, height: 170)
    private let start = Date(timeIntervalSinceReferenceDate: 4096)
    private func warp(_ id: Int = 1, direction: CGFloat = 1, strength: Double = 1, after: TimeInterval = 0) -> SkyWarp {
        SkyWarp(id: id, direction: direction, strength: strength, start: start.addingTimeInterval(after))
    }
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
    private func near(_ left: CGFloat, _ right: CGFloat, within tolerance: CGFloat = 1e-6) -> Bool { abs(left - right) < tolerance }

    // MARK: The stars

    @Test func theStarsAreTheSameOnEveryLaunchAndStayInsideTheField() {
        for size in [header, CGSize(width: 430, height: 268), CGSize(width: 300, height: 120)] {
            let field = SkyStars(size: size)
            #expect(field.stars == SkyStars(size: size).stars)
            #expect(field.clouds == SkyStars(size: size).clouds)
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -SkyStars.pad, dy: -SkyStars.pad)
            #expect(field.stars.allSatisfy { bounds.contains(CGPoint(x: $0.x, y: $0.y)) && $0.radius > 0 && $0.alpha > 0 && $0.alpha <= 1 })
            #expect(field.clouds.allSatisfy { bounds.contains(CGPoint(x: $0.x, y: $0.y)) })
        }
        #expect(SkyStars(size: .zero).stars.isEmpty)
    }

    @Test func theFieldIsDenseAndEvenAtTheHeadersSize() {
        // The sky is dense, and as dense whatever the header's size.
        let field = SkyStars(size: header)
        let area = (header.width + 2 * SkyStars.pad) * (header.height + 2 * SkyStars.pad)
        let scattered = field.stars.filter { $0.kind != .lane }
        #expect(abs(Double(scattered.count) / Double(area) - Double(SkyStars.density)) < 0.0001)
        #expect(field.stars.count > 700)
        #expect(field.stars.filter { if case .bright = $0.kind { true } else { false } }.count >= 12)
        // The scattered stars are spread evenly: no eighth of the field is nearly empty or crowded.
        var cells = [Int](repeating: 0, count: 8)
        for star in scattered where star.x >= 0 && star.x < header.width && star.y >= 0 && star.y < header.height {
            cells[Int(star.x / header.width * 4) + 4 * Int(star.y / header.height * 2)] += 1
        }
        let mean = Double(cells.reduce(0, +)) / 8
        #expect(cells.allSatisfy { Double($0) > mean * 0.55 && Double($0) < mean * 1.45 }, "\(cells)")
    }

    @Test func travelMovesNearerStarsFartherAndWrapsEveryStarInsideTheField() throws {
        let field = SkyStars(size: header)
        let low = -SkyStars.pad, high = header.width + SkyStars.pad
        for offset in [0, 10, -10, 387.5, -4_321, 1_000_000, -1e12] as [CGFloat] {
            for star in field.stars {
                let point = field.position(of: star, offset: offset)
                #expect(point.x >= low && point.x < high && point.y == star.y, "\(offset) \(star)")
            }
        }
        // Every star travels, a star in front by more.
        #expect(field.stars.allSatisfy { $0.depth > 0 && $0.depth <= 1 })
        let near = field.stars.filter { $0.depth > 0.5 && $0.x > 100 && $0.x < 300 }.prefix(5)
        #expect(!near.isEmpty)
        for star in near {
            #expect(abs(field.position(of: star, offset: 40).x - (star.x - 40 * star.depth)) < 1e-9)
            #expect(abs(field.position(of: star, offset: -40).x - (star.x + 40 * star.depth)) < 1e-9)
        }
        // Wrapping only moves a star by whole fields, so the density never changes.
        let span = header.width + 2 * SkyStars.pad
        for star in field.stars.prefix(200) where star.depth > 0 {
            let moved = field.position(of: star, offset: 5_000).x - (star.x - 5_000 * star.depth)
            #expect(abs(moved / span - (moved / span).rounded()) < 1e-6)
        }
    }

    @Test func theLaneOfDustCrossesOnASlantAndKeepsItsShapeHoweverFarTheFieldTravels() {
        // A lane of dust runs from the lower leading corner to the upper trailing one. It travels as one piece and
        // wraps onto itself, so no amount of travel scatters it.
        let field = SkyStars(size: header)
        let lane = field.stars.filter { $0.kind == .lane }
        let spanX = header.width + 2 * SkyStars.pad, spanY = header.height + 2 * SkyStars.pad
        #expect(abs(lane.count - Int((300 * spanX / 462).rounded())) <= 1)
        #expect(lane.allSatisfy { $0.depth == SkyStars.laneDepth })
        func mean(_ stars: [SkyStar]) -> CGFloat { stars.map(\.y).reduce(0, +) / CGFloat(max(1, stars.count)) }
        #expect(mean(lane.filter { $0.x < header.width * 0.3 }) > mean(lane.filter { $0.x > header.width * 0.7 }) + header.height / 3)
        let reach = 26 * header.height / 170 + 0.01
        for offset in [0, 333, -5_000, 123_456.5] as [CGFloat] {
            let shift = field.position(of: lane[0], offset: offset).x - lane[0].x
            for star in lane {
                let point = field.position(of: star, offset: offset)
                // One piece: every grain moved by the same amount, give or take whole fields.
                let moved = (point.x - star.x - shift) / spanX
                #expect(abs(moved - moved.rounded()) < 1e-6, "\(offset)")
                // Still a lane: each grain within the lane's width of its center line, across the wrap.
                var gap = abs(point.y - field.laneCenter(at: point.x, offset: offset)).truncatingRemainder(dividingBy: spanY)
                gap = min(gap, spanY - gap)
                #expect(gap <= reach, "\(offset) \(point) \(gap)")
            }
        }
    }

    // MARK: One streak of travel

    @Test func theSpeedFollowsOneBellInTimeAndIsStillAtBothEnds() {
        #expect(SkyMotion.bell(0) == 0)
        #expect(abs(SkyMotion.bell(1)) < 1e-12)
        #expect(SkyMotion.bell(0.5) == 1)
        #expect(abs(SkyMotion.bell(0.25) - 0.5) < 1e-12)
        #expect(abs(SkyMotion.bell(0.2) - SkyMotion.bell(0.8)) < 1e-12)
        // Outside the streak, and for a time that is not a number, nothing moves and no NaN reaches a position.
        for value in [-0.4, 1.3, -.infinity, .infinity, .nan] { #expect(SkyMotion.bell(value) == 0, "\(value)") }

        let one = warp(strength: 1)
        #expect(SkyMotion.progress(of: one, at: at(-5)) == 0)
        #expect(abs(SkyMotion.progress(of: one, at: at(SkyWarp.duration / 2)) - 0.5) < 1e-9)
        #expect(SkyMotion.progress(of: one, at: at(60)) == 1)
        #expect(SkyMotion.speed(of: one, at: at(0)) == 0)
        #expect(near(SkyMotion.speed(of: one, at: at(SkyWarp.duration / 2)), SkyMotion.peakSpeed))
        #expect(SkyMotion.speed(of: one, at: at(SkyWarp.duration * 2)) == 0)
        #expect(near(SkyMotion.speed(of: warp(strength: 1.6), at: at(SkyWarp.duration / 2)), SkyMotion.peakSpeed * 1.6))
        #expect(near(SkyMotion.speed(of: warp(strength: 40), at: at(SkyWarp.duration / 2)), SkyMotion.peakSpeed * 1.6))
        #expect(SkyMotion.speed(of: warp(strength: -3), at: at(0.3)) == 0)
        #expect(SkyMotion.speed(of: warp(strength: .nan), at: at(0.3)) == 0)
        #expect(SkyMotion.speed(of: nil, at: at(0.3)) == 0)
    }

    @Test func theBreathOfLightRisesAndFallsWithTheStreak() {
        #expect(SkyMotion.flash(of: warp(), at: at(0)) == 0)
        #expect(abs(SkyMotion.flash(of: warp(), at: at(SkyWarp.duration / 2)) - 0.16) < 1e-9)
        #expect(SkyMotion.flash(of: warp(), at: at(SkyWarp.duration)) == 0)
        #expect(abs(SkyMotion.flash(of: warp(strength: 1.6), at: at(SkyWarp.duration / 2)) - 0.16 * 1.4) < 1e-9)
        #expect(SkyMotion.flash(of: warp(strength: 0), at: at(0.3)) == 0)
        #expect(SkyMotion.flash(of: warp(strength: .nan), at: at(0.3)) == 0)
    }

    @Test func theDistanceIsTheSpeedAddedUpAndEndsAtHalfThePeakTimesTheDuration() {
        #expect(SkyMotion.distance(strength: 1, progress: 0) == 0)
        let whole = SkyMotion.distance(strength: 1, progress: 1)
        #expect(abs(whole - SkyMotion.peakSpeed * CGFloat(SkyWarp.duration) / 2) < 1e-9)
        #expect(SkyMotion.distance(strength: 1, progress: 4) == whole)
        #expect(SkyMotion.distance(strength: 1, progress: -1) == 0)
        #expect(SkyMotion.distance(strength: .nan, progress: 0.5) == 0)
        #expect(SkyMotion.distance(strength: 1, progress: .nan) == 0)
        #expect(abs(SkyMotion.distance(strength: 0.5, progress: 1) - whole / 2) < 1e-9)
        // It only grows, and its slope is the speed at that moment.
        var last: CGFloat = 0
        for step in 1...200 {
            let progress = Double(step) / 200, here = SkyMotion.distance(strength: 1, progress: progress)
            #expect(here >= last); last = here
        }
        let h = 1e-5
        for progress in [0.1, 0.37, 0.5, 0.9] {
            let slope = (SkyMotion.distance(strength: 1, progress: progress + h) - SkyMotion.distance(strength: 1, progress: progress - h))
                / CGFloat(2 * h * SkyWarp.duration)
            #expect(abs(slope - SkyMotion.peakSpeed * CGFloat(SkyMotion.bell(progress))) < 0.01, "\(progress)")
        }
    }

    @Test func aValueWrapsIntoItsSpanHoweverFarItWent() {
        for value in [-16, 0, 485.999, 486, 487, -17, 1e9, -1e9, 1e15] as [CGFloat] {
            let wrapped = SkyMotion.wrapped(value, from: -16, length: 502)
            #expect(wrapped >= -16 && wrapped < 486, "\(value) -> \(wrapped)")
        }
        #expect(SkyMotion.wrapped(100, from: -16, length: 502) == 100)
        #expect(SkyMotion.wrapped(486 + 20, from: -16, length: 502) == 4)
        #expect(SkyMotion.wrapped(-20, from: -16, length: 502) == 482)
        #expect(SkyMotion.wrapped(.nan, from: -16, length: 502) == -16)
        #expect(SkyMotion.wrapped(.infinity, from: -16, length: 502) == -16)
        #expect(SkyMotion.wrapped(40, from: -16, length: 0) == -16)
    }

    @Test func aStreakPointsAwayFromAVanishingPointFarAhead() {
        // Traveling toward the trailing side, the vanishing point is far to the right and the stars streak to the left,
        // fanning a little away from the row of bodies.
        let right = SkyMotion.vanishingPoint(direction: 1, in: header, layout: SkyLayout())
        #expect(right.x > header.width * 1.5 && abs(right.y - header.height * SkyLayout().horizon) < 1e-9)
        let above = SkyMotion.streak(from: CGPoint(x: 235, y: 10), vanishing: right)
        let below = SkyMotion.streak(from: CGPoint(x: 235, y: 160), vanishing: right)
        #expect(above.dx < -0.95 && above.dy < 0 && below.dx < -0.95 && below.dy > 0)
        #expect(abs(hypot(above.dx, above.dy) - 1) < 1e-9 && abs(hypot(below.dx, below.dy) - 1) < 1e-9)
        let left = SkyMotion.vanishingPoint(direction: -1, in: header, layout: SkyLayout())
        #expect(left.x < -header.width * 0.5)
        #expect(SkyMotion.streak(from: CGPoint(x: 235, y: 60), vanishing: left).dx > 0.95)
        // A star on the vanishing point still gets a direction.
        let onPoint = SkyMotion.streak(from: right, vanishing: right)
        #expect(onPoint.dx.isFinite && onPoint.dy.isFinite && abs(hypot(onPoint.dx, onPoint.dy) - 1) < 1e-9)
    }

    // MARK: Rest, and Reduce Motion

    @Test func nothingAnimatesAtRestAfterTheStreakOrUnderReduceMotion() {
        // US-25: at rest the sky installs no timeline; AC-24.04: with Reduce Motion it never moves.
        #expect(!SkyMotion.isAnimating(nil, reduceMotion: false, at: at(0)))
        #expect(SkyMotion.isAnimating(warp(), reduceMotion: false, at: at(0)))
        #expect(SkyMotion.isAnimating(warp(), reduceMotion: false, at: at(SkyWarp.duration - 0.01)))
        #expect(!SkyMotion.isAnimating(warp(), reduceMotion: false, at: at(SkyWarp.duration)))
        #expect(!SkyMotion.isAnimating(warp(), reduceMotion: false, at: at(3600)))
        #expect(!SkyMotion.isAnimating(warp(), reduceMotion: true, at: at(0.2)))
        #expect(!SkyMotion.isAnimating(warp(strength: 0), reduceMotion: false, at: at(0.2)))
        #expect(!SkyMotion.isAnimating(warp(strength: .nan), reduceMotion: false, at: at(0.2)))
        #expect(!SkyMotion.isAnimating(warp(direction: 0), reduceMotion: false, at: at(0.2)))
    }

    @Test func theFieldRestsWhereAStreakLeftItAndTheNextOneStartsThere() {
        var travel = SkyTravel()
        #expect(travel.offset(at: at(0)) == 0)
        let whole = SkyMotion.distance(strength: 1, progress: 1)
        travel.begin(warp(1, direction: 1), at: at(0), reduceMotion: false)
        #expect(travel.offset(at: at(0)) == 0)
        #expect(near(travel.offset(at: at(SkyWarp.duration / 2)), whole / 2))
        #expect(travel.offset(at: at(10)) == whole)
        #expect(travel.offset(at: .distantFuture) == whole)
        // The same streak again changes nothing, however often the view asks.
        travel.begin(warp(1, direction: 1), at: at(5), reduceMotion: false)
        #expect(travel.offset(at: at(10)) == whole)
        // The next one, the other way, starts from where the field rests and ends back at the start.
        travel.begin(warp(2, direction: -1, after: 20), at: at(20), reduceMotion: false)
        #expect(travel.offset(at: at(20)) == whole)
        #expect(near(travel.offset(at: at(40)), 0))
        // One that interrupts another starts from where the field is at that moment: no jump.
        travel.begin(warp(3, direction: 1, after: 50), at: at(50), reduceMotion: false)
        let midway = travel.offset(at: at(50 + SkyWarp.duration / 2))
        travel.begin(warp(4, direction: 1, after: 50 + SkyWarp.duration / 2), at: at(50 + SkyWarp.duration / 2), reduceMotion: false)
        #expect(travel.offset(at: at(50 + SkyWarp.duration / 2)) == midway)
        #expect(near(travel.offset(at: at(90)), midway + whole))
        // Without a streak the field stays where it is.
        travel.begin(nil, at: at(100), reduceMotion: false)
        #expect(near(travel.offset(at: at(200)), midway + whole))
    }

    @Test func underReduceMotionAStreakNeverMovesTheField() {
        var travel = SkyTravel()
        travel.begin(warp(1), at: at(0), reduceMotion: true)
        #expect(travel.offset(at: at(0.3)) == 0 && travel.offset(at: at(30)) == 0)
        #expect(!SkyMotion.isAnimating(travel.warp, reduceMotion: true, at: at(0.3)))
        travel.begin(warp(2, direction: -1, after: 40), at: at(40), reduceMotion: true)
        #expect(travel.offset(at: .distantFuture) == 0)
    }
}

/// The sky as drawn.
@MainActor struct SkyFieldRenderTests {
    private let header = CGSize(width: 470, height: 170)
    private func bright(_ image: HeaderArtBitmap, over level: Double) -> Int {
        var count = 0
        for y in 0..<image.height { for x in 0..<image.width where HeaderArtBitmap.luminance(image.at(x, y)) > level { count += 1 } }
        return count
    }

    @Test func theSkyIsDarkWithStarsInBothAppearances() throws {
        // Design notes, Appearance: in the light appearance the sky stays dark inside its window.
        let dark = try HeaderArtBitmap(SkyField(warp: nil, reduceMotion: false).environment(\.colorScheme, .dark), size: header)
        let light = try HeaderArtBitmap(SkyField(warp: nil, reduceMotion: false).environment(\.colorScheme, .light), size: header)
        #expect(dark.matches(light))
        #expect(dark.luminance(in: CGRect(origin: .zero, size: header)) < 40)
        #expect(dark.at(point: CGPoint(x: 2, y: 2)).a == 255 && dark.at(point: CGPoint(x: 468, y: 168)).a == 255)
        #expect(bright(dark, over: 110) > 150)
        // The same drawing every time.
        #expect(try HeaderArtBitmap(SkyField(warp: nil, reduceMotion: false), size: header).matches(dark))
    }

    @Test func aStreakDrawsTrailsAndRestDrawsPoints() throws {
        let stars = SkyStars(size: header)
        let rest = try HeaderArtBitmap(SkyCanvas(stars: stars), size: header)
        let field = try HeaderArtBitmap(SkyField(warp: nil, reduceMotion: false), size: header)
        #expect(rest.matches(field))
        for direction in [1, -1] as [CGFloat] {
            let streak = try HeaderArtBitmap(SkyCanvas(stars: stars, offset: direction * 270, speed: SkyMotion.peakSpeed,
                                                       direction: direction, flash: 0), size: header)
            #expect(bright(streak, over: 110) > 3 * bright(rest, over: 110), "\(direction)")
        }
        // A field that has traveled and stopped is as quiet as one that never moved.
        let settled = try HeaderArtBitmap(SkyCanvas(stars: stars, offset: 270), size: header)
        #expect(abs(bright(settled, over: 110) - bright(rest, over: 110)) < bright(rest, over: 110) / 4)
    }

    /// Opt-in: writes the sky at rest and at the middle of a streak each way, and the bodies on it, to the directory
    /// that `LUNLET_ART_DIR` names, for a visual review. Nothing is asserted and nothing is committed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_ART_DIR"] != nil))
    func renderTheSkyForReview() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LUNLET_ART_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stars = SkyStars(size: header)
        try HeaderArtBitmap(SkyField(warp: nil, reduceMotion: false), size: header).png().write(to: directory.appendingPathComponent("sky-rest.png"))
        for (name, direction) in [("sky-warp-trailing", 1), ("sky-warp-leading", -1)] as [(String, CGFloat)] {
            let canvas = SkyCanvas(stars: stars, offset: direction * SkyMotion.distance(strength: 1, progress: 0.5),
                                   speed: SkyMotion.peakSpeed, direction: direction, flash: 0.16)
            try HeaderArtBitmap(canvas, size: header).png().write(to: directory.appendingPathComponent(name + ".png"))
        }
        // The field long after many streaks, to see that travel leaves it as even as it began.
        try HeaderArtBitmap(SkyCanvas(stars: stars, offset: 123_456.5), size: header).png().write(to: directory.appendingPathComponent("sky-traveled.png"))
        // What one streak costs to draw off screen: every frame of 0.72 s at 120 per second, rasterized on the CPU at 2x.
        let frames = 87, clock = ContinuousClock(), began = clock.now
        for frame in 0..<frames {
            let progress = Double(frame) / Double(frames)
            let canvas = SkyCanvas(stars: stars, offset: SkyMotion.distance(strength: 1, progress: progress),
                                   speed: SkyMotion.peakSpeed * CGFloat(SkyMotion.bell(progress)), direction: 1, flash: 0.16 * SkyMotion.bell(progress))
            _ = try HeaderArtBitmap(canvas, size: header)
        }
        let spent = clock.now - began
        print("sky streak: \(frames) frames drawn off screen in \(spent), \(spent / frames) each")
        func body(_ kind: HeaderBody, lit: Double?, mirrored: Bool = false, side: CGFloat, x: CGFloat, y: CGFloat = 60) -> some View {
            HeaderBodyArt(kind, lit: lit, mirrored: mirrored).frame(width: side, height: side).position(x: x, y: y)
        }
        let overview = ZStack {
            SkyField(warp: nil, reduceMotion: false)
            body(.agent(.codex), lit: 0.62, mirrored: true, side: 48, x: 113)
            body(.all, lit: nil, side: 48, x: 235)
            body(.agent(.claude), lit: 0.85, side: 48, x: 357)
        }
        try HeaderArtBitmap(overview, size: header).png().write(to: directory.appendingPathComponent("sky-overview.png"))
        let chosen = ZStack {
            SkyField(warp: nil, reduceMotion: false)
            body(.agent(.codex), lit: 0.62, side: 64, x: 235)
            body(.all, lit: nil, side: 30, x: 343, y: 66)
            body(.agent(.claude), lit: 0.85, side: 24, x: 415, y: 66)
        }
        try HeaderArtBitmap(chosen, size: header).png().write(to: directory.appendingPathComponent("sky-chosen.png"))
        let shares: [Double?] = [nil, 1, 0.85, 0.62, 0.23, 0.05]
        let sheet = ZStack {
            SkyField(warp: nil, reduceMotion: false)
            ForEach(0..<shares.count, id: \.self) { column in
                body(.agent(.codex), lit: shares[column], side: 64, x: 44 + CGFloat(column) * 76, y: 44)
                body(.agent(.claude), lit: shares[column], mirrored: true, side: 26, x: 44 + CGFloat(column) * 76, y: 104)
                body(.agent(.claude), lit: shares[column], side: 26, x: 44 + CGFloat(column) * 76, y: 140)
            }
        }
        try HeaderArtBitmap(sheet, size: header).png().write(to: directory.appendingPathComponent("sky-bodies.png"))
    }
}

/// The sky in a real window, where its task and timeline run. Opt-in with the other native checks.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_PANEL"] == "1"))
@MainActor struct SkyFieldOnScreenTests {
    private final class Model: ObservableObject {
        @Published var warp: SkyWarp?
    }
    private struct Host: View {
        @ObservedObject var model: Model
        let reduceMotion: Bool
        var body: some View { SkyField(warp: model.warp, reduceMotion: reduceMotion) }
    }
    private func fixture(reduceMotion: Bool) -> (Model, NSPanel, NSHostingView<Host>) {
        _ = NSApplication.shared
        let model = Model()
        let panel = NSPanel(contentRect: .init(x: 600, y: 400, width: 470, height: 170),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: Host(model: model, reduceMotion: reduceMotion))
        panel.contentView = hosting
        panel.orderFrontRegardless()
        return (model, panel, hosting)
    }
    /// How many pixels of the view are bright: few for points, many for trails.
    private func bright(_ view: NSView) throws -> Int {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                if 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent > 0.43 { count += 1 }
            }
        }
        return count
    }
    private func wait(upTo seconds: Int = 10, until met: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if try await met() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test func aStreakPlaysOnceAndTheSkyComesToRestByItself() async throws {
        // AC-19.09 and US-25: one streak when a body is chosen, then a still sky again with nothing left running.
        let (model, panel, hosting) = fixture(reduceMotion: false)
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(200))
        let rest = try bright(hosting)
        try #require(rest > 50, "the still sky draws its stars: \(rest)")
        // A streak runs on the wall clock for 0.72 s. Another suite holding the main actor that long hides it from
        // this one, so a streak nobody saw is played again rather than counted as missing.
        var trails = false
        for attempt in 1...4 where !trails {
            model.warp = SkyWarp(id: attempt, direction: 1, strength: 1, start: Date())
            trails = try await wait(upTo: 2) { try bright(hosting) > 2 * rest }
        }
        #expect(trails, "trails appear")
        #expect(try await wait { abs(try bright(hosting) - rest) < rest / 3 }, "and the sky returns to points")
        // The last of the streak may still be fading in when it first looks like points; wait until two looks agree.
        var settled = try bright(hosting)
        #expect(try await wait(upTo: 5) {
            try await Task.sleep(for: .milliseconds(150))
            let now = try bright(hosting)
            defer { settled = now }
            return now == settled
        }, "the sky comes to rest")
        // Nothing moves afterwards: two looks a moment apart are the same picture.
        try await Task.sleep(for: .milliseconds(600))
        #expect(try bright(hosting) == settled)
    }

    @Test func underReduceMotionChoosingABodyNeverMovesTheSky() async throws {
        // AC-24.04.
        let (model, panel, hosting) = fixture(reduceMotion: true)
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(200))
        let rest = try bright(hosting)
        try #require(rest > 50)
        model.warp = SkyWarp(id: 1, direction: -1, strength: 1.6, start: Date())
        let moved = try await wait(upTo: 1) { try bright(hosting) > rest + rest / 3 }
        #expect(!moved)
    }
}
