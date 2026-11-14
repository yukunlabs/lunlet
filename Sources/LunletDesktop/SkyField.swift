// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.09; US-24, AC-24.04; US-25, AC-25.01.
import SwiftUI

/// One travel streak: `direction` is -1 toward the leading side or +1 toward the trailing side, `strength` 0...1.6,
/// `start` when it began.
struct SkyWarp: Equatable {
    var id: Int
    var direction: CGFloat
    var strength: Double
    var start: Date
    static let duration: TimeInterval = 0.72
}

/// Where the header's content sits in the sky, as shares of its height: the row of bodies, and the band of labels
/// below it where the sky is quieter so the words stay readable.
struct SkyLayout: Equatable {
    /// The row of bodies; streaks fan away from it.
    var horizon: CGFloat = 60.0 / 170
    /// Where the labels begin.
    var calm: CGFloat = 92.0 / 170
    /// The height over which streaks thin out below that line.
    var calmSpan: CGFloat = 24.0 / 170
}

/// The arithmetic of one streak. Speed follows one bell in time, so the sky starts and stops without a jerk, and
/// the distance is that speed added up, so a frame is a function of the clock alone and no frame depends on the
/// one before it.
enum SkyMotion {
    /// Points per second of the nearest stars at the middle of a streak of strength 1.
    static let peakSpeed: CGFloat = 1500
    /// A trail is as long as the star travels in this many seconds.
    static let trail: CGFloat = 0.055
    static let strongest = 1.6

    /// sin² over the streak: 0 at both ends, 1 in the middle, and 0 outside it or for a time that is not a number.
    static func bell(_ progress: Double) -> Double {
        guard progress.isFinite, progress > 0, progress < 1 else { return 0 }
        let wave = sin(.pi * progress)
        return wave * wave
    }
    /// How far through its duration a streak is, 0...1.
    static func progress(of warp: SkyWarp, at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(warp.start) / SkyWarp.duration
        return elapsed.isFinite ? min(1, max(0, elapsed)) : (elapsed > 0 ? 1 : 0)
    }
    private static func usable(_ strength: Double) -> Double {
        strength.isFinite ? min(strongest, max(0, strength)) : 0
    }
    /// The nearest stars' speed at `date`, never negative.
    static func speed(of warp: SkyWarp?, at date: Date) -> CGFloat {
        guard let warp else { return 0 }
        return peakSpeed * CGFloat(usable(warp.strength) * bell(progress(of: warp, at: date)))
    }
    /// The breath of light around the center, strongest at the middle of a streak.
    static func flash(of warp: SkyWarp, at date: Date) -> Double {
        0.16 * min(1.4, usable(warp.strength)) * bell(progress(of: warp, at: date))
    }
    /// How far the nearest stars have traveled `progress` of the way through a streak: the bell added up.
    static func distance(strength: Double, progress: Double) -> CGFloat {
        guard progress.isFinite else { return 0 }
        let part = min(1, max(0, progress))
        return peakSpeed * CGFloat(usable(strength) * SkyWarp.duration * (part / 2 - sin(2 * .pi * part) / (4 * .pi)))
    }
    /// Whether a timeline has anything to draw: only during a streak, and never with Reduce Motion (AC-24.04).
    static func isAnimating(_ warp: SkyWarp?, reduceMotion: Bool, at date: Date) -> Bool {
        guard let warp, !reduceMotion, usable(warp.strength) > 0, warp.direction.isFinite, warp.direction != 0 else { return false }
        return date < warp.start.addingTimeInterval(SkyWarp.duration)
    }
    /// `value` carried into `low ..< low + length` by whole lengths.
    static func wrapped(_ value: CGFloat, from low: CGFloat, length: CGFloat) -> CGFloat {
        guard value.isFinite, length > 0 else { return low }
        var rest = (value - low).truncatingRemainder(dividingBy: length)
        if rest < 0 { rest += length }
        return rest < length ? low + rest : low
    }
    /// The point far ahead that the view travels toward.
    static func vanishingPoint(direction: CGFloat, in size: CGSize, layout: SkyLayout) -> CGPoint {
        CGPoint(x: size.width / 2 + direction * 620 * size.width / 430, y: size.height * layout.horizon)
    }
    /// The unit direction a star streaks in: away from the vanishing point, its vertical part damped.
    static func streak(from point: CGPoint, vanishing: CGPoint) -> CGVector {
        let dx = point.x - vanishing.x, dy = (point.y - vanishing.y) * 0.55, length = hypot(dx, dy)
        guard length.isFinite, length > 1e-9 else { return CGVector(dx: 1, dy: 0) }
        return CGVector(dx: dx / length, dy: dy / length)
    }
}

