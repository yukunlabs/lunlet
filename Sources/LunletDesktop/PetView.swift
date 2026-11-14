// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-39, AC-39.02, AC-39.03, AC-39.04, AC-39.06, AC-39.07, AC-39.08; US-24, AC-24.02.
// Refs: US-40, AC-40.03, AC-40.05, AC-40.06.
import AppKit
import LunletCore
import SwiftUI

/// The dog's colors: a coat's four tones, the skin's accent for the collar, and fixed lantern and bubble tones.
struct PetPalette: Equatable {
    let coat: Color, ear: Color, muzzle: Color, dark: Color, collar: Color
    static let lanternOn = Color(red: 0xF5 / 255, green: 0xA3 / 255, blue: 0x3B / 255)
    static let lanternGlow = Color(red: 0xFF / 255, green: 0xB3 / 255, blue: 0x41 / 255)
    static let lanternOff = Color(red: 0x9A / 255, green: 0x9A / 255, blue: 0x9E / 255)
    static let blush = Color(red: 0xF2 / 255, green: 0x8B / 255, blue: 0x9B / 255)
    static let check = Color(red: 0x2E / 255, green: 0x9E / 255, blue: 0x5B / 255)
    /// The ink of bubbles and sleep marks over a pack, the dog's dark tone.
    static let ink = Color(red: 0x2B / 255, green: 0x26 / 255, blue: 0x22 / 255)

    static func make(coat: PetCoat, accent: AllowanceColor) -> PetPalette {
        func color(_ hex: Int) -> Color { AllowanceColor(hex: hex).color }
        let collar = accent.color
        switch coat {
        case .golden: return .init(coat: color(0xE9B86B), ear: color(0xCF9448), muzzle: color(0xFAEBD0), dark: color(0x2B2622), collar: collar)
        case .cream: return .init(coat: color(0xF3EADB), ear: color(0xD8C2A3), muzzle: color(0xFFFBF5), dark: color(0x2B2622), collar: collar)
        case .slate: return .init(coat: color(0x5E6773), ear: color(0x434B55), muzzle: color(0xC4CBD3), dark: color(0x15181C), collar: collar)
        }
    }
}

/// The dog as flat vector shapes in a 220 × 190 design space, scaled to any size (AC-39.06). Poses are the six
/// states, interpolated when they change; blinks, gaze, ear flicks and the loops of each pose take their phase
/// from the time the view passes, and everything stands still when it passes none.
enum PetDrawing {
    static let designSize = CGSize(width: 220, height: 190)

    static func transform(for size: CGSize) -> CGAffineTransform {
        let scale = min(size.width / designSize.width, size.height / designSize.height)
        let dx = (size.width - designSize.width * scale) / 2, dy = (size.height - designSize.height * scale) / 2
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
    }

    /// The seated amount of a pose: 1 sitting, 0 lying.
    static func sitting(_ pose: PetPose) -> Double { pose == .asleep || pose == .idle ? 0 : 1 }
    /// How far the head hangs below its seated place: the Failed dog lowers it (AC-39.06).
    static func headDrop(_ pose: PetPose) -> Double { pose == .failed ? 10 : 0 }
    /// The head center in design space for a seated amount and a drop.
    static func head(sit: Double, drop: Double = 0) -> CGPoint { CGPoint(x: 104 + 6 * sit, y: 108 - 28 * sit + drop) }
    /// The head's position in a view of `size`, for the gaze toward a point outside the window.
    static func headCenter(pose: PetPose, in size: CGSize) -> CGPoint {
        head(sit: sitting(pose), drop: headDrop(pose)).applying(transform(for: size))
    }

