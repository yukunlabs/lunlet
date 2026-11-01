// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.01, AC-32.04; US-19, AC-19.01, AC-19.02, AC-19.03; US-16, AC-16.02, AC-16.03; US-13, AC-13.09.
// Refs: US-33, AC-33.01, AC-33.04, AC-33.05, AC-33.06, AC-33.08, AC-33.09, AC-33.10.
// Refs: US-02, AC-02.03, AC-02.05, AC-02.08; US-04, AC-04.11, AC-04.13.
// Refs: US-02, AC-02.07.
// Refs: US-20, AC-20.03, AC-20.05, AC-20.06.
// Refs: US-22, AC-22.01, AC-22.02.
// Refs: US-17, AC-17.01, AC-17.02, AC-17.04.
// Refs: US-18, AC-18.01; US-20, AC-20.01, AC-20.02; US-25, AC-25.02; US-26, AC-26.01.
// Refs: US-06, AC-06.01, AC-06.05; US-05, AC-05.06.
// Refs: US-02, AC-02.01, AC-02.02, AC-02.04, AC-02.05; US-11, AC-11.03;
// Refs: US-01, AC-01.04; US-04, AC-04.03, AC-04.05, AC-04.08, AC-04.09; US-05, AC-05.05.
// Refs: US-03, AC-03.05, AC-03.06, AC-03.07, AC-03.08, AC-03.10; US-12, AC-12.04, AC-12.05; US-13, AC-13.02, AC-13.04.
// Refs: US-35, AC-35.01, AC-35.04.
// Refs: US-05, AC-05.09; US-08, AC-08.01, AC-08.05.
import AppKit
import Combine
import LunletClaude
import LunletCodex
import LunletCore
import LunletFeishu
import LunletMessaging
import SwiftUI

/// One application owner for resources that must finish cleanup before macOS quits.
@MainActor public final class CompanionRuntime {
    let preferences: PreferencesStore
    let skins: SkinCatalog
    private var preferenceObservations: Set<AnyCancellable> = []
    private var savedEnrollment: FeishuEnrollment?
    private var setupLoading: Task<Void, Never>?
    let botSetup: BotChannelSetupModel
    private var savedBotEnrollment: BotEnrollment?
    private var selectedChannel: CommunicationChannel
    let setup: FeishuSetupModel
    let usage: AccountUsageModel
    let history: LocalUsageModel
    private let usageHover: UsageHoverPanelController
    let claudeHistory: LocalUsageModel
    private let claudeUsageHover: UsageHoverPanelController
    let claudeLimits: ClaudePlanLimitsModel
    private var availabilityRefresh: Task<Void, Never>?
    private let notifications: LockedCompletionNotifications
    private let observation: SessionObservationModel
    /// Codex input for reply-capable Feishu cards; unused while cards are notification-only.
    private let replyDispatch: FeishuReplyDispatch
    let sessions: SessionListModel
    let away: AwayModeModel
    let panel: CompanionPanelController
    private let entry: NotchEntryController
    private let cues: TransientCuePanel
    private var menu: MenuBarController?
    /// Sparkle, only in a configured release build; previews and unconfigured builds never check (AC-35.04).
    private var updater: AppUpdater?
    private var started = false
    private var closing: Task<Void, Never>?