/// One star. `depth` is how near it is, up to 1: nearer stars travel farther in a streak.
struct SkyStar: Equatable {
    enum Kind: Equatable {
        case dust
        /// A grain of the slanted lane of dust, which travels as one piece.
        case lane
        case star
        /// A bright star with a glow, in one of three tints.
        case bright(Int)
    }
    var x: CGFloat
    var y: CGFloat
    var depth: CGFloat
    var radius: CGFloat
    var alpha: Double
    var kind: Kind
}

/// A distant galaxy: a faint tilted smudge.
struct SkyCloud: Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var tilt: Double
    var warm: Bool
}

/// Every star of a sky of one size, from a fixed seed: the same on every launch and in every render. Most are
/// scattered evenly over the field and a margin around it; a lane of dust crosses it on a slant, from the lower
/// leading corner to the upper trailing one.
struct SkyStars: Equatable {
    /// The margin around the visible field that stars also fill, so a streak never drags an empty edge into view.
    static let pad: CGFloat = 16
    /// Scattered stars per square point: a dense sky.
    static let density: CGFloat = 756.0 / 138_600
    /// The lane's one depth: its grains travel together, and because the lane climbs one field's height over one
    /// field's width it wraps onto itself, so travel never scatters it.
    static let laneDepth: CGFloat = 0.17

    let size: CGSize
    let stars: [SkyStar]
    let clouds: [SkyCloud]

    /// The content follows from the size alone.
    static func == (left: SkyStars, right: SkyStars) -> Bool { left.size == right.size }

    init(size: CGSize) {
        self.size = size
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { stars = []; clouds = []; return }
        let spanX = size.width + 2 * Self.pad, spanY = size.height + 2 * Self.pad
        // The prototype's field measured 462 by 300 with its margin.
        let scale = spanX * spanY / 138_600
        // SplitMix64 from a fixed seed. A plain multiplicative generator lines the lane's dust up in visible rows,
        // because each star takes several numbers in a row from it.
        var state: UInt64 = 11
        func next() -> CGFloat {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            mixed ^= mixed >> 31
            return CGFloat(mixed >> 11) / 9_007_199_254_740_992
        }
        func count(_ reference: CGFloat) -> Int { Int((reference * scale).rounded()) }
        var all: [SkyStar] = []
        for _ in 0..<count(520) {
            all.append(SkyStar(x: next() * spanX - Self.pad, y: next() * spanY - Self.pad, depth: 0.10 + next() * 0.18,
                               radius: 0.22 + next() * 0.3, alpha: Double(0.10 + next() * 0.30), kind: .dust))
        }
        // The lane: dust gathered about a slanted line, denser toward its middle.
        for _ in 0..<Int((300 * spanX / 462).rounded()) {
            let x = next() * spanX - Self.pad, spread = (next() + next() + next() - 1.5) / 1.5
            let y = Self.laneCenter(at: x, offset: 0, size: size) + spread * 26 * size.height / 170
            all.append(SkyStar(x: x, y: SkyMotion.wrapped(y, from: -Self.pad, length: spanY), depth: Self.laneDepth,
                               radius: 0.2 + next() * 0.28, alpha: Double(0.10 + next() * 0.26), kind: .lane))
        }
        for _ in 0..<count(210) {
            all.append(SkyStar(x: next() * spanX - Self.pad, y: next() * spanY - Self.pad, depth: 0.30 + next() * 0.55,
                               radius: 0.42 + next() * 0.7, alpha: Double(0.2 + next() * 0.5), kind: .star))
        }
        for index in 0..<count(18) {
            all.append(SkyStar(x: next() * spanX - Self.pad, y: next() * spanY - Self.pad, depth: 0.8 + next() * 0.2,
                               radius: 0.95 + next() * 0.6, alpha: Double(0.75 + next() * 0.25), kind: .bright(index % 3)))
        }
        stars = all
        clouds = (0..<max(2, count(5))).map { _ in
            SkyCloud(x: next() * spanX - Self.pad, y: next() * spanY - Self.pad, width: 7 + next() * 9,
                     tilt: Double(next()) * .pi, warm: next() <= 0.5)
        }
    }

