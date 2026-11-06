// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-39, AC-39.01, AC-39.02, AC-39.03, AC-39.04, AC-39.05, AC-39.06, AC-39.07, AC-39.08.
// Refs: US-03, AC-03.06, AC-03.10; US-13, AC-13.02, AC-13.04, AC-13.09; US-21, AC-21.03; US-12, AC-12.04.
import AppKit
import Combine
import LunletCore

/// Sends task cues to the island below the notch or to the desktop pet, whichever entry is in use, so a finish
/// shows once (AC-13.06, AC-39.04).
@MainActor final class CueRouter: TaskCuePresenting {
    private let island: TransientCuePanel
    weak var pet: PetEntryController?
    var mode: EntryPresentation = .notch {
        didSet { guard mode != oldValue else { return }; island.hideImmediately(); pet?.hide() }
    }
    init(island: TransientCuePanel) { self.island = island }
    func show(_ cues: [TaskCue]) {
        if mode == .pet { pet?.show(cues) } else { island.show(cues) }
    }
    func hide() { island.hide(); pet?.hide() }
}

/// Owns the desktop-pet entry: a small floating window with the dog, shown while the pet presentation is chosen
/// and the display is available, placed where the owner last dragged it on that display (AC-39.02).
@MainActor final class PetEntryController: NSObject, TaskCuePresenting {
    static let windowSize = CGSize(width: 176, height: 152)
    static let margin: CGFloat = 24
    private(set) var window: FloatingPanel?
    private let host: PetHostView
    private let companion: CompanionPanelController
    private let sessions: SessionListModel
    private let preferences: PreferencesStore?
    private let skins: SkinCatalog?
    private let display: @MainActor () -> NSScreen?
    private let available: @MainActor () -> Bool
    private let motionAllowed: @MainActor () -> Bool
    private var monitor: DisplayStateMonitor?
    private var observations: Set<AnyCancellable> = []
    private var moveObservation: NotificationObservation?
    private var mouseMonitors: [Any] = []
    private var cue: TaskCue?
    private var motion = PetMotionInput()
    private var panelFrame: CGRect?
    private var palette: PetPalette
    private var active = false
    private var repositioning = false
    private var closed = false
    private var lastPointerCheck: CGPoint?
    /// Refresh and Settings for the context menu; set by the runtime.
    var refreshAction: (() -> Void)?
    var settingsAction: (() -> Void)?

