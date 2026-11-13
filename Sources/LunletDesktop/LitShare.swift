// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.10; US-24, AC-24.04.
import SwiftUI

/// The lit share of a header body: the fraction of the disc's area that is lit equals percent left (AC-19.10).
/// The boundary between day and night, the terminator, is half an ellipse through the poles.
enum LitShare {
    /// A share inside 0...1; one that is not a number reads as nothing left.
    static func clamped(_ fraction: Double) -> Double {
        fraction.isNaN ? 0 : min(1, max(0, fraction))
    }

    /// Half-width of the terminator ellipse for a disc of `radius` whose lit share of the area is `fraction` (0...1):
    /// radius * |2f - 1|.
    static func terminatorHalfWidth(radius: CGFloat, fraction: Double) -> CGFloat {
        radius * CGFloat(abs(2 * clamped(fraction) - 1))
    }

    /// The night side as a path in a disc centered at `center`: empty at 1, the whole disc at 0; its area is
    /// (1 - fraction) of the disc. The night is on the trailing side, so the lit side faces a Sun on the leading side.
    static func nightPath(center: CGPoint, radius: CGFloat, fraction: Double) -> Path {
        nightPath(center: center, radius: radius, fraction: fraction, mirrored: false)
    }

    /// The same night with the sides exchanged when `mirrored`, for a body whose Sun is on its trailing side.
    static func nightPath(center: CGPoint, radius: CGFloat, fraction: Double, mirrored: Bool) -> Path {
        let share = clamped(fraction)
        guard share < 1, radius > 0 else { return Path() }
        // A quarter of a circle or of an ellipse as one cubic curve.
        let kappa: CGFloat = 0.5522847498
        let side: CGFloat = mirrored ? -1 : 1
        // Above half the terminator bows toward the dark limb and leaves a crescent of night; below half it bows
        // into the lit side.
        let bow = (share >= 0.5 ? 1 : -1) * side * terminatorHalfWidth(radius: radius, fraction: share)
        let top = CGPoint(x: center.x, y: center.y - radius), bottom = CGPoint(x: center.x, y: center.y + radius)
        let limb = center.x + side * radius, terminator = center.x + bow
        var path = Path()
        path.move(to: top)
        path.addCurve(to: CGPoint(x: limb, y: center.y),
                      control1: CGPoint(x: center.x + side * radius * kappa, y: top.y),
                      control2: CGPoint(x: limb, y: center.y - radius * kappa))
        path.addCurve(to: bottom,
                      control1: CGPoint(x: limb, y: center.y + radius * kappa),
                      control2: CGPoint(x: center.x + side * radius * kappa, y: bottom.y))
        path.addCurve(to: CGPoint(x: terminator, y: center.y),
                      control1: CGPoint(x: center.x + bow * kappa, y: bottom.y),
                      control2: CGPoint(x: terminator, y: center.y + radius * kappa))
        path.addCurve(to: top,
                      control1: CGPoint(x: terminator, y: center.y - radius * kappa),
                      control2: CGPoint(x: center.x + bow * kappa, y: top.y))
        path.closeSubpath()
        return path
    }
}
