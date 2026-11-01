// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.01, AC-32.04.
// Refs: US-04, AC-04.08; US-03, AC-03.08, AC-03.10; US-12, AC-12.04.
// Refs: US-24, AC-24.01, AC-24.02.
import AppKit
import SwiftUI

enum UsageHoverPlacement {
    static func frame(size: CGSize, parent: CGRect, visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width)
        let bottom = parent.minY < visible.maxY
            ? max(visible.minY, parent.minY)
            : max(visible.minY, visible.maxY - size.height)
        let height = min(size.height, visible.height, visible.maxY - bottom)
        let left = parent.minX - width - 8
        let preferredX = left >= visible.minX ? left : parent.maxX + 8
        return CGRect(x: max(visible.minX, min(preferredX, visible.maxX - width)),
                      y: bottom,
                      width: width, height: height)
    }
}

/// The overview and chart remain separate windows, with a grace period across their gap.
@MainActor final class UsageHoverPanelController {
    /// The overview's designed size; its chart layout compresses from this height.
    nonisolated static let overviewSize = CGSize(width: 320, height: 357)
    private enum HoverDelay {
        static let open = Duration.milliseconds(180)
        static let close = Duration.milliseconds(300)
    }
    private(set) var window: NSPanel?
    var isVisible: Bool { window?.isVisible == true }
    var visibilityChanged: ((Bool) -> Void)?
    var interactionOccurred: (() -> Void)?
    var dismissalRequested: (() -> Void)?
    private let observesSystemEvents: Bool
    private let size: CGSize
    private weak var anchor: NSView?
    private var content: (@MainActor () -> AnyView)?
    private var hoverOpen: Task<Void, Never>?
    private var hoverClose: Task<Void, Never>?
    private var keyboardPinned = false
    private var pointerInAnchor = false
    private var pointerInPopup = false
    private var suppressedUntilAnchorExit = false
    private var closed = false
    private var localMonitor: Any?
    private var observations: [NotificationObservation] = []

