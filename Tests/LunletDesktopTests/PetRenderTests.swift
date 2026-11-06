// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-39, AC-39.03, AC-39.05, AC-39.06; US-40, AC-40.03, AC-40.05.
import AppKit
import SwiftUI
import Testing
import LunletCore
@testable import LunletDesktop

/// Opt-in offscreen renders of the dog in every pose and coat, and of the panel growing out of it as its bubble,
/// for review before an on-device check. Set `LUNLET_RENDER_DIR` to a directory outside the repository.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUNLET_RENDER_DIR"] != nil))
@MainActor struct PetRenderTests {
    private static let accent = AllowanceColor(hex: 0xC83F49)

    @Test func renderPosesCoatsAndTheBubble() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LUNLET_RENDER_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = PetEntryController.windowSize
        // Every pose in every coat, settled, on a neutral desktop tone.
        let sheet = NSImage(size: CGSize(width: size.width * 5, height: size.height * 3), flipped: false) { _ in
            NSColor(white: 0.82, alpha: 1).setFill(); CGRect(origin: .zero, size: CGSize(width: size.width * 5, height: size.height * 3)).fill()
            for (row, coat) in PetCoat.allCases.enumerated() {
                for (column, pose) in PetPose.allCases.enumerated() {
                    let origin = CGPoint(x: CGFloat(column) * size.width, y: CGFloat(2 - row) * size.height)
                    Self.drawDog(pose: pose, coat: coat, at: origin, size: size, panelOpen: false)
                }
            }
            return true
        }
        try Self.write(sheet, to: directory.appendingPathComponent("pet-poses.png"))
        // The bubble above the dog growing from its head, and below it, at three points of the expansion.
        for (name, edge) in [("above", BubbleTail.Edge.bottom), ("below", .top)] {
            let canvas = CGSize(width: 520, height: 560)
            let image = NSImage(size: canvas, flipped: false) { _ in
                NSColor(white: 0.82, alpha: 1).setFill(); CGRect(origin: .zero, size: canvas).fill()
                let dogOrigin = CGPoint(x: (canvas.width - size.width) / 2, y: edge == .bottom ? 24 : canvas.height - size.height - 24)
                // The drawing's head center is y-down; the image is y-up.
                let head = PetDrawing.headCenter(pose: .waiting, in: size)
                let headFrame = CGRect(x: dogOrigin.x + head.x - 32, y: dogOrigin.y + size.height - head.y - 32, width: 64, height: 64)
                let anchor = CGRect(x: headFrame.minX, y: dogOrigin.y, width: headFrame.width, height: headFrame.maxY - dogOrigin.y)
                let screen = PanelScreen(frame: CGRect(origin: .zero, size: canvas), visibleFrame: CGRect(origin: .zero, size: canvas), safeTop: 0)
                var panel = PanelPlacement.panel(near: anchor, tabRow: false, screen: screen)
                panel.size.height = min(panel.height, 380)
                if edge == .top { panel.origin.y = anchor.minY - PanelPlacement.bubbleGap - panel.height }
                let tail = PanelPlacement.tail(panel: panel, anchor: anchor)
                for (index, progress) in [0.3, 0.65, 1.0].enumerated() {
                    let path = NotchSurfaceGeometry.bubble(size: panel.size, tail: tail, progress: CGFloat(progress))
                    var move = CGAffineTransform(translationX: panel.minX, y: panel.minY)
                    let placed = path.copy(using: &move) ?? path
                    NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.98, alpha: index == 2 ? 0.96 : 0.35).setFill()
                    NSBezierPath(cgPath: placed).fill()
                    NSColor(white: 0.55, alpha: index == 2 ? 0.9 : 0.4).setStroke()
                    let outline = NSBezierPath(cgPath: placed); outline.lineWidth = 1; outline.stroke()
                }
                Self.drawDog(pose: .waiting, coat: .golden, at: dogOrigin, size: size, panelOpen: true)
                return true
            }
            try Self.write(image, to: directory.appendingPathComponent("pet-bubble-\(name).png"))
        }
    }

    /// The sample pack Mochi, written as `mochi/` in the render directory, in every pose beside the dog (US-40).
    @Test func renderTheSamplePackInEveryPose() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LUNLET_RENDER_DIR"]))
        let folder = directory.appendingPathComponent("mochi", isDirectory: true)
        let size = try SamplePetPack.write(to: folder)
        #expect(size.width == 1536 && size.height == 2288)
        let library = PetPackLibrary(lunletDirectory: directory, codexDirectory: directory.appendingPathComponent("none"))
        let entry = try #require(library.entry(for: PetPackReference(source: .lunlet, folder: "mochi")))
        let pack = try #require(entry.pack, "\(String(describing: entry.failure))")
        let sheet = try #require(await library.loadSheet(for: pack))
        let window = PetEntryController.windowSize
        let image = NSImage(size: CGSize(width: window.width * 5, height: window.height * 2), flipped: false) { _ in
            NSColor(white: 0.82, alpha: 1).setFill(); CGRect(origin: .zero, size: CGSize(width: window.width * 5, height: window.height * 2)).fill()
            for (column, pose) in PetPose.allCases.enumerated() {
                Self.drawDog(pose: pose, coat: .golden, at: CGPoint(x: CGFloat(column) * window.width, y: window.height), size: window, panelOpen: false)
                let state = PetState(pose: pose, sessionID: nil, sessionCount: 1, waitingCount: 0, runningCount: 0, summary: nil)
                var input = PetMotionInput(); input.pose = pose
                let tempo = PetTempo(); tempo.input = input; tempo.sprite = sheet.version
                let view = PetCanvasView(state: state, appearance: .sprite(sheet), tempo: tempo, animating: false)
                let renderer = ImageRenderer(content: view.frame(width: window.width, height: window.height))
                renderer.scale = 2
                renderer.nsImage?.draw(in: CGRect(origin: CGPoint(x: CGFloat(column) * window.width, y: 0), size: window))
            }
            return true
        }
        try Self.write(image, to: directory.appendingPathComponent("pet-pack-poses.png"))
    }

    private static func drawDog(pose: PetPose, coat: PetCoat, at origin: CGPoint, size: CGSize, panelOpen: Bool) {
        let palette = PetPalette.make(coat: coat, accent: accent)
        let state = PetState(pose: pose, sessionID: nil, sessionCount: 1, waitingCount: 0, runningCount: 0, summary: nil)
        var input = PetMotionInput(); input.pose = pose; input.panelOpen = panelOpen
        if panelOpen { input.gaze = CGPoint(x: 0, y: -0.8) }
        let tempo = PetTempo(); tempo.input = input
        let view = PetCanvasView(state: state, appearance: .dog(palette), tempo: tempo, animating: false)
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return }
        image.draw(in: CGRect(origin: origin, size: size))
    }
    private static func write(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: url)
    }
}
