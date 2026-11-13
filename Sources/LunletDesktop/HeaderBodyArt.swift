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
/// a blue planet with a dark storm for Codex and a banded planet with a red spot for Claude Code. The art is only a
/// picture: it takes no clicks and says nothing to VoiceOver, so the header labels and frames it (AC-24.02).
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
    /// An ellipse turned by `degrees` about `pivot`, or about its own center.
    private func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, degrees: Double = 0, pivot: CGPoint? = nil) -> Path {
        let pivot = pivot ?? CGPoint(x: x, y: y)
        let turn = CGAffineTransform(translationX: pivot.x, y: pivot.y).rotated(by: degrees * .pi / 180)
            .translatedBy(x: -pivot.x, y: -pivot.y)
        return Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry)).applying(turn).applying(placement)
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

    private struct Look {
        /// Highlight, body and shadowed tone of the globe.
        let globe: (UInt32, UInt32, UInt32)
        let halo: Color
        /// Cloud bands across the disc: the tilt in degrees, then each band's height on the disc, half-thickness,
        /// color and opacity.
        let tilt: Double
        let bands: [(y: CGFloat, thickness: CGFloat, color: UInt32, opacity: Double)]

        static let codex = Look(globe: (0xd4e2ff, 0x4a78ee, 0x182a96),
                                halo: Color(.sRGB, red: 90 / 255, green: 130 / 255, blue: 1, opacity: 0.55), tilt: -10,
                                bands: [(20, 4, 0xffffff, 0.12), (31, 5, 0x14237a, 0.26), (44, 4, 0x14237a, 0.22)])
        static let claude = Look(globe: (0xfff3e0, 0xe8c49c, 0xa06c44),
                                 halo: Color(.sRGB, red: 235 / 255, green: 190 / 255, blue: 140 / 255, opacity: 0.45), tilt: -6,
                                 bands: [(12, 3.2, 0x9a5a34, 0.42), (19, 2.6, 0xfff8ee, 0.45), (25, 3.6, 0xa8623a, 0.50),
                                         (32, 3.0, 0xfff8ee, 0.40), (39, 4.2, 0x96552f, 0.50), (46, 2.8, 0xfff8ee, 0.30),
                                         (52, 3.4, 0x8a4a28, 0.42)])
    }

    private func drawPlanet(_ provider: SessionProvider, in context: GraphicsContext) {
        let look = provider == .codex ? Look.codex : Look.claude
        let mid = HeaderBodyArt.box / 2, radius = HeaderBodyArt.discRadius
        let disc = circle(mid, mid, radius)

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
        let pivot = CGPoint(x: mid, y: mid)
        // Belts and weather are drawn soft, as cloud is. Nothing on a disc is a sharp mark: two bright strokes or two
        // dark dots on a round body read as a face.
        var belts = inner
        belts.drawLayer { layer in
            layer.addFilter(.blur(radius: 0.75 * unit))
            for band in look.bands {
                layer.fill(ellipse(mid, band.y, 32, band.thickness, degrees: look.tilt, pivot: pivot),
                           with: .color(Self.rgb(band.color, band.opacity)))
            }
        }
        var weather = inner
        weather.drawLayer { layer in
            switch provider {
            case .codex:
                // One dark storm and two thin veils of high cloud along the belts.
                layer.addFilter(.blur(radius: 0.9 * unit))
                layer.fill(ellipse(25, 35, 5.4, 2.9, degrees: look.tilt, pivot: pivot), with: .color(Self.rgb(0x101c66, 0.5)))
                layer.fill(ellipse(37, 25, 10, 1.1, degrees: look.tilt, pivot: pivot), with: .color(.white.opacity(0.36)))
                layer.fill(ellipse(21, 46, 7, 0.9, degrees: look.tilt, pivot: pivot), with: .color(.white.opacity(0.24)))
            case .claude:
                // The red spot rides one of the belts.
                layer.addFilter(.blur(radius: 0.5 * unit))
                layer.fill(ellipse(41, 39.5, 5.2, 3.0, degrees: look.tilt, pivot: pivot), with: .color(Self.rgb(0xc9553a, 0.86)))
                layer.fill(ellipse(41, 39.5, 2.8, 1.4, degrees: look.tilt, pivot: pivot), with: .color(Self.rgb(0xf0936c, 0.6)))
            }
        }
        // The limb darkens and a highlight sits where the light falls.
        inner.fill(disc, with: .radialGradient(
            Gradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0), location: 0.66),
                             .init(color: .black.opacity(0.42), location: 1)]),
            center: center, startRadius: 0, endRadius: radius * unit))
        inner.fill(disc, with: .radialGradient(
            Gradient(colors: [.white.opacity(0.36), .white.opacity(0)]),
            center: point(16.44, 22.68), startRadius: 0, endRadius: radius * unit))

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
        let mid = HeaderBodyArt.box / 2, radius = HeaderBodyArt.sunRadius
        // Two glows, a wide one and a tight one, then the corona that the disc sits in.
        let wide = Self.rgb(0xff781e), tight = Self.rgb(0xffb040)
        func glow(_ color: Color, _ profile: [(CGFloat, Double)]) {
            let outer = profile[profile.count - 1].0
            context.fill(circle(mid, mid, outer), with: .radialGradient(
                Gradient(stops: profile.map { .init(color: color.opacity($0.1), location: $0.0 / outer) }),
                center: center, startRadius: 0, endRadius: outer * unit))
        }
        glow(wide, [(0, 0.45), (18, 0.43), (24, 0.33), (31, 0.21), (38, 0.11), (46, 0.04), (56, 0)])
        glow(tight, [(0, 0.85), (22, 0.80), (25, 0.55), (28, 0.30), (32, 0.12), (37, 0.03), (42, 0)])
        context.fill(circle(mid, mid, 31), with: .radialGradient(
            Gradient(stops: [.init(color: Self.rgb(0xffb347, 0.55), location: 0), .init(color: Self.rgb(0xffb347, 0.55), location: 0.70),
                             .init(color: Self.rgb(0xff8a1e, 0), location: 1)]),
            center: center, startRadius: 0, endRadius: 31 * unit))

        let disc = circle(mid, mid, radius)
        context.fill(disc, with: .radialGradient(
            Gradient(stops: [.init(color: Self.rgb(0xfffdf0), location: 0), .init(color: Self.rgb(0xffe27a), location: 0.32),
                             .init(color: Self.rgb(0xff9f2e), location: 0.72), .init(color: Self.rgb(0xe2571a), location: 1)]),
            center: point(27.16, 26.2), startRadius: 0, endRadius: 34.56 * unit))
        var inner = context
        inner.clip(to: disc)
        // Brighter cells on the surface, soft, and no spots: two dark dots on a bright disc read as a face.
        var cells = Path()
        cells.addPath(ellipse(22, 24, 6, 3.5, degrees: -20)); cells.addPath(ellipse(38, 38, 7, 3, degrees: 25))
        cells.addPath(ellipse(36, 19, 4, 2)); cells.addPath(ellipse(20, 41, 4.5, 2.2, degrees: 15))
        inner.drawLayer { layer in
            layer.addFilter(.blur(radius: 1.8 * unit))
            layer.fill(cells, with: .color(Self.rgb(0xfff6c9, 0.36)))
        }
    }
}
