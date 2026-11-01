// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-21, AC-21.02.
// Refs: US-02, AC-02.03, AC-02.05; US-03, AC-03.04, AC-03.05, AC-03.06, AC-03.07, AC-03.10.
// Refs: US-12, AC-12.04, AC-12.05.
import AppKit
import Combine

/// The context menu shared by the notch entry and the menu-bar fallback.
@MainActor enum EntryMenu {
    static func make(target: AnyObject, open: Selector) -> NSMenu {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Open Lunlet", action: open, keyEquivalent: ""); item.target = target
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        return menu
    }
}

/// The lun·let lettering as a single-color template image: the system tints it in the menu bar,
/// and SwiftUI tints it wherever the app names itself.
enum LunletWordmark {
    /// Matches the visual weight of system menu-bar glyphs rather than filling the bar.
    static let menuBarHeight: CGFloat = 12
    static let aboutHeight: CGFloat = 15
    static func image(height: CGFloat = menuBarHeight) -> NSImage {
        let words = [VineArtwork.leftInk, VineArtwork.rightInk].map { VinePath.make($0) }
        let bounds = words.map(\.boundingBoxOfPath)
        let gap: CGFloat = 3, stroke: CGFloat = 2.4
        let unitsHeight = (bounds.map(\.maxY).max() ?? 20) - (bounds.map(\.minY).min() ?? 0) + stroke
        let scale = height / unitsHeight
        let unitsWidth = bounds.reduce(0) { $0 + $1.width } + gap + stroke * 2
        let size = NSSize(width: ceil(unitsWidth * scale), height: height)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: scale, y: scale)
            context.setStrokeColor(NSColor.black.cgColor); context.setLineWidth(stroke)
            context.setLineCap(.round); context.setLineJoin(.round)
            var x = stroke
            for (word, box) in zip(words, bounds) {
                context.saveGState()
                context.translateBy(x: x - box.minX, y: stroke / 2 - (bounds.map(\.minY).min() ?? 0))
                context.addPath(word); context.strokePath()
                context.restoreGState()
                x += box.width + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Lunlet"
        return image
    }
}

@MainActor final class MenuBarController: NSObject {
    private(set) var item: NSStatusItem?
    private let panel: CompanionPanelController
    private var subscriptions: Set<AnyCancellable> = []

    init(panel: CompanionPanelController, sessions: SessionListModel) {
        self.panel = panel
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        if let button = item.button {
            button.image = LunletWordmark.image()
            button.imagePosition = .imageLeading
            button.target = self; button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Lunlet")
        }
        sessions.$compactStatus.removeDuplicates().sink { [weak self] status in
            self?.item?.button?.title = status.badge.isEmpty ? "" : " " + status.badge
            self?.item?.button?.toolTip = "Lunlet · " + status.description
            self?.item?.button?.setAccessibilityValue(status.description)
        }.store(in: &subscriptions)
    }
    @objc private func clicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            NSMenu.popUpContextMenu(EntryMenu.make(target: self, open: #selector(openPanel)), with: event, for: sender)
        } else { panel.toggle(on: sender.window?.screen) }
    }
    @objc private func openPanel() { panel.show(on: item?.button?.window?.screen) }
    func setNotchEntryAvailable(_ available: Bool) {
        let showFallback = !available
        guard let item, item.isVisible != showFallback else { return }
        item.isVisible = showFallback
    }
    func shutdown() {
        subscriptions.removeAll()
        if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
    }
}
