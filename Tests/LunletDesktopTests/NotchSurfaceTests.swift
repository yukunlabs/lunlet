// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-03, AC-03.05, AC-03.10, AC-03.11; US-13, AC-13.06, AC-13.07, AC-13.08; US-24, AC-24.02.
import AppKit
import SwiftUI
import Testing
import LunletCore
@testable import LunletDesktop

struct NotchSurfaceTests {
    @Test func asymmetricCueRetractionStaysAlignedWithHardwareNotch() {
        let path = NotchSurfaceGeometry.path(size: .init(width: 450, height: 44), notchWidth: 185, notchHeight: 32, progress: 0, notchCenter: 200)
        #expect(path.boundingBoxOfPath.midX == 200)
        #expect(path.boundingBoxOfPath.width == 185)
    }
    @Test func openSurfaceEnclosesTheNotchAndExpandsToBothSides() {
        let size = CGSize(width: 470, height: 340)
        let path = NotchSurfaceGeometry.path(size: size, notchWidth: 185, notchHeight: 32, progress: 1)
        #expect(path.contains(CGPoint(x: 235, y: 339)))
        #expect(path.contains(CGPoint(x: 40, y: 330)))
        #expect(path.contains(CGPoint(x: 430, y: 330)))
        #expect(path.contains(CGPoint(x: 20, y: 280)))
        #expect(path.contains(CGPoint(x: 450, y: 280)))
        #expect(path.boundingBoxOfPath == CGRect(origin: .zero, size: size))
    }
    @Test func retractedSurfaceStaysAtTheTopAndNeverFillsTheCardArea() {
        let path = NotchSurfaceGeometry.path(size: .init(width: 470, height: 340), notchWidth: 185, notchHeight: 32, progress: 0)
        #expect(path.boundingBoxOfPath.height == 32)
        #expect(path.boundingBoxOfPath.maxY == 340)
        #expect(path.boundingBoxOfPath.midX == 235)
        #expect(path.boundingBoxOfPath.width == 185)
        #expect(path.contains(CGPoint(x: 235, y: 310)))
        #expect(!path.contains(CGPoint(x: 235, y: 200)))
        #expect(path.contains(CGPoint(x: 143, y: 339)))
        #expect(path.contains(CGPoint(x: 327, y: 339)))
        #expect(path.contains(CGPoint(x: 143, y: 309)))
        #expect(path.contains(CGPoint(x: 327, y: 309)))
    }
    @Test func collapsedGeometryUsesEachReportedDeviceSizeWithoutExteriorPadding() {
        for notch in [CGSize(width: 160, height: 26), CGSize(width: 185, height: 32), CGSize(width: 230, height: 40)] {
            let path = NotchSurfaceGeometry.path(size: .init(width: 470, height: 340),
                notchWidth: notch.width, notchHeight: notch.height, progress: 0)
            #expect(path.boundingBoxOfPath.size == notch)
            #expect(path.boundingBoxOfPath.midX == 235)
            #expect(path.boundingBoxOfPath.maxY == 340)
        }
    }
    @Test @MainActor func collapsedSurfaceDoesNotPaintAnIdleFrostedRectangle() {
        let surface = NotchSurfaceView(content: AnyView(EmptyView()))
        surface.frame = .init(x: 0, y: 0, width: 470, height: 340)
        surface.notchWidth = 185; surface.notchHeight = 32
        surface.setExpanded(false, animated: false)
        #expect(surface.subviews.allSatisfy { $0.alphaValue == 0 })
        surface.setExpanded(true, animated: false)
        #expect(surface.subviews.allSatisfy { $0.alphaValue == 1 })
    }
    // AC-03.08: glass leaves the panel's own pixels clear, and the window server hands clicks on clear pixels to the
    // application below; a faint fill inside the silhouette keeps every point of the panel its own, while the outline's
    // mask leaves the room beside the shoulders clear. The cue island is opaque and ignores the pointer.
    @Test @MainActor func everyPointInsideThePanelOutlineKeepsItsClicks() throws {
        let panel = NotchSurfaceView(content: AnyView(EmptyView()))
        let fill = try #require(panel.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        #expect(fill.alphaComponent > 0 && fill.alphaComponent < 0.05 && panel.layer?.mask != nil)
        #expect(NotchSurfaceView(content: AnyView(EmptyView()), style: .island).layer?.backgroundColor == nil)
    }
    // AC-03.11: one silhouette morphs in place, so the panel (with or without a notch) and the cue island keep the
    // same path elements at rest, in between and expanded.
    @Test func everySilhouetteKeepsTheSamePathElementsThroughItsMorph() {
        func types(_ path: CGPath) -> [Int32] {
            var types: [Int32] = []
            path.applyWithBlock { types.append($0.pointee.type.rawValue) }
            return types
        }
        let size = CGSize(width: 490, height: 362)
        let shapes = [0.0, 0.3, 0.7, 1.0].flatMap { progress in [
            NotchSurfaceGeometry.path(size: size, notchWidth: 185, notchHeight: 32, progress: progress),
            NotchSurfaceGeometry.path(size: size, notchWidth: nil, notchHeight: 0, progress: progress),
            NotchSurfaceGeometry.island(size: .init(width: 529, height: 62), notchWidth: 185, notchHeight: 32, progress: progress),
        ] }
        #expect(Set(shapes.map(types)).count == 1)
    }
    // Design direction: the expanded panel is flush with the top edge, flares into the menu bar with
    // concave shoulders and rounds only its bottom corners; at rest it is exactly the reported notch area.
    @Test func expandedPanelHangsFlushFromTheTopEdgeWithShouldersOnlyWhileExpanded() {
        let size = CGSize(width: 490, height: 362), shoulder = NotchSurfaceGeometry.shoulderRadius
        let open = NotchSurfaceGeometry.path(size: size, notchWidth: 185, notchHeight: 32, progress: 1)
        #expect(shoulder == 10 && NotchSurfaceGeometry.cornerRadius == 20)
        #expect(open.boundingBoxOfPath == CGRect(origin: .zero, size: size))
        // Square body corners at the screen edge: no gap beside the menu bar.
        #expect(open.contains(CGPoint(x: shoulder + 0.5, y: 361.5)) && open.contains(CGPoint(x: 479.5, y: 361.5)))
        // Concave shoulders reach outward along the top edge only.
        #expect(open.contains(CGPoint(x: 3, y: 361.8)) && open.contains(CGPoint(x: 487, y: 361.8)))
        #expect(!open.contains(CGPoint(x: 1, y: 355)) && !open.contains(CGPoint(x: 489, y: 355)))
        #expect(!open.contains(CGPoint(x: 5, y: 200)) && !open.contains(CGPoint(x: 485, y: 200)))
        // Rounded bottom corners with the surface radius.
        #expect(!open.contains(CGPoint(x: shoulder + 0.5, y: 0.5)) && !open.contains(CGPoint(x: 479.5, y: 0.5)))
        #expect(open.contains(CGPoint(x: shoulder + 20, y: 0.5)) && open.contains(CGPoint(x: shoulder + 0.5, y: 20)))
        let resting = NotchSurfaceGeometry.path(size: size, notchWidth: 185, notchHeight: 32, progress: 0)
        #expect(resting.boundingBoxOfPath == CGRect(x: 152.5, y: 330, width: 185, height: 32))
        let partway = NotchSurfaceGeometry.path(size: size, notchWidth: 185, notchHeight: 32, progress: 0.5)
        #expect(CGRect(origin: .zero, size: size).contains(partway.boundingBoxOfPath))
    }
    @Test func anExternalDisplayHasNoInventedNeck() {
        let path = NotchSurfaceGeometry.path(size: .init(width: 470, height: 340), notchWidth: nil, notchHeight: 0, progress: 1)
        #expect(path.contains(CGPoint(x: 40, y: 339)))
        #expect(path.contains(CGPoint(x: 430, y: 339)))
    }

