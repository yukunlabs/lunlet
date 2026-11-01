// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-03, AC-03.05, AC-03.08, AC-03.10, AC-03.11; US-13, AC-13.06, AC-13.07, AC-13.08.
// Refs: US-24, AC-24.02.
import AppKit
import SwiftUI
import QuartzCore

/// Every silhouette is built from one outline with the same elements at rest, expanded and in between,
/// so a surface morphs in place from the reported notch area.
enum NotchSurfaceGeometry {
    /// Bottom corner radius of an expanded surface.
    static let cornerRadius: CGFloat = PanelStyle.Radius.surface
    /// Concave shoulders that blend an expanded panel into the menu bar beside the notch; absent at rest.
    static let shoulderRadius: CGFloat = 10
    /// Control-point distance approximating a quarter circle with one cubic curve.
    private static let kappa: CGFloat = 0.5523

    /// The panel silhouette. Below a notch it hangs from the top screen edge: a flush top, concave shoulders
    /// while expanded and rounded bottom corners, with the body inset by the shoulder radius on both sides.
    /// Without a notch it is a simple rounded panel growing from the top center.
    static func path(size: CGSize, notchWidth: CGFloat?, notchHeight: CGFloat, progress: CGFloat,
                     notchCenter: CGFloat? = nil) -> CGPath {
        let p = min(1, max(0, progress))
        guard let notchWidth else {
            let restingWidth = min(size.width, 160), restingHeight: CGFloat = 0.5
            let width = restingWidth + (size.width - restingWidth) * p
            let height = restingHeight + (size.height - restingHeight) * p
            let minX = (size.width - restingWidth) / 2 * (1 - p)
            let radius = min(cornerRadius, height / 2, width / 2)
            return outline(minX: minX, maxX: minX + width, bottom: size.height - height, top: size.height,
                           shoulder: -radius, bottomRadius: radius)
        }
        let inset = bodyInset(notchWidth: notchWidth)
        let rest = resting(size: size, notchWidth: notchWidth, notchHeight: notchHeight, notchCenter: notchCenter)
        let minX = rest.minX + (inset - rest.minX) * p, maxX = rest.maxX + (size.width - inset - rest.maxX) * p
        let height = rest.height + (size.height - rest.height) * p
        let bottomRadius = min(cornerRadius * p, height / 2, (maxX - minX) / 2)
        return outline(minX: minX, maxX: maxX, bottom: size.height - height, top: size.height,
                       shoulder: min(shoulderRadius * p, inset), bottomRadius: bottomRadius)
    }
    /// A cue island continuing the hardware notch: square top corners flush with the screen edge and rounded
    /// bottom corners, without shoulders, so it reads as the notch itself extending (AC-13.08).
    static func island(size: CGSize, notchWidth: CGFloat, notchHeight: CGFloat, progress: CGFloat,
                       notchCenter: CGFloat? = nil) -> CGPath {
        let p = min(1, max(0, progress))
        let rest = resting(size: size, notchWidth: notchWidth, notchHeight: notchHeight, notchCenter: notchCenter)
        let width = rest.width + (size.width - rest.width) * p, height = rest.height + (size.height - rest.height) * p
        let minX = rest.minX * (1 - p)
        return outline(minX: minX, maxX: minX + width, bottom: size.height - height, top: size.height, shoulder: 0,
                       bottomRadius: min(cornerRadius * p, height / 2, width / 2))
    }
    /// Horizontal room for the shoulders on each side of a panel body below a notch.
    static func bodyInset(notchWidth: CGFloat?) -> CGFloat { notchWidth == nil ? 0 : shoulderRadius }