    /// Where a star is once the nearest stars have traveled `offset` points toward the leading side: it moves by its
    /// depth and wraps by whole fields, so the density of the field never changes.
    func position(of star: SkyStar, offset: CGFloat) -> CGPoint {
        guard star.depth > 0 else { return CGPoint(x: star.x, y: star.y) }
        return CGPoint(x: SkyMotion.wrapped(star.x - star.depth * offset, from: -Self.pad, length: size.width + 2 * Self.pad), y: star.y)
    }
    /// The height of the lane's center line at `x` once the nearest stars have traveled `offset`.
    func laneCenter(at x: CGFloat, offset: CGFloat) -> CGFloat { Self.laneCenter(at: x, offset: offset, size: size) }
    static func laneCenter(at x: CGFloat, offset: CGFloat, size: CGSize) -> CGFloat {
        let spanX = size.width + 2 * pad, spanY = size.height + 2 * pad
        let along = SkyMotion.wrapped(x + pad + laneDepth * offset, from: 0, length: spanX) / spanX
        return size.height + pad - along * spanY
    }
}

/// Where the field is: what earlier streaks left, and the one that may be under way. A streak that ends leaves the
/// field where it stopped, so rest is one still drawing and the next streak starts from it without a jump.
struct SkyTravel: Equatable {
    /// The travel of the nearest stars that finished streaks have added up to.
    private(set) var settled: CGFloat = 0
    private(set) var warp: SkyWarp?

    func offset(at date: Date) -> CGFloat {
        guard let warp else { return settled }
        let side: CGFloat = warp.direction > 0 ? 1 : warp.direction < 0 ? -1 : 0
        return settled + side * SkyMotion.distance(strength: warp.strength, progress: SkyMotion.progress(of: warp, at: date))
    }
    /// Takes up `next`, keeping what the field has traveled so far. With Reduce Motion no streak is ever taken up.
    mutating func begin(_ next: SkyWarp?, at date: Date, reduceMotion: Bool) {
        let adopted = reduceMotion ? nil : next
        guard adopted?.id != warp?.id else { return }
        settled = offset(at: date)
        warp = adopted
    }
}

/// The night sky behind the header: a dense, even star field with soft color clouds, still at rest. A non-nil `warp`
/// plays one streak and returns to rest; with `reduceMotion` it never moves.
///
/// The sky is dark in both appearances; the header clips it into its window. At rest it is one drawing with no
/// timeline, timer or per-frame work (US-25); a timeline exists only for the 0.72 s of a streak.
struct SkyField: View {
    private let warp: SkyWarp?
    private let reduceMotion: Bool
    private let layout: SkyLayout
    @ViewState private var travel = SkyTravel()
    @ViewState private var moving = false

    init(warp: SkyWarp?, reduceMotion: Bool) {
        self.init(warp: warp, reduceMotion: reduceMotion, layout: SkyLayout())
    }
    init(warp: SkyWarp?, reduceMotion: Bool, layout: SkyLayout) {
        self.warp = warp; self.reduceMotion = reduceMotion; self.layout = layout
    }

    private struct Trigger: Equatable {
        let warp: Int?
        let reduceMotion: Bool
    }