    /// Where a pointer counts as being on the dog: head, ears, body, paws and the bubble while it shows (AC-39.02).
    static func silhouette(pose: PetPose, bubbleShown: Bool = true) -> Path {
        var path = Path()
        let h = head(sit: sitting(pose), drop: headDrop(pose))
        path.addEllipse(in: CGRect(x: h.x - 40, y: h.y - 40, width: 80, height: 80))
        path.addRect(CGRect(x: h.x - 52, y: h.y - 24, width: 104, height: 64))
        if sitting(pose) > 0.5 {
            path.addEllipse(in: CGRect(x: 62, y: 92, width: 96, height: 80))
            path.addRect(CGRect(x: 82, y: 136, width: 56, height: 44))
            path.addRect(CGRect(x: 150, y: 76, width: 36, height: 50))
        } else {
            path.addEllipse(in: CGRect(x: 54, y: 116, width: 124, height: 60))
            path.addRect(CGRect(x: 72, y: 156, width: 80, height: 20))
        }
        if pose.bubble != nil, bubbleShown { path.addRect(CGRect(x: h.x + 26, y: h.y - 82, width: 48, height: 46)) }
        return path
    }

    private static func mix(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a + (b - a) * CGFloat(p) }
    private static func mix(_ a: CGRect, _ b: CGRect, _ p: Double) -> CGRect {
        CGRect(x: mix(a.minX, b.minX, p), y: mix(a.minY, b.minY, p), width: mix(a.width, b.width, p), height: mix(a.height, b.height, p))
    }
    private static func mix(_ a: CGPoint, _ b: CGPoint, _ p: Double) -> CGPoint { CGPoint(x: mix(a.x, b.x, p), y: mix(a.y, b.y, p)) }