    private static func resting(size: CGSize, notchWidth: CGFloat, notchHeight: CGFloat, notchCenter: CGFloat?) -> CGRect {
        let width = min(size.width, notchWidth), height = min(size.height, notchHeight)
        return CGRect(x: (notchCenter ?? size.width / 2) - width / 2, y: size.height - height, width: width, height: height)
    }
    /// A positive `shoulder` flares concavely outward along the top edge; a negative one rounds the top corners
    /// convexly; zero leaves them square. The element sequence never changes, so any two outlines animate.
    private static func outline(minX: CGFloat, maxX: CGFloat, bottom: CGFloat, top: CGFloat,
                                shoulder: CGFloat, bottomRadius: CGFloat) -> CGPath {
        let t = abs(shoulder), out: CGFloat = shoulder >= 0 ? 1 : -1, k = t * kappa
        let b = bottomRadius, kb = b * kappa
        let path = CGMutablePath()
        path.move(to: .init(x: minX - out * t, y: top))
        path.addLine(to: .init(x: maxX + out * t, y: top))
        path.addCurve(to: .init(x: maxX, y: top - t), control1: .init(x: maxX + out * (t - k), y: top),
                      control2: .init(x: maxX, y: top - t + k))
        path.addLine(to: .init(x: maxX, y: bottom + b))
        path.addCurve(to: .init(x: maxX - b, y: bottom), control1: .init(x: maxX, y: bottom + b - kb),
                      control2: .init(x: maxX - b + kb, y: bottom))
        path.addLine(to: .init(x: minX + b, y: bottom))
        path.addCurve(to: .init(x: minX, y: bottom + b), control1: .init(x: minX + b - kb, y: bottom),
                      control2: .init(x: minX, y: bottom + b - kb))
        path.addLine(to: .init(x: minX, y: top - t))
        path.addCurve(to: .init(x: minX - out * t, y: top), control1: .init(x: minX, y: top - t + k),
                      control2: .init(x: minX - out * (t - k), y: top))
        path.closeSubpath()
        return path
    }
}

/// The expanded panel silhouette as a SwiftUI shape, so glass and the behind-window mask follow its outline.
struct NotchSilhouette: Shape, Equatable {
    var notchWidth: CGFloat?
    var notchHeight: CGFloat = 0
    var notchCenter: CGFloat?
    func path(in rect: CGRect) -> Path {
        let outline = NotchSurfaceGeometry.path(size: rect.size, notchWidth: notchWidth, notchHeight: notchHeight,
                                                progress: 1, notchCenter: notchCenter)
        // The outline is unflipped (its top edge at maxY); SwiftUI's y axis points down.
        return Path(outline).applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: rect.minX, ty: rect.maxY))
    }
}

/// A single silhouette encloses the hardware notch at rest, during cues, and in details.
@MainActor final class NotchSurfaceView: HoverTrackingView {
    /// The panel is translucent glass hanging from the top edge; a task cue is an opaque black island
    /// continuing the notch, or the equivalent black pill on a display without one.
    enum Style { case panel, island }
    /// Perceived spring durations: the surface expands in about 0.36 s and collapses a little faster,
    /// both critically damped so the outline never overshoots its window.
    nonisolated static let expandResponse: TimeInterval = 0.36
    nonisolated static let collapseResponse: TimeInterval = 0.24
    /// Time for the expansion spring to settle completely.
    nonisolated static let expandDuration = spring(response: expandResponse).settlingDuration
    /// A collapsing surface has faded out completely after this time, while its spring's last fraction of a point
    /// is still settling out of sight.
    nonisolated static let collapseDuration = collapseResponse
    /// Owners order a collapsing window out only after the collapse has finished drawing.
    nonisolated static let retractionDelay = Duration.milliseconds(Int(collapseDuration * 1000) + 20)
    /// Island content slides this far out from under the notch as it appears and back as it retracts.
    static let slideDistance: CGFloat = 8
    /// Content fades in after the outline has started to open, and out quickly as it closes.
    private enum Fade {
        static let delay: CFTimeInterval = 0.08, reveal: CFTimeInterval = 0.18, conceal: CFTimeInterval = 0.12
    }
    let style: Style
    /// Below perception over glass, yet never zero alpha in the window's own pixels.
    static let hitTestFill = NSColor.black.withAlphaComponent(0.02)
    private let backdrop: NSView
    private let content: NSHostingView<AnyView>
    private let silhouette = CAShapeLayer()
    private var expanded = false
    var notchWidth: CGFloat? { didSet { needsLayout = true } }
    var notchHeight: CGFloat = 0 { didSet { needsLayout = true } }
    var notchCenterX: CGFloat? { didSet { needsLayout = true } }

