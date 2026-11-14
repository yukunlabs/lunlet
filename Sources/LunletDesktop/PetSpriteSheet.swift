// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-40, AC-40.03, AC-40.04, AC-40.05, AC-40.06; US-39, AC-39.02, AC-39.04.
import AppKit
import LunletCore
import SwiftUI

/// A pack's decoded sheet: cells cut on demand, each with an alpha mask for the hit test and its opaque bounds.
@MainActor final class PetSpriteSheet {
    nonisolated let pack: PetPack
    let image: CGImage
    private var cells: [Int: CGImage] = [:]
    private var masks: [Int: [UInt8]] = [:]
    private var opaque: [Int: CGRect?] = [:]
    nonisolated static let cellWidth = PetSpriteLayout.cellWidth, cellHeight = PetSpriteLayout.cellHeight
    nonisolated static let opaqueThreshold: UInt8 = 24

    init(pack: PetPack, image: CGImage) { self.pack = pack; self.image = image }
    nonisolated var version: PetSpriteVersion { pack.version }

    private func key(_ frame: PetSpriteFrame) -> Int { frame.row * PetSpriteLayout.columns + frame.column }
    /// The cell's pixels, sharing the sheet's storage; nil outside the sheet.
    func cell(_ frame: PetSpriteFrame) -> CGImage? {
        guard frame.row >= 0, frame.row < version.rows, frame.column >= 0, frame.column < PetSpriteLayout.columns else { return nil }
        if let cached = cells[key(frame)] { return cached }
        let rect = CGRect(x: frame.column * Self.cellWidth, y: frame.row * Self.cellHeight, width: Self.cellWidth, height: Self.cellHeight)
        guard let cut = image.cropping(to: rect) else { return nil }
        cells[key(frame)] = cut
        return cut
    }
    /// One alpha byte per pixel, rows from the top of the cell.
    func mask(_ frame: PetSpriteFrame) -> [UInt8]? {
        if let cached = masks[key(frame)] { return cached }
        guard let cell = cell(frame) else { return nil }
        let width = Self.cellWidth, height = Self.cellHeight
        var data = [UInt8](repeating: 0, count: width * height)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            // A bitmap context stores its first scanline at the top, where the image's first row lands.
            context.draw(cell, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        masks[key(frame)] = data
        return data
    }
    /// Whether the cell is opaque at a pixel, `y` down from the cell's top (AC-40.06).
    func isOpaque(_ frame: PetSpriteFrame, x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < Self.cellWidth, y < Self.cellHeight, let mask = mask(frame) else { return false }
        return mask[y * Self.cellWidth + x] >= Self.opaqueThreshold
    }
    /// The opaque pixels' bounds in cell coordinates, y down; nil for an empty cell.
    func opaqueBounds(_ frame: PetSpriteFrame) -> CGRect? {
        if let cached = opaque[key(frame)] { return cached }
        guard let mask = mask(frame) else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<Self.cellHeight {
            let row = y * Self.cellWidth
            for x in 0..<Self.cellWidth where mask[row + x] >= Self.opaqueThreshold {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        let bounds: CGRect? = maxX >= 0 ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : nil
        opaque[key(frame)] = bounds
        return bounds
    }
}

/// Draws a pack's pet in the pet window: the cell the frame rule picks, with Lunlet's bubble and sleep marks
/// above it (AC-40.03, AC-40.05).
@MainActor enum PetSpriteDrawing {
    /// Room above the cell for the bubble; the cell fills the rest of the window's height.
    nonisolated static let bubbleRoom: CGFloat = 44
    /// The drawing's units relative to the dog's design space, so bubbles match the dog's.
    nonisolated static let unit: CGFloat = 0.8

    /// The cell's rectangle in a view of `size`, y down: as tall as the room allows, centered, on the bottom edge.
    nonisolated static func cellRect(in size: CGSize) -> CGRect {
        let scale = max(0.01, min((size.height - bubbleRoom) / CGFloat(PetSpriteSheet.cellHeight), size.width / CGFloat(PetSpriteSheet.cellWidth)))
        let width = CGFloat(PetSpriteSheet.cellWidth) * scale, height = CGFloat(PetSpriteSheet.cellHeight) * scale
        return CGRect(x: (size.width - width) / 2, y: size.height - height, width: width, height: height)
    }
    nonisolated static func cue(from input: PetMotionInput, version: PetSpriteVersion) -> PetSpriteCue {
        PetSpriteCue(pose: input.pose, poseChangedAt: input.poseChangedAt, jumpedAt: input.impulseAt, drag: input.drag,
                     dragStartedAt: input.dragStartedAt, lookX: input.gaze.map { Double($0.x) }, lookY: input.gaze.map { Double($0.y) },
                     hasLookRows: version.hasLookRows)
    }
    nonisolated static func frame(at time: TimeInterval?, input: PetMotionInput, version: PetSpriteVersion) -> PetSpriteFrame {
        PetSpriteRule.frame(at: time ?? input.poseChangedAt, cue: cue(from: input, version: version), reduceMotion: time == nil)
    }
    /// The top center of the pet's opaque pixels in its resting frame, in view points, y down: what the panel's
    /// tail points at and where the bubble and sleep marks hang.
    static func topCenter(in size: CGSize, sheet: PetSpriteSheet) -> CGPoint {
        let rect = cellRect(in: size)
        guard let bounds = sheet.opaqueBounds(PetSpriteFrame(row: 0, column: 0)) else { return CGPoint(x: rect.midX, y: rect.minY) }
        let scale = rect.width / CGFloat(PetSpriteSheet.cellWidth)
        return CGPoint(x: rect.minX + bounds.midX * scale, y: rect.minY + bounds.minY * scale)
    }
    /// The bubble's tail tip, up and to the right of the top center.
    static func bubbleTip(in size: CGSize, sheet: PetSpriteSheet) -> CGPoint {
        let top = topCenter(in: size, sheet: sheet)
        return CGPoint(x: top.x + 14, y: top.y - 2)
    }
    static func bubbleRect(in size: CGSize, sheet: PetSpriteSheet) -> CGRect {
        let tip = bubbleTip(in: size, sheet: sheet)
        return CGRect(x: tip.x - 8 * unit, y: tip.y - 44 * unit, width: 44 * unit, height: 46 * unit)
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, state: PetState, sheet: PetSpriteSheet,
                     input: PetMotionInput, time: TimeInterval?) {
        var c = context
        let live = time != nil, t = time ?? input.poseChangedAt + PetMotion.transitionDuration
        let frame = frame(at: time, input: input, version: sheet.version)
        let rect = cellRect(in: size)
        if let cell = sheet.cell(frame) { c.draw(Image(decorative: cell, scale: 1), in: rect) }
        let tip = bubbleTip(in: size, sheet: sheet)
        c.translateBy(x: tip.x, y: tip.y); c.scaleBy(x: unit, y: unit); c.translateBy(x: -tip.x, y: -tip.y)
        if let glyph = input.pose.bubble, !input.panelOpen {
            let scale = CGFloat(live ? PetMotion.bubbleScale(at: t, since: input.poseChangedAt) : 1)
            PetDrawing.drawBubble(in: &c, tip: tip, glyph: glyph, scale: scale, ink: PetPalette.ink)
        }
        if input.pose == .asleep {
            PetDrawing.drawSleep(in: &c, origin: CGPoint(x: tip.x + 8, y: tip.y - 10), time: live ? t : nil, ink: PetPalette.ink)
        }
    }
}
