// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-17, AC-17.08; US-24, AC-24.01, AC-24.02, AC-24.03; US-13, AC-13.09.
// Refs: US-02, AC-02.07; US-22, AC-22.01, AC-22.03.
// Refs: US-16, AC-16.02; US-18, AC-18.01; US-20, AC-20.02; US-31, AC-31.01, AC-31.03.
// Refs: US-01, AC-01.01, AC-01.02, AC-01.04, AC-01.06, AC-01.08; US-02, AC-02.05.
// Refs: US-03, AC-03.01, AC-03.05, AC-03.06, AC-03.08, AC-03.09, AC-03.10.
// Refs: US-04, AC-04.01, AC-04.03, AC-04.04, AC-04.05, AC-04.07, AC-04.08, AC-04.09, AC-04.10; US-05, AC-05.03, AC-05.07.
// Refs: US-12, AC-12.02, AC-12.04, AC-12.05; US-15, AC-15.03.
// Refs: US-19, AC-19.01, AC-19.02, AC-19.03, AC-19.04, AC-19.05; US-33, AC-33.01, AC-33.04, AC-33.09.
// Refs: US-35, AC-35.01, AC-35.04.
import AppKit
import LunletCore
import SwiftUI

// Explicit alias selects the property wrapper on SDKs that also expose a State macro.
// Every Lunlet view uses this one alias.
typealias ViewState<Value> = State<Value>

