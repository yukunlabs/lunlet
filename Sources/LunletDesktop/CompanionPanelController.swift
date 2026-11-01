// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-03, AC-03.01, AC-03.04, AC-03.05, AC-03.06, AC-03.07, AC-03.08, AC-03.09, AC-03.10, AC-03.11; US-04, AC-04.08.
// Refs: US-12, AC-12.04, AC-12.05; US-13, AC-13.02; US-19, AC-19.05; US-24, AC-24.03.
import AppKit
import OSLog
import SwiftUI

extension Notification.Name {
    /// Posted with the hiding controller as its object.
    static let companionPanelDidHide = Notification.Name("Lunlet.companionPanelDidHide")
}

private struct CompanionPanelHostKey: EnvironmentKey { static let defaultValue: ObjectIdentifier? = nil }
private struct NotchBandKey: EnvironmentKey { static let defaultValue: NotchBand? = nil }
extension EnvironmentValues {
    /// The controller hosting this content, so views react only to their own panel's dismissal.
    var companionPanelHost: ObjectIdentifier? {
        get { self[CompanionPanelHostKey.self] }
        set { self[CompanionPanelHostKey.self] = newValue }
    }
    /// The menu-bar band beside the notch that holds the header; nil keeps a normal header row.
    var notchBand: NotchBand? {
        get { self[NotchBandKey.self] }
        set { self[NotchBandKey.self] = newValue }
    }
}

/// Content reports whether it shows a tab row below the notch band, so the panel keeps its page budget.
struct CompanionPanelTabRow: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Header geometry the controller shares with its hosted content.
@MainActor private final class CompanionPanelLayout: ObservableObject {
    @Published var band: NotchBand?
    var tabRow = false
    var tabRowChanged: (() -> Void)?
}

private struct CompanionPanelRoot: View {
    @ObservedObject var layout: CompanionPanelLayout
    let host: ObjectIdentifier
    let content: AnyView
    var body: some View {
        content.environment(\.companionPanelHost, host).environment(\.notchBand, layout.band)
            .onPreferenceChange(CompanionPanelTabRow.self) { [layout] tabRow in
                MainActor.assumeIsolated {
                    guard layout.tabRow != tabRow else { return }
                    layout.tabRow = tabRow; layout.tabRowChanged?()
                }
            }
    }
}

extension NSScreen {
    var displayNumber: NSNumber? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber }
}

/// Dismissing a panel does not destroy its hosted state or terminate the app.
@MainActor final class CompanionPanelController: NSObject {
    private(set) var window: NSPanel?
    var beforeShow: (() -> Void)?
    var beforeHide: (() -> Void)?
    private let motionAllowed: @MainActor () -> Bool
    private let observesSystemEvents: Bool
    private var retraction: Task<Void, Never>?
    /// The collapse that is running was started by the pointer leaving, not by a dismissal,
    /// so the pointer returning before it finishes restores the preview instead of a new open.
    private var retractingForHover = false
    private var presentationRequested = false
    private var surface: NotchSurfaceView?
    private let layout = CompanionPanelLayout()
    private let screen: @MainActor () -> PanelScreen?
    private var preferredDisplay: NSNumber?
    private var content: (@MainActor () -> AnyView)?
    private var observations: [NotificationObservation] = []
    private var mouseMonitor: Any?
    private var localMonitor: Any?
    private var hoverOpen: Task<Void, Never>?
    private var hoverClose: Task<Void, Never>?
    private var pointerInEntry = false
    private var pointerInPanel = false
    private var pointerInAuxiliary = false
    private(set) var isPinned = false
    var visibilityChanged: ((Bool) -> Void)?
    private var closed = false
    var isVisible: Bool { window?.isVisible == true }
    private enum HoverDelay {
        static let open = Duration.milliseconds(220)
        static let close = Duration.milliseconds(380)
    }