    // AC-13.08: the cue island is flush with the top screen edge and rounds only its bottom corners.
    @Test func cueIslandContinuesTheNotchFromTheTopEdge() {
        let size = CGSize(width: 529, height: 62)
        let path = NotchSurfaceGeometry.island(size: size, notchWidth: 185, notchHeight: 32, progress: 1)
        #expect(path.boundingBoxOfPath == CGRect(origin: .zero, size: size))
        #expect(path.contains(CGPoint(x: 0.5, y: 61.5)) && path.contains(CGPoint(x: 528.5, y: 61.5)))
        #expect(!path.contains(CGPoint(x: 1, y: 1)) && !path.contains(CGPoint(x: 528, y: 1)))
        #expect(path.contains(CGPoint(x: 264.5, y: 0.5)) && path.contains(CGPoint(x: 0.5, y: 31)))
    }
    @Test func cueIslandRetractsIntoTheReportedNotchWithCompatibleAnimationPaths() {
        let size = CGSize(width: 529, height: 62)
        let resting = NotchSurfaceGeometry.island(size: size, notchWidth: 185, notchHeight: 32, progress: 0, notchCenter: 250)
        #expect(resting.boundingBoxOfPath.size == CGSize(width: 185, height: 32))
        #expect(resting.boundingBoxOfPath.midX == 250 && resting.boundingBoxOfPath.maxY == 62)
        let elements = [0.0, 0.3, 0.7, 1.0].map { progress in
            var types: [CGPathElementType] = []
            NotchSurfaceGeometry.island(size: size, notchWidth: 185, notchHeight: 32, progress: progress)
                .applyWithBlock { types.append($0.pointee.type) }
            return types.map(\.rawValue)
        }
        #expect(Set(elements).count == 1)
    }
    // AC-13.08: translucent material over the menu bar made the cue blend in.
    @Test @MainActor func cueIslandIsOpaqueBlackWhileThePanelKeepsItsMaterial() throws {
        func black(_ view: NSView) -> Bool {
            guard let cg = view.layer?.backgroundColor, let color = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) else { return false }
            return color.alphaComponent == 1 && color.redComponent == 0 && color.greenComponent == 0 && color.blueComponent == 0
        }
        let panel = NotchSurfaceView(content: AnyView(EmptyView()))
        #expect(panel.style == .panel && panel.subviews.contains { $0 is NSHostingView<PanelMaterial> })
        let cue = TaskCueText(cue: TaskCue(sessionID: "s", connectionID: "c", turnID: "t", title: "lunlet", phase: .started))
        let notch = PanelScreen(frame: .init(x: 0, y: 0, width: 1512, height: 982),
                                visibleFrame: .init(x: 0, y: 0, width: 1512, height: 950), safeTop: 32,
                                notch: .init(x: 663.5, y: 950, width: 185, height: 32))
        let plain = PanelScreen(frame: .init(x: 0, y: 0, width: 1920, height: 1080),
                                visibleFrame: .init(x: 0, y: 0, width: 1920, height: 1056), safeTop: 0)
        for screen in [notch, plain] {
            let frame = PanelPlacement.cue(size: cue.size(screen: screen), screen: screen)
            let island = TransientCuePanel.surface(text: cue, screen: screen, frame: frame)
            #expect(island.style == .island)
            #expect(!island.subviews.contains { $0 is NSHostingView<PanelMaterial> })
            island.setExpanded(true, animated: false)
            let backdrop = try #require(island.subviews.first)
            #expect(black(backdrop) && island.subviews.allSatisfy { $0.alphaValue == 1 })
        }
    }

    // Design direction: plain system material without the notch haze; the content fills the body below
    // the shoulders, including the notch band that holds the header.
    @Test @MainActor func panelSurfaceIsMaterialShapedLikeItsSilhouetteWithoutHaze() throws {
        let surface = NotchSurfaceView(content: AnyView(EmptyView()))
        surface.frame = .init(x: 0, y: 0, width: 490, height: 362)
        surface.notchWidth = 185; surface.notchHeight = 32; surface.notchCenterX = 245
        surface.layoutSubtreeIfNeeded()
        #expect(surface.subviews.count == 2 && surface.subviews.allSatisfy { !($0.layer is CAGradientLayer) })
        let material = try #require(surface.subviews.first as? NSHostingView<PanelMaterial>)
        #expect(material.frame == surface.bounds)
        #expect(material.rootView.outline == NotchSilhouette(notchWidth: 185, notchHeight: 32, notchCenter: 245))
        #expect(surface.bodyFrame == CGRect(x: 10, y: 0, width: 470, height: 362))
        #expect(surface.subviews.last?.frame == surface.bodyFrame)
        // AC-03.10: Reduce Transparency and Increase Contrast make the surface opaque and bordered.
        #expect(!PanelMaterial.opaque(reduceTransparency: false, contrast: .standard))
        #expect(PanelMaterial.opaque(reduceTransparency: true, contrast: .standard))
        #expect(PanelMaterial.opaque(reduceTransparency: false, contrast: .increased))
        // The SwiftUI outline is the same silhouette, flipped into SwiftUI's top-left coordinates.
        let outline = NotchSilhouette(notchWidth: 185, notchHeight: 32).path(in: CGRect(x: 0, y: 0, width: 490, height: 362))
        #expect(outline.boundingRect == CGRect(x: 0, y: 0, width: 490, height: 362))
        #expect(outline.contains(CGPoint(x: 3, y: 0.2)) && !outline.contains(CGPoint(x: 10.5, y: 361.5)))
    }
    // The approved motion: the outline expands on a critically damped spring of about 0.36 s and collapses on a
    // quicker one; Reduce Motion keeps the same geometry without a transition.
    @Test @MainActor func expansionUsesASpringAndReduceMotionHasNoTransition() throws {
        let surface = NotchSurfaceView(content: AnyView(EmptyView()))
        surface.frame = .init(x: 0, y: 0, width: 490, height: 362)
        surface.notchWidth = 185; surface.notchHeight = 32
        let mask = try #require(surface.layer?.mask as? CAShapeLayer)
        surface.setExpanded(true, animated: true)
        let expand = try #require(mask.animation(forKey: "notch-unfold") as? CASpringAnimation)
        #expect(NotchSurfaceView.expandResponse == 0.36 && abs(expand.perceptualDuration - 0.36) < 0.001)
        #expect(expand.duration == NotchSurfaceView.expandDuration && expand.duration == expand.settlingDuration)
        surface.setExpanded(false, animated: true)
        let collapse = try #require(mask.animation(forKey: "notch-unfold") as? CASpringAnimation)
        #expect(collapse.perceptualDuration < expand.perceptualDuration && collapse.bounce == 0)
        // The surface has faded out when the owner orders its window out; the spring's tail settles out of sight.
        let fade = try #require(surface.subviews.first?.layer?.animation(forKey: "material-reveal") as? CABasicAnimation)
        #expect(fade.duration == NotchSurfaceView.collapseDuration && NotchSurfaceView.collapseDuration == collapse.perceptualDuration)
        #expect(NotchSurfaceView.retractionDelay > .milliseconds(Int(fade.duration * 1000)))
        surface.setExpanded(true, animated: false)
        #expect(mask.animationKeys() == nil && surface.subviews.allSatisfy { $0.layer?.animationKeys() == nil })
        #expect(mask.path?.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 490, height: 362))
    }
}
