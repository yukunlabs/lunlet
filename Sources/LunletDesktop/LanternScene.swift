// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-17, AC-17.03, AC-17.05, AC-17.06, AC-17.07; US-04, AC-04.13; US-16, AC-16.03; US-03, AC-03.10; US-12, AC-12.04.
import AppKit
import LunletCore
import QuartzCore

/// The application owns placement and animation; a skin supplies appearance only.
@MainActor final class LanternScene {
    let layer = CALayer()
    private var lamps: [CALayer] = []
    init() { layer.name = "lanterns" }

    /// One agent hangs five lanterns on one cord. Two agents hang two cords that cross once under the notch, each
    /// with five smaller lanterns in that agent's color, interleaved along the width.
    func render(notch: CGSize, allowances: [AgentAllowance], accentHex: String?) {
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }; lamps.removeAll()
        let accent = accentHex.flatMap(AllowanceColor.init(hexString:)) ?? SkinKind.lantern.fallbackAccent
        let gold = NSColor(srgbRed: 0.94, green: 0.78, blue: 0.53, alpha: 1)
        // The cord hangs from the notch corners and rises 17 points into each wing.
        let left = EntryMetrics.wing, right = EntryMetrics.wing + notch.width, top = notch.height + 1
        let agents = Array(allowances.prefix(2))
        guard agents.count == 2 else {
            let cord = CGMutablePath()
            cord.move(to: .init(x: left - 17, y: notch.height - 8))
            cord.addCurve(to: .init(x: left, y: top), control1: .init(x: left - 12, y: notch.height - 2),
                          control2: .init(x: left - 8, y: top))
            cord.addCurve(to: .init(x: right, y: top),
                          control1: .init(x: left + notch.width * 0.3, y: notch.height + 2.5),
                          control2: .init(x: left + notch.width * 0.7, y: notch.height + 2.5))
            cord.addCurve(to: .init(x: right + 17, y: notch.height - 8),
                          control1: .init(x: right + 8, y: top), control2: .init(x: right + 12, y: notch.height - 2))
            layer.addSublayer(stroke(cord, color: accent.nsColor.withAlphaComponent(0.65), width: 1.1))
            layer.addSublayer(stroke(cord, color: gold.withAlphaComponent(0.6), width: 0.45))
            let levels = LanternLevels.values(remaining: agents.first?.remaining)
            for index in 0..<5 {
                let lamp = makeLamp(brightness: levels?[index], glass: accent, gold: gold)
                lamp.name = "lamp-\(index)"
                let fraction = (CGFloat(index) + 0.5) / 5
                lamp.position = .init(x: left + notch.width * fraction, y: top + 4.5 * fraction * (1 - fraction))
                lamps.append(lamp); layer.addSublayer(lamp)
            }
            return
        }
        // The wings carry one cord each; under the notch the pair splits. Each cord dips most under a different
        // fifth of the width, so the two cross once at the middle and their lanterns hang at staggered heights
        // within the entry's drop.
        for (x, direction) in [(left, CGFloat(-1)), (right, CGFloat(1))] {
            let tail = CGMutablePath()
            tail.move(to: .init(x: x + 17 * direction, y: notch.height - 8))
            tail.addCurve(to: .init(x: x, y: top), control1: .init(x: x + 12 * direction, y: notch.height - 2),
                          control2: .init(x: x + 8 * direction, y: top))
            layer.addSublayer(stroke(tail, color: accent.nsColor.withAlphaComponent(0.65), width: 1.1))
            layer.addSublayer(stroke(tail, color: gold.withAlphaComponent(0.6), width: 0.45))
        }
        func depth(_ fraction: CGFloat, peak: CGFloat) -> CGFloat {
            let shape = pow(fraction, 2 * peak) * pow(1 - fraction, 2 * (1 - peak))
            return 5.5 * shape / (pow(peak, 2 * peak) * pow(1 - peak, 2 * (1 - peak)))
        }
        var pendingLamps: [CALayer] = []
        for (cordIndex, allowance) in agents.enumerated() {
            let peak: CGFloat = cordIndex == 0 ? 0.2 : 0.8
            let glass = glassColor(for: allowance.provider, accent: accent)
            let cord = CGMutablePath()
            for step in 0...32 {
                let fraction = CGFloat(step) / 32
                let point = CGPoint(x: left + notch.width * fraction, y: top + depth(fraction, peak: peak))
                if step == 0 { cord.move(to: point) } else { cord.addLine(to: point) }
            }
            let line = stroke(cord, color: glass.nsColor.withAlphaComponent(0.65), width: 1.0)
            line.name = "cord-\(allowance.provider)"
            layer.addSublayer(line)
            layer.addSublayer(stroke(cord, color: gold.withAlphaComponent(0.5), width: 0.4))
            let levels = LanternLevels.values(remaining: allowance.remaining)
            for index in 0..<5 {
                let lamp = makeLamp(brightness: levels?[index], glass: glass, gold: gold)
                lamp.name = "lamp-\(allowance.provider)-\(index)"
                let fraction = (CGFloat(index) + (cordIndex == 0 ? 0.25 : 0.75)) / 5
                lamp.position = .init(x: left + notch.width * fraction, y: top + depth(fraction, peak: peak))
                lamp.transform = CATransform3DMakeScale(0.68, 0.68, 1)
                pendingLamps.append(lamp)
            }
        }
        // Lanterns over both cords, in width order, so neither cord's lamps sit behind the other's.
        for lamp in pendingLamps.sorted(by: { $0.position.x < $1.position.x }) { lamps.append(lamp); layer.addSublayer(lamp) }
    }

    /// Codex lanterns take the skin's glass; Claude Code's take its distinct sibling, as every meter does (AC-16.03).
    private func glassColor(for provider: SessionProvider, accent: AllowanceColor) -> AllowanceColor {
        provider == .codex ? accent : accent.agentVariant(turn: AgentPalette.hueShift(provider))
    }

    /// One lantern hanging from its anchor at the top: glass lit to `brightness`, or a dashed outline when unknown.
    private func makeLamp(brightness: Double?, glass: AllowanceColor, gold: NSColor) -> CALayer {
        let lamp = CALayer()
        lamp.bounds = .init(x: 0, y: 0, width: 16, height: 15); lamp.anchorPoint = .init(x: 0.5, y: 0)
        let body = CGPath(roundedRect: CGRect(x: 1.5, y: 2.5, width: 13, height: 9.5),
                          cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
        if let brightness {
            let pane = CAGradientLayer(); pane.frame = lamp.bounds
            pane.colors = [glass.blended(toward: .init(hex: 0xffdfaa), amount: 0.45).cgColor,
                           glass.cgColor, glass.blended(toward: .init(hex: 0x592535), amount: 0.55).cgColor]
            pane.locations = [0, 0.46, 1]
            pane.startPoint = .init(x: 0.2, y: 0); pane.endPoint = .init(x: 0.75, y: 1)
            let mask = CAShapeLayer(); mask.path = body; pane.mask = mask
            pane.opacity = Float(0.12 + 0.88 * brightness); lamp.addSublayer(pane)
            lamp.shadowColor = glass.cgColor; lamp.shadowOpacity = Float(brightness * 0.32)
            lamp.shadowRadius = 2.5; lamp.shadowOffset = .zero; lamp.shadowPath = body
            lamp.addSublayer(stroke(body, color: gold.withAlphaComponent(0.08 + brightness * 0.25), width: 0.45))
        } else {
            let outline = stroke(body, color: .secondaryLabelColor, width: 0.6)
            outline.lineDashPattern = [1, 2]; lamp.addSublayer(outline)
        }
        let intensity = brightness.map { 0.2 + $0 * 0.6 } ?? 0.3
        let frame = CGMutablePath()
        frame.move(to: .init(x: 8, y: 0)); frame.addLine(to: .init(x: 8, y: 2))
        frame.move(to: .init(x: 5.5, y: 2)); frame.addLine(to: .init(x: 10.5, y: 2))
        frame.move(to: .init(x: 5.5, y: 12.2)); frame.addLine(to: .init(x: 10.5, y: 12.2))
        for control: CGFloat in [1.5, 5, 11, 14.5] {
            frame.move(to: .init(x: 8, y: 2.8))
            frame.addQuadCurve(to: .init(x: 8, y: 11.5), control: .init(x: control, y: 7))
        }
        lamp.addSublayer(stroke(frame, color: gold.withAlphaComponent(intensity), width: 0.45))
        let tassel = CGMutablePath()
        tassel.move(to: .init(x: 8, y: 12.4)); tassel.addLine(to: .init(x: 8, y: 15))
        tassel.move(to: .init(x: 7, y: 13.3)); tassel.addLine(to: .init(x: 6.7, y: 14.8))
        tassel.move(to: .init(x: 9, y: 13.3)); tassel.addLine(to: .init(x: 9.3, y: 14.8))
        lamp.addSublayer(stroke(tassel, color: gold.withAlphaComponent(intensity * 0.8), width: 0.4))
        return lamp
    }

    func stopAnimations() { for lamp in lamps { lamp.removeAllAnimations() } }
    func react() {
        for (index, lamp) in lamps.enumerated() {
            let motion = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            motion.values = [0, index.isMultiple(of: 2) ? -0.13 : 0.13, 0.06, 0]
            motion.keyTimes = [0, 0.25, 0.6, 1]; motion.duration = 1.1
            motion.timingFunctions = Array(repeating: .init(name: .easeInEaseOut), count: 3)
            lamp.add(motion, forKey: "lantern-sway")
        }
    }
    private func stroke(_ path: CGPath, color: NSColor, width: CGFloat) -> CAShapeLayer {
        let shape = CAShapeLayer(); shape.path = path; shape.fillColor = nil
        shape.strokeColor = color.cgColor; shape.lineWidth = width; shape.lineCap = .round; shape.lineJoin = .round
        return shape
    }
}