    var body: some View {
        GeometryReader { proxy in
            let stars = SkyStars(size: proxy.size)
            Group {
                if moving, let current = travel.warp {
                    TimelineView(.animation) { timeline in
                        SkyCanvas(stars: stars, offset: travel.offset(at: timeline.date),
                                  speed: SkyMotion.speed(of: current, at: timeline.date), direction: current.direction,
                                  flash: SkyMotion.flash(of: current, at: timeline.date), layout: layout)
                    }
                } else {
                    // Rest: where the last streak left the field, drawn once.
                    SkyCanvas(stars: stars, offset: travel.offset(at: .distantFuture), layout: layout).equatable()
                }
            }
            // The two drawings agree where they meet, so the change between them is never animated.
            .animation(nil, value: moving)
        }
        .task(id: Trigger(warp: warp?.id, reduceMotion: reduceMotion)) {
            let now = Date()
            travel.begin(warp, at: now, reduceMotion: reduceMotion)
            guard let current = travel.warp, SkyMotion.isAnimating(current, reduceMotion: reduceMotion, at: now) else {
                moving = false
                return
            }
            moving = true
            try? await Task.sleep(for: .seconds(max(0, current.start.addingTimeInterval(SkyWarp.duration).timeIntervalSince(now))))
            if !Task.isCancelled { moving = false }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The sky for one state of the field: how far it has traveled and, during a streak, how fast and which way.
struct SkyCanvas: View, Equatable {
    let stars: SkyStars
    var offset: CGFloat = 0
    var speed: CGFloat = 0
    var direction: CGFloat = 0
    var flash: Double = 0
    var layout = SkyLayout()

    var body: some View {
        Canvas { context, size in
            SkyDrawing(stars: stars, offset: offset, speed: speed, direction: direction, flash: flash, layout: layout)
                .draw(in: context, size: size)
        }
    }
}

struct SkyDrawing {
    let stars: SkyStars
    let offset: CGFloat
    let speed: CGFloat
    let direction: CGFloat
    let flash: Double
    let layout: SkyLayout

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double, _ opacity: Double = 1) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: opacity)
    }
    /// White, the two tints of bright stars, and the pale blue of a near star's trail.
    private static let tints: [(Double, Double, Double)] = [(255, 255, 255), (207, 224, 255), (255, 233, 201), (207, 220, 255)]
    private static let alphaSteps = 24.0
    private static let widthStep: CGFloat = 0.25

    /// Marks of one tint and one opacity are drawn as one path, in a fixed order, so a frame costs a few dozen
    /// fills rather than one for every star, and two renders of the same state match to the pixel.
    private struct Batches {
        var fills: [Int: Path] = [:]
        var strokes: [Int: Path] = [:]

        static func step(_ alpha: Double) -> Int { Int((min(1, max(0, alpha)) * SkyDrawing.alphaSteps).rounded()) }
        mutating func fill(tint: Int, alpha: Double, _ add: (inout Path) -> Void) {
            let step = Self.step(alpha)
            guard step > 0 else { return }
            add(&fills[tint * 100 + step, default: Path()])
        }
        mutating func stroke(tint: Int, alpha: Double, width: CGFloat, from: CGPoint, to: CGPoint) {
            let step = Self.step(alpha), wide = max(1, Int((width / SkyDrawing.widthStep).rounded()))
            guard step > 0 else { return }
            var path = strokes[(tint * 100 + wide) * 100 + step, default: Path()]
            path.move(to: from); path.addLine(to: to)
            strokes[(tint * 100 + wide) * 100 + step] = path
        }
        func draw(in context: GraphicsContext) {
            for key in fills.keys.sorted() {
                let tint = SkyDrawing.tints[key / 100], alpha = Double(key % 100) / SkyDrawing.alphaSteps
                context.fill(fills[key] ?? Path(), with: .color(SkyDrawing.rgb(tint.0, tint.1, tint.2, alpha)))
            }
            for key in strokes.keys.sorted() {
                let tint = SkyDrawing.tints[key / 10_000], alpha = Double(key % 100) / SkyDrawing.alphaSteps
                context.stroke(strokes[key] ?? Path(), with: .color(SkyDrawing.rgb(tint.0, tint.1, tint.2, alpha)),
                               style: StrokeStyle(lineWidth: CGFloat(key / 100 % 100) * SkyDrawing.widthStep, lineCap: .round))
            }
        }
    }

