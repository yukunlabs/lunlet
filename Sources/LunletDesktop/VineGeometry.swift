// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-03, AC-03.07, AC-03.08, AC-03.10; US-04, AC-04.10, AC-04.13; US-13, AC-13.07.
import Foundation
import CoreGraphics

/// Entry geometry shared by placement, artwork, lanterns and skin validation.
/// Reviewed vectors are drawn around a reference notch and stretched across the actual one.
enum EntryMetrics {
    /// The notch the artwork coordinates were drawn around.
    static let referenceNotch = CGSize(width: 185, height: 32)
    /// Artwork margin on each side of the reference notch, occupied by the lettering.
    static let artworkWing: CGFloat = 44
    /// Transparent clearance between the screen-facing artwork edge and the entry window edge.
    static let outerInset: CGFloat = 8
    /// Entry width on each side of the actual notch.
    static let wing = artworkWing + outerInset
    /// Entry height below the notch, holding the vine.
    static let drop: CGFloat = 17
    /// Coordinate space for skin body paths: both wings plus the reference notch.
    static let artworkSize = CGSize(width: artworkWing * 2 + referenceNotch.width, height: 44)
    /// Coordinate space for each skin word.
    static let wordSize = CGSize(width: 40, height: 26)
}

/// The drawing follows the actual notch; letter sizes and exterior clearance stay in points.
struct VineGeometry {
    let notch: CGSize
    var size: CGSize { .init(width: notch.width + EntryMetrics.wing * 2, height: notch.height + EntryMetrics.drop) }
    func map(_ p: CGPoint) -> CGPoint {
        let wing = EntryMetrics.artworkWing, reference = EntryMetrics.referenceNotch
        let x: CGFloat
        if p.x < wing { x = p.x + EntryMetrics.outerInset }
        else if p.x <= wing + reference.width { x = EntryMetrics.wing + (p.x - wing) * notch.width / reference.width }
        else { x = EntryMetrics.wing + notch.width + p.x - wing - reference.width }
        // Points below the notch line (y 22...32 in artwork space) follow a taller notch downward.
        let shift = (notch.height - reference.height) * (0.5 + 0.5 * min(1, max(0, (p.y - 22) / 10)))
        return .init(x: x, y: p.y + shift)
    }
    func body() -> CGPath { path(VineArtwork.body) }
    func path(_ source: String) -> CGPath { VinePath.make(source, map: map) }

    func points(on path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = [], current = CGPoint.zero, start = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                current = element.points[0]; start = current; points.append(current)
            case .addLineToPoint:
                current = element.points[0]; points.append(current)
            case .addCurveToPoint:
                let a = current, b = element.points[0], c = element.points[1], d = element.points[2]
                for index in 1...24 {
                    let t = CGFloat(index) / 24, u = 1 - t
                    points.append(.init(x: u*u*u*a.x + 3*u*u*t*b.x + 3*u*t*t*c.x + t*t*t*d.x,
                                        y: u*u*u*a.y + 3*u*u*t*b.y + 3*u*t*t*c.y + t*t*t*d.y))
                }
                current = d
            case .closeSubpath: points.append(start); current = start
            default: break // Artwork uses only moves, lines, cubic curves, and closes.
            }
        }
        return points
    }
    func location(at fraction: Double, on points: [CGPoint]) -> (point: CGPoint, angle: CGFloat) {
        guard let first = points.first else { return (.zero, 0) }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var remaining = lengths.reduce(0, +) * min(1, max(0, fraction))
        for (index, length) in lengths.enumerated() where length > 0 {
            let a = points[index], b = points[index + 1]
            if remaining <= length {
                let t = remaining / length
                return (.init(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), atan2(b.y - a.y, b.x - a.x))
            }
            remaining -= length
        }
        return (points.last ?? first, 0)
    }
}

/// Two agents' strands twisted around one centerline (AC-04.13). Both strands are sampled at the same fractions of
/// the centerline, so one fraction names the same place on each strand and on the shared marks.
struct VineRope {
    /// Distance of each strand from the centerline where they are widest apart.
    static let amplitude: CGFloat = 2.1
    /// One crossing between each pair of 10% marks, so the strands are widest apart at every mark.
    static let segments = 10
    private static let samples = 240
    let center: [CGPoint]
    let normals: [CGPoint]
    let strands: [[CGPoint]]