    init(observesSystemEvents: Bool = true, size: CGSize = UsageHoverPanelController.overviewSize) {
        self.observesSystemEvents = observesSystemEvents
        self.size = size
    }
    func setContent(_ content: @escaping @MainActor () -> AnyView) {
        guard !closed, window == nil else { return }
        self.content = content
    }
    func prepareForParentPresentation() {
        guard !closed, !isVisible else { return }
        suppressedUntilAnchorExit = false
    }
    func anchorAttached(_ anchor: NSView) {
        guard !closed, anchor.window != nil else { return }
        self.anchor = anchor
    }
    func showForKeyboard() {
        guard !closed else { return }
        hoverOpen?.cancel(); hoverOpen = nil
        hoverClose?.cancel(); hoverClose = nil
        keyboardPinned = true
        present()
        guard isVisible else { keyboardPinned = false; return }
        interactionOccurred?()
        window?.makeKey()
        window?.selectNextKeyView(nil)
    }
    func anchorHoverChanged(_ inside: Bool, anchor: NSView) {
        guard !closed else { return }
        if !inside {
            guard self.anchor === anchor else { return }
            pointerInAnchor = false; suppressedUntilAnchorExit = false
            hoverOpen?.cancel(); hoverOpen = nil
            updateHoverDismissal()
            return
        }
        guard anchor.window?.isVisible == true else { return }
        self.anchor = anchor
        guard !suppressedUntilAnchorExit else { return }
        pointerInAnchor = true
        hoverClose?.cancel(); hoverClose = nil
        guard !isVisible, hoverOpen == nil else { return }
        hoverOpen = Task { [weak self] in
            do { try await Task.sleep(for: HoverDelay.open) } catch { return }
            guard let self, self.pointerInAnchor, !self.closed else { return }
            self.hoverOpen = nil
            self.present()
        }
    }
    func popupHoverChanged(_ inside: Bool) {
        guard !closed, isVisible else { return }
        pointerInPopup = inside
        updateHoverDismissal()
    }
    private func updateHoverDismissal() {
        hoverClose?.cancel(); hoverClose = nil
        guard !keyboardPinned, !pointerInAnchor, !pointerInPopup, isVisible, !closed else { return }
        hoverClose = Task { [weak self] in
            do { try await Task.sleep(for: HoverDelay.close) } catch { return }
            guard let self, !self.keyboardPinned, !self.pointerInAnchor, !self.pointerInPopup else { return }
            self.hide()
        }
    }
    private func present() {
        guard !closed, let content, let anchor, anchor.window?.isVisible == true,
              let frame = placement() else { return }
        if window == nil {
            let panel = FloatingPanel(identifier: "Lunlet.usageHover", title: "Usage on This Mac", frame: frame, acceptsKey: true)
            panel.dismiss = { [weak self] in
                guard let self else { return }
                if self.keyboardPinned {
                    self.hide(); self.anchor?.window?.makeKey()
                } else if let dismissalRequested = self.dismissalRequested { dismissalRequested() }
                else { self.hide() }
            }
            let root = UsageHoverContentView(content: content())
            if observesSystemEvents { root.hover = { [weak self] in self?.popupHoverChanged($0) } }
            panel.contentView = root
            window = panel
        }
        if window?.frame != frame { window?.setFrame(frame, display: true) }
        window?.orderFrontRegardless()
        visibilityChanged?(true)
        installObservers()
    }
    private func placement() -> CGRect? {
        guard let anchor, let parent = anchor.window, parent.isVisible,
              let display = parent.screen else { return nil }
        // Attach to the visible panel body, not the window's room for the shoulders beside it.
        let body = (parent.contentView as? NotchSurfaceView).map { parent.convertToScreen($0.convert($0.bodyFrame, to: nil)) }
        return UsageHoverPlacement.frame(size: size, parent: body ?? parent.frame, visible: display.visibleFrame)
    }
    func reposition() {
        guard isVisible else { return }
        guard let frame = placement() else { hide(); return }
        if window?.frame != frame { window?.setFrame(frame, display: true) }
    }
    func handleInteraction(_ type: NSEvent.EventType, in target: NSWindow?) {
        guard let target, target === window, isVisible,
              [.leftMouseDown, .rightMouseDown, .scrollWheel].contains(type) else { return }
        interactionOccurred?()
        if type != .scrollWheel { window?.makeKey() }
    }
    func anchorRemoved(_ removed: NSView) {
        guard anchor === removed else { return }
        hide(); anchor = nil; suppressedUntilAnchorExit = false
    }
    func hide() {
        hoverOpen?.cancel(); hoverOpen = nil
        hoverClose?.cancel(); hoverClose = nil
        suppressedUntilAnchorExit = suppressedUntilAnchorExit || pointerInAnchor
        pointerInAnchor = false; pointerInPopup = false; keyboardPinned = false
        let wasVisible = isVisible
        window?.orderOut(nil)
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        observations.removeAll()
        if wasVisible { visibilityChanged?(false) }
    }
    func shutdown() {
        guard !closed else { return }
        closed = true; hide()
        window?.close(); window?.contentView = nil; window = nil
        content = nil; anchor = nil
        visibilityChanged = nil; interactionOccurred = nil; dismissalRequested = nil
    }
    private func installObservers() {
        guard observesSystemEvents, localMonitor == nil else { return }
        let interactions: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .scrollWheel]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: interactions) { [weak self] event in
            MainActor.assumeIsolated { self?.handleInteraction(event.type, in: event.window) }
            return event
        }
        observations = [NotificationObservation(center: .default,
                                                name: NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.reposition()
        }]
        observations += [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map {
            NotificationObservation(center: .default, name: $0,
                value: { ($0.object as? NSWindow).map(ObjectIdentifier.init) },
                receive: { [weak self] identity in
                    guard let self, let parent = self.anchor?.window, identity == ObjectIdentifier(parent) else { return }
                    self.reposition()
                })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observations += [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification].map {
            NotificationObservation(center: workspace, name: $0) { [weak self] in self?.hide() }
        }
    }
}

private final class UsageHoverContentView: HoverTrackingView {
    init(content: AnyView) {
        super.init(frame: .zero)
        let hosting = NSHostingView(rootView: content.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanelMaterial())
            .clipShape(RoundedRectangle(cornerRadius: PanelStyle.Radius.surface, style: .continuous)))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }
    required init?(coder: NSCoder) { nil }
}

/// Place behind the weekly allowance block to retain native anchor geometry.
struct UsageHoverAnchor: NSViewRepresentable {
    let controller: UsageHoverPanelController
    func makeNSView(context: Context) -> UsageHoverAnchorView {
        let view = UsageHoverAnchorView()
        view.controller = controller
        return view
    }
    func updateNSView(_ view: UsageHoverAnchorView, context: Context) { view.controller = controller }
    static func dismantleNSView(_ view: UsageHoverAnchorView, coordinator: ()) {
        view.controller?.anchorRemoved(view); view.controller = nil
    }
}

final class UsageHoverAnchorView: HoverTrackingView {
    weak var controller: UsageHoverPanelController?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func hoverChanged(_ inside: Bool) { controller?.anchorHoverChanged(inside, anchor: self) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { controller?.anchorRemoved(self) }
        else { controller?.anchorAttached(self) }
    }
}
