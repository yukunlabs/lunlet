// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-21, AC-21.02, AC-21.04, AC-21.05.
// Refs: US-02, AC-02.03, AC-02.05; US-03, AC-03.04, AC-03.05, AC-03.06, AC-03.07, AC-03.10.
// Refs: US-12, AC-12.04, AC-12.05.
import AppKit
import Combine
import LunletClaude
import LunletCore

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
    private var status: CompactSessionStatus
    private var preferred: LunletPreferences
    private var codex: AccountLimitsSnapshot?
    private var claude: ClaudePlanLimits?
    private var claudeConnected = false
    /// Ticks once a minute only while a countdown is on the entry (AC-21.04), so the text keeps time without polling.
    private var countdownTick: Timer?

    init(panel: CompanionPanelController, sessions: SessionListModel, usage: AccountUsageModel? = nil,
         claudeLimits: ClaudePlanLimitsModel? = nil, preferences: PreferencesStore? = nil) {
        self.panel = panel
        status = sessions.compactStatus
        preferred = preferences?.value ?? .init()
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
            self?.status = status; self?.updateTitle()
        }.store(in: &subscriptions)
        if let usage {
            usage.$state.sink { [weak self, weak usage] state in
                switch state {
                case .available(let snapshot): self?.codex = snapshot
                case .loading: self?.codex = usage?.displayedSnapshot
                default: self?.codex = nil
                }
                self?.updateTitle()
            }.store(in: &subscriptions)
        }
        if let claudeLimits {
            claudeLimits.$limits.combineLatest(claudeLimits.$connection).sink { [weak self] limits, connection in
                self?.claude = limits; self?.claudeConnected = connection == .connected; self?.updateTitle()
            }.store(in: &subscriptions)
        }
        if let preferences {
            preferences.$value.sink { [weak self] value in self?.preferred = value; self?.updateTitle() }.store(in: &subscriptions)
        }
    }

    /// The waiting count, then the allowance text when chosen, as plain text after the lettering (AC-21.02, AC-21.04).
    private func updateTitle() {
        guard let button = item?.button else { return }
        let now = Date(), agents = preferred.sessionProviders
        let windows = MenuBarAllowanceText.windows(providers: agents, codex: codex, claude: claude,
                                                   claudeConnected: claudeConnected, now: now)
        let allowance = MenuBarAllowanceText.text(windows: windows, mode: preferred.menuBarAllowance,
                                                  onlyBelow: preferred.menuBarAllowanceBelow, agents: agents.count, now: now)
        let parts = [status.badge, allowance ?? ""].filter { !$0.isEmpty }
        button.title = parts.isEmpty ? "" : " " + parts.joined(separator: "  ")
        button.toolTip = "Lunlet · " + status.description + (allowance.map { " · Allowance " + $0 + " left" } ?? "")
        button.setAccessibilityValue(status.description + (allowance.map { ", allowance " + $0 + " left" } ?? ""))
        let needsTick = allowance != nil && preferred.menuBarAllowance == .percentAndReset
        if needsTick, countdownTick == nil {
            countdownTick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTitle() }
            }
            countdownTick?.tolerance = 10
        } else if !needsTick { countdownTick?.invalidate(); countdownTick = nil }
    }
    @objc private func clicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            NSMenu.popUpContextMenu(EntryMenu.make(target: self, open: #selector(openPanel)), with: event, for: sender)
        } else { panel.toggle(on: sender.window?.screen) }
    }
    @objc private func openPanel() { panel.show(on: item?.button?.window?.screen) }
    func setNotchEntryAvailable(_ available: Bool) { setVisible(!available) }
    /// Shown in menu-bar mode and as the fallback without a notch entry; never beside the desktop pet (AC-21.03, AC-39.01).
    func setVisible(_ visible: Bool) {
        guard let item, item.isVisible != visible else { return }
        item.isVisible = visible
    }
    func shutdown() {
        subscriptions.removeAll()
        countdownTick?.invalidate(); countdownTick = nil
        if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
    }
}