    init(motionAllowed: @escaping @MainActor () -> Bool = { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         observesSystemEvents: Bool = true, screen: @escaping @MainActor () -> PanelScreen? = { PanelScreen.current }) {
        self.motionAllowed = motionAllowed; self.observesSystemEvents = observesSystemEvents; self.screen = screen
        super.init()
    }
    func setContent(_ content: @escaping @MainActor () -> AnyView) {
        guard !closed, window == nil else { return }
        self.content = content
    }
    func show() { show(on: nil) }
    func show(on display: NSScreen?) { present(on: display, pinned: true) }
    private func present(on display: NSScreen?, pinned: Bool) {
        guard !closed, let content else { return }
        if let display { preferredDisplay = display.displayNumber }
        guard let geometry = currentScreen else { return }
        hoverOpen?.cancel(); hoverOpen = nil
        hoverClose?.cancel(); hoverClose = nil
        retraction?.cancel(); retraction = nil; retractingForHover = false
        presentationRequested = true
        isPinned = pinned
        beforeShow?()
        if window == nil {
            let panel = FloatingPanel(identifier: "Lunlet.companion", title: "Lunlet", acceptsKey: true)
            panel.dismiss = { [weak self] in self?.hide() }
            let root = CompanionPanelRoot(layout: layout, host: ObjectIdentifier(self), content: content())
            let surface = NotchSurfaceView(content: AnyView(root))
            if observesSystemEvents { surface.hover = { [weak self] inside in self?.pointerChanged(inside) } }
            panel.contentView = surface; self.surface = surface
            window = panel
            // A tab row appearing or disappearing while visible resizes the panel after SwiftUI's update.
            layout.tabRowChanged = { [weak self] in
                Task { @MainActor [weak self] in self?.fitTabRow() }
            }
            if observesSystemEvents {
                observations = [NotificationObservation(center: .default,
                                                        name: NSApplication.didChangeScreenParametersNotification) { [weak self] in
                    self?.reposition()
                }]
                let workspace = NSWorkspace.shared.notificationCenter
                observations += [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification].map {
                    NotificationObservation(center: workspace, name: $0) { [weak self] in self?.hide(animated: false) }
                }
                observations.append(NotificationObservation(center: workspace, name: NSWorkspace.didActivateApplicationNotification,
                    value: { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier },
                    receive: { [weak self] processID in
                        if let processID { self?.applicationActivated(processID: processID) }
                    }))
            }
        }
        applyGeometry(geometry)
        // Laying out reports the content's tab row; size the window for it before the expansion starts.
        surface?.layoutSubtreeIfNeeded()
        if needsTabRowFit(geometry) { applyGeometry(geometry) }
        surface?.setExpanded(true, animated: motionAllowed())
        // This is a user-initiated open; task cues never use this key-window path.
        if pinned { window?.makeKeyAndOrderFront(nil) } else { window?.orderFrontRegardless() }
        visibilityChanged?(true)
        if observesSystemEvents, localMonitor == nil {
            let interactions: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .scrollWheel]
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: interactions) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.interactionOccurred(event.type, in: event.window)
                }
                return event
            }
        }
        if observesSystemEvents, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.outsideClick(at: NSEvent.mouseLocation) }
            }
        }
    }
    func toggle() { toggle(on: nil) }
    func toggle(on display: NSScreen?) {
        if presentationRequested && isPinned { hide() } else if presentationRequested { pin() } else { show(on: display) }
    }
    func pin() {
        guard isVisible, !closed else { return }
        isPinned = true; hoverClose?.cancel(); hoverClose = nil
        window?.makeKeyAndOrderFront(nil)
    }
    func entryHoverChanged(_ inside: Bool, on display: NSScreen?) {
        hoverOpen?.cancel(); hoverOpen = nil
        pointerInEntry = inside
        updateHoverDismissal()
        guard inside, !presentationRequested, !closed else { return }
        hoverOpen = Task { [weak self] in
            do { try await Task.sleep(for: HoverDelay.open) } catch { return }
            self?.present(on: display, pinned: false)
        }
    }
    func interactionOccurred(_ type: NSEvent.EventType, in target: NSWindow?) {
        guard let target, target === window,
              [.leftMouseDown, .rightMouseDown, .scrollWheel].contains(type) else { return }
        pin()
    }
    func cancelHoverPreview() {
        hoverOpen?.cancel(); hoverOpen = nil
        if !isPinned { hide() }
    }
    func pointerChanged(_ inside: Bool) {
        pointerInPanel = inside
        updateHoverDismissal()
    }
    func auxiliaryHoverChanged(_ inside: Bool) {
        pointerInAuxiliary = inside
        updateHoverDismissal()
    }
    private func updateHoverDismissal() {
        hoverClose?.cancel(); hoverClose = nil
        guard !closed else { return }
        // Entry and panel tracking events may arrive in either order.
        if pointerInEntry || pointerInPanel || pointerInAuxiliary {
            if retractingForHover { present(on: nil, pinned: false) }
            return
        }
        hoverOpen?.cancel(); hoverOpen = nil
        guard presentationRequested, isVisible, !isPinned else { return }
        hoverClose = Task { [weak self] in
            do { try await Task.sleep(for: HoverDelay.close) } catch { return }
            guard let self, !self.pointerInEntry, !self.pointerInPanel, !self.pointerInAuxiliary, !self.isPinned else { return }
            self.hide()
            self.retractingForHover = self.retraction != nil
        }
    }
    func hide(animated: Bool = true) {
        presentationRequested = false
        NotificationCenter.default.post(name: .companionPanelDidHide, object: self)
        beforeHide?()
        retraction?.cancel(); retraction = nil; retractingForHover = false
        hoverOpen?.cancel(); hoverOpen = nil; hoverClose?.cancel(); hoverClose = nil
        isPinned = false
        pointerInEntry = false; pointerInPanel = false; pointerInAuxiliary = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        guard animated, motionAllowed(), isVisible, !closed else {
            surface?.setExpanded(false, animated: false)
            window?.orderOut(nil); visibilityChanged?(false)
            return
        }
        surface?.setExpanded(false, animated: true)
        retraction = Task { [weak self] in
            do { try await Task.sleep(for: NotchSurfaceView.retractionDelay) } catch { return }
            guard let self, !self.presentationRequested else { return }
            self.surface?.stopAnimations(); self.window?.orderOut(nil); self.visibilityChanged?(false)
            self.retraction = nil; self.retractingForHover = false
        }
    }
    func outsideClick(at point: CGPoint) {
        guard let window, window.isVisible else { return }
        // The panel body, not the window's room for the shoulders beside it.
        let body = surface.map { window.convertToScreen($0.convert($0.bodyFrame, to: nil)) } ?? window.frame
        if !body.contains(point) { hide(); return }
        // This monitor sees only clicks delivered to other applications, so a click inside the body passed through the
        // panel; it is logged with body-relative coordinates only, so a regression shows in the unified log.
        Self.diagnostics.notice("click-through x=\(Int(point.x - body.minX)) y=\(Int(body.maxY - point.y)) pinned=\(self.isPinned) key=\(window.isKeyWindow)")
    }
    private static let diagnostics = Logger(subsystem: "com.lunlet", category: "panel")
    func applicationActivated(processID: pid_t) { if processID != getpid() { hide(animated: false) } }
    func shutdown() {
        guard !closed else { return }
        closed = true; hide(animated: false); observations.removeAll()
        window?.close(); window?.contentView = nil; window = nil
        surface?.hover = nil; surface = nil; layout.tabRowChanged = nil
        content = nil; beforeShow = nil; beforeHide = nil; visibilityChanged = nil
    }
    private var currentScreen: PanelScreen? {
        if let preferredDisplay, let display = NSScreen.screens.first(where: { $0.displayNumber == preferredDisplay }) {
            return PanelScreen(display)
        }
        return screen()
    }
    private func applyGeometry(_ geometry: PanelScreen) {
        let frame = PanelPlacement.panel(tabRow: layout.tabRow, screen: geometry)
        window?.setFrame(frame, display: true)
        surface?.notchWidth = geometry.notch?.width
        surface?.notchHeight = geometry.notch?.height ?? 0
        surface?.notchCenterX = geometry.notch.map { $0.midX - frame.minX }
        let band = PanelPlacement.band(panel: frame, screen: geometry)
        if layout.band != band { layout.band = band }
    }
    /// Resizes a visible panel only when the tab row changed its height, leaving a running expansion alone.
    private func fitTabRow() {
        guard !closed, isVisible, let geometry = currentScreen, needsTabRowFit(geometry) else { return }
        applyGeometry(geometry)
        surface?.setExpanded(presentationRequested, animated: false)
    }
    private func needsTabRowFit(_ geometry: PanelScreen) -> Bool {
        guard let window else { return false }
        return abs(window.frame.height - PanelPlacement.panel(tabRow: layout.tabRow, screen: geometry).height) >= 1
    }
    private func reposition() {
        guard !closed, isVisible, let geometry = currentScreen else { return }
        applyGeometry(geometry)
        surface?.setExpanded(presentationRequested, animated: false)
    }
}