    public convenience init() {
        self.init(preferences: PreferencesStore(), skins: SkinCatalog(), notifications: LockedCompletionNotifications())
    }
    init(preferences: PreferencesStore, skins: SkinCatalog, notifications: LockedCompletionNotifications,
         botSetup: BotChannelSetupModel = BotChannelSetupModel()) {
        self.botSetup = botSetup
        self.selectedChannel = preferences.value.channel
        self.preferences = preferences
        self.skins = skins
        let setup = FeishuSetupModel(), usage = AccountUsageModel(), away = AwayModeModel()
        let accounting = CodexAccountingCatalog()
        let history = LocalUsageModel(reader: CodexLocalUsageReader(accounting: accounting)), usageHover = UsageHoverPanelController()
        self.history = history; self.usageHover = usageHover
        let claudeHistory = LocalUsageModel(reader: ClaudeLocalUsageReader())
        let claudeUsageHover = UsageHoverPanelController()
        self.claudeHistory = claudeHistory; self.claudeUsageHover = claudeUsageHover
        let panel = CompanionPanelController()
        let cues = TransientCuePanel(expanded: { [weak panel] in panel?.isVisible == true })
        let sessions = SessionListModel(presenter: cues)
        // The entry draws one strand per selected agent, so it follows Claude's limits as it follows Codex usage.
        // Plan limits connect on their own while Claude Code is selected, unless the owner disconnected them (AC-33.08).
        let claudeLimits = ClaudePlanLimitsModel(connectsAutomatically: true, choices: .standard)
        self.claudeLimits = claudeLimits
        let entry = NotchEntryController(companion: panel, usage: usage, claudeLimits: claudeLimits, preferences: preferences,
                                         skinCatalog: skins, sessions: sessions)
        self.entry = entry
        self.notifications = notifications
        // Sources start only for selected providers; deselecting one stops its source.
        let observation = SessionObservationModel(model: sessions, providers: Set(preferences.value.sessionProviders)) { provider in
            switch provider {
            case .codex: CodexSessionMonitor(accounting: accounting)
            case .claude: ClaudeSessionMonitor()
            }
        }
        self.observation = observation
        replyDispatch = CodexReplyDispatch.make(observation: observation)
        observation.snapshotReceived = { [weak notifications] in notifications?.receive($0, baseline: $1) }
        botSetup.checkAuthorizationAction = { [weak notifications] in notifications?.checkAuthorization() }
        setup.checkAuthorizationAction = { [weak notifications] in notifications?.checkAuthorization() }
        self.cues = cues
        self.setup = setup; self.usage = usage; self.away = away; self.sessions = sessions; self.panel = panel
        setup.enrollmentChanged = { [weak self] enrollment in
            guard let self else { return }
            self.savedEnrollment = enrollment
            if self.selectedChannel == .feishu { self.configureNotifications() }
        }
        botSetup.enrollmentChanged = { [weak self] enrollment in
            guard let self else { return }
            self.savedBotEnrollment = enrollment
            if self.selectedChannel != .feishu { self.configureNotifications() }
        }
        preferences.$value.map(\.historyDays).removeDuplicates().sink { [weak history, weak claudeHistory] in
            history?.setHistoryDays($0); claudeHistory?.setHistoryDays($0)
        }.store(in: &preferenceObservations)
        preferences.$value.map(\.sessionProviders).removeDuplicates().sink { [weak self] providers in
            self?.observation.setProviders(Set(providers))
            if providers.contains(.claude), self?.started == true { self?.claudeHistory.refreshIfNeeded() }
            if self?.started == true { self?.claudeLimits.setActive(providers.contains(.claude)) }
        }.store(in: &preferenceObservations)
        preferences.$value.map(\.channel).removeDuplicates().sink { [weak self] channel in
            // Published emits before value changes; this owns routing during that transition.
            self?.selectedChannel = channel
            self?.botSetup.select(channel.botChannel)
            self?.configureNotifications(channel: channel)
        }
            .store(in: &preferenceObservations)
        panel.visibilityChanged = { [weak entry, weak claudeLimits] visible in
            entry?.panelVisibilityChanged(visible)
            // Claude limits are read on file events only while the panel can show them.
            claudeLimits?.setWatching(visible)
        }
        cues.changed = { [weak entry] in entry?.cueChanged($0) }
        // Chart series use the same single control tint as the panel.
        usageHover.setContent {
            AnyView(PanelTinted(preferences: preferences, skins: skins, agent: .codex) {
                UsageOverviewPanel(account: usage, history: history)
            })
        }
        claudeUsageHover.setContent {
            // Claude's weekly trend in percent used, then daily usage opening on cost (AC-33.09, AC-33.10).
            AnyView(PanelTinted(preferences: preferences, skins: skins, agent: .claude) { [limits = self.claudeLimits] in
                UsageOverviewPanel(claudeLimits: limits, history: claudeHistory)
            })
        }
        for hover in [usageHover, claudeUsageHover] {
            // Either chart keeps the panel open while the pointer is inside it.
            hover.visibilityChanged = { [weak panel, weak usageHover, weak claudeUsageHover] _ in
                panel?.auxiliaryHoverChanged(usageHover?.isVisible == true || claudeUsageHover?.isVisible == true)
            }
            hover.interactionOccurred = { [weak panel] in panel?.pin() }
            hover.dismissalRequested = { [weak panel] in panel?.hide() }
        }
        panel.beforeHide = { [weak usageHover, weak claudeUsageHover] in usageHover?.hide(); claudeUsageHover?.hide() }
        panel.beforeShow = { [weak self, weak cues, weak usage, weak history, weak usageHover, weak claudeUsageHover, weak sessions] in
            // Opening right after a cue shows that cue's agent and conversation (AC-13.09).
            sessions?.applyCueFocus()
            cues?.hideImmediately(); usage?.refreshIfNeeded(); history?.refreshIfNeeded()
            if self?.preferences.value.sessionProviders.contains(.claude) == true {
                self?.claudeHistory.refreshIfNeeded(); self?.claudeLimits.refresh()
            }
            usageHover?.prepareForParentPresentation(); claudeUsageHover?.prepareForParentPresentation()
        }
        panel.setContent { [weak self] in
            AnyView(CompanionPanel(preferences: preferences, skins: skins, setup: setup, botSetup: botSetup,
                                   notifications: notifications, usage: usage, sessions: sessions,
                                   history: history, usageHover: usageHover,
                                   claudeHistory: claudeHistory, claudeUsageHover: claudeUsageHover,
                                   refresh: { [weak self] in self?.refresh() })
                .environment(\.claudePlanLimits, self?.claudeLimits).environment(\.appUpdater, self?.updater))
        }
    }