struct CompanionPanel: View {
    /// Home is the single selected provider's page, or the Overview when several are selected.
    private enum Page: Equatable { case home, provider(SessionProvider), settings }
    @ObservedObject private var preferences: PreferencesStore
    @ObservedObject private var skins: SkinCatalog
    @ObservedObject private var setup: FeishuSetupModel
    @ObservedObject private var botSetup: BotChannelSetupModel
    @ObservedObject private var usage: AccountUsageModel
    @ObservedObject private var history: LocalUsageModel
    @ObservedObject private var claudeHistory: LocalUsageModel
    private let usageHover: UsageHoverPanelController
    private let claudeUsageHover: UsageHoverPanelController
    private let refresh: () -> Void
    @ObservedObject private var sessions: SessionListModel
    @ObservedObject private var notifications: LockedCompletionNotifications
    @ViewState private var page = Page.home
    /// Each provider tab keeps its own Active/History choice.
    @ViewState private var historyShown: [SessionProvider: Bool] = [:]
    @ViewState private var connectionExpanded = false
    @ViewState private var connectionHovered = false
    /// The Settings category a page asked for; the header's Settings button opens the default category.
    @ViewState private var settingsEntry: PreferenceCategory?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionPanelHost) private var host
    @Environment(\.notchBand) private var band
    /// Present only in a configured release build; its notice sits beside the channel entry (AC-35.01, AC-35.04).
    @Environment(\.appUpdater) private var updater
    /// A chosen skin or owner accent tints the controls; otherwise a contrast-safe default does.
    private var accent: Color { skins.controlTint(for: preferences.value).color }

    init(preferences: PreferencesStore, skins: SkinCatalog, setup: FeishuSetupModel, botSetup: BotChannelSetupModel,
                notifications: LockedCompletionNotifications, usage: AccountUsageModel, sessions: SessionListModel,
                history: LocalUsageModel, usageHover: UsageHoverPanelController,
                claudeHistory: LocalUsageModel, claudeUsageHover: UsageHoverPanelController,
                refresh: @escaping () -> Void, openingTab: SessionProvider? = nil, openingHistory: Bool = false,
                openingSettings: PreferenceCategory? = nil) {
        // The runtime opens home; the opt-in page renders open a provider tab or a Settings category directly.
        _page = ViewState(initialValue: openingSettings != nil ? .settings : openingTab.map(Page.provider) ?? .home)
        _settingsEntry = ViewState(initialValue: openingSettings)
        _historyShown = ViewState(initialValue: openingTab.map { [$0: openingHistory] } ?? [:])
        self.preferences = preferences; self.skins = skins
        self.history = history; self.usageHover = usageHover; self.refresh = refresh
        self.claudeHistory = claudeHistory; self.claudeUsageHover = claudeUsageHover
        self.botSetup = botSetup; self.notifications = notifications
        self.setup = setup; self.usage = usage; self.sessions = sessions
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if page == .settings {
                    PreferencesPane(preferences: preferences, skins: skins, setup: setup, botSetup: botSetup,
                                    notifications: notifications, openConnection: { connectionExpanded = true },
                                    initialCategory: settingsEntry)
                } else {
                    // A page that fits fills the stable page budget, its last flexible element taking the rest of the
                    // height, so it never ends in blank glass; a longer page scrolls instead.
                    ViewThatFits(in: .vertical) {
                        pageContent
                            .padding(.horizontal, PanelStyle.Grid.margin)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        ScrollView {
                            pageContent
                                .padding(.horizontal, PanelStyle.Grid.margin)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .environment(\.openSettings) { category in
                        hideUsageCharts(); connectionExpanded = false; settingsEntry = category; page = .settings
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .overlay(alignment: .bottomLeading) {
            if connectionExpanded {
                GeometryReader { geometry in
                    ZStack(alignment: .bottomLeading) {
                        // A clear catcher: clicking elsewhere in the panel closes only the card.
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { connectionExpanded = false }
                            .accessibilityLabel("Dismiss connection card")
                        // The card's body may use every point above the footer that its own chrome leaves free.
                        ConnectionCard(preferences: preferences, setup: setup, botSetup: botSetup, notifications: notifications,
                                       bodyLimit: geometry.size.height - PanelStyle.Layout.footerHeight - ConnectionCard.chrome,
                                       close: { connectionExpanded = false })
                            .padding(.leading, PanelStyle.Space.module)
                            .padding(.bottom, PanelStyle.Layout.footerHeight)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
        }
        .preference(key: CompanionPanelTabRow.self, value: hasTabs)
        .onReceive(NotificationCenter.default.publisher(for: .companionPanelDidHide)) { notification in
            guard host == nil || (notification.object as AnyObject?).map(ObjectIdentifier.init) == host else { return }
            connectionExpanded = false
        }
        // Opening right after a cue shows its agent's page with the conversation selected, in Active or History
        // wherever it now is (AC-13.09).
        .onChange(of: sessions.cueFocus) { _, focus in
            guard let focus, selected.contains(focus.provider) else { return }
            connectionExpanded = false
            historyShown[focus.provider] = sessions.history.contains { $0.observation.sessionID == focus.sessionID }
            if hasTabs { select(tab: focus.provider) } else { page = .home }
        }
        .font(PanelStyle.Text.secondary).tint(accent)
        .labelStyle(CompactLabelStyle())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(PanelStyle.motion(reduce: reduceMotion), value: connectionExpanded)
    }

    private var isRefreshing: Bool {
        usage.state == .loading || history.isLoading || claudeHistory.isLoading || sessions.isRefreshing
    }
    private var selected: [SessionProvider] { preferences.value.sessionProviders }
    /// One selected provider is shown directly; several share an Overview with separate provider pages.
    private var shownProvider: SessionProvider? {
        guard page != .settings else { return nil }
        if case .provider(let provider) = page { return ProviderPages.shown(selected: selected, requested: provider) }
        return ProviderPages.shown(selected: selected, requested: nil)
    }
    private var homeTitle: String { ProviderPages.homeTitle(selected: selected) }
    private var usageModels: [SessionProvider: LocalUsageModel] { [.codex: history, .claude: claudeHistory] }

    @ViewBuilder private var pageContent: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Grid.margin) {
            if selected.isEmpty {
                Text("The selected agents are unavailable in this build.")
                    .font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
                Button("Choose an available agent") { page = .settings }
            } else if let provider = shownProvider {
                providerPage(provider)
            } else {
                ProviderOverview(codexHistory: history, claudeHistory: claudeHistory, account: usage, providers: selected,
                                 accentHex: allowanceAccent)
            }
        }
    }

    @ViewBuilder private func providerPage(_ provider: SessionProvider) -> some View {
        switch provider {
        case .codex:
            AccountUsageSummary(model: usage, hoverPanel: usageHover,
                historyDays: history.historyDays, accentHex: allowanceAccent)
        case .claude:
            ClaudeUsageSummary(history: claudeHistory, hoverPanel: claudeUsageHover, accentHex: allowanceAccent)
        }
        SessionPanel(model: sessions, usage: usageModels, provider: provider,
                     showingHistory: Binding(get: { historyShown[provider] ?? false },
                                             set: { historyShown[provider] = $0 }))
    }
    private func hideUsageCharts() { usageHover.hide(); claudeUsageHover.hide() }
    private func select(tab provider: SessionProvider?) {
        hideUsageCharts()
        page = provider.map(Page.provider) ?? .home
    }

    private var hasTabs: Bool { !ProviderPages.tabs(selected: selected).isEmpty }

    /// Beside a notch the header shares the menu-bar band: the page title at the leading edge and Refresh and
    /// Settings at the trailing edge, both clear of the lettering. Several agents need a tab bar wider than the
    /// band, so it takes a row below the band and names the page itself. Without a notch one normal header row
    /// holds the title or tabs and the actions. VoiceOver reads the title or tabs first, then the actions.
    @ViewBuilder private var header: some View {
        if let band {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Group { if !hasTabs || page == .settings { pageTitle } }
                        .frame(width: band.leadingWidth, alignment: .leading).accessibilitySortPriority(3)
                    Spacer(minLength: 0)
                    // Two 28 pt buttons keep their targets beside a wide notch by closing their gap first.
                    actions(spacing: min(PanelStyle.Space.tight, max(0, band.trailingWidth - 2 * PanelStyle.Layout.iconButton)))
                        .frame(width: band.trailingWidth, alignment: .trailing).accessibilitySortPriority(1)
                }
                .padding(.horizontal, PanelStyle.Space.margin)
                .frame(height: band.height)
                if hasTabs && page != .settings {
                    tabStrip.padding(.horizontal, PanelStyle.Grid.margin)
                        .frame(maxWidth: .infinity, alignment: .leading).frame(height: PanelStyle.Layout.headerHeight)
                        .accessibilitySortPriority(2)
                }
            }
            .padding(.bottom, PanelStyle.Layout.headerGap)
            .accessibilityElement(children: .contain)
        } else {
            HStack(spacing: PanelStyle.Space.tight) {
                if hasTabs && page != .settings { tabStrip } else { pageTitle }
                Spacer(minLength: PanelStyle.Space.medium)
                actions(spacing: PanelStyle.Space.tight)
            }
            .frame(height: PanelStyle.Layout.headerHeight)
            .padding(.horizontal, PanelStyle.Space.margin).padding(.bottom, PanelStyle.Layout.headerGap)
        }
    }

    /// The page title; in Settings, a Back button before it.
    @ViewBuilder private var pageTitle: some View {
        if page == .settings {
            HStack(spacing: 0) {
                Button { page = .home } label: { Image(systemName: "chevron.backward") }
                    .buttonStyle(PanelIconButtonStyle())
                    .help("Back to " + homeTitle).accessibilityLabel("Back to " + homeTitle)
                title("Settings")
            }
            .padding(.leading, -6)
        } else {
            title(shownProvider?.displayName ?? homeTitle)
        }
    }
    private func title(_ text: String) -> some View {
        // A narrow band beside a wide notch scales the headline down, never below 10 points.
        Text(text).font(PanelStyle.Text.title).lineLimit(1).minimumScaleFactor(0.8)
            .accessibilityAddTraits(.isHeader)
    }

    private func actions(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Button(action: refresh) {
                ZStack {
                    Image(systemName: "arrow.clockwise").opacity(isRefreshing ? 0 : 1)
                    if isRefreshing { ProgressView().controlSize(.mini) }
                }
            }
            .buttonStyle(PanelIconButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh all available account, usage, and connection data (⌘R)")
            .accessibilityLabel(isRefreshing ? "Refreshing" : "Refresh all")
            if page != .settings {
                Button { hideUsageCharts(); connectionExpanded = false; settingsEntry = nil; page = .settings } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(PanelIconButtonStyle())
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (⌘,)").accessibilityLabel("Settings")
            }
        }
    }

    /// The tab bar starts on the cards' edge, so its first label shares their text edge and later agents append to
    /// the right; tabs wider than the room scroll horizontally rather than shrinking their text.
    private var tabStrip: some View {
        ViewThatFits(in: .horizontal) {
            tabBar
            ScrollView(.horizontal, showsIndicators: false) { tabBar }
        }
    }

    /// The tab bar: Overview, then each selected provider in selection order, in the panel's segmented style.
    private var tabBar: some View {
        let tabs = ProviderPages.tabs(selected: selected).map { PanelSegmentedControl<SessionProvider?>.Segment(
            value: $0, title: $0?.displayName ?? "Overview") }
        return PanelSegmentedControl(selection: Binding(get: { shownProvider }, set: { select(tab: $0) }), segments: tabs,
                                     label: "Agent pages")
            .help("Overview summarizes every selected agent; each agent tab keeps its own page.")
    }

    private var footer: some View {
        HStack(spacing: PanelStyle.Space.margin) {
            if page == .settings {
                Spacer(minLength: PanelStyle.Space.tight)
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .keyboardShortcut("q", modifiers: .command)
            } else {
                HStack(spacing: PanelStyle.Space.medium) {
                    connectionButton
                    if let updater { UpdateNoticeButton(updater: updater) }
                }
                Spacer(minLength: PanelStyle.Space.tight)
            }
        }
        .padding(.horizontal, PanelStyle.Space.margin)
        .frame(height: PanelStyle.Layout.footerHeight)
        .overlay(alignment: .top) {
            if page == .settings { Rectangle().fill(PanelStyle.separator).frame(height: 0.5) }
        }
    }

    private var connectionButton: some View {
        Button {
            connectionExpanded.toggle()
            if connectionExpanded { hideUsageCharts(); if preferences.value.channel == .feishu { setup.connect() } }
        } label: {
            HStack(spacing: PanelStyle.Space.small) {
                // The colored icon alone carries the state; the words stay in help and VoiceOver.
                Image(systemName: channelHealth.symbol)
                    .foregroundStyle(channelHealth == .notConnected ? accent : channelHealth.tone.color)
                    .frame(width: 14).accessibilityHidden(true)
                Text(channelName).foregroundStyle(.primary)
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(connectionExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .font(PanelStyle.Text.secondary.weight(.medium))
            .padding(.horizontal, PanelStyle.Grid.textInset).frame(height: 26)
            .background(connectionExpanded ? AnyShapeStyle(.tint.opacity(0.18))
                        : connectionHovered ? AnyShapeStyle(.primary.opacity(0.1)) : AnyShapeStyle(PanelStyle.moduleFill),
                        in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { connectionHovered = $0 }
        .animation(PanelStyle.hover(reduce: reduceMotion), value: connectionHovered)
        .help(channelHealth.word + " · " + channelExplanation)
        .accessibilityLabel(channelName + ", " + channelHealth.word + ": " + channelExplanation)
        .accessibilityValue(connectionExpanded ? "Expanded" : "Collapsed")
    }

    private var readinessStages: [ReadinessStage] {
        preferences.value.channel == .feishu
            ? setup.readinessStages(delivery: notifications.status, authorization: notifications.authorizationCheck)
            : botSetup.readinessStages(delivery: notifications.status, authorization: notifications.authorizationCheck)
    }
    private var allowanceAccent: String? { skins.accentHex(for: preferences.value) }
    private var channelName: String {
        preferences.value.channel == .feishu ? setup.platformName : preferences.value.channel.title
    }
    private var channelExplanation: String { notifications.status.explanation }
    private var channelHealth: ChannelHealth { ChannelHealth(stages: readinessStages) }
}

