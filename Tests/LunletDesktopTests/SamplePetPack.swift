// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-40, AC-40.02, AC-40.03.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Mochi, a round cream cat drawn in code as a v2 pack in Codex's format: the sample pack the pet render test
/// draws and the one offered to try the import with. Nothing here is copied from another pet.
enum SamplePetPack {
    static let cellW = 192, cellH = 208, columns = 8, rows = 11

    /// Writes `pet.json` and `spritesheet.png` into `folder` (created if needed) and returns the sheet's size.
    @discardableResult
    static func write(to folder: URL) throws -> (width: Int, height: Int) {
        let width = cellW * columns, height = cellH * rows
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.featureUnsupported)
        }
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)   // y down, rows from the top
        ctx.setShouldAntialias(true)
        func cell(_ row: Int, _ col: Int) -> CGPoint { CGPoint(x: CGFloat(col * cellW), y: CGFloat(row * cellH)) }
        let cream = CGColor(red: 0.98, green: 0.93, blue: 0.84, alpha: 1)
        let creamDark = CGColor(red: 0.89, green: 0.80, blue: 0.66, alpha: 1)
        let ink = CGColor(red: 0.20, green: 0.16, blue: 0.14, alpha: 1)
        let blush = CGColor(red: 0.96, green: 0.62, blue: 0.66, alpha: 0.8)
        let nose = CGColor(red: 0.93, green: 0.55, blue: 0.58, alpha: 1)
        let accent = CGColor(red: 0.78, green: 0.25, blue: 0.29, alpha: 1)

        struct Pose {
            var dy: CGFloat = 0, dx: CGFloat = 0, lean: CGFloat = 0, squash: CGFloat = 1
            var earDrop: CGFloat = 0, blink: CGFloat = 0, pupil = CGPoint.zero, mouth: CGFloat = 0.5  // mouth 0 sad…1 smile
            var pawUp: CGFloat = 0, pawSide: CGFloat = 1, tail: CGFloat = 0, eyeNarrow: CGFloat = 0, brow: CGFloat = 0, sweat = false, lines = false, chin = false, closedEyes = false
            var tilt: CGFloat = 0
        }

        func ellipse(_ c: CGContext, _ r: CGRect, _ color: CGColor) { c.setFillColor(color); c.fillEllipse(in: r) }

        func draw(_ p: Pose, at origin: CGPoint, in c: CGContext) {
            c.saveGState()
            c.translateBy(x: origin.x + 96 + p.dx, y: origin.y + 128 + p.dy)
            c.rotate(by: p.lean + p.tilt)
            c.scaleBy(x: 1 / p.squash, y: p.squash)
            // tail
            c.setStrokeColor(creamDark); c.setLineWidth(14); c.setLineCap(.round)
            c.move(to: CGPoint(x: 50, y: 30)); c.addQuadCurve(to: CGPoint(x: 84 + p.tail * 10, y: -10 - p.tail * 18), control: CGPoint(x: 90, y: 34))
            c.strokePath()
            // ears
            c.setFillColor(cream)
            for side in [-1.0, 1.0] {
                let bx = CGFloat(side) * 42, tipY: CGFloat = -92 + p.earDrop * 22, tipX = bx + CGFloat(side) * (6 - p.earDrop * 10)
                c.move(to: CGPoint(x: bx - 22, y: -48)); c.addLine(to: CGPoint(x: tipX, y: tipY)); c.addLine(to: CGPoint(x: bx + 22, y: -48)); c.closePath(); c.fillPath()
                c.setFillColor(blush)
                c.move(to: CGPoint(x: bx - 10, y: -52)); c.addLine(to: CGPoint(x: tipX, y: tipY + 14)); c.addLine(to: CGPoint(x: bx + 10, y: -52)); c.closePath(); c.fillPath()
                c.setFillColor(cream)
            }
            // body
            ellipse(c, CGRect(x: -66, y: -66, width: 132, height: 140), cream)
            ellipse(c, CGRect(x: -30, y: 10, width: 60, height: 50), CGColor(red: 1, green: 0.98, blue: 0.95, alpha: 1))
            // feet
            ellipse(c, CGRect(x: -44 + (p.lines ? 6 : 0), y: 58, width: 34, height: 18), creamDark)
            ellipse(c, CGRect(x: 10 - (p.lines ? 6 : 0), y: 58, width: 34, height: 18), creamDark)
            // paw (waving) / chin
            if p.pawUp > 0 {
                c.saveGState(); c.translateBy(x: 58 * p.pawSide, y: 12); c.rotate(by: -p.pawUp * p.pawSide)
                ellipse(c, CGRect(x: -12, y: -40, width: 24, height: 48), cream); ellipse(c, CGRect(x: -11, y: -44, width: 22, height: 20), creamDark); c.restoreGState()
            }
            if p.chin { ellipse(c, CGRect(x: 10, y: 2, width: 26, height: 22), creamDark) }
            // blush
            ellipse(c, CGRect(x: -52, y: -6, width: 18, height: 10), blush); ellipse(c, CGRect(x: 34, y: -6, width: 18, height: 10), blush)
            // eyes
            for side in [-1.0, 1.0] {
                let ex = CGFloat(side) * 24, ey: CGFloat = -18
                if p.closedEyes {
                    c.setStrokeColor(ink); c.setLineWidth(4); c.move(to: CGPoint(x: ex - 9, y: ey + 2)); c.addLine(to: CGPoint(x: ex + 9, y: ey - 4)); c.strokePath()
                    c.move(to: CGPoint(x: ex - 9, y: ey - 4)); c.addLine(to: CGPoint(x: ex + 9, y: ey + 2)); c.strokePath()
                    continue
                }
                let open = (1 - p.blink) * (1 - 0.55 * p.eyeNarrow)
                let h = max(2, 22 * open)
                ellipse(c, CGRect(x: ex - 11, y: ey - h / 2, width: 22, height: h), ink)
                if open > 0.4 { ellipse(c, CGRect(x: ex - 4 + p.pupil.x * 5, y: ey - h / 2 + 3 + p.pupil.y * 4, width: 6, height: 6), CGColor(red: 1, green: 1, blue: 1, alpha: 1)) }
                if p.brow != 0 {
                    c.setStrokeColor(ink); c.setLineWidth(3); c.move(to: CGPoint(x: ex - 10, y: ey - 20 - p.brow * 4 * CGFloat(side)))
                    c.addLine(to: CGPoint(x: ex + 10, y: ey - 20 + p.brow * 4 * CGFloat(side))); c.strokePath()
                }
            }
            // nose and mouth
            ellipse(c, CGRect(x: -5, y: 0, width: 10, height: 7), nose)
            c.setStrokeColor(ink); c.setLineWidth(3)
            let m = p.mouth
            c.move(to: CGPoint(x: -12, y: 12)); c.addQuadCurve(to: CGPoint(x: 0, y: 10 + m * 6), control: CGPoint(x: -6, y: 6 + m * 14))
            c.addQuadCurve(to: CGPoint(x: 12, y: 12), control: CGPoint(x: 6, y: 6 + m * 14)); c.strokePath()
            // collar
            c.setFillColor(accent); c.fill(CGRect(x: -36, y: 40, width: 72, height: 9).insetBy(dx: 0, dy: 0))
            ellipse(c, CGRect(x: -6, y: 46, width: 12, height: 12), CGColor(red: 0.97, green: 0.78, blue: 0.32, alpha: 1))
            if p.sweat { ellipse(c, CGRect(x: 58, y: -50, width: 10, height: 16), CGColor(red: 0.55, green: 0.75, blue: 0.95, alpha: 0.9)) }
            if p.lines {
                c.setStrokeColor(creamDark); c.setLineWidth(4)
                for i in 0..<3 { c.move(to: CGPoint(x: -96 * p.pawSide, y: -10 + CGFloat(i) * 14)); c.addLine(to: CGPoint(x: -72 * p.pawSide, y: -10 + CGFloat(i) * 14)); c.strokePath() }
            }
            c.restoreGState()
        }

        // Row 0 idle: breathing bob with a blink on the fifth frame.
        let idleDY: [CGFloat] = [0, -2, -4, -2, 0, 1]
        for (i, dy) in idleDY.enumerated() { var p = Pose(); p.dy = dy; p.blink = i == 4 ? 1 : 0; p.squash = 1 + (i == 2 ? 0.02 : 0); draw(p, at: cell(0, i), in: ctx) }
        // Row 1 running-right, row 2 running-left: lean, feet shuffle, speed lines.
        for i in 0..<8 {
            var p = Pose(); p.lean = 0.18; p.dy = [0, -6, -10, -6, 0, -4, -8, -4][i]; p.lines = i % 2 == 0; p.pawSide = 1; p.mouth = 0.8; p.tail = 0.6
            draw(p, at: cell(1, i), in: ctx)
            var q = p; q.lean = -0.18; q.pawSide = -1
            draw(q, at: cell(2, i), in: ctx)
        }
        // Row 3 waving.
        for (i, angle) in [0.3, 0.9, 1.2, 0.6].enumerated() { var p = Pose(); p.pawUp = CGFloat(angle); p.mouth = 1; p.tail = 0.4; draw(p, at: cell(3, i), in: ctx) }
        // Row 4 jumping.
        let jump: [(CGFloat, CGFloat)] = [(0, 0.9), (-22, 1.06), (-40, 1.08), (-22, 1.04), (0, 0.94)]
        for (i, j) in jump.enumerated() { var p = Pose(); p.dy = j.0; p.squash = j.1; p.mouth = 1; p.tail = 1; draw(p, at: cell(4, i), in: ctx) }
        // Row 5 failed: drooping ears, crossed eyes, a sway.
        for i in 0..<8 { var p = Pose(); p.earDrop = 1; p.closedEyes = true; p.mouth = 0; p.dy = 4; p.lean = CGFloat(sin(Double(i) / 8 * 2 * .pi)) * 0.05; p.sweat = i < 4; draw(p, at: cell(5, i), in: ctx) }
        // Row 6 waiting: head tilt, raised brows, wide eyes.
        for i in 0..<6 { var p = Pose(); p.tilt = 0.12 + CGFloat(sin(Double(i) / 6 * 2 * .pi)) * 0.05; p.brow = 1; p.mouth = 0.3; p.pupil = CGPoint(x: 0.6, y: -0.3); p.tail = CGFloat(i % 2) * 0.5; draw(p, at: cell(6, i), in: ctx) }
        // Row 7 running (working): focused eyes, quick bounce, a sweat drop.
        for i in 0..<6 { var p = Pose(); p.eyeNarrow = 1; p.dy = [0, -5, -8, -5, 0, -2][i]; p.sweat = true; p.mouth = 0.6; p.tail = CGFloat(i % 2); draw(p, at: cell(7, i), in: ctx) }
        // Row 8 review: nod with a paw on the chin.
        for i in 0..<6 { var p = Pose(); p.chin = true; p.eyeNarrow = 0.5; p.tilt = -0.06; p.dy = [0, 2, 4, 2, 0, -1][i]; p.pupil = CGPoint(x: -0.3, y: 0.5); draw(p, at: cell(8, i), in: ctx) }
        // Rows 9 and 10: sixteen look directions clockwise from up.
        for index in 0..<16 {
            let angle = Double(index) * 22.5 * .pi / 180
            var p = Pose(); p.pupil = CGPoint(x: CGFloat(sin(angle)), y: CGFloat(-cos(angle))); p.dx = CGFloat(sin(angle)) * 4; p.tilt = CGFloat(sin(angle)) * 0.06; p.mouth = 0.6
            draw(p, at: cell(9 + index / 8, index % 8), in: ctx)
        }

        guard let image = ctx.makeImage(),
              let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent("spritesheet.png") as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        let manifest = """
        {
          "id": "mochi",
          "displayName": "Mochi",
          "description": "A round cream cat, Lunlet's sample pet pack.",
          "spriteVersionNumber": 2,
          "spritesheetPath": "spritesheet.png"
        }

        """
        try manifest.write(to: folder.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)
        return (image.width, image.height)
    }
}