    func draw(in context: GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        drawBackdrop(in: context, size: size)
        drawClouds(in: context, size: size)
        drawStars(in: context, size: size)
        if flash > 0 {
            // A breath of light around the center at the middle of a streak.
            var lit = context
            lit.opacity = min(1, flash)
            glow(in: lit, center: CGPoint(x: size.width / 2, y: size.height * 62 / 170),
                 radii: CGSize(width: 190 * size.width / 430, height: 110 * size.height / 170),
                 stops: [.init(color: Self.rgb(190, 205, 255, 0.5), location: 0), .init(color: Self.rgb(150, 170, 255, 0.1), location: 0.55),
                         .init(color: Self.rgb(150, 170, 255, 0), location: 0.75)])
        }
    }

    /// An elliptical glow that fades along its radius.
    private func glow(in context: GraphicsContext, center: CGPoint, radii: CGSize, stops: [Gradient.Stop]) {
        guard radii.width > 0, radii.height > 0 else { return }
        var local = context
        local.translateBy(x: center.x, y: center.y)
        local.scaleBy(x: 1, y: radii.height / radii.width)
        local.fill(Path(ellipseIn: CGRect(x: -radii.width, y: -radii.width, width: 2 * radii.width, height: 2 * radii.width)),
                   with: .radialGradient(Gradient(stops: stops), center: .zero, startRadius: 0, endRadius: radii.width))
    }

