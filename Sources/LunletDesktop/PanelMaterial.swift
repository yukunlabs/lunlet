// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-03, AC-03.05, AC-03.09, AC-03.10, AC-03.11; US-24, AC-24.02.
import AppKit
import SwiftUI

/// The panel's surface: dark frosted glass in both appearances, as the notch it hangs from is dark, so the header's sky
/// is the surface's own darkness with stars in it rather than a picture set on a lighter page. The system's glass
/// (Liquid Glass on macOS 26 and later, otherwise a vibrant behind-window material that stays active while the panel
/// is not key) lies under a fill of the surface's deep color, about half of each: the window behind colors the
/// surface softly and the surface stays dark over any window. The fill is drawn over the glass rather than given to
/// it as a tint, which the system's glass does not darken with.
/// Reduce Transparency and Increase Contrast use the same color opaque, with a visible border.
struct PanelMaterial: View {
    /// The surface outline; nil is a rounded panel with the surface radius.
    var outline: NotchSilhouette?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    static func opaque(reduceTransparency: Bool, contrast: ColorSchemeContrast) -> Bool {
        reduceTransparency || contrast == .increased
    }
    private var shape: AnyShape {
        outline.map(AnyShape.init) ?? AnyShape(RoundedRectangle(cornerRadius: PanelStyle.Radius.surface, style: .continuous))
    }
    var body: some View {
        Group {
            if Self.opaque(reduceTransparency: reduceTransparency, contrast: contrast) {
                // A 2 pt stroke clipped to the outline leaves a 1 pt border inside it.
                shape.fill(PanelStyle.surface)
                    .overlay { shape.stroke(Color.white.opacity(0.28), lineWidth: 2).clipShape(shape) }
            } else {
                ZStack {
                    if #available(macOS 26, *) {
                        Color.clear.glassEffect(.regular, in: shape)
                    } else {
                        BehindWindowMaterial(shape: shape)
                    }
                    shape.fill(PanelStyle.surface.opacity(PanelStyle.surfaceDepth))
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The pre-glass fallback: the window server blurs whatever lies behind the window. The mask image, not a
/// layer mask, shapes the blur, as behind-window blending requires.
private struct BehindWindowMaterial: View {
    let shape: AnyShape
    var body: some View {
        GeometryReader { geometry in
            FrostedSurface(mask: Self.mask(shape.path(in: CGRect(origin: .zero, size: geometry.size)), size: geometry.size))
        }
    }
    private static func mask(_ path: Path, size: CGSize) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let outline = path.cgPath
        return NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill(); NSBezierPath(cgPath: outline).fill()
            return true
        }
    }
}

private struct FrostedSurface: NSViewRepresentable {
    let mask: NSImage?
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        view.maskImage = mask
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.maskImage = mask }
}
