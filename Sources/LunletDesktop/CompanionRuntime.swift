// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.01, AC-32.04; US-19, AC-19.01, AC-19.02, AC-19.03; US-16, AC-16.02, AC-16.03; US-13, AC-13.09.
// Refs: US-41, AC-41.01, AC-41.05.
// Refs: US-33, AC-33.01, AC-33.04, AC-33.05, AC-33.06, AC-33.08, AC-33.09, AC-33.10.
// Refs: US-02, AC-02.03, AC-02.05, AC-02.08; US-04, AC-04.11, AC-04.13; US-13, AC-13.10, AC-13.11; US-21, AC-21.04.
// Refs: US-02, AC-02.07.
// Refs: US-20, AC-20.03, AC-20.05, AC-20.06.
// Refs: US-22, AC-22.01, AC-22.02; US-12, AC-12.04; US-14, AC-14.01.
// Refs: US-17, AC-17.01, AC-17.02, AC-17.04.
// Refs: US-18, AC-18.01; US-20, AC-20.01, AC-20.02; US-25, AC-25.01, AC-25.02; US-26, AC-26.01.
// Refs: US-38, AC-38.01, AC-38.02, AC-38.07; US-40, AC-40.01.
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

/// Writes what Claude Code's Stop hook needs from the running app (the app record, the bundled helper's path and a
/// sweep of ended stops) once, the first time Claude Code is selected while the app runs; a Mac where Claude Code
/// is not selected never has those files written or its stop folders read at launch (US-38, US-25).
@MainActor final class ClaudeHookPreparation {
    private let prepare: @MainActor () -> Void
    private var done = false
    init(_ prepare: @escaping @MainActor () -> Void) { self.prepare = prepare }
    func selectionChanged(_ selected: Bool, running: Bool) {
        guard selected, running, !done else { return }
        done = true
        prepare()
    }
}

