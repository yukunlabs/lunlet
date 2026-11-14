// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.09, AC-19.10; US-24, AC-24.02, AC-24.04.
import LunletCore
import SwiftUI

/// What a header slot stands for.
enum HeaderBody: Hashable {
    case all
    case agent(SessionProvider)
}

/// One body drawn as vector art that fills its square frame. `lit` is the share of the disc that is lit; nil draws
/// the body with no night side (the caller dims and rings an unknown one). `mirrored` flips the art horizontally so
/// the lit side faces a Sun on its right.
///
/// Each body has one fixed look that no skin tints (design notes, Panel header and pages): the Sun for all agents,
/// a blue planet with a dark storm and bright cirrus for Codex and a banded planet with a red spot for Claude Code.
/// The planets are globes with weather placed by latitude and longitude; the Sun is a light, the same on every side,
/// in a corona of uneven streamers. The art is only a picture: it takes no clicks and says nothing to VoiceOver, so
/// the header labels and frames it (AC-24.02).
struct HeaderBodyArt: View {
    /// The art's own coordinate space: a square of 62 units with the body at its center.
    static let box: CGFloat = 62
    /// A planet's disc in that space.
    static let discRadius: CGFloat = 26
    /// The Sun's disc, inside its corona.
    static let sunRadius: CGFloat = 24
    /// How far a glow may reach past the frame, as a share of its side; a parent that clips cuts it there.
    static let bleed: CGFloat = 0.5

    /// The light a body casts on the page under it: its own color, which the page takes on while that body is the
    /// chosen one. The Sun's is the Overview's.
    static func light(of body: HeaderBody) -> Color {
        switch body {
        case .all: Color(.sRGB, red: 1.0, green: 0.68, blue: 0.40, opacity: 1)
        case .agent(.codex): Color(.sRGB, red: 0.32, green: 0.50, blue: 1.0, opacity: 1)
        case .agent(.claude): Color(.sRGB, red: 1.0, green: 0.62, blue: 0.52, opacity: 1)
        }
    }

    private let kind: HeaderBody
    private let lit: Double?
    private let mirrored: Bool

    init(_ kind: HeaderBody, lit: Double?, mirrored: Bool = false) {
        self.kind = kind; self.lit = lit; self.mirrored = mirrored
    }