    init(centerline points: [CGPoint], amplitude: CGFloat = Self.amplitude) {
        let center = Self.resample(points, count: Self.samples + 1)
        let normals = center.indices.map { index -> CGPoint in
            let a = center[max(0, index - 1)], b = center[min(center.count - 1, index + 1)]
            let length = max(hypot(b.x - a.x, b.y - a.y), .ulpOfOne)
            return .init(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
        }
        let offsets = center.indices.map { Self.offset(at: Double($0) / Double(Self.samples)) * amplitude }
        self.center = center; self.normals = normals
        strands = [1, -1].map { (sign: CGFloat) in
            center.indices.map { .init(x: center[$0].x + normals[$0].x * offsets[$0] * sign,
                                       y: center[$0].y + normals[$0].y * offsets[$0] * sign) }
        }
    }
    /// Signed separation as a share of the amplitude. The strands leave the lettering as one vine, part at the
    /// first crossing and rejoin at the last, so both words keep a single connected stroke.
    static func offset(at fraction: Double) -> CGFloat {
        let fromEnd = min(fraction, 1 - fraction) * Double(segments)
        let ramp = min(1, max(0, (fromEnd - 0.5) * 2))
        return CGFloat(ramp * ramp * (3 - 2 * ramp) * cos(Double.pi * fraction * Double(segments)))
    }
    /// Strands alternate in front at successive crossings, like a twisted rope.
    static func isFront(_ strand: Int, segment: Int) -> Bool { (segment + strand).isMultiple(of: 2) }

    func point(_ strand: Int, at fraction: Double) -> CGPoint { Self.sample(strands[strand], at: fraction) }
    /// The strand's segments on one side of the twist, from its start up to `fraction` of its length.
    func path(_ strand: Int, front: Bool, through fraction: Double = 1) -> CGPath {
        let path = CGMutablePath(), points = strands[strand], end = min(1, max(0, fraction))
        let last = Double(points.count - 1)
        for segment in 0..<Self.segments where Self.isFront(strand, segment: segment) == front {
            let start = Double(segment) / Double(Self.segments)
            guard end > start else { break }
            let stop = min(end, Double(segment + 1) / Double(Self.segments))
            path.move(to: point(strand, at: start))
            let first = Int((start * last).rounded(.down)) + 1, interior = Int((stop * last).rounded(.up)) - 1
            if first <= interior { for index in first...interior { path.addLine(to: points[index]) } }
            path.addLine(to: point(strand, at: stop))
        }
        return path
    }
    /// A mark across both strands at `fraction`, reaching `reach` points either side of the centerline.
    func mark(at fraction: Double, reach: CGFloat) -> (CGPoint, CGPoint) {
        let point = Self.sample(center, at: fraction)
        let normal = normals[Int((min(1, max(0, fraction)) * Double(normals.count - 1)).rounded())]
        return (.init(x: point.x - normal.x * reach, y: point.y - normal.y * reach),
                .init(x: point.x + normal.x * reach, y: point.y + normal.y * reach))
    }

    static func sample(_ points: [CGPoint], at fraction: Double) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        let position = min(1, max(0, fraction)) * Double(points.count - 1)
        let index = min(points.count - 2, Int(position)), t = CGFloat(position - Double(index))
        let a = points[index], b = points[index + 1]
        return .init(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
    /// Evenly spaced points along a polyline, so a fraction of the samples is the same fraction of its length.
    static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count > 1, count > 1 else { return Array(repeating: points.first ?? .zero, count: max(1, count)) }
        var lengths: [CGFloat] = [0]
        for (a, b) in zip(points, points.dropFirst()) { lengths.append(lengths[lengths.count - 1] + hypot(b.x - a.x, b.y - a.y)) }
        var result: [CGPoint] = [], index = 0
        for step in 0..<count {
            let target = lengths[lengths.count - 1] * CGFloat(step) / CGFloat(count - 1)
            while index < points.count - 2, lengths[index + 1] < target { index += 1 }
            let span = lengths[index + 1] - lengths[index]
            let t = span > 0 ? min(1, max(0, (target - lengths[index]) / span)) : 0
            let a = points[index], b = points[index + 1]
            result.append(.init(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return result
    }
}

/// Builds reviewed vectors and skin paths already checked by SkinPathValidation.
/// Unvalidated user content must never reach this internal builder.
enum VinePath {
    private static let tokens = try! NSRegularExpression(pattern: #"[MLCZ]|-?(?:[0-9]*\.)?[0-9]+"#)
    static func make(_ source: String, map: (CGPoint) -> CGPoint = { $0 }) -> CGPath {
        let range = NSRange(source.startIndex..., in: source)
        let values = tokens.matches(in: source, range: range).map { (source as NSString).substring(with: $0.range) }
        let path = CGMutablePath()
        var cursor = 0
        func point() -> CGPoint {
            precondition(cursor + 1 < values.count)
            let p = CGPoint(x: Double(values[cursor])!, y: Double(values[cursor + 1])!)
            cursor += 2; return map(p)
        }
        while cursor < values.count {
            let command = values[cursor]; cursor += 1
            switch command {
            case "M": path.move(to: point())
            case "L": path.addLine(to: point())
            case "C":
                let a = point(), b = point(), c = point()
                path.addCurve(to: c, control1: a, control2: b)
            case "Z": path.closeSubpath()
            default: preconditionFailure("Unsupported internal vine command")
            }
        }
        return path
    }
}

// Independent vectors refined in the approved local design study.
enum VineArtwork {
    static let body = "M33 22 C38 20.5 40 22.5 44 26.4 C49 32.5 56 34.9 68 34.7 C78 34.5 80 37 89 37 C99 37 102 33.7 113 33.7 C124 33.7 126 37 137 37 C148 37 150 33.7 161 33.7 C172 33.7 174 36.9 185 36.9 C195 36.9 198 34.5 208 34.5 C219 34.4 226 31.5 231 26.7 C235 22.7 237 20.5 241 22"
    static let pulse = "M30.4 20.2 C36.5 19.4 39.8 22.8 43.8 26.7 C49 32.8 56 35.1 68 34.9 C78 34.7 80 37.3 89 37.3 C99 37.3 102 33.8 113 33.8 C124 33.8 126 37.2 137 37.2 C148 37.2 150 33.8 161 33.8 C172 33.8 174 37 185 37 C195 37 198 34.6 208 34.6 C219 34.5 226 31.6 231.5 27 C236 22.8 240 19.6 243.6 20.2"
    /// The twisted pair's centerline: the vine's ends with a level run beneath the notch, which the twist waves.
    static let rope = "M33 22 C38 20.5 40 22.5 44 26.4 C49 32.5 56 35.4 68 35.4 C100 35.4 176 35.4 208 35.4 C219 35.3 226 31.5 231 26.7 C235 22.7 237 20.5 241 22"
    static let ropePulse = "M30.4 20.2 C36.5 19.4 39.8 22.8 43.8 26.7 C49 32.8 56 35.7 68 35.7 C100 35.7 176 35.7 208 35.7 C219 35.5 226 31.6 231.5 27 C236 22.8 240 19.6 243.6 20.2"
    static let rear = "M33 22 C38 20.5 40 22.5 44 26.4 C49 32.5 56 34.9 68 34.7 C78 34.9 80 32.8 89 32.8 C99 32.8 102 36.1 113 36.1 C124 36.1 126 32.8 137 32.8 C148 32.8 150 36.1 161 36.1 C172 36.1 174 32.9 185 32.9 C195 32.9 198 34.5 208 34.5 C219 34.4 226 31.5 231 26.7 C235 22.7 237 20.5 241 22"
    static let leftInk = "M6 15 C13 8 15 2 12 2 C8 2 6 17 9 18 C12 19 15 12 16 10 C14 15 13 19 17 19 C20 19 22 13 23 10 L21 18 C21 20 23 20 25 17 L28 10 C29 9 27 16 28 16 C29 12 31 10 33 11 C36 12 30 20 35 18"
    static let leftTendril = "M8.8 16.5 C6.9 17.4 4.4 18 3.8 16.2 C3.1 14.3 5.4 13.5 6.1 14.8"
    static let leftShoot = "M30 11.6 C30.3 9.6 30.3 8.6 31.3 7.4 C30.7 4.5 33.6 3.4 37.1 4.5 C35.5 5 35.2 7.6 32.2 7.8 C31.4 8.7 31 10.2 30.9 11.6Z"
    static let leftVein = "M31.3 8.4 C32.1 6.5 33.4 5.8 35.6 4.9"
    static let rightInk = "M6 15 C13 8 15 2 12 2 C8 2 6 17 9 18 C10 19 12 18 14 16 C13.7 15.5 13.8 15.2 14 15 C23 16 24 8 18 10 C13 11 11 20 18 20 C21 20 23 18 24 16 M28 5 C26 10 23 20 28 19 C30 19 31 17 32 16 M23 10 C26 9.6 31 9.5 34 9 C36 8.7 36.7 7 35.6 6.1 C34.6 5.3 33.5 6.1 33.9 7"
    static let rightTendril = "M33.8 9 C35.8 8.7 36.8 7.3 35.8 6.2 C34.9 5.3 33.8 6 34.1 6.9"
    static let rightShoot = "M26.4 7.6 C26.5 5.5 27.1 4.1 28.8 3.4 C29 .7 32.2 .5 35.5 2.5 C33.4 2.4 32.4 5 29.6 4 C28 4.3 27.3 6 27.3 7.7Z"
    static let rightVein = "M28.1 4.9 C29.7 3.1 31.3 2.8 33.7 2.5"
    static let curls = "M43 25.2 C37.9 24.8 36.3 18.9 40.2 18.4 C43.5 17.8 44 21.8 41.3 22.3 M231.5 27 C236.5 31 241.3 28.2 239.8 24.7 C239 22.7 236.8 23.1 236.9 25"
    static let sprout = "M0 0 C1.5 0 2.5 .8 3.5 1.7 M2.5 .8 C5.1 .6 6.1 2.7 8.4 4 C5.5 4.4 3.3 2.9 3 1.9Z"
}
