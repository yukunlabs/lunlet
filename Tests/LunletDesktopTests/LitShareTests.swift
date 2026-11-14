// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.10; US-24, AC-24.04.
import CoreGraphics
import SwiftUI
import Testing
@testable import LunletDesktop

/// The lit share of a header body (AC-19.10): the night side's area is exactly what is not left.
struct LitShareTests {
    private let center = CGPoint(x: 40, y: 50), radius: CGFloat = 26

    /// The area a path encloses, with every curve flattened finely.
    private func area(_ path: Path) -> CGFloat {
        var points: [CGPoint] = [], current = CGPoint.zero, total: CGFloat = 0
        func close() {
            guard points.count > 2 else { points = []; return }
            var sum: CGFloat = 0
            for index in points.indices {
                let a = points[index], b = points[(index + 1) % points.count]
                sum += a.x * b.y - b.x * a.y
            }
            total += abs(sum) / 2; points = []
        }
        path.forEach { element in
            switch element {
            case .move(let to): close(); points = [to]; current = to
            case .line(let to): points.append(to); current = to
            case .quadCurve(let to, let control):
                for step in 1...48 {
                    let t = CGFloat(step) / 48, u = 1 - t
                    points.append(CGPoint(x: u * u * current.x + 2 * u * t * control.x + t * t * to.x,
                                          y: u * u * current.y + 2 * u * t * control.y + t * t * to.y))
                }
                current = to
            case .curve(let to, let c1, let c2):
                for step in 1...48 {
                    let t = CGFloat(step) / 48, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    points.append(CGPoint(x: a * current.x + b * c1.x + c * c2.x + d * to.x,
                                          y: a * current.y + b * c1.y + c * c2.y + d * to.y))
                }
                current = to
            case .closeSubpath: close()
            }
        }
        close()
        return total
    }

    @Test func theTerminatorHalfWidthIsTheRadiusTimesTheDistanceFromHalf() {
        for (fraction, expected) in [(0.0, 26.0), (0.1, 20.8), (0.25, 13.0), (0.5, 0.0), (0.62, 6.24), (0.85, 18.2), (1.0, 26.0)] {
            #expect(abs(LitShare.terminatorHalfWidth(radius: radius, fraction: fraction) - expected) < 1e-9, "\(fraction)")
        }
    }

    @Test func aShareOutsideZeroToOneIsClampedAndAnUnreadableOneIsDark() {
        #expect(LitShare.terminatorHalfWidth(radius: radius, fraction: -0.3) == radius)
        #expect(LitShare.terminatorHalfWidth(radius: radius, fraction: 1.7) == radius)
        #expect(LitShare.nightPath(center: center, radius: radius, fraction: 1.7).isEmpty)
        #expect(LitShare.nightPath(center: center, radius: radius, fraction: .infinity).isEmpty)
        let disc = CGFloat.pi * radius * radius
        #expect(abs(area(LitShare.nightPath(center: center, radius: radius, fraction: -2)) - disc) < disc * 0.005)
        #expect(abs(area(LitShare.nightPath(center: center, radius: radius, fraction: .nan)) - disc) < disc * 0.005)
        #expect(LitShare.nightPath(center: center, radius: 0, fraction: 0.4).isEmpty)
    }

    @Test func theNightSideCoversExactlyTheShareThatIsNotLeft() {
        // AC-19.10: the lit share of the disc's area equals percent left.
        let disc = CGFloat.pi * radius * radius
        for fraction in [0, 0.1, 0.25, 0.5, 0.62, 0.85, 1] {
            let night = LitShare.nightPath(center: center, radius: radius, fraction: fraction)
            #expect(abs(area(night) - (1 - fraction) * disc) < disc * 0.005, "\(fraction): \(area(night) / disc)")
            // The night never leaves the disc.
            if !night.isEmpty {
                let bounds = night.boundingRect
                let limit = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
                #expect(limit.insetBy(dx: -0.01, dy: -0.01).contains(bounds), "\(fraction): \(bounds)")
            }
        }
        #expect(LitShare.nightPath(center: center, radius: radius, fraction: 1).isEmpty)
    }

    @Test func theNightIsOnTheTrailingSideAndMirroringMovesItToTheLeadingSide() {
        func point(_ offset: CGFloat) -> CGPoint { CGPoint(x: center.x + offset * radius, y: center.y) }
        let mostlyLit = LitShare.nightPath(center: center, radius: radius, fraction: 0.62)
        #expect(mostlyLit.contains(point(0.9)))
        #expect(!mostlyLit.contains(point(0)))
        #expect(!mostlyLit.contains(point(-0.9)))
        // Below half the terminator bows into the lit side, so the center is dark.
        let mostlyDark = LitShare.nightPath(center: center, radius: radius, fraction: 0.25)
        #expect(mostlyDark.contains(point(0)))
        #expect(mostlyDark.contains(point(-0.3)))
        #expect(!mostlyDark.contains(point(-0.8)))

        let mirrored = LitShare.nightPath(center: center, radius: radius, fraction: 0.62, mirrored: true)
        #expect(mirrored.contains(point(-0.9)))
        #expect(!mirrored.contains(point(0)))
        #expect(!mirrored.contains(point(0.9)))
        // A path keeps its points in single precision, so the two areas agree to that precision.
        #expect(abs(area(mirrored) - area(mostlyLit)) < 0.01, "\(area(mirrored)) \(area(mostlyLit))")
    }
}
