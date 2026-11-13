// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.09, AC-19.10; US-24, AC-24.02, AC-24.04.
import AppKit
import SwiftUI
import Testing
import LunletCore
@testable import LunletDesktop

/// A view rendered to pixels, first scanline at the top, for the header art's tests.
@MainActor struct HeaderArtBitmap {
    typealias Pixel = (r: Int, g: Int, b: Int, a: Int)
    let width: Int, height: Int, scale: CGFloat, pixels: [UInt8]

    init(_ view: some View, size: CGSize, scale: CGFloat = 2) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        width = image.width; height = image.height; self.scale = scale
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try #require(drawn)
        pixels = bytes
    }

    func at(_ x: Int, _ y: Int) -> Pixel {
        let i = (min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
    }
    /// The pixel at a point given in the view's own coordinates.
    func at(point: CGPoint) -> Pixel { at(Int(point.x * scale), Int(point.y * scale)) }
    static func luminance(_ p: Pixel) -> Double { 0.299 * Double(p.r) + 0.587 * Double(p.g) + 0.114 * Double(p.b) }
    /// The mean luminance of the pixels inside a rectangle given in the view's coordinates.
    func luminance(in rect: CGRect) -> Double {
        var sum = 0.0, count = 0.0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) { sum += Self.luminance(at(x, y)); count += 1 }
        }
        return count > 0 ? sum / count : 0
    }
    /// Whether two renders are the same drawing. The renderer may round a channel one level differently from one
    /// render to the next, so a level's difference is not a different drawing.
    func matches(_ other: HeaderArtBitmap) -> Bool {
        guard width == other.width, height == other.height else { return false }
        return !zip(pixels, other.pixels).contains { abs(Int($0) - Int($1)) > 1 }
    }
    func png() throws -> Data {
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
}

/// The three header bodies as drawn (AC-19.09, AC-19.10): one fixed look for each, the lit share of the disc equal to
/// what is left, and the lit side turned toward the Sun.
@MainActor struct HeaderBodyArtTests {
    private let side: CGFloat = 64
    private var center: CGPoint { CGPoint(x: side / 2, y: side / 2) }
    /// The disc's radius in a frame of `side` points.
    private var radius: CGFloat { side * HeaderBodyArt.discRadius / HeaderBodyArt.box }

