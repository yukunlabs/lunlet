// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-02, AC-02.03, AC-02.05; US-17, AC-17.01, AC-17.02, AC-17.03, AC-17.04, AC-17.08.
// Refs: US-16, AC-16.02, AC-16.03; US-21, AC-21.01, AC-21.03; US-17, AC-17.05, AC-17.07.
// Refs: US-04, AC-04.03, AC-04.07, AC-04.10, AC-04.13.
// Refs: US-03, AC-03.04, AC-03.07, AC-03.08, AC-03.10, AC-03.11; US-12, AC-12.04, AC-12.05.
// Refs: US-13, AC-13.02, AC-13.03, AC-13.07.
import AppKit
import Combine
import LunletClaude
import LunletCore

/// Owns the notch-side entry and reports notch availability for the exclusive menu fallback.
@MainActor final class NotchEntryController {
    private(set) var window: NSPanel?
    private var usageObservation: AnyCancellable?
    private var claudeObservation: AnyCancellable?
    private var codexRemaining: Double?
    private var claudeLimits: ClaudePlanLimits?
    private var claudeConnected = false
    /// Re-evaluates the Claude strand once at its weekly reset, so an expired reading turns unknown without polling.
    private var resetDeadline: (at: Date, task: Task<Void, Never>)?
    private var sessionObservation: AnyCancellable?
    private var preferenceObservation: AnyCancellable?
    private var prefersNotch = true
    private var preferred = LunletPreferences()
    private let skinCatalog: SkinCatalog?
    private var skinObservation: AnyCancellable?
    var notchAvailabilityChanged: ((Bool) -> Void)?
    private let companion: CompanionPanelController
    private let mark = LettermarkView(frame: .zero)
    private let display: () -> NSScreen?
    private let available: () -> Bool
    private var monitor: DisplayStateMonitor?
    private var closed = false
    private var cuePose: LettermarkView.Pose?
    init(companion: CompanionPanelController,
         display: @escaping () -> NSScreen? = { PanelScreen.notchDisplay },
         available: @escaping () -> Bool = { SystemDisplayState.isAvailable }, usage: AccountUsageModel? = nil,
         claudeLimits: ClaudePlanLimitsModel? = nil,
         preferences: PreferencesStore? = nil, skinCatalog: SkinCatalog? = nil, sessions: SessionListModel? = nil) {
        self.companion = companion; self.display = display; self.available = available; self.skinCatalog = skinCatalog
        if let sessions {
            sessionObservation = sessions.$compactStatus.removeDuplicates().sink { [weak self] in self?.mark.setSessionStatus($0) }
        }
        if let preferences {
            preferenceObservation = preferences.$value.sink { [weak self] value in
                guard let self else { return }
                let next = value.presentation == .notch
                let modeChanged = self.prefersNotch != next
                self.prefersNotch = next; self.preferred = value
                self.updateSkin(); self.updateAllowances()
                if modeChanged, self.monitor != nil { self.refresh() }
            }
        }
        if let skinCatalog {
            skinObservation = skinCatalog.$skins.sink { [weak self] skins in self?.updateSkin(available: skins) }
        }
        if let usage {
            usageObservation = usage.$state.sink { [weak self, weak usage] state in
                let snapshot: AccountLimitsSnapshot?
                switch state {
                case .available(let value): snapshot = value
                case .loading: snapshot = usage?.displayedSnapshot
                default: snapshot = nil
                }
                self?.codexRemaining = snapshot.flatMap(AccountUsagePresentation.weekly)?.remainingPercent
                self?.updateAllowances()
            }
        }
        if let claudeLimits {
            // Both values arrive from the published change itself; the model's stored values are still the old ones.
            claudeObservation = claudeLimits.$limits.combineLatest(claudeLimits.$connection).sink { [weak self] limits, connection in
                self?.claudeLimits = limits; self?.claudeConnected = connection == .connected
                self?.updateAllowances()
            }
        }
    }