/// One application owner for resources that must finish cleanup before macOS quits.
@MainActor public final class CompanionRuntime {
    let preferences: PreferencesStore
    let skins: SkinCatalog
    /// Pet packs on this Mac, for the pet entry and Settings (US-40). Nothing is read at launch: a chosen pack is
    /// read alone, and the folders are listed when Settings first shows the picker (US-25).
    let petPacks = PetPackLibrary(deferred: true)
    /// Claude Code's Stop hook runs the helper this build bundles; stop folders of ended helpers are swept (US-38).
    private let claudeHookPreparation = ClaudeHookPreparation {
        ClaudeHookInstallation.prepare(helper: Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("lunlet-hook", isDirectory: false))
    }
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
    let allowanceNotifier: AllowanceNotifier
    private let claudeHook: ClaudeHookModel
    private var availabilityRefresh: Task<Void, Never>?
    private let notifications: LockedCompletionNotifications
    private let observation: SessionObservationModel
    /// Codex input for reply-capable Feishu cards; unused while cards are notification-only.
    private let replyDispatch: FeishuReplyDispatch
    let sessions: SessionListModel
    let away: AwayModeModel
    let panel: CompanionPanelController
    private let entry: NotchEntryController
    let pet: PetEntryController
    /// The panel's page, so an entry's menu and the application menu can ask for Settings (AC-39.05, AC-39.07).
    let navigation = PanelNavigation()
    private let cues: TransientCuePanel
    private let cueRouter: CueRouter
    private var menu: MenuBarController?
    private var notchAvailable = false
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
        let cueRouter = CueRouter(island: cues)
        self.cueRouter = cueRouter
        let sessions = SessionListModel(presenter: cueRouter)
        // The entry draws one strand per selected agent, so it follows Claude's limits as it follows Codex usage.
        // Plan limits connect on their own while Claude Code is selected, unless the owner disconnected them (AC-33.08).
        let claudeLimits = ClaudePlanLimitsModel(connectsAutomatically: true, choices: .standard)
        self.claudeLimits = claudeLimits
        // Allowance notifications follow the readings the cards already take (AC-41.05); Notification Center is the
        // deliverer only in the bundled app.
        let allowanceNotifier = AllowanceNotifier(deliverer: AllowanceNotificationCenter.system())
        self.allowanceNotifier = allowanceNotifier
        allowanceNotifier.observe(preferences: preferences)
        allowanceNotifier.observe(usage: usage)
        allowanceNotifier.observe(claudeLimits: claudeLimits)
        let claudeHook = ClaudeHookModel(connectsAutomatically: true)
        self.claudeHook = claudeHook
        let entry = NotchEntryController(companion: panel, usage: usage, claudeLimits: claudeLimits, preferences: preferences,
                                         skinCatalog: skins, sessions: sessions)
        self.entry = entry
        let pet = PetEntryController(companion: panel, sessions: sessions, preferences: preferences, skins: skins, packs: petPacks)
        self.pet = pet
        pet.settingsAction = { [weak navigation] in navigation?.openSettings() }
        cueRouter.pet = pet
        cueRouter.mode = preferences.value.presentation
        cueRouter.soundEnabled = preferences.value.needsYouSound
        self.notifications = notifications
        // Sources start only for selected providers; deselecting one stops its source.
        let observation = SessionObservationModel(model: sessions, providers: Set(preferences.value.sessionProviders)) { provider in
            switch provider {
            case .codex: CodexSessionMonitor(accounting: accounting)
            case .claude: ClaudeSessionMonitor()
            }
        }
        self.observation = observation
        replyDispatch = ReplyDispatch.make(observation: observation)
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
            guard let self else { return }
            self.observation.setProviders(Set(providers))
            // An agent that is not selected has no account or history read, and what was read does not linger
            // (AC-19.01, AC-25.01); selecting it reads again.
            self.usage.setActive(providers.contains(.codex))
            self.history.setActive(providers.contains(.codex)); self.claudeHistory.setActive(providers.contains(.claude))
            guard self.started else { return }
            self.history.refreshIfNeeded(); self.claudeHistory.refreshIfNeeded()
            // The helper's files are in place before the hook that runs it is connected.
            self.claudeHookPreparation.selectionChanged(providers.contains(.claude), running: true)
            self.claudeLimits.setActive(providers.contains(.claude))
            self.claudeHook.setActive(providers.contains(.claude))
        }.store(in: &preferenceObservations)
        preferences.$value.map(\.presentation).removeDuplicates().sink { [weak self] presentation in
            self?.cueRouter.mode = presentation
            self?.updateMenuVisibility(presentation: presentation)
        }.store(in: &preferenceObservations)
        preferences.$value.map(\.needsYouSound).removeDuplicates().sink { [weak self] enabled in
            self?.cueRouter.soundEnabled = enabled
        }.store(in: &preferenceObservations)
        preferences.$value.map(\.channel).removeDuplicates().sink { [weak self] channel in
            // Published emits before value changes; this owns routing during that transition.
            self?.selectedChannel = channel
            self?.botSetup.select(channel.botChannel)
            self?.configureNotifications(channel: channel)
        }
            .store(in: &preferenceObservations)
        panel.visibilityChanged = { [weak entry, weak pet, weak panel, weak claudeLimits] visible in
            entry?.panelVisibilityChanged(visible)
            pet?.panelVisibilityChanged(visible, frame: panel?.window?.frame)
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
            // Each of these reads only while its agent is selected.
            cues?.hideImmediately(); usage?.refreshIfNeeded(); history?.refreshIfNeeded()
            self?.claudeHistory.refreshIfNeeded()
            if self?.preferences.value.sessionProviders.contains(.claude) == true { self?.claudeLimits.refresh() }
            usageHover?.prepareForParentPresentation(); claudeUsageHover?.prepareForParentPresentation()
        }
        allowanceNotifier.openProvider = { [weak self, weak sessions, weak panel] provider in
            guard self?.closing == nil else { return }
            sessions?.focus(provider: provider)
            panel?.show()
        }
        panel.setContent { [weak self, navigation] in
            AnyView(CompanionPanel(preferences: preferences, skins: skins, setup: setup, botSetup: botSetup,
                                   notifications: notifications, usage: usage, sessions: sessions,
                                   history: history, usageHover: usageHover,
                                   claudeHistory: claudeHistory, claudeUsageHover: claudeUsageHover,
                                   refresh: { [weak self] in self?.refresh() }, navigation: navigation)
                .environment(\.claudePlanLimits, self?.claudeLimits).environment(\.claudeHook, self?.claudeHook)
                .environment(\.allowanceNotifier, self?.allowanceNotifier)
                .environment(\.appUpdater, self?.updater).environment(\.petPacks, self?.petPacks))
        }
    }

    public func start() {
        guard menu == nil, closing == nil else { return }
        let menu = MenuBarController(panel: panel, sessions: sessions, usage: usage, claudeLimits: claudeLimits, preferences: preferences)
        self.menu = menu
        // Started before the panel can first open, so its content sees the updater; Sparkle's window opens with the
        // panel out of the way.
        updater = AppUpdater.start()
        updater?.willPresent = { [weak panel] in panel?.hide() }
        entry.notchAvailabilityChanged = { [weak self] available in
            self?.notchAvailable = available
            self?.updateMenuVisibility()
        }
        pet.refreshAction = { [weak self] in self?.refresh() }
        entry.start()
        pet.start()
        started = true
        usage.start(); history.refreshIfNeeded(); claudeHistory.refreshIfNeeded(); observation.start()
        // The helper's files are in place before the hook that runs it is connected, and only for a selected Claude Code.
        claudeHookPreparation.selectionChanged(preferences.value.sessionProviders.contains(.claude), running: true)
        claudeLimits.setActive(preferences.value.sessionProviders.contains(.claude))
        claudeHook.setActive(preferences.value.sessionProviders.contains(.claude))
        setupLoading = Task { await setup.load() }
        botSetup.sealSavedConnections()
        notifications.replyWindowObserver = { [weak observation] open in observation?.setClaudeReplyWindow(open) }
    }

    public func showPanel() {
        guard closing == nil else { return }
        panel.show()
    }
    /// Opens the panel on its Settings page, for the application menu (AC-39.07).
    public func showSettings() {
        guard closing == nil else { return }
        navigation.openSettings()
        panel.show()
    }

    /// One application entry at a time: the menu-bar item appears in menu-bar mode and as the fallback without a
    /// notch entry, never beside the pet (AC-21.03, AC-39.01).
    private func updateMenuVisibility(presentation: EntryPresentation? = nil) {
        let mode = presentation ?? preferences.value.presentation
        menu?.setVisible(mode == .menuBar || (mode == .notch && !notchAvailable))
    }
    func refresh() {
        guard closing == nil else { return }
        usage.refresh(); history.refresh(); claudeHistory.refresh()
        claudeLimits.refresh()
        observation.refresh(); entry.refresh(); notifications.checkAuthorization(); allowanceNotifier.checkAuthorization()
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
        entry.shutdown(); pet.shutdown()
        panel.shutdown(); usageHover.shutdown(); claudeUsageHover.shutdown()
        // Each stage is logged by number as it finishes, or as `uncertain` with `timeout` when it overran its bound,
        // so a quit never waits on a provider or a socket and the log names the cleanup that stalled (AC-12.04,
        // AC-14.01). An overrunning stage keeps finishing in the background while the next one starts.
        let operation = DiagnosticOperation()
        func stage(_ number: Int, _ body: @escaping @MainActor () async -> Void) async {
            let work = Task { await body() }
            let finished = await BoundedWait.settle(work, limit: Self.shutdownStageLimit)
            DiagnosticLog.record(.shutdown, component: .app, outcome: finished ? .processing : .uncertain, operation: operation,
                                 reason: finished ? nil : .timeout, code: number)
        }
        let task = Task {
            await stage(1) {
                self.setupLoading?.cancel(); await self.setupLoading?.value; self.setupLoading = nil
                self.availabilityRefresh?.cancel(); await self.availabilityRefresh?.value; self.availabilityRefresh = nil
            }
            await stage(2) { await self.observation.shutdown() }
            setup.checkAuthorizationAction = nil
            await stage(3) { await self.botSetup.shutdown(); self.savedBotEnrollment = nil }
            await stage(4) { await self.notifications.shutdown(); self.savedEnrollment = nil }
            sessions.shutdown()
            cues.shutdown()
            await stage(5) { await self.away.shutdown() }
            await stage(6) { await self.usage.shutdown(); await self.allowanceNotifier.shutdown() }
            await stage(7) { await self.history.shutdown(); await self.claudeHistory.shutdown() }
            await stage(8) { await self.claudeLimits.shutdown() }
            await stage(9) { await self.setup.shutdown() }
        }
        closing = task
        await task.value
    }
    /// A cleanup stage's share of the quit. Nine stages never reach the application's termination watchdog together
    /// unless several stall at once, and one stalled stage delays the quit by this much, not indefinitely.
    private static let shutdownStageLimit: Duration = .seconds(2)
}