    var body: some View {
        Color.clear
            .overlay {
                GeometryReader { proxy in
                    let side = min(proxy.size.width, proxy.size.height), margin = side * Self.bleed
                    Canvas { context, _ in
                        HeaderBodyDrawing(kind: kind, lit: lit, mirrored: mirrored, side: side,
                                          origin: CGPoint(x: margin, y: margin)).draw(in: context)
                    }
                    .frame(width: side + 2 * margin, height: side + 2 * margin)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .allowsHitTesting(false)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The drawing itself, for a body whose 62-unit box has `side` points and starts at `origin`.
struct HeaderBodyDrawing {
    let kind: HeaderBody
    let lit: Double?
    let mirrored: Bool
    let side: CGFloat
    let origin: CGPoint

    /// The night side over a planet's surface: dark and translucent, so the surface still reads through it.
    static let night = Color(.sRGB, red: 7 / 255, green: 6 / 255, blue: 20 / 255, opacity: 1)
    static let nightOpacity = 0.72

    private var unit: CGFloat { side / HeaderBodyArt.box }
    /// The Sun is the same from either side.
    private var flips: Bool { mirrored && kind != .all }
    private var center: CGPoint { point(HeaderBodyArt.box / 2, HeaderBodyArt.box / 2) }

    /// The share to draw as lit, or nil when nothing is dark: the Sun, an unknown share, and a full one.
    var litShare: Double? {
        guard kind != .all, let lit else { return nil }
        let share = LitShare.clamped(lit)
        return share < 1 ? share : nil
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + (flips ? HeaderBodyArt.box - x : x) * unit, y: origin.y + y * unit)
    }
    /// From the art's units to the canvas.
    private var placement: CGAffineTransform {
        flips ? CGAffineTransform(a: -unit, b: 0, c: 0, d: unit, tx: origin.x + HeaderBodyArt.box * unit, ty: origin.y)
              : CGAffineTransform(a: unit, b: 0, c: 0, d: unit, tx: origin.x, ty: origin.y)
    }
    private func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)).applying(placement)
    }
    private static func rgb(_ hex: UInt32, _ opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
              blue: Double(hex & 0xff) / 255, opacity: opacity)
    }

    func draw(in context: GraphicsContext) {
        switch kind {
        case .all: drawSun(in: context)
        case .agent(.codex): drawPlanet(.codex, in: context)
        case .agent(.claude): drawPlanet(.claude, in: context)
        }
    }

    // MARK: Planets

    /// A fixed sequence of numbers from 0 up to 1, so that scattered marks are the same drawing every time.
    private struct Scatter {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) & 0xff_ffff) / Double(0x100_0000)
        }
    }

    /// A planet as a globe seen from a little above its equator. Marks are placed by latitude and longitude in
    /// degrees, longitude 0 facing the viewer, so belts bend around the globe and a storm near the limb is seen edge
    /// on. Points are in the art's units.
    private struct Globe {
        /// How far the north pole leans toward the viewer, and how far the axis is turned in the picture, in degrees.
        let lean: Double
        let tilt: Double
        private var mid: Double { Double(HeaderBodyArt.box / 2) }
        private var radius: Double { Double(HeaderBodyArt.discRadius) }

        func point(_ latitude: Double, _ longitude: Double) -> CGPoint {
            let t = latitude * .pi / 180, l = longitude * .pi / 180, phi = lean * .pi / 180, turn = tilt * .pi / 180
            let x = cos(t) * sin(l) * radius
            let y = -(sin(t) * cos(phi) - cos(t) * cos(l) * sin(phi)) * radius
            return CGPoint(x: mid + x * cos(turn) - y * sin(turn), y: mid + x * sin(turn) + y * cos(turn))
        }
        /// The longitude at which a latitude meets the limb.
        private func reach(_ latitude: Double) -> Double {
            acos(max(-1, min(1, -tan(latitude * .pi / 180) * tan(lean * .pi / 180)))) * 180 / .pi
        }
        /// A latitude from limb to limb, wandering by up to `wave` degrees along the way and not at all at the limb,
        /// where it is seen end on.
        func edge(_ latitude: Double, wave: Double, phase: Double) -> [CGPoint] {
            let limit = reach(latitude), steps = 40
            return (0...steps).map { step in
                let part = Double(step) / Double(steps) * 2 - 1, l = part * limit * .pi / 180
                let wander = sin(5 * l + phase) + 0.55 * sin(11 * l + 1.9 * phase) + 0.3 * sin(23 * l + 0.7 * phase)
                return point(latitude + wave * wander * cos(part * .pi / 2), part * limit)
            }
        }
        /// A belt between two latitudes with wandering edges; one that starts at a pole covers the cap.
        func belt(north: Double, south: Double, wave: Double, phase: Double) -> Path {
            let turn = tilt * .pi / 180, far = 3 * radius
            let up = CGPoint(x: sin(turn) * far, y: -cos(turn) * far)
            var points: [CGPoint]
            if north >= 90 {
                points = edge(south, wave: wave, phase: phase)
                points += [points[points.count - 1], points[0]].map { CGPoint(x: $0.x + up.x, y: $0.y + up.y) }
            } else if south <= -90 {
                points = edge(north, wave: wave, phase: phase)
                points += [points[points.count - 1], points[0]].map { CGPoint(x: $0.x - up.x, y: $0.y - up.y) }
            } else {
                points = edge(north, wave: wave, phase: phase) + edge(south, wave: wave, phase: phase + 2.4).reversed()
            }
            var path = Path()
            path.addLines(points); path.closeSubpath()
            return path
        }
        /// A thin line of cloud along a latitude.
        func line(_ latitude: Double, wave: Double, phase: Double) -> Path {
            var path = Path()
            path.addLines(edge(latitude, wave: wave, phase: phase))
            return path
        }
        /// A streak of cloud along a latitude between two longitudes, thickest in the middle and `thickness` degrees
        /// to either side there; `rise` carries it that many degrees of latitude from one end to the other.
        func streak(_ latitude: Double, from: Double, to: Double, thickness: Double, rise: Double = 0) -> Path {
            let steps = 16
            func side(_ sign: Double) -> [CGPoint] {
                (0...steps).map { step in
                    let part = Double(step) / Double(steps)
                    return point(latitude + rise * part + sign * thickness * sin(.pi * part), from + (to - from) * part)
                }
            }
            var path = Path()
            path.addLines(side(1) + side(-1).reversed()); path.closeSubpath()
            return path
        }
        /// An oval storm, `tall` degrees of latitude by `wide` degrees along its own latitude.
        func oval(_ latitude: Double, _ longitude: Double, tall: Double, wide: Double) -> Path {
            let steps = 32, stretch = max(0.3, cos(latitude * .pi / 180))
            var path = Path()
            path.addLines((0..<steps).map { step in
                let angle = 2 * Double.pi * Double(step) / Double(steps)
                return point(latitude + tall / 2 * sin(angle), longitude + wide / 2 * cos(angle) / stretch)
            })
            path.closeSubpath()
            return path
        }
    }

    private struct Look {
        /// Highlight, body and shadowed tone of the globe.
        let globe: (UInt32, UInt32, UInt32)
        let halo: Color
        /// The haze along the lit limb.
        let rim: UInt32
        let shape: Globe
        /// Belts from north to south: their edges' latitudes, color, opacity and how far the edges wander.
        let belts: [(north: Double, south: Double, color: UInt32, opacity: Double, wave: Double)]
        /// Thin lines of cloud: latitude, color, opacity and width in the art's units.
        let lines: [(latitude: Double, color: UInt32, opacity: Double, width: CGFloat)]

        /// A deep blue ice giant: faint belts, a brighter cap in the south.
        static let codex = Look(
            globe: (0xd4e2ff, 0x4a78ee, 0x182a96), halo: Color(.sRGB, red: 90 / 255, green: 130 / 255, blue: 1, opacity: 0.55),
            rim: 0xa9d6ff, shape: Globe(lean: 10, tilt: -10),
            belts: [(90, 64, 0x1a2c96, 0.36, 0.8), (50, 36, 0x2040bc, 0.28, 1.2), (22, 8, 0xa6c8ff, 0.17, 1.0),
                    (-8, -31, 0x13268a, 0.34, 1.5), (-44, -56, 0x1a3298, 0.28, 1.0), (-68, -90, 0x86aeff, 0.22, 0.8)],
            lines: [(58, 0x0f1e78, 0.22, 0.5), (31, 0xffffff, 0.14, 0.45), (15, 0xdcebff, 0.14, 0.4), (2, 0xffffff, 0.12, 0.4),
                    (-14, 0x0c1a70, 0.2, 0.45), (-37, 0xc4dcff, 0.16, 0.45), (-50, 0x0f1e78, 0.2, 0.45), (-62, 0xffffff, 0.12, 0.45)])
        /// A banded gas giant: dark polar regions, two broad rust belts either side of a bright equator.
        static let claude = Look(
            globe: (0xfff3e0, 0xe8c49c, 0xa06c44), halo: Color(.sRGB, red: 235 / 255, green: 190 / 255, blue: 140 / 255, opacity: 0.45),
            rim: 0xfff1da, shape: Globe(lean: 14, tilt: -6),
            belts: [(90, 60, 0x8c725f, 0.52, 1.2), (50, 43, 0xa87048, 0.55, 1.0), (24, 8, 0xa55f36, 0.80, 1.7),
                    (6, -5, 0xfff7ea, 0.42, 0.8), (-8, -22, 0xad6a42, 0.74, 1.7), (-33, -39, 0xb58059, 0.55, 1.0),
                    (-48, -54, 0xa77d60, 0.42, 1.0), (-62, -90, 0x8a7361, 0.54, 1.2)],
            lines: [(55, 0xfff6e8, 0.26, 0.45), (34, 0xc39a74, 0.36, 0.45), (20, 0x7a4324, 0.40, 0.45), (13, 0x8a4f2c, 0.32, 0.4),
                    (0.5, 0xd2aa80, 0.40, 0.4), (-12, 0x7a4324, 0.36, 0.45), (-16.5, 0xe3bd98, 0.34, 0.5), (-27, 0xe6caa8, 0.32, 0.45),
                    (-44, 0xfff6e8, 0.28, 0.45), (-58, 0x7d6652, 0.3, 0.45)])
    }

    private func drawPlanet(_ provider: SessionProvider, in context: GraphicsContext) {
        let look = provider == .codex ? Look.codex : Look.claude
        let mid = HeaderBodyArt.box / 2, radius = HeaderBodyArt.discRadius
        let disc = circle(mid, mid, radius), globe = look.shape, placement = placement

        // A soft halo in the body's own tone lifts it off the sky: the falloff of a blurred disc edge.
        let reach: CGFloat = 12
        let falloff: [(CGFloat, Double)] = [(0, 0.5), (2, 0.31), (4, 0.16), (6, 0.067), (8, 0.023), (reach, 0)]
        let outer = radius + reach
        var haloStops = [Gradient.Stop(color: look.halo.opacity(0), location: 0),
                         Gradient.Stop(color: look.halo.opacity(0), location: (radius - 1) / outer)]
        haloStops += falloff.map { Gradient.Stop(color: look.halo.opacity($0.1), location: (radius + $0.0) / outer) }
        context.fill(circle(mid, mid, outer), with: .radialGradient(Gradient(stops: haloStops), center: center,
                                                                     startRadius: 0, endRadius: outer * unit))

        var inner = context
        inner.clip(to: disc)
        // The globe, lit from the upper leading side.
        inner.fill(disc, with: .radialGradient(
            Gradient(stops: [.init(color: Self.rgb(look.globe.0), location: 0), .init(color: Self.rgb(look.globe.1), location: 0.5),
                             .init(color: Self.rgb(look.globe.2), location: 1)]),
            center: point(20.6, 22.68), startRadius: 0, endRadius: 49.4 * unit))
        /// One layer of cloud, drawn soft. Nothing on a disc is a sharp mark, and no two marks are a pair: two
        /// bright strokes or two dark dots on a round body read as a face.
        func soft(_ blur: CGFloat, _ draw: (inout GraphicsContext, (Path, UInt32, Double) -> Void) -> Void) {
            var layer = inner
            layer.drawLayer { cloud in
                cloud.addFilter(.blur(radius: blur * unit))
                var marks: [(Path, UInt32, Double)] = []
                draw(&cloud) { marks.append(($0, $1, $2)) }
                for mark in marks { cloud.fill(mark.0.applying(placement), with: .color(Self.rgb(mark.1, mark.2))) }
            }
        }
        soft(0.45) { _, fill in
            for (index, belt) in look.belts.enumerated() {
                fill(globe.belt(north: belt.north, south: belt.south, wave: belt.wave, phase: Double(index) * 1.7), belt.color, belt.opacity)
            }
        }
        var lines = inner
        lines.drawLayer { layer in
            layer.addFilter(.blur(radius: 0.22 * unit))
            for (index, line) in look.lines.enumerated() {
                layer.stroke(globe.line(line.latitude, wave: 0.7, phase: Double(index) * 2.3).applying(placement),
                             with: .color(Self.rgb(line.color, line.opacity)), lineWidth: line.width * unit)
            }
        }
        switch provider {
        case .codex:
            // The dark storm in the southern belt and a smaller one far south.
            soft(0.7) { _, fill in
                fill(globe.oval(-21, -16, tall: 13, wide: 24), 0x0d1860, 0.6)
                fill(globe.oval(-21, -16, tall: 7, wide: 14), 0x080f42, 0.35)
                fill(globe.oval(-54, 30, tall: 6, wide: 10), 0x0d1860, 0.45)
            }
            // Bright cirrus: the storm's companion along its southern rim, streaks high over the north, and a small
            // quick cloud between the storms.
            soft(0.3) { _, fill in
                // Faint wisps and thin shadows all over, each one its own length.
                var scatter = Scatter(state: 0x4e97_0b15)
                for _ in 0..<16 {
                    let latitude = -62 + 124 * scatter.next(), from = -72 + 120 * scatter.next(), length = 10 + 22 * scatter.next()
                    let bright = scatter.next() < 0.6
                    fill(globe.streak(latitude, from: from, to: from + length, thickness: 0.4 + 0.5 * scatter.next(),
                                      rise: (scatter.next() - 0.5) * 1.6), bright ? 0xffffff : 0x0c1a70, 0.09 + 0.1 * scatter.next())
                }
                fill(globe.streak(-29.5, from: -33, to: -3, thickness: 1.5), 0xffffff, 0.8)
                fill(globe.streak(-32.5, from: -20, to: 4, thickness: 0.9), 0xffffff, 0.5)
                fill(globe.streak(27, from: 0, to: 42, thickness: 1.3), 0xffffff, 0.62)
                fill(globe.streak(30.5, from: 16, to: 50, thickness: 0.8), 0xffffff, 0.42)
                fill(globe.streak(23.5, from: -34, to: -10, thickness: 0.9), 0xffffff, 0.4)
                fill(globe.streak(8, from: -55, to: -28, thickness: 0.7), 0xffffff, 0.28)
                fill(globe.streak(-3, from: 20, to: 48, thickness: 0.7), 0xffffff, 0.26)
                fill(globe.oval(-42, 14, tall: 2.6, wide: 6), 0xffffff, 0.72)
                fill(globe.oval(-54, 30, tall: 1.8, wide: 3.6), 0xffffff, 0.55)
            }
        case .claude:
            soft(0.3) { _, fill in
                // Turbulence inside the two broad belts: short streaks, darker and paler by turns.
                var scatter = Scatter(state: 0x7b2a_91c3)
                for index in 0..<20 {
                    let latitude = index % 2 == 0 ? 10 + 12 * scatter.next() : -10 - 10 * scatter.next()
                    let from = -74 + 128 * scatter.next(), length = 8 + 16 * scatter.next()
                    let dark = scatter.next() < 0.55
                    fill(globe.streak(latitude, from: from, to: from + length, thickness: 0.45 + 0.5 * scatter.next(),
                                      rise: (scatter.next() - 0.5) * 2.4), dark ? 0x7a4324 : 0xe2b78f, 0.2 + 0.14 * scatter.next())
                }
                // Festoons: blue-gray wisps trailing from the north belt into the bright zone at the equator.
                fill(globe.streak(7, from: -58, to: -40, thickness: 0.7, rise: -5.5), 0x6a7da6, 0.3)
                fill(globe.streak(7.5, from: -21, to: -9, thickness: 0.6, rise: -4.5), 0x6a7da6, 0.24)
                fill(globe.streak(6.5, from: 12, to: 34, thickness: 0.8, rise: -6.5), 0x6a7da6, 0.3)
                // A wake of pale cloud beside the spot, inside the south belt.
                fill(globe.streak(-11.5, from: -24, to: 6, thickness: 0.8), 0xf3dcc0, 0.42)
                fill(globe.streak(-15, from: -36, to: 0, thickness: 0.8), 0xf3dcc0, 0.4)
                fill(globe.streak(-18.5, from: -20, to: 8, thickness: 0.8), 0xf3dcc0, 0.42)
                // White ovals along the south temperate belt, no two alike.
                fill(globe.oval(-43, -46, tall: 3.8, wide: 5.6), 0xfffaf2, 0.72)
                fill(globe.oval(-44.5, -24, tall: 2.6, wide: 3.8), 0xfffaf2, 0.6)
                fill(globe.oval(-42.5, 13, tall: 3.2, wide: 4.8), 0xfffaf2, 0.66)
            }
            // The red spot rides the south belt's edge, in a hollow of pale cloud.
            soft(0.35) { _, fill in
                fill(globe.oval(-22, 27, tall: 16, wide: 27), 0xfdebd2, 0.72)
                fill(globe.oval(-22, 27, tall: 13, wide: 23), 0x9b3a20, 0.8)
                fill(globe.oval(-22, 27, tall: 11, wide: 20), 0xcf5a36, 0.95)
                fill(globe.oval(-21.4, 26, tall: 6, wide: 12), 0xee9a72, 0.6)
                fill(globe.oval(-21.2, 25.4, tall: 2.4, wide: 5), 0xf8c4a2, 0.5)
            }
        }
        // The limb darkens, a highlight sits where the light falls, and haze brightens the lit limb.
        inner.fill(disc, with: .radialGradient(
            Gradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0), location: 0.66),
                             .init(color: .black.opacity(0.42), location: 1)]),
            center: center, startRadius: 0, endRadius: radius * unit))
        inner.fill(disc, with: .radialGradient(
            Gradient(colors: [.white.opacity(0.3), .white.opacity(0)]),
            center: point(16.44, 22.68), startRadius: 0, endRadius: radius * unit))
        inner.fill(disc, with: .radialGradient(
            Gradient(stops: [.init(color: Self.rgb(look.rim, 0), location: 0.84), .init(color: Self.rgb(look.rim, 0.3), location: 0.95),
                             .init(color: Self.rgb(look.rim, 0.5), location: 1)]),
            center: point(mid + 3.4, mid + 2.6), startRadius: 0, endRadius: radius * unit))

        if let share = litShare {
            // The night keeps the exact share (AC-19.10); a band past the dark limb keeps its soft edge from
            // thinning the night at the rim, where the disc clips it.
            let night = LitShare.nightPath(center: center, radius: radius * unit, fraction: share, mirrored: flips)
            let rim = LitShare.nightPath(center: center, radius: (radius + 4) * unit, fraction: 0.5, mirrored: flips)
                .subtracting(Path(ellipseIn: CGRect(x: center.x - (radius - 0.5) * unit, y: center.y - (radius - 0.5) * unit,
                                                    width: 2 * (radius - 0.5) * unit, height: 2 * (radius - 0.5) * unit)))
            var shade = inner
            shade.opacity = Self.nightOpacity
            shade.drawLayer { layer in
                layer.addFilter(.blur(radius: 0.9 * unit))
                layer.fill(night, with: .color(Self.night))
                layer.fill(rim, with: .color(Self.night))
            }
        }
        context.stroke(disc, with: .color(.white.opacity(0.09)), lineWidth: 0.8 * unit)
    }

    // MARK: The Sun

    private func drawSun(in context: GraphicsContext) {
        let mid = HeaderBodyArt.box / 2, radius = HeaderBodyArt.sunRadius, placement = placement
        func polar(_ distance: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: mid + distance * CGFloat(cos(angle)), y: mid + distance * CGFloat(sin(angle)))
        }
        /// Light that fades with distance from the center along a profile of distances and opacities.
        func glow(_ target: GraphicsContext, _ color: UInt32, _ profile: [(CGFloat, Double)]) {
            let outer = profile[profile.count - 1].0
            target.fill(circle(mid, mid, outer), with: .radialGradient(
                Gradient(stops: profile.map { .init(color: Self.rgb(color, $0.1), location: $0.0 / outer) }),
                center: center, startRadius: 0, endRadius: outer * unit))
        }
        // The light it throws on the sky: a wide warm haze.
        glow(context, 0xff7a1c, [(0, 0.42), (20, 0.40), (26, 0.31), (33, 0.2), (41, 0.11), (50, 0.045), (60, 0)])
        // The corona: streamers standing out from the limb all the way around, long, short and middling by turns
        // and each a little off its place, so no side is the bright one.
        var light = context
        light.blendMode = .plusLighter
        func ray(_ layer: inout GraphicsContext, angle: Double, length: CGFloat, half: Double, color: UInt32, strength: Double) {
            let base = radius - 1.2, tip = radius + length
            var petal = Path()
            petal.move(to: polar(base, angle - half))
            petal.addQuadCurve(to: polar(tip, angle), control: polar(base + length * 0.45, angle - half * 0.35))
            petal.addQuadCurve(to: polar(base, angle + half), control: polar(base + length * 0.45, angle + half * 0.35))
            petal.closeSubpath()
            layer.fill(petal.applying(placement), with: .radialGradient(
                Gradient(stops: [.init(color: Self.rgb(color, strength), location: 0), .init(color: Self.rgb(color, strength * 0.5), location: 0.4),
                                 .init(color: Self.rgb(color, 0), location: 1)]),
                center: center, startRadius: radius * unit, endRadius: tip * unit))
        }
        light.drawLayer { layer in
            layer.addFilter(.blur(radius: 1.0 * unit))
            var scatter = Scatter(state: 0x5eed_50a2)
            // An odd number of long ones, so that no two stand across from each other as a drawn star's would.
            let count = 25
            for index in 0..<count {
                let angle = (Double(index) / Double(count) * 360 + (scatter.next() - 0.5) * 9) * .pi / 180
                let rank = index % 5, spread = scatter.next()
                let length = CGFloat(rank == 0 ? 17 + 8 * spread : rank == 2 ? 10 + 5 * spread : 5 + 3.5 * spread)
                ray(&layer, angle: angle, length: length, half: ((rank == 0 ? 3.2 : 2.6) + 1.6 * scatter.next()) * .pi / 180,
                    color: 0xffc468, strength: (rank == 0 ? 0.5 : 0.42) + 0.14 * scatter.next())
            }
        }
        // A fringe of fine spicules, which makes the limb burn rather than end.
        light.drawLayer { layer in
            layer.addFilter(.blur(radius: 0.35 * unit))
            var scatter = Scatter(state: 0xf1a3_e001)
            let count = 80
            for index in 0..<count {
                let angle = (Double(index) / Double(count) * 360 + (scatter.next() - 0.5) * 3) * .pi / 180
                ray(&layer, angle: angle, length: CGFloat(1.6 + 2.8 * scatter.next()), half: 1.5 * .pi / 180,
                    color: 0xffd98a, strength: 0.4 + 0.3 * scatter.next())
            }
        }
        // The hot light at the limb itself.
        glow(context, 0xffc45a, [(0, 0.9), (23, 0.86), (26, 0.56), (29, 0.31), (33, 0.13), (38, 0.04), (43, 0)])
        // Prominences: loops of fire standing off the limb.
        var loops = context
        loops.drawLayer { layer in
            layer.addFilter(.blur(radius: 0.3 * unit))
            for (degrees, width, height) in [(38.0, 13.0, 3.6), (151, 10, 2.6), (262, 15, 4.2), (318, 8, 2.2)] as [(Double, Double, CGFloat)] {
                let from = (degrees - width / 2) * .pi / 180, to = (degrees + width / 2) * .pi / 180
                var loop = Path()
                loop.move(to: polar(radius - 0.6, from))
                loop.addQuadCurve(to: polar(radius - 0.6, to), control: polar(radius + 2 * height, degrees * .pi / 180))
                layer.fill(loop.applying(placement), with: .color(Self.rgb(0xff7a2a, 0.3)))
                layer.stroke(loop.applying(placement), with: .color(Self.rgb(0xff9440, 0.9)), lineWidth: 0.8 * unit)
            }
        }

        // The disc: the same on every side, white-hot at the core and deeper toward the limb, with a feathered edge.
        let feather: CGFloat = 1.1, edge = radius / (radius + feather)
        context.fill(circle(mid, mid, radius + feather), with: .radialGradient(
            Gradient(stops: [.init(color: Self.rgb(0xfffdf2), location: 0), .init(color: Self.rgb(0xfff6cc), location: 0.3 * edge),
                             .init(color: Self.rgb(0xffe07a), location: 0.56 * edge), .init(color: Self.rgb(0xffc54d), location: 0.78 * edge),
                             .init(color: Self.rgb(0xffa32a), location: 0.92 * edge), .init(color: Self.rgb(0xff8a1c), location: edge),
                             .init(color: Self.rgb(0xff8a1c, 0), location: 1)]),
            center: center, startRadius: 0, endRadius: (radius + feather) * unit))
        var inner = context
        inner.clip(to: circle(mid, mid, radius))
        // The surface seethes: broad cells of slower fire, then fine grains, brighter and deeper by turns, thinning
        // toward the core, which is too bright to show them.
        inner.drawLayer { layer in
            layer.addFilter(.blur(radius: 1.6 * unit))
            var scatter = Scatter(state: 0xce11_5eed)
            // Spread evenly around the disc, so that no side gathers the deeper ones and looks shaded.
            let count = 20
            for index in 0..<count {
                let distance = radius * CGFloat(0.4 + 0.52 * scatter.next())
                let angle = (Double(index) + scatter.next() * 0.8) / Double(count) * 2 * .pi
                let at = polar(distance, angle), size = CGFloat(3 + 3.5 * scatter.next())
                layer.fill(Path(ellipseIn: CGRect(x: at.x - size, y: at.y - size * 0.7, width: 2 * size, height: 1.4 * size)).applying(placement),
                           with: .color(index % 2 == 0 ? Self.rgb(0xfff4c2, 0.16) : Self.rgb(0xf58a1e, 0.1)))
            }
        }
        inner.drawLayer { layer in
            layer.addFilter(.blur(radius: 0.3 * unit))
            var scatter = Scatter(state: 0x6a17_2026)
            for _ in 0..<170 {
                let distance = radius * CGFloat(0.34 + 0.64 * scatter.next().squareRoot()), angle = scatter.next() * 2 * .pi
                let at = polar(distance, angle), size = CGFloat(0.45 + 0.6 * scatter.next())
                let bright = scatter.next() < 0.5, strength = 0.07 + 0.09 * scatter.next()
                layer.fill(Path(ellipseIn: CGRect(x: at.x - size, y: at.y - size, width: 2 * size, height: 2 * size)).applying(placement),
                           with: .color(bright ? Self.rgb(0xfffbe0, strength) : Self.rgb(0xe8730f, strength)))
            }
        }
        // The limb blooms: light spills over the disc's edge, which a lit ball's never does.
        var bloom = context
        bloom.blendMode = .plusLighter
        glow(bloom, 0xffe6a0, [(0, 0), (radius * 0.7, 0), (radius * 0.96, 0.3), (radius + 1.4, 0.3), (radius + 5, 0.12), (radius + 10, 0)])
    }
}