    // swiftlint:disable:next function_body_length
    static func draw(in context: inout GraphicsContext, size: CGSize, state: PetState, palette: PetPalette,
                     input: PetMotionInput, time: TimeInterval?) {
        var c = context
        c.concatenate(transform(for: size))
        let pose = input.pose, live = time != nil, t = time ?? input.poseChangedAt + PetMotion.transitionDuration
        let wave = { (period: Double, phase: Double) -> Double in live ? sin(2 * .pi * t / period + phase) : 0 }
        // The posture blends from the previous pose over the transition (AC-39.03).
        let progress = PetMotion.transition(at: t, since: input.poseChangedAt)
        let sit = mix(CGFloat(sitting(input.previousPose ?? pose)), CGFloat(sitting(pose)), progress)
        let drop = mix(CGFloat(headDrop(input.previousPose ?? pose)), CGFloat(headDrop(pose)), progress)
        let h = head(sit: Double(sit), drop: Double(drop))
        let settledPose: PetPose = progress < 0.5 ? (input.previousPose ?? pose) : pose
        // Loops: a hop while Done, a head bob while Working, breathing always, a bounce after a click.
        let hop: CGFloat = pose == .done && live ? CGFloat(-14 * max(0, sin(2 * .pi * t / 1.1))) : 0
        let bob: CGFloat = pose == .working ? CGFloat(-1.5 * (1 + wave(1.6, 0))) : 0
        let breathe = 1 + CGFloat((0.012 + 0.018 * Double(1 - sit)) * (0.5 + 0.5 * wave(3.2, 0)))
        let bounce = live ? PetMotion.impulse(at: t, since: input.impulseAt) : 0
        c.translateBy(x: 0, y: hop)
        c.translateBy(x: 110, y: 180); c.scaleBy(x: 1 + CGFloat(0.08 * bounce), y: 1 - CGFloat(0.12 * bounce)); c.translateBy(x: -110, y: -180)

        // Tail, behind the body: anchor and curve blend between the seated and lying tails.
        let anchor = mix(CGPoint(x: 164, y: 152), CGPoint(x: 156, y: 124), Double(sit))
        let tip = mix(CGPoint(x: 176, y: 124), CGPoint(x: 170, y: 80), Double(sit))
        let c1 = mix(CGPoint(x: 186, y: 152), CGPoint(x: 180, y: 118), Double(sit)), c2 = mix(CGPoint(x: 192, y: 130), CGPoint(x: 186, y: 94), Double(sit))
        var tail = Path(); tail.move(to: anchor); tail.addCurve(to: tip, control1: c1, control2: c2)
        let wag: (amplitude: Double, period: Double, base: Double)
        switch pose {
        case .working: wag = (15, 0.9, 1)
        case .done: wag = (18, 0.6, -24)
        case .waiting: wag = (4, 2.5, 0)
        case .idle: wag = (6, 2.2, 0)
        case .asleep: wag = (0, 1, 0)
        // The Failed dog holds its tail still and low (AC-39.06).
        case .failed: wag = (0, 1, 12)
        }
        let eager = input.hovered || input.panelOpen
        let amplitude = eager ? max(wag.amplitude, 16) : wag.amplitude, period = eager ? min(wag.period, 0.5) : wag.period
        let angle = CGFloat((wag.base + amplitude * wave(period, 0)) * .pi / 180)
        let pivot = CGAffineTransform(translationX: anchor.x, y: anchor.y).rotated(by: angle).translatedBy(x: -anchor.x, y: -anchor.y)
        c.stroke(tail.applying(pivot), with: .color(palette.coat), style: .init(lineWidth: 11, lineCap: .round))

        // Body, breathing from its base; legs and paws morph between standing and stretched.
        let body = mix(CGRect(x: 54, y: 116, width: 124, height: 60), CGRect(x: 62, y: 92, width: 96, height: 80), Double(sit))
        let squash = CGAffineTransform(translationX: 0, y: body.maxY).scaledBy(x: 1, y: breathe).translatedBy(x: 0, y: -body.maxY)
        c.fill(Path(ellipseIn: body).applying(squash), with: .color(palette.coat))
        if sit > 0.5 { c.fill(Path(ellipseIn: CGRect(x: 86, y: 122, width: 48, height: 48)), with: .color(palette.muzzle.opacity(Double(sit)))) }
        for side in 0..<2 {
            let standing = CGRect(x: side == 0 ? 84 : 118, y: 138, width: 18, height: 36)
            let stretched = CGRect(x: side == 0 ? 76 : 116, y: 158, width: 32, height: 16)
            let leg = mix(stretched, standing, Double(sit))
            c.fill(Path(roundedRect: leg, cornerRadius: min(leg.width, leg.height) / 2), with: .color(palette.coat))
            let pad = mix(CGRect(x: side == 0 ? 73 : 133, y: 160, width: 18, height: 12), CGRect(x: side == 0 ? 82 : 116, y: 167, width: 22, height: 12), Double(sit))
            c.fill(Path(ellipseIn: pad), with: .color(palette.muzzle))
        }

        // Head group: bobbing while working, tilting slowly, turning a little toward what it looks at.
        let gaze = input.gaze ?? (live ? PetMotion.wander(at: t) : .zero)
        let tilt = CGFloat((live ? PetMotion.tilt(at: t) : 0) + Double(gaze.x) * 4) * .pi / 180
        let neck = CGPoint(x: h.x, y: h.y + 34)
        c.translateBy(x: 0, y: bob)
        c.translateBy(x: neck.x, y: neck.y); c.rotate(by: Angle(radians: tilt)); c.translateBy(x: -neck.x, y: -neck.y)
        let perked = pose == .waiting || pose == .done, flat = pose == .failed
        let twitch: (left: Double, right: Double) = live ? PetMotion.earTwitch(at: t) : (0, 0)
        for side in [-1.0, 1.0] {
            let ax = h.x + 36 * side, ay = h.y - 20
            var degrees = perked ? 52.0 : flat ? 0.0 : (eager ? 30.0 : 14.0)
            degrees += (side < 0 ? twitch.left : twitch.right) * 14
            if let previous = input.previousPose, progress < 1 {
                let before = (previous == .waiting || previous == .done) ? 52.0 : previous == .failed ? 0.0 : 14.0
                degrees = before + (degrees - before) * progress
            }
            let pivot = CGAffineTransform(translationX: ax, y: ay).rotated(by: CGFloat(degrees * side * .pi / 180)).translatedBy(x: -ax, y: -ay)
            c.fill(Path(ellipseIn: CGRect(x: ax - 14, y: h.y - 24, width: 28, height: 60)).applying(pivot), with: .color(palette.ear))
        }
        c.fill(Path(ellipseIn: CGRect(x: h.x - 40, y: h.y - 40, width: 80, height: 80)), with: .color(palette.coat))
        c.fill(Path(ellipseIn: CGRect(x: h.x - 24, y: h.y - 3, width: 48, height: 34)), with: .color(palette.muzzle))
        for side in [-1.0, 1.0] {
            c.fill(Path(ellipseIn: CGRect(x: h.x + 26 * side - 6, y: h.y - 1, width: 12, height: 12)), with: .color(PetPalette.blush.opacity(0.45)))
        }
        c.fill(Path(ellipseIn: CGRect(x: h.x - 7.5 + gaze.x * 1.5, y: h.y + 0.5, width: 15, height: 11)), with: .color(palette.dark))
        var mouth = Path()
        mouth.move(to: .init(x: h.x - 12, y: h.y + 16))
        if settledPose == .failed {
            // A flat, slightly turned-down mouth under the lowered head.
            mouth.addQuadCurve(to: .init(x: h.x + 12, y: h.y + 16), control: .init(x: h.x, y: h.y + 11))
        } else {
            mouth.addQuadCurve(to: .init(x: h.x, y: h.y + 16), control: .init(x: h.x - 6, y: h.y + 24))
            mouth.addQuadCurve(to: .init(x: h.x + 12, y: h.y + 16), control: .init(x: h.x + 6, y: h.y + 24))
        }
        c.stroke(mouth, with: .color(palette.dark), style: .init(lineWidth: 2.4, lineCap: .round))
        // Eyes: closed while asleep, smiling while done, else open, blinking and looking around.
        let blink = settledPose == .asleep || settledPose == .done || !live ? 0 : PetMotion.blink(at: t)
        for side in [-1.0, 1.0] {
            let ex = h.x + 16 * side
            switch settledPose {
            case .asleep:
                var lid = Path(); lid.move(to: .init(x: ex - 6, y: h.y - 8)); lid.addQuadCurve(to: .init(x: ex + 6, y: h.y - 8), control: .init(x: ex, y: h.y - 3))
                c.stroke(lid, with: .color(palette.dark), style: .init(lineWidth: 2.6, lineCap: .round))
            case .done:
                var smile = Path(); smile.move(to: .init(x: ex - 6, y: h.y - 6)); smile.addQuadCurve(to: .init(x: ex + 6, y: h.y - 6), control: .init(x: ex, y: h.y - 13))
                c.stroke(smile, with: .color(palette.dark), style: .init(lineWidth: 2.6, lineCap: .round))
            default:
                let open = CGFloat(1 - 0.92 * blink)
                let eye = CGRect(x: ex - 5.5 + gaze.x * 2.4, y: h.y - 8 - 5.5 * open + gaze.y * 1.6, width: 11, height: 11 * open)
                c.fill(Path(ellipseIn: eye), with: .color(palette.dark))
                if open > 0.5 {
                    c.fill(Path(ellipseIn: CGRect(x: eye.midX + 0.8, y: eye.midY - 3.5, width: 3.6, height: 3.6 * open)), with: .color(.white))
                }
            }
        }
        // Collar and lantern tag: lit while working, pulsing while waiting, dim while idle and failed, off while asleep.
        let cy = h.y + 34
        c.fill(Path(roundedRect: CGRect(x: h.x - 30, y: cy, width: 60, height: 11), cornerRadius: 5.5), with: .color(palette.collar))
        let lit = pose != .asleep
        let glow: Double
        switch pose {
        case .asleep: glow = 0
        case .idle, .failed: glow = 0.22
        case .waiting: glow = live ? 0.35 + 0.5 * (0.5 + 0.5 * wave(1.4, 0)) : 0.6
        default: glow = 0.6
        }
        if glow > 0 {
            // A soft halo as a radial gradient; a blur filter would cost an offscreen pass every frame (AC-39.08).
            let center = CGPoint(x: h.x, y: cy + 21), reach: CGFloat = 18
            let halo = Gradient(stops: [.init(color: PetPalette.lanternGlow.opacity(glow), location: 0),
                                        .init(color: PetPalette.lanternGlow.opacity(glow * 0.75), location: 0.45),
                                        .init(color: PetPalette.lanternGlow.opacity(0), location: 1)])
            c.fill(Path(ellipseIn: CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2)),
                   with: .radialGradient(halo, center: center, startRadius: 0, endRadius: reach))
        }
        let cap = palette.collar.opacity(0.75)
        c.fill(Path(roundedRect: CGRect(x: h.x - 6, y: cy + 9, width: 12, height: 4), cornerRadius: 1.5), with: .color(cap))
        c.fill(Path(roundedRect: CGRect(x: h.x - 7, y: cy + 12, width: 14, height: 18), cornerRadius: 4),
               with: .color(lit ? PetPalette.lanternOn : PetPalette.lanternOff))
        c.fill(Path(roundedRect: CGRect(x: h.x - 2, y: cy + 15, width: 4, height: 10), cornerRadius: 2), with: .color(.white.opacity(lit ? 0.55 : 0.25)))
        c.fill(Path(roundedRect: CGRect(x: h.x - 5, y: cy + 30, width: 10, height: 3), cornerRadius: 1.5), with: .color(cap))
        c.translateBy(x: neck.x, y: neck.y); c.rotate(by: Angle(radians: -tilt)); c.translateBy(x: -neck.x, y: -neck.y)
        c.translateBy(x: 0, y: -bob)
        // Bubble with its glyph, popping in; the open panel is the dog's bubble instead (AC-39.04, AC-39.05).
        if let glyph = pose.bubble, !input.panelOpen {
            let scale = CGFloat(live ? PetMotion.bubbleScale(at: t, since: input.poseChangedAt) : 1)
            drawBubble(in: &c, tip: CGPoint(x: h.x + 36, y: h.y - 36), glyph: glyph, scale: scale, ink: palette.dark)
        }
        if pose == .asleep { drawSleep(in: &c, origin: CGPoint(x: h.x + 44, y: h.y - 26), time: live ? t : nil, ink: palette.dark) }
        if pose == .done {
            for (index, star) in [(CGPoint(x: 44, y: 70), 9.0), (CGPoint(x: 60, y: 34), 7.0), (CGPoint(x: 178, y: 56), 8.0)].enumerated() {
                let opacity = live ? 0.15 + 0.85 * (0.5 + 0.5 * wave(1.1, Double(index) * 2)) : 1
                let (p, r) = (star.0, CGFloat(star.1))
                var path = Path()
                path.move(to: .init(x: p.x, y: p.y - r)); path.addLine(to: .init(x: p.x + r * 0.3, y: p.y - r * 0.3))
                path.addLine(to: .init(x: p.x + r, y: p.y)); path.addLine(to: .init(x: p.x + r * 0.3, y: p.y + r * 0.3))
                path.addLine(to: .init(x: p.x, y: p.y + r)); path.addLine(to: .init(x: p.x - r * 0.3, y: p.y + r * 0.3))
                path.addLine(to: .init(x: p.x - r, y: p.y)); path.addLine(to: .init(x: p.x - r * 0.3, y: p.y - r * 0.3)); path.closeSubpath()
                c.fill(path, with: .color(PetPalette.lanternGlow.opacity(opacity)))
            }
        }
    }
}