    private func drawBackdrop(in context: GraphicsContext, size: CGSize) {
        let sx = size.width / 430, sy = size.height / 170, rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [.init(color: Self.rgb(4, 3, 10), location: 0), .init(color: Self.rgb(10, 9, 27), location: 0.55),
                             .init(color: Self.rgb(18, 16, 41), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        func cloud(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: (Double, Double, Double, Double)) {
            glow(in: context, center: CGPoint(x: size.width * x, y: size.height * y), radii: CGSize(width: width * sx, height: height * sy),
                 stops: [.init(color: Self.rgb(color.0, color.1, color.2, color.3), location: 0),
                         .init(color: Self.rgb(color.0, color.1, color.2, 0), location: 0.7)])
        }
        cloud(0.72, 0.12, 120, 70, (230, 90, 170, 0.09))
        cloud(0.88, 0.78, 170, 100, (60, 150, 230, 0.12))
        cloud(0.14, 0.26, 150, 90, (120, 90, 255, 0.16))
        // A faint sheen across the field, along the lane of far dust.
        let angle = 104 * Double.pi / 180, along = CGVector(dx: sin(angle), dy: -cos(angle))
        let reach = (abs(size.width * along.dx) + abs(size.height * along.dy)) / 2
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        context.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [.init(color: Self.rgb(150, 140, 255, 0), location: 0.22), .init(color: Self.rgb(150, 140, 255, 0.085), location: 0.42),
                             .init(color: Self.rgb(255, 214, 190, 0.06), location: 0.52), .init(color: Self.rgb(255, 214, 190, 0), location: 0.72)]),
            startPoint: CGPoint(x: middle.x - along.dx * reach, y: middle.y - along.dy * reach),
            endPoint: CGPoint(x: middle.x + along.dx * reach, y: middle.y + along.dy * reach)))
        // Warm light around the middle of the row, where the Sun rests.
        glow(in: context, center: CGPoint(x: size.width / 2, y: size.height * layout.horizon),
             radii: CGSize(width: 210 * sx, height: 120 * sy),
             stops: [.init(color: Self.rgb(255, 186, 96, 0.22), location: 0), .init(color: Self.rgb(255, 150, 70, 0.06), location: 0.55),
                     .init(color: Self.rgb(255, 150, 70, 0), location: 0.76)])
    }

    private func drawClouds(in context: GraphicsContext, size: CGSize) {
        let calm = size.height * layout.calm
        for cloud in stars.clouds {
            var local = context
            local.translateBy(x: cloud.x, y: cloud.y)
            local.rotate(by: .radians(cloud.tilt))
            local.scaleBy(x: 1, y: 0.42)
            local.opacity = cloud.y < calm ? 1 : 0.5
            let tint: (Double, Double, Double) = cloud.warm ? (255, 214, 190) : (200, 190, 255)
            local.fill(Path(ellipseIn: CGRect(x: -cloud.width, y: -cloud.width, width: 2 * cloud.width, height: 2 * cloud.width)),
                       with: .radialGradient(
                        Gradient(stops: [.init(color: Self.rgb(tint.0, tint.1, tint.2, 0.34), location: 0),
                                         .init(color: Self.rgb(tint.0, tint.1, tint.2, 0.12), location: 0.35),
                                         .init(color: Self.rgb(tint.0, tint.1, tint.2, 0), location: 1)]),
                        center: .zero, startRadius: 0, endRadius: cloud.width))
        }
    }

    private func drawStars(in context: GraphicsContext, size: CGSize) {
        let calm = size.height * layout.calm, calmSpan = max(1, size.height * layout.calmSpan)
        let vanishing = SkyMotion.vanishingPoint(direction: direction, in: size, layout: layout)
        var batches = Batches()
        for star in stars.stars {
            let point = stars.position(of: star, offset: offset)
            let length = speed * star.depth * SkyMotion.trail
            let glint = min(1, star.alpha + Double(min(0.4, length / 60)))
            if length < 1.2 {
                // A point: the sky is quieter behind the labels than among the bodies.
                let alpha = glint * (point.y < calm ? 1 : 0.55)
                switch star.kind {
                case .dust, .lane:
                    batches.fill(tint: 0, alpha: alpha) { $0.addRect(CGRect(x: point.x, y: point.y, width: 2 * star.radius, height: 2 * star.radius)) }
                case .star:
                    batches.fill(tint: 0, alpha: alpha) {
                        $0.addEllipse(in: CGRect(x: point.x - star.radius, y: point.y - star.radius, width: 2 * star.radius, height: 2 * star.radius))
                    }
                case .bright(let tint):
                    // A glow that fades to nothing; a flat disc reads as a ring drawn around the star.
                    let reach = star.radius * 3.4, color = Self.tints[tint]
                    context.fill(Path(ellipseIn: CGRect(x: point.x - reach, y: point.y - reach, width: 2 * reach, height: 2 * reach)),
                                 with: .radialGradient(
                                    Gradient(stops: [.init(color: Self.rgb(color.0, color.1, color.2, alpha * 0.36), location: 0),
                                                     .init(color: Self.rgb(color.0, color.1, color.2, alpha * 0.10), location: 0.45),
                                                     .init(color: Self.rgb(color.0, color.1, color.2, 0), location: 1)]),
                                    center: point, startRadius: 0, endRadius: reach))
                    batches.fill(tint: tint, alpha: alpha) {
                        $0.addEllipse(in: CGRect(x: point.x - star.radius, y: point.y - star.radius, width: 2 * star.radius, height: 2 * star.radius))
                    }
                }
                continue
            }
            // A trail, bright among the bodies and thinner over the labels: a faint tail and a bright head.
            let band = point.y < calm ? 1 : max(0.22, 1 - Double((point.y - calm) / calmSpan) * 0.78)
            let alpha = glint * band, way = SkyMotion.streak(from: point, vanishing: vanishing)
            let tint: Int = if case .bright(let own) = star.kind { own } else { star.depth > 0.72 ? 3 : 0 }
            let width = star.radius * 1.4
            batches.stroke(tint: tint, alpha: alpha * 0.30, width: width, from: point,
                           to: CGPoint(x: point.x - way.dx * length, y: point.y - way.dy * length))
            batches.stroke(tint: tint, alpha: alpha * 0.95, width: width, from: point,
                           to: CGPoint(x: point.x - way.dx * length * 0.34, y: point.y - way.dy * length * 0.34))
        }
        batches.draw(in: context)
    }
}