    init(content: AnyView, style: Style = .panel) {
        self.style = style
        let host = NSHostingView(rootView: content)
        switch style {
        case .panel:
            backdrop = NSHostingView(rootView: PanelMaterial())
        case .island:
            // Opaque in every appearance and under Reduce Transparency: no material or gradient.
            let fill = NSView(); fill.wantsLayer = true; fill.layer?.backgroundColor = NSColor.black.cgColor
            backdrop = fill
            host.appearance = NSAppearance(named: .darkAqua)
        }
        self.content = host
        super.init(frame: .zero)
        wantsLayer = true; layer?.mask = silhouette
        // The window server hands clicks on fully transparent pixels of a non-opaque window to the application below.
        // Glass is composited by the window server, so the panel's own pixels there are clear; a faint fill inside the
        // silhouette keeps every point of the panel its own, while the room outside the outline still passes clicks
        // through. The cue island is opaque and ignores the pointer anyway.
        if style == .panel { layer?.backgroundColor = Self.hitTestFill.cgColor }
        addSubview(backdrop)
        host.wantsLayer = true
        addSubview(host)
    }
    required init?(coder: NSCoder) { nil }
    nonisolated static func spring(response: TimeInterval) -> CASpringAnimation {
        CASpringAnimation(perceptualDuration: response, bounce: 0)
    }
    /// The panel body inside the shoulders; it holds the content, including the header in the notch band.
    var bodyFrame: CGRect {
        bounds.insetBy(dx: style == .panel ? NotchSurfaceGeometry.bodyInset(notchWidth: notchWidth) : 0, dy: 0)
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        content.frame = bodyFrame
        if let material = backdrop as? NSHostingView<PanelMaterial> {
            let outline = NotchSilhouette(notchWidth: notchWidth, notchHeight: notchHeight, notchCenter: notchCenterX)
            if material.rootView.outline != outline { material.rootView = PanelMaterial(outline: outline) }
        }
        silhouette.frame = bounds
        silhouette.path = silhouettePath(expanded: expanded)
        CATransaction.commit()
    }
    func setExpanded(_ value: Bool, animated: Bool) {
        layoutSubtreeIfNeeded()
        let current = silhouette.presentation()?.path ?? silhouette.path
        let previousOpacity = backdrop.layer?.presentation()?.opacity ?? Float(backdrop.alphaValue)
        expanded = value
        let target = silhouettePath(expanded: value)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        silhouette.removeAllAnimations(); silhouette.path = target
        content.layer?.removeAllAnimations(); content.alphaValue = value ? 1 : 0
        backdrop.layer?.removeAllAnimations(); backdrop.alphaValue = value ? 1 : 0
        CATransaction.commit()
        // Reduce Motion keeps the same geometry without a transition.
        guard animated, let current else { window?.invalidateShadow(); return }
        let unfold = Self.spring(response: value ? Self.expandResponse : Self.collapseResponse)
        unfold.keyPath = "path"
        unfold.fromValue = current; unfold.toValue = target
        unfold.duration = unfold.settlingDuration
        silhouette.add(unfold, forKey: "notch-unfold")
        let backdropFade = CABasicAnimation(keyPath: "opacity")
        backdropFade.fromValue = previousOpacity; backdropFade.toValue = value ? 1 : 0
        backdropFade.duration = value ? Fade.reveal : Self.collapseDuration
        backdropFade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        backdrop.layer?.add(backdropFade, forKey: "material-reveal")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = value ? 0 : 1; fade.toValue = value ? 1 : 0
        fade.duration = value ? Fade.reveal : Fade.conceal
        fade.beginTime = CACurrentMediaTime() + (value ? Fade.delay : 0)
        fade.fillMode = .backwards
        content.layer?.add(fade, forKey: "content-reveal")
        guard style == .island else { return }
        // Additive and in the surface's unflipped coordinates: a positive offset sits toward the notch.
        let slide = Self.spring(response: value ? Self.expandResponse : Fade.conceal)
        slide.keyPath = "position.y"
        slide.isAdditive = true
        slide.fromValue = value ? Self.slideDistance : 0; slide.toValue = value ? 0 : Self.slideDistance
        slide.duration = value ? Self.expandDuration : Fade.conceal
        slide.beginTime = fade.beginTime; slide.fillMode = .backwards
        content.layer?.add(slide, forKey: "content-slide")
    }
    func stopAnimations() {
        silhouette.removeAllAnimations(); content.layer?.removeAllAnimations(); backdrop.layer?.removeAllAnimations()
    }
    private func silhouettePath(expanded: Bool) -> CGPath {
        let progress: CGFloat = expanded ? 1 : 0
        if style == .island, let notchWidth {
            return NotchSurfaceGeometry.island(size: bounds.size, notchWidth: notchWidth, notchHeight: notchHeight,
                                               progress: progress, notchCenter: notchCenterX)
        }
        return NotchSurfaceGeometry.path(size: bounds.size, notchWidth: notchWidth, notchHeight: notchHeight,
                                         progress: progress, notchCenter: notchCenterX)
    }
}