extension PetDrawing {
    /// A white bubble with its glyph whose tail ends at `tip`, growing from the tip by `scale` (AC-39.04). The glyph
    /// is a stroked shape, so a frame lays out no text.
    static func drawBubble(in c: inout GraphicsContext, tip: CGPoint, glyph: String, scale: CGFloat, ink: Color) {
        let bx = tip.x - 6, by = tip.y - 42
        var bubble = Path(roundedRect: CGRect(x: bx, y: by, width: 40, height: 34), cornerRadius: 12)
        bubble.move(to: .init(x: bx + 8, y: by + 33)); bubble.addLine(to: .init(x: bx + 4, y: by + 43)); bubble.addLine(to: .init(x: bx + 16, y: by + 34)); bubble.closeSubpath()
        let grow = CGAffineTransform(translationX: tip.x, y: tip.y).scaledBy(x: scale, y: scale).translatedBy(x: -tip.x, y: -tip.y)
        c.fill(bubble.applying(grow), with: .color(.white))
        c.stroke(bubble.applying(grow), with: .color(ink), style: .init(lineWidth: 2, lineJoin: .round))
        guard scale > 0.6 else { return }
        let s = scale, cx = tip.x + 14 * s, cy = tip.y - 25 * s
        var shape = Path()
        if glyph == "✓" {
            shape.move(to: .init(x: cx - 7 * s, y: cy + 0.5 * s)); shape.addLine(to: .init(x: cx - 2 * s, y: cy + 5.5 * s))
            shape.addLine(to: .init(x: cx + 8 * s, y: cy - 6 * s))
            c.stroke(shape, with: .color(PetPalette.check), style: .init(lineWidth: 3.4 * s, lineCap: .round, lineJoin: .round))
        } else if glyph == "!" {
            // An exclamation mark: a stem and the question mark's dot (AC-39.04).
            shape.move(to: .init(x: cx, y: cy - 9 * s)); shape.addLine(to: .init(x: cx, y: cy + 4 * s))
            c.stroke(shape, with: .color(ink), style: .init(lineWidth: 3.4 * s, lineCap: .round))
            c.fill(Path(ellipseIn: CGRect(x: cx - 1.9 * s, y: cy + 7.6 * s, width: 3.8 * s, height: 3.8 * s)), with: .color(ink))
        } else {
            // A question mark: an arch, a short stem and a dot.
            shape.move(to: .init(x: cx - 5.5 * s, y: cy - 4 * s))
            shape.addCurve(to: .init(x: cx + 5.5 * s, y: cy - 4 * s), control1: .init(x: cx - 5.5 * s, y: cy - 11.5 * s), control2: .init(x: cx + 5.5 * s, y: cy - 11.5 * s))
            shape.addCurve(to: .init(x: cx, y: cy + 3 * s), control1: .init(x: cx + 5.5 * s, y: cy + 1 * s), control2: .init(x: cx, y: cy - 1 * s))
            shape.addLine(to: .init(x: cx, y: cy + 5 * s))
            c.stroke(shape, with: .color(ink), style: .init(lineWidth: 3 * s, lineCap: .round, lineJoin: .round))
            c.fill(Path(ellipseIn: CGRect(x: cx - 1.9 * s, y: cy + 7.6 * s, width: 3.8 * s, height: 3.8 * s)), with: .color(ink))
        }
    }
    /// Three drifting "z" marks rising from `origin`, each a stroked zigzag; still when `time` is nil.
    static func drawSleep(in c: inout GraphicsContext, origin: CGPoint, time t: TimeInterval?, ink: Color) {
        for (index, size) in [14.0, 18.0, 22.0].enumerated() {
            let phase = t.map { (($0 + Double(index) * 0.6).truncatingRemainder(dividingBy: 2.4) / 2.4) } ?? Double(index) / 3
            let opacity = t != nil ? (phase < 0.3 ? phase / 0.3 : 1 - (phase - 0.3) / 0.7) * 0.9 : 0.7
            let drift = CGFloat(phase) * 18
            let p = CGPoint(x: origin.x + 9 * CGFloat(index) + drift * 0.5, y: origin.y - 15 * CGFloat(index) - drift)
            let w = CGFloat(size) * 0.3, h = CGFloat(size) * 0.32
            var z = Path()
            z.move(to: .init(x: p.x - w, y: p.y - h)); z.addLine(to: .init(x: p.x + w, y: p.y - h))
            z.addLine(to: .init(x: p.x - w, y: p.y + h)); z.addLine(to: .init(x: p.x + w, y: p.y + h))
            c.stroke(z, with: .color(ink.opacity(opacity)), style: .init(lineWidth: CGFloat(size) * 0.16, lineCap: .round, lineJoin: .round))
        }
    }
}

