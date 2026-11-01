// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-03, AC-03.05, AC-03.08, AC-03.10, AC-03.11; US-13, AC-13.02; US-12, AC-12.04.
import AppKit

/// The borderless, non-activating panel behind every floating Lunlet surface.
/// Only panels that accept keyboard focus become key; none becomes main.
final class FloatingPanel: NSPanel {
    var dismiss: (() -> Void)?
    private let acceptsKey: Bool
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    init(identifier: String, title: String, frame: CGRect = .zero, acceptsKey: Bool, level: NSWindow.Level = .statusBar) {
        self.acceptsKey = acceptsKey
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.identifier = .init(identifier); self.title = title; self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false; isReleasedWhenClosed = false
        isOpaque = false; backgroundColor = .clear
    }
    override func cancelOperation(_ sender: Any?) {
        if let dismiss { dismiss() } else { super.cancelOperation(sender) }
    }
    override func performClose(_ sender: Any?) {
        if let dismiss { dismiss() } else { super.performClose(sender) }
    }
}

/// Reports pointer entry and exit anywhere in the visible view.
class HoverTrackingView: NSView {
    var hover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    /// Subclasses that route hover elsewhere override this instead of the mouse events.
    func hoverChanged(_ inside: Bool) { hover?(inside) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking); self.tracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { hoverChanged(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged(false) }
}