    public func start() {
        guard menu == nil, closing == nil else { return }
        let menu = MenuBarController(panel: panel, sessions: sessions)
        self.menu = menu
        // Started before the panel can first open, so its content sees the updater; Sparkle's window opens with the
        // panel out of the way.
        updater = AppUpdater.start()
        updater?.willPresent = { [weak panel] in panel?.hide() }
        entry.notchAvailabilityChanged = { [weak menu] in menu?.setNotchEntryAvailable($0) }
        entry.start()
        started = true
        usage.start(); history.refreshIfNeeded(); observation.start()
        if preferences.value.sessionProviders.contains(.claude) { claudeHistory.refreshIfNeeded() }
        claudeLimits.setActive(preferences.value.sessionProviders.contains(.claude))
        setupLoading = Task { await setup.load() }
    }

    public func showPanel() {
        guard closing == nil else { return }
        panel.show()
    }

    func refresh() {
        guard closing == nil else { return }
        usage.refresh(); history.refresh()
        if preferences.value.sessionProviders.contains(.claude) { claudeHistory.refresh() }
        claudeLimits.refresh()
        observation.refresh(); entry.refresh(); notifications.checkAuthorization()
        if availabilityRefresh == nil {
            availabilityRefresh = Task { defer { availabilityRefresh = nil }; await away.refreshAvailability() }
        }
    }

    private func configureNotifications(channel: CommunicationChannel? = nil) {
        guard closing == nil else { return }
        let selected = channel ?? selectedChannel
        // The Feishu sender and its reply service live exactly as long as Feishu is selected with an enrollment.
        if selected == .feishu {
            notifications.configure(sender: savedEnrollment.map { FeishuCompletionSender(enrollment: $0, dispatch: replyDispatch) })
        }
        else if let enrollment = savedBotEnrollment, enrollment.binding.channel == selected.botChannel {
            notifications.configure(sender: OwnerChannelCompletionSender(enrollment: enrollment, dispatch: replyDispatch))
        } else { notifications.configure(sender: nil) }
    }

    /// Hides and releases windows synchronously, then awaits every owned cleanup.
    public func shutdown() async {
        if let closing { await closing.value; return }
        preferenceObservations.removeAll()
        menu?.shutdown(); menu = nil
        updater?.willPresent = nil
        entry.shutdown()
        panel.shutdown(); usageHover.shutdown(); claudeUsageHover.shutdown()
        // Each finished stage is logged by number, so a quit that stalls names the cleanup it waited on (AC-14.01).
        let operation = DiagnosticOperation()
        func reached(_ stage: Int) {
            DiagnosticLog.record(.shutdown, component: .app, outcome: .processing, operation: operation, code: stage)
        }
        let task = Task {
            setupLoading?.cancel(); await setupLoading?.value; setupLoading = nil
            availabilityRefresh?.cancel(); await availabilityRefresh?.value; availabilityRefresh = nil
            reached(1)
            await observation.shutdown(); reached(2)
            setup.checkAuthorizationAction = nil
            await botSetup.shutdown(); savedBotEnrollment = nil; reached(3)
            await notifications.shutdown(); savedEnrollment = nil; reached(4)
            sessions.shutdown()
            cues.shutdown()
            await away.shutdown(); reached(5)
            await usage.shutdown(); reached(6)
            await history.shutdown(); await claudeHistory.shutdown(); reached(7)
            await claudeLimits.shutdown(); reached(8)
            await setup.shutdown(); reached(9)
        }
        closing = task
        await task.value
    }
}