/// What the pet window shows: the code-drawn dog in a coat, or a pack's sprite sheet (US-40).
enum PetAppearance: Equatable {
    case dog(PetPalette)
    case sprite(PetSpriteSheet)
    static func == (lhs: PetAppearance, rhs: PetAppearance) -> Bool {
        switch (lhs, rhs) {
        case (.dog(let a), .dog(let b)): a == b
        case (.sprite(let a), .sprite(let b)): a === b
        default: false
        }
    }
    var spriteVersion: PetSpriteVersion? { if case .sprite(let sheet) = self { sheet.version } else { nil } }
}

/// The dog, redrawn on a state change and, while it moves, at each frame the clock publishes: twelve a second for
/// its loops, thirty for the quick things (AC-39.08). The motion input is read from the clock at draw time; a clock
/// without a frame draws the pet standing still.
struct PetCanvasView: View {
    let state: PetState
    let appearance: PetAppearance
    @ObservedObject var clock: PetFrameClock

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            switch appearance {
            case .dog(let palette):
                PetDrawing.draw(in: &context, size: size, state: state, palette: palette, input: clock.input, time: clock.frame)
            case .sprite(let sheet):
                PetSpriteDrawing.draw(in: &context, size: size, state: state, sheet: sheet, input: clock.input, time: clock.frame)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

/// Hosts the dog in its floating window: a press that does not move the window is a click, a drag moves it
/// (AC-39.02), the secondary button opens the menu, and hovering shows the status line as a tooltip (AC-39.04).
final class PetHostView: HoverTrackingView {
    private let hosting: NSHostingView<PetCanvasView>
    private let clock = PetFrameClock()
    private(set) var state = PetState(pose: .asleep, sessionID: nil, sessionCount: 0, waitingCount: 0, runningCount: 0, summary: nil)
    private(set) var input = PetMotionInput()
    /// What is shown; `appearance` is NSView's own.
    private(set) var shown: PetAppearance
    private var animating = false
    var clicked: (() -> Void)?
    var contextMenu: (() -> NSMenu)?
    var dragStarted: (() -> Void)?
    var dragEnded: (() -> Void)?

    init(palette: PetPalette) {
        shown = .dog(palette)
        hosting = NSHostingView(rootView: PetCanvasView(state: state, appearance: .dog(palette), clock: clock))
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([hosting.leadingAnchor.constraint(equalTo: leadingAnchor), hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     hosting.topAnchor.constraint(equalTo: topAnchor), hosting.bottomAnchor.constraint(equalTo: bottomAnchor)])
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// A changed state or appearance rebuilds the view. While the pet moves, any motion change but the gaze (a click,
    /// a drag, attention) shows in a frame at once, as does a gaze that turns a pack to another look cell (AC-40.03);
    /// the dog's gaze alone reaches the next quick frame through the clock. Standing still, every change redraws.
    func update(_ state: PetState, appearance: PetAppearance, input: PetMotionInput, animating: Bool) {
        var prompt = input, previous = self.input
        prompt.gaze = nil; previous.gaze = nil
        let rebuild = state != self.state || appearance != self.shown || animating != self.animating || prompt != previous
        let motionChanged = input != self.input
        let now = Date().timeIntervalSinceReferenceDate
        let cellChanged = motionChanged && appearance.spriteVersion.map { version in
            PetSpriteDrawing.frame(at: now, input: input, version: version) != PetSpriteDrawing.frame(at: now, input: self.input, version: version)
        } ?? false
        self.state = state; self.shown = appearance; self.input = input; self.animating = animating
        clock.input = input; clock.sprite = appearance.spriteVersion
        if rebuild { hosting.rootView = PetCanvasView(state: state, appearance: appearance, clock: clock) }
        if animating {
            if rebuild || cellChanged || !clock.isRunning { clock.start() }
        } else {
            clock.stop()
            if motionChanged, !rebuild { hosting.rootView = PetCanvasView(state: state, appearance: appearance, clock: clock) }
        }
        guard rebuild else { return }
        toolTip = state.summary ?? state.pose.title
        setAccessibilityLabel(state.accessibilityLabel)
        setAccessibilityValue(state.summary ?? state.pose.title)
    }
    /// Whether a point in this view's coordinates lies on the pet rather than on transparent space: the dog's
    /// silhouette, or a pack's opaque pixels in its current cell and its bubble while shown (AC-39.02, AC-40.06).
    func isOnDog(_ point: CGPoint) -> Bool {
        let flipped = CGPoint(x: point.x, y: bounds.height - point.y)
        switch shown {
        case .dog:
            let design = flipped.applying(PetDrawing.transform(for: bounds.size).inverted())
            return PetDrawing.silhouette(pose: state.pose, bubbleShown: !input.panelOpen).contains(design)
        case .sprite(let sheet):
            if input.pose.bubble != nil, !input.panelOpen, PetSpriteDrawing.bubbleRect(in: bounds.size, sheet: sheet).contains(flipped) { return true }
            let rect = PetSpriteDrawing.cellRect(in: bounds.size)
            guard rect.contains(flipped) else { return false }
            let frame = PetSpriteDrawing.frame(at: animating ? Date().timeIntervalSinceReferenceDate : nil, input: input, version: sheet.version)
            let x = Int((flipped.x - rect.minX) / rect.width * CGFloat(PetSpriteSheet.cellWidth))
            let y = Int((flipped.y - rect.minY) / rect.height * CGFloat(PetSpriteSheet.cellHeight))
            return sheet.isOpaque(frame, x: x, y: y)
        }
    }
    /// The head's center in this view's coordinates, the origin of the dog's gaze; a pack's top center.
    var headCenter: CGPoint {
        switch shown {
        case .dog:
            let design = PetDrawing.headCenter(pose: state.pose, in: bounds.size)
            return CGPoint(x: design.x, y: bounds.height - design.y)
        case .sprite(let sheet):
            let top = PetSpriteDrawing.topCenter(in: bounds.size, sheet: sheet)
            return CGPoint(x: top.x, y: bounds.height - top.y - 24)
        }
    }
    /// The head's circle in this view's coordinates, which the companion panel's bubble tail points at; for a pack,
    /// a square whose top is the pet's top center (AC-40.05).
    var headFrame: CGRect {
        switch shown {
        case .dog:
            let center = headCenter, radius = 40 * PetDrawing.transform(for: bounds.size).a
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case .sprite(let sheet):
            let top = PetSpriteDrawing.topCenter(in: bounds.size, sheet: sheet)
            return CGRect(x: top.x - 32, y: bounds.height - top.y - 64, width: 64, height: 64)
        }
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let origin = window.frame.origin
        dragStarted?()
        window.performDrag(with: event)
        dragEnded?()
        let delta = hypot(window.frame.origin.x - origin.x, window.frame.origin.y - origin.y)
        if delta < 3 { clicked?() }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func accessibilityPerformPress() -> Bool { clicked?(); return clicked != nil }
}
