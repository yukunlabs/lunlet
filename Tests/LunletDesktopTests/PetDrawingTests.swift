// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-39, AC-39.04, AC-39.06, AC-39.08; US-40, AC-40.05.
import AppKit
import SwiftUI
import Testing
import LunletCore
@testable import LunletDesktop

/// The dog sampled pixel by pixel in its 220 × 190 design space: the lantern glow, the bubble glyphs and the sleep
/// marks, which every frame draws as shapes rather than laid-out text.
@MainActor struct PetDrawingTests {
    private struct Bitmap {
        typealias Pixel = (r: Int, g: Int, b: Int, a: Int)
        let width: Int, height: Int, pixels: [UInt8]
        func at(_ x: Int, _ y: Int) -> Pixel {
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
        }
        func count(x: ClosedRange<Int>, y: ClosedRange<Int>, where predicate: (Pixel) -> Bool) -> Int {
            var found = 0
            for row in y { for column in x where predicate(at(column, row)) { found += 1 } }
            return found
        }
    }
    private static func dark(_ p: Bitmap.Pixel) -> Bool { p.a > 128 && p.r + p.g + p.b < 300 }
    private static func green(_ p: Bitmap.Pixel) -> Bool { p.a > 128 && p.g > p.r + 30 && p.g > p.b + 30 }

    private func render(_ pose: PetPose, coat: PetCoat = .golden) throws -> Bitmap {
        let palette = PetPalette.make(coat: coat, accent: AllowanceColor(hex: 0xC83F49))
        let state = PetState(pose: pose, sessionID: nil, sessionCount: 1, waitingCount: 0, runningCount: 0, summary: nil)
        let clock = PetFrameClock()
        var input = PetMotionInput(); input.pose = pose; clock.input = input
        let view = PetCanvasView(state: state, appearance: .dog(palette), clock: clock)
        let renderer = ImageRenderer(content: view.frame(width: PetDrawing.designSize.width, height: PetDrawing.designSize.height))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // The first scanline is the top of the image, so a row is a design-space y.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        return Bitmap(width: width, height: height, pixels: pixels)
    }

    @Test func theLanternGlowWarmsTheCoatWhileWorkingAndIsOffAsleep() throws {
        // On the slate coat a warm glow beside the lantern turns red above blue; the plain coat stays the other way.
        let working = try render(.working, coat: .slate).at(119, 135)
        #expect(working.r > working.b, "\(working)")
        let asleep = try render(.asleep, coat: .slate).at(113, 163)
        #expect(asleep.b > asleep.r, "\(asleep)")
    }

    @Test func theBubbleShowsAQuestionMarkWhileWaitingAndACheckWhenDone() throws {
        let waiting = try render(.waiting), done = try render(.done)
        #expect(waiting.count(x: 144...176, y: 6...32, where: Self.dark) > 15)
        #expect(waiting.count(x: 144...176, y: 6...32, where: Self.green) == 0)
        #expect(done.count(x: 144...176, y: 6...32, where: Self.green) > 15)
        #expect(try render(.idle).count(x: 140...180, y: 2...36, where: Self.dark) == 0)
    }

    @Test func sleepMarksRiseBesideTheSleepingHeadOnly() throws {
        #expect(try render(.asleep).count(x: 150...190, y: 15...90, where: Self.dark) > 10)
        #expect(try render(.idle).count(x: 150...190, y: 15...90, where: Self.dark) == 0)
    }
}