    init(companion: CompanionPanelController, sessions: SessionListModel, preferences: PreferencesStore? = nil, skins: SkinCatalog? = nil,
         display: @escaping @MainActor () -> NSScreen? = { NSScreen.main ?? NSScreen.screens.first },
         available: @escaping @MainActor () -> Bool = { SystemDisplayState.isAvailable },
         motionAllowed: @escaping @MainActor () -> Bool = { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.companion = companion; self.sessions = sessions; self.preferences = preferences; self.skins = skins
        self.display = display; self.available = available; self.motionAllowed = motionAllowed
        palette = Self.palette(preferences?.value, skins: skins)
        host = PetHostView(palette: palette)
        super.init()
        host.clicked = { [weak self] in self?.clicked() }
        host.hover = { [weak self] inside in
            guard let self else { return }
            motion.hovered = inside; updateState()
        }
        host.contextMenu = { [weak self] in self?.menu() ?? NSMenu() }
        host.moved = { [weak self] in self?.moved() }
        if let preferences {
            preferences.$value.sink { [weak self] value in
                guard let self else { return }
                let next = value.presentation == .pet
                let modeChanged = active != next
                active = next
                palette = Self.palette(value, skins: skins)
                if modeChanged, monitor != nil { refresh() } else { updateState() }
            }.store(in: &observations)
        }
        if let skins {
            skins.$skins.sink { [weak self] _ in
                guard let self else { return }
                palette = Self.palette(preferences?.value, skins: skins); updateState()
            }.store(in: &observations)
        }
        sessions.$sessions.sink { [weak self] _ in self?.updateState() }.store(in: &observations)
        sessions.$monitoringAvailable.sink { [weak self] _ in self?.updateState() }.store(in: &observations)
    }

    static func palette(_ preferences: LunletPreferences?, skins: SkinCatalog?) -> PetPalette {
        let accent = preferences.flatMap { value in skins?.accentHex(for: value).flatMap(AllowanceColor.init(hexString:)) }
            ?? AllowanceColor(hex: 0xC83F49)
        return PetPalette.make(coat: preferences?.petCoat ?? .golden, accent: accent)
    }

    /// The current state, from the sessions and the finish cue the list model is presenting (AC-39.03).
    var state: PetState { PetPoseRule.state(sessions: sessions.sessions, cue: cue, monitoringAvailable: sessions.monitoringAvailable) }

    func start() {
        guard !closed, monitor == nil else { return }
        monitor = DisplayStateMonitor { [weak self] in self?.refresh() }
        monitor?.recheck()
    }

    func refresh() {
        guard !closed else { return }
        guard active, available(), let screen = display() else { hideWindow(); return }
        if window == nil {
            let panel = FloatingPanel(identifier: "Lunlet.pet", title: "Lunlet pet", frame: CGRect(origin: .zero, size: Self.windowSize),
                                      acceptsKey: false, level: .floating)
            // On every Space, but not over a full-screen app (AC-39.02); the dog itself is the only click target.
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
            panel.hasShadow = false; panel.isMovableByWindowBackground = false; panel.acceptsMouseMovedEvents = true
            panel.contentView = host
            window = panel
            moveObservation = NotificationObservation(center: .default, name: NSWindow.didMoveNotification,
                                                      value: { ($0.object as? NSWindow).map(ObjectIdentifier.init) }) { [weak self] moved in
                guard let self, !repositioning, let window, moved == ObjectIdentifier(window) else { return }
                self.moved()
            }
        }
        repositioning = true
        window?.setFrame(frame(on: screen), display: true)
        repositioning = false
        window?.orderFrontRegardless()
        updateState()
        startPointerTracking()
    }

    private func hideWindow() {
        stopPointerTracking()
        window?.orderOut(nil)
        host.update(state, palette: palette, input: motion, animating: false)
    }

    /// The saved place on this display, clamped to its visible area, or the lower trailing corner.
    func frame(on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame, size = Self.windowSize
        var origin = CGPoint(x: visible.maxX - size.width - Self.margin, y: visible.minY + Self.margin)
        if let saved = preferences?.value.petPositions[Self.key(for: screen)] { origin = CGPoint(x: saved.x, y: saved.y) }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
    static func key(for screen: NSScreen) -> String { screen.displayNumber.map { String($0.intValue) } ?? "main" }

    /// The dog was dragged: its place is kept and an open bubble follows it (AC-39.02, AC-39.05).
    private func moved() {
        savePosition()
        guard companion.isVisible, let anchor = bubbleAnchor else { return }
        companion.move(near: anchor)
        panelVisibilityChanged(true, frame: companion.window?.frame)
    }
    private func savePosition() {
        guard let window, let screen = window.screen ?? display(), let preferences else { return }
        let origin = window.frame.origin
        preferences.update { $0.petPositions[Self.key(for: screen)] = .init(x: origin.x, y: origin.y) }
    }

    // MARK: Cues

    func show(_ cues: [TaskCue]) { cue = cues.last; updateState() }
    func hide() { cue = nil; updateState() }

    private func updateState() {
        let state = state, now = Date().timeIntervalSinceReferenceDate
        if state.pose != motion.pose {
            motion.previousPose = motion.pose; motion.pose = state.pose; motion.poseChangedAt = now
        }
        let animating = window?.isVisible == true && available() && motionAllowed()
        host.update(state, palette: palette, input: motion, animating: animating)
    }

    /// The panel opened or closed beside the dog: it looks up at it while it is open (AC-39.05).
    func panelVisibilityChanged(_ visible: Bool, frame: CGRect?) {
        motion.panelOpen = visible && active
        panelFrame = visible ? frame : nil
        updateGaze(toward: visible ? frame.map { CGPoint(x: $0.midX, y: $0.midY) } : nil)
        updateState()
    }

    /// Looks toward a screen point near the dog, or wanders when nothing is near.
    private func updateGaze(toward point: CGPoint?) {
        guard let window else { motion.gaze = nil; return }
        let head = host.headCenter
        let headOnScreen = CGPoint(x: window.frame.minX + head.x, y: window.frame.minY + head.y)
        guard let point else { motion.gaze = nil; return }
        let dx = point.x - headOnScreen.x, dy = headOnScreen.y - point.y
        let distance = hypot(dx, dy)
        guard distance > 1 else { motion.gaze = .zero; return }
        let reach = min(1, distance / 120)
        motion.gaze = CGPoint(x: dx / distance * reach, y: dy / distance * reach * 0.7)
    }

    // MARK: Interaction

    private func clicked() {
        let state = state
        motion.impulseAt = Date().timeIntervalSinceReferenceDate
        updateState()
        if let id = state.sessionID { sessions.select(id) }
        companion.toggle(on: window?.screen, near: bubbleAnchor)
    }
    /// What the panel's bubble tail points at: the head from above, the whole dog from below (AC-39.05).
    var bubbleAnchor: CGRect? {
        guard let window else { return nil }
        let head = host.headFrame.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        return CGRect(x: head.minX, y: window.frame.minY, width: head.width, height: head.maxY - window.frame.minY)
    }
    private func menu() -> NSMenu {
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open Lunlet", action: #selector(openPanel), keyEquivalent: ""); open.target = self
        let refresh = menu.addItem(withTitle: "Refresh", action: #selector(refreshAll), keyEquivalent: ""); refresh.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ""); settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        return menu
    }
    @objc private func openPanel() { companion.show(on: window?.screen, near: bubbleAnchor) }
    @objc private func refreshAll() { refreshAction?() }
    @objc private func openSettings() { settingsAction?() ?? companion.show(on: window?.screen, near: bubbleAnchor) }

    /// Only the dog takes the pointer: over transparent space the window ignores it, so clicks reach what is beneath.
    private func startPointerTracking() {
        guard mouseMonitors.isEmpty else { return }
        let check: @Sendable (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: check) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in check(event); return event }) {
            mouseMonitors.append(local)
        }
        pointerMoved()
    }
    private func stopPointerTracking() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll(); lastPointerCheck = nil
    }
    private func pointerMoved() {
        guard let window, window.isVisible else { return }
        let point = NSEvent.mouseLocation
        if let last = lastPointerCheck, abs(last.x - point.x) < 1, abs(last.y - point.y) < 1 { return }
        lastPointerCheck = point
        let inside = window.frame.contains(point)
        let local = CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
        let over = inside && host.isOnDog(local)
        if window.ignoresMouseEvents != !over { window.ignoresMouseEvents = !over }
        // The dog watches a pointer that comes near, and the panel while it is open.
        if motion.panelOpen, let panelFrame {
            updateGaze(toward: CGPoint(x: panelFrame.midX, y: panelFrame.midY))
        } else {
            let head = host.headCenter
            let near = hypot(point.x - (window.frame.minX + head.x), point.y - (window.frame.minY + head.y)) < 260
            let previous = motion.gaze
            updateGaze(toward: near ? point : nil)
            if (previous == nil) != (motion.gaze == nil) || near { updateState() }
        }
    }

    func shutdown() {
        guard !closed else { return }; closed = true
        monitor = nil; observations.removeAll(); moveObservation = nil
        stopPointerTracking()
        window?.orderOut(nil); window?.close(); window?.contentView = nil; window = nil
    }
}