    private func render(_ kind: HeaderBody, lit: Double?, mirrored: Bool = false, side: CGFloat? = nil) throws -> HeaderArtBitmap {
        let side = side ?? self.side
        return try HeaderArtBitmap(HeaderBodyArt(kind, lit: lit, mirrored: mirrored), size: CGSize(width: side, height: side))
    }
    /// The share of the disc's pixels that are clearly darker than in the fully lit drawing.
    private func nightShare(_ image: HeaderArtBitmap, against full: HeaderArtBitmap) -> Double {
        var night = 0.0, all = 0.0
        let cx = Double(center.x * image.scale), cy = Double(center.y * image.scale), limit = Double(radius * image.scale) * 0.97
        for y in 0..<image.height {
            for x in 0..<image.width where hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy) < limit {
                all += 1
                if HeaderArtBitmap.luminance(image.at(x, y)) < 0.62 * HeaderArtBitmap.luminance(full.at(x, y)) { night += 1 }
            }
        }
        return night / all
    }

    @Test func eachBodyHasItsOwnFixedLook() throws {
        // AC-19.09: a body for each agent and one for all agents, told apart without reading a color key.
        let middle = CGRect(x: center.x - 8, y: center.y - 14, width: 16, height: 10)
        func mean(_ image: HeaderArtBitmap) -> (r: Double, g: Double, b: Double) {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for y in Int(middle.minY * image.scale)..<Int(middle.maxY * image.scale) {
                for x in Int(middle.minX * image.scale)..<Int(middle.maxX * image.scale) {
                    let p = image.at(x, y); r += Double(p.r); g += Double(p.g); b += Double(p.b); n += 1
                }
            }
            return (r / n, g / n, b / n)
        }
        let codex = mean(try render(.agent(.codex), lit: 1)), claude = mean(try render(.agent(.claude), lit: 1))
        let sun = mean(try render(.all, lit: nil))
        #expect(codex.b > codex.r + 40, "Codex's planet is blue: \(codex)")
        #expect(claude.r > claude.b + 40, "Claude Code's planet is warm: \(claude)")
        #expect(sun.r > 230 && sun.g > 170 && sun.b < sun.g - 30, "the Sun glows: \(sun)")
    }

    @Test func theLitShareOfTheDiscEqualsWhatIsLeft() throws {
        // AC-19.10: the lit share of its body equals the percent left.
        for kind in [HeaderBody.agent(.codex), .agent(.claude)] {
            let full = try render(kind, lit: 1)
            #expect(nightShare(full, against: full) == 0)
            for share in [0.85, 0.62, 0.5, 0.23, 0.05] {
                let measured = nightShare(try render(kind, lit: share), against: full)
                #expect(abs(measured - (1 - share)) < 0.04, "\(kind) at \(share): night \(measured)")
            }
        }
    }

    @Test func theLitSideFacesTheSunOnEitherSide() throws {
        // Right of the Sun the lit side is the leading one; mirrored, for a body left of the Sun, it is the trailing one.
        let leading = CGRect(x: center.x - radius * 0.8, y: center.y - 6, width: radius * 0.5, height: 12)
        let trailing = CGRect(x: center.x + radius * 0.3, y: center.y - 6, width: radius * 0.5, height: 12)
        for kind in [HeaderBody.agent(.codex), .agent(.claude)] {
            let plain = try render(kind, lit: 0.5), mirrored = try render(kind, lit: 0.5, mirrored: true)
            #expect(plain.luminance(in: leading) > 1.6 * plain.luminance(in: trailing), "\(kind)")
            #expect(mirrored.luminance(in: trailing) > 1.6 * mirrored.luminance(in: leading), "\(kind)")
        }
        // Mirroring turns the whole drawing, surface included, not only the night.
        let plain = try render(.agent(.claude), lit: 1), mirrored = try render(.agent(.claude), lit: 1, mirrored: true)
        var differing = 0
        for y in stride(from: 8, to: plain.height - 8, by: 4) {
            for x in stride(from: 8, to: plain.width - 8, by: 4) {
                let a = plain.at(x, y), b = mirrored.at(plain.width - 1 - x, y)
                if abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) > 36 { differing += 1 }
            }
        }
        #expect(differing == 0)
    }

    @Test func anUnknownShareDrawsNoNightAndTheSunIsAlwaysWhole() throws {
        // The caller dims and rings a body whose limit is unknown; the art itself shows no invented night (AC-04.03).
        func same(_ a: HeaderArtBitmap, _ b: HeaderArtBitmap) -> Bool { a.matches(b) }
        #expect(same(try render(.agent(.codex), lit: nil), try render(.agent(.codex), lit: 1)))
        #expect(!same(try render(.agent(.codex), lit: nil), try render(.agent(.codex), lit: 0.6)))
        #expect(same(try render(.all, lit: 0.1), try render(.all, lit: nil)))
        #expect(same(try render(.all, lit: nil, mirrored: true), try render(.all, lit: nil)))
    }

    @Test func theArtFillsItsFrameAtEverySizeTheHeaderUses() throws {
        for side in [18, 26, 44, 64, 72] as [CGFloat] {
            for kind in [HeaderBody.all, .agent(.codex), .agent(.claude)] {
                let image = try render(kind, lit: 0.7, side: side)
                #expect(image.width == Int(side * 2) && image.height == Int(side * 2))
                let half = side / 2, disc = half * (kind == .all ? HeaderBodyArt.sunRadius : HeaderBodyArt.discRadius) / (HeaderBodyArt.box / 2)
                #expect(image.at(point: CGPoint(x: half, y: half)).a == 255, "\(kind) \(side)")
                #expect(image.at(point: CGPoint(x: half - disc * 0.86, y: half)).a == 255, "\(kind) \(side)")
                #expect(image.at(point: CGPoint(x: half, y: half + disc * 0.86)).a == 255, "\(kind) \(side)")
                // Past the disc only its glow remains: a planet's halo is faint, the Sun's is strong and fades by the corner.
                if kind == .all {
                    #expect(image.at(point: CGPoint(x: 0.5, y: 0.5)).a < 140, "\(kind) \(side)")
                } else {
                    #expect(image.at(point: CGPoint(x: half + disc * 0.74, y: half - disc * 0.74)).a < 160, "\(kind) \(side)")
                    #expect(image.at(point: CGPoint(x: 0.5, y: 0.5)).a < 8, "\(kind) \(side)")
                }
            }
        }
    }

    /// Opt-in: writes the bodies at the header's two sizes for every share, plain and mirrored, to the directory that
    /// `LUNLET_ART_DIR` names, for a visual review. Nothing is asserted and nothing is committed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_ART_DIR"] != nil))
    func renderTheBodiesForReview() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LUNLET_ART_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shares: [Double?] = [nil, 1, 0.85, 0.62, 0.23, 0.05]
        let kinds: [HeaderBody] = [.agent(.codex), .agent(.claude), .all]
        let sheet = VStack(alignment: .leading, spacing: 14) {
            ForEach([64, 26] as [CGFloat], id: \.self) { side in
                ForEach(0..<kinds.count, id: \.self) { row in
                    HStack(spacing: 18) {
                        ForEach(0..<shares.count, id: \.self) { column in
                            HeaderBodyArt(kinds[row], lit: shares[column]).frame(width: side, height: side)
                        }
                        HeaderBodyArt(kinds[row], lit: 0.62, mirrored: true).frame(width: side, height: side)
                        HeaderBodyArt(kinds[row], lit: 0.23, mirrored: true).frame(width: side, height: side)
                    }
                }
            }
        }
        .padding(24)
        .background(Color(.sRGB, red: 0.03, green: 0.03, blue: 0.08, opacity: 1))
        let size = CGSize(width: 24 * 2 + 8 * 64 + 7 * 18, height: 24 * 2 + 3 * 64 + 3 * 26 + 5 * 14)
        try HeaderArtBitmap(sheet, size: size, scale: 2).png().write(to: directory.appendingPathComponent("bodies.png"))
    }
}