    /// Each selected agent's weekly remaining, in selection order. Claude Code reports percent used, so its strand
    /// shows the complement of a connected, unexpired seven-day reading; the agents are never combined.
    static func allowances(providers: [SessionProvider], codex: Double?, claude: ClaudePlanLimits?, claudeConnected: Bool,
                           now: Date) -> [AgentAllowance] {
        (providers.isEmpty ? [.codex] : providers).map { provider in
            switch provider {
            case .codex: return .init(provider: .codex, remaining: codex)
            case .claude:
                let week = claudeConnected ? ClaudeLimitsText.current(claude?.sevenDay, now: now) : nil
                return .init(provider: .claude, remaining: week.map { 100 - $0.usedPercent })
            }
        }
    }
    private func updateAllowances() {
        guard !closed else { return }
        let now = Date(), providers = preferred.sessionProviders
        mark.setAllowances(Self.allowances(providers: providers, codex: codexRemaining, claude: claudeLimits,
                                           claudeConnected: claudeConnected, now: now))
        let reset = providers.contains(.claude) && claudeConnected
            ? ClaudeLimitsText.current(claudeLimits?.sevenDay, now: now)?.resetsAt : nil
        guard reset != resetDeadline?.at else { return }
        resetDeadline?.task.cancel(); resetDeadline = nil
        guard let reset else { return }
        let delay = reset.timeIntervalSince(now) + 1
        resetDeadline = (reset, Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.resetDeadline = nil
            self?.updateAllowances()
        })
    }

    /// `@Published` delivers the new skins before the catalog stores them, so use the delivered list.
    private func updateSkin(available: [SkinDefinition]? = nil) {
        let choices = available ?? skinCatalog?.skins ?? SkinCatalog.builtins
        mark.setSkin(SkinCatalog.skin(id: preferred.skinID, in: choices))
        mark.setAccent(SkinCatalog.accentHex(for: preferred, in: choices))
    }
    func start() {
        guard !closed, monitor == nil else { return }
        monitor = DisplayStateMonitor { [weak self] in self?.refresh() }
        monitor?.recheck()
    }
    func refresh() {
        guard !closed else { return }
        // A display change or wake may follow a weekly reset that passed while asleep.
        updateAllowances()
        guard prefersNotch else {
            mark.setActive(false); window?.orderOut(nil); notchAvailabilityChanged?(false)
            companion.cancelHoverPreview(); return
        }
        guard available() else {
            mark.setActive(false); window?.orderOut(nil); companion.hide(animated: false); return
        }
        guard let geometry = display().map(PanelScreen.init), let notch = geometry.notch,
              let frame = PanelPlacement.entry(screen: geometry) else {
            mark.setActive(false); window?.orderOut(nil); notchAvailabilityChanged?(false); companion.cancelHoverPreview(); return
        }
        if window == nil {
            let panel = FloatingPanel(identifier: "Lunlet.entry", title: "Lunlet entry", frame: frame, acceptsKey: false,
                                      level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
            panel.collectionBehavior.insert(.stationary); panel.hasShadow = false
            panel.contentView = mark; window = panel
            mark.hover = { [weak self] inside in
                guard let self else { return }
                self.companion.entryHoverChanged(inside, on: self.window?.screen)
                self.updatePose(hovering: inside)
            }
            mark.clicked = { [weak self] in
                guard let self else { return }
                self.companion.toggle(on: self.window?.screen)
            }
        }
        mark.notchSize = notch.size
        window?.setFrame(frame, display: true); mark.layoutSubtreeIfNeeded()
        window?.orderFrontRegardless(); mark.setActive(true)
        notchAvailabilityChanged?(true)
    }
    func panelVisibilityChanged(_ visible: Bool) {
        mark.setDetailsVisible(visible)
        // Once open, the enclosing panel owns the pointer and click-to-pin path.
        window?.ignoresMouseEvents = visible
        if visible {
            // Ignoring mouse events does not guarantee an entry-exit callback.
            // Release the old region and seed the expanded panel's occupancy.
            companion.entryHoverChanged(false, on: window?.screen)
            companion.pointerChanged(companion.window?.frame.contains(NSEvent.mouseLocation) == true)
        }
        updatePose(hovering: visible)
    }
    func cueChanged(_ pose: LettermarkView.Pose?) {
        cuePose = pose; updatePose(hovering: companion.isVisible, replay: pose != nil)
    }
    private func updatePose(hovering: Bool, replay: Bool = false) {
        mark.setPose(hovering ? .awake : cuePose ?? .resting, replay: replay)
    }
    func shutdown() {
        sessionObservation = nil
        guard !closed else { return }; closed = true
        monitor = nil
        for observation in [usageObservation, claudeObservation, preferenceObservation, skinObservation] { observation?.cancel() }
        usageObservation = nil; claudeObservation = nil; preferenceObservation = nil; skinObservation = nil
        resetDeadline?.task.cancel(); resetDeadline = nil
        mark.setActive(false); mark.hover = nil; mark.clicked = nil
        window?.orderOut(nil); window?.close(); window?.contentView = nil; window = nil
        notchAvailabilityChanged?(false); notchAvailabilityChanged = nil
    }
}
