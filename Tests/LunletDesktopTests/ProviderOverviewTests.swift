// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.01, AC-19.02, AC-19.03, AC-19.04, AC-19.05.
// Refs: US-33, AC-33.01, AC-33.02, AC-33.04, AC-33.06, AC-33.09, AC-33.10; US-13, AC-13.01; US-15, AC-15.01; US-02, AC-02.03.
import AppKit
import Foundation
import SwiftUI
import Testing
import LunletClaude
import LunletCodex
import LunletCore
@testable import LunletDesktop

@MainActor private final class RecordingCues: TaskCuePresenting {
    private(set) var titles: [String] = []
    func show(_ cues: [TaskCue]) { titles += cues.map(\.title) }
    func hide() {}
}
private struct FixedUsage: LocalUsageReading {
    let history: LocalUsageHistory
    func readHistory(now: Date, calendar: Calendar, days: Int) async throws -> LocalUsageHistory { history }
}

@MainActor struct ProviderOverviewTests {
    private func row(_ provider: SessionProvider, phase: SessionPhase = .running, project: String = "Synthetic") -> SessionSnapshot {
        .init(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .unverified, phase: phase),
              project: project, turnID: "turn-\(UUID().uuidString.prefix(4))", activityConfirmed: true,
              localPreview: "Synthetic preview", provider: provider)
    }

    // Refs: US-19, AC-19.01.
    @Test func onlyImplementedAgentsAreOfferedAndClaudeIsSelectable() {
        #expect(AgentProvider.allCases == [.codex, .claude] && AgentProvider.claude.title == "Claude Code")
        var preferences = LunletPreferences()
        preferences.providers = [.claude, .codex]
        #expect(preferences.sessionProviders == [.claude, .codex])
    }

    // Refs: US-19, AC-19.02, AC-19.03, AC-19.05.
    @Test func oneProviderOpensDirectlyAndSeveralShareAnOverview() {
        // Tabs: Overview first, then each selected provider in selection order; one provider has no tab bar.
        #expect(ProviderPages.tabs(selected: [.codex]).isEmpty && ProviderPages.tabs(selected: []).isEmpty)
        #expect(ProviderPages.tabs(selected: [.codex, .claude]) == [nil, .codex, .claude])
        #expect(ProviderPages.tabs(selected: [.claude, .codex]) == [nil, .claude, .codex])
        #expect(ProviderPages.shown(selected: [.claude], requested: nil) == .claude)
        #expect(ProviderPages.shown(selected: [.codex], requested: .claude) == .codex)
        #expect(ProviderPages.shown(selected: [.codex, .claude], requested: nil) == nil)
        #expect(ProviderPages.shown(selected: [.codex, .claude], requested: .claude) == .claude)
        #expect(ProviderPages.homeTitle(selected: [.claude]) == "Claude Code")
        #expect(ProviderPages.homeTitle(selected: [.codex, .claude]) == "Overview")
        #expect(ProviderPages.homeTitle(selected: []) == "Agents")
    }

    // Refs: US-33, AC-33.01, AC-33.02; US-15, AC-15.01; US-02, AC-02.03.
    @Test func providerPagesFilterClearAndLabelTheirOwnRows() {
        let cues = RecordingCues()
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: cues)
        // Codex alone keeps its unlabelled presentation.
        model.receive(row(.codex, project: "Alpha"), origin: .liveTransition)
        #expect(!model.labelsAgents && cues.titles == ["Alpha"] && model.compactStatus.description.hasPrefix("Codex ·"))
        model.setMonitoredProviders([.codex, .claude])
        let claude = row(.claude, project: "Beta")
        model.receive(claude, origin: .liveTransition)
        model.receive(row(.codex, project: "Gamma"), origin: .liveTransition)
        #expect(model.labelsAgents && cues.titles.suffix(2) == ["Claude · Beta", "Codex · Gamma"])
        #expect(model.displayedSessions(for: .claude).map(\.project) == ["Beta"] && model.displayedSessions.count == 3)
        model.monitoringConnected(partial: false, provider: .codex); model.monitoringConnected(partial: false, provider: .claude)
        #expect(model.compactStatus.description == "Agents · 0 waiting · 3 running")
        // Clearing a provider page moves only that provider's rows into History.
        model.clearDisplayedSessions(provider: .claude)
        #expect(model.history(for: .claude).count == 1 && model.history(for: .codex).isEmpty)
        #expect(model.displayedSessions.map(\.provider) == [.codex, .codex])
        // Deselecting a provider drops its rows; the remaining provider keeps its availability.
        model.setMonitoredProviders([.codex])
        #expect(model.sessions.allSatisfy { $0.provider == .codex } && model.history.isEmpty && model.monitoringAvailable)
        model.shutdown()
    }

    // Refs: US-33, AC-33.06.
    @Test func claudeSubagentChildrenAreNeitherRowsNorCues() {
        let cues = RecordingCues()
        let model = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: cues)
        model.setMonitoredProviders([.claude])
        let child = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .unverified,
                                                       phase: .running), project: "Child", turnID: "t", activityConfirmed: true,
                                    localPreview: "Child", parentSessionID: UUID(), provider: .claude)
        model.receive(child, origin: .liveTransition)
        #expect(model.displayedSessions.isEmpty && cues.titles.isEmpty && model.sessions.count == 1)
        model.shutdown()
    }

    // Refs: US-19, AC-19.04, AC-19.05; US-33, AC-33.04.
    @Test func totalsSumKnownUsageAndStayLowerBoundsWithoutTreatingMissingUsageAsZero() throws {
        let codex = LocalUsageAmount(tokens: 2_000, estimatedUSD: 1.5, partial: false)
        // Claude records are a lower bound; this day also has tokens without a published price.
        let claude = LocalUsageAmount(tokens: 500, estimatedUSD: 0.25, partial: true, pricedTokens: 300, unpricedTokens: 200)
        let total = try #require(OverviewUsage.combined([codex, claude]))
        #expect(total.tokens == 2_500 && total.estimatedUSD == 1.75 && total.partial)
        #expect(total.pricedTokens == 2_300 && total.unpricedTokens == 200 && total.costPartial)
        #expect(LocalUsageText.tokens(total).hasPrefix("≥") && LocalUsageText.cost(total).hasPrefix("≥$"))
        // Unpriced usage keeps the cost a known subtotal; no price at all leaves the cost unknown, never $0.
        let unpriced = LocalUsageAmount(tokens: 700, estimatedUSD: nil, partial: false)
        #expect(OverviewUsage.combined([unpriced])?.estimatedUSD == nil && OverviewUsage.combined([unpriced])?.tokens == 700)
        #expect(LocalUsageText.cost(OverviewUsage.combined([unpriced])) == "Cost unavailable")
        let mixed = OverviewUsage.combined([codex, unpriced])
        #expect(mixed?.estimatedUSD == 1.5 && mixed?.unpricedTokens == 700 && mixed?.costPartial == true)
        // A provider without a value is left out rather than counted as zero; none at all stays unknown.
        #expect(OverviewUsage.combined([codex, nil])?.tokens == 2_000 && OverviewUsage.combined([codex, nil])?.partial == true)
        #expect(OverviewUsage.combined([nil, nil]) == nil && OverviewUsage.combined([]) == nil)
        // A provider's range is exact only when every displayed day is known and complete.
        let now = Date(), calendar = Calendar.current
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let complete = LocalUsageHistory(days: [.init(date: yesterday, amount: codex), .init(date: now, amount: codex)],
                                         sessions: [:], partial: false)
        #expect(OverviewUsage.range(complete) == LocalUsageAmount(tokens: 4_000, estimatedUSD: 3, partial: false))
        let gap = LocalUsageHistory(days: [.init(date: yesterday, amount: .init(tokens: nil, estimatedUSD: nil, partial: false)),
                                           .init(date: now, amount: codex)], sessions: [:], partial: false)
        #expect(OverviewUsage.range(gap)?.tokens == 2_000 && OverviewUsage.range(gap)?.partial == true)
        #expect(OverviewUsage.range(.init(days: [.init(date: now, amount: codex)], sessions: [:], partial: true))?.partial == true)
        #expect(OverviewUsage.range(nil) == nil)
        // Today is only today's recorded day, never the latest stale day.
        let stale = LocalUsageHistory(days: [.init(date: yesterday, amount: codex)], sessions: [:], partial: false)
        #expect(OverviewUsage.today(stale, now: now) == nil && OverviewUsage.today(complete, now: now) == codex)
    }

    // Refs: US-19, AC-19.04, AC-19.05.
    @Test func overviewChartSplitsEachDayByAgentAndAveragesOnlyKnownDays() throws {
        let calendar = Calendar.current, now = Date()
        let days = OverviewChart.days(count: 3, now: now, calendar: calendar)
        #expect(days.count == 3 && calendar.isDate(days[2], inSameDayAs: now))
        let codex = LocalUsageHistory(days: [.init(date: days[0], amount: .init(tokens: 1_000, estimatedUSD: 2, partial: false)),
                                             .init(date: days[2], amount: .init(tokens: 3_000, estimatedUSD: 6, partial: false))],
                                      sessions: [:], partial: false)
        let claude = LocalUsageHistory(days: [.init(date: days[2], amount: .init(tokens: 9_000, estimatedUSD: 4, partial: true))],
                                       sessions: [:], partial: true)
        let cost = OverviewChart.values([(.codex, codex), (.claude, claude)], days: days, cost: true, calendar: calendar)
        #expect(cost.count == 6)
        // A day without a record is unknown for that agent, never zero.
        #expect(cost.filter { $0.day == days[1] }.allSatisfy { $0.value == nil })
        #expect(cost.first { $0.day == days[2] && $0.provider == .claude }?.value == 4)
        #expect(cost.first { $0.day == days[2] && $0.provider == .claude }?.partial == true)
        // The average covers only days with a known value: (2 + (6 + 4)) / 2.
        #expect(OverviewChart.average(cost) == 6)
        let tokens = OverviewChart.values([(.codex, codex), (.claude, claude)], days: days, cost: false, calendar: calendar)
        #expect(OverviewChart.average(tokens) == 6_500, "tokens average \(String(describing: OverviewChart.average(tokens)))")
        #expect(OverviewChart.average(OverviewChart.values([(.codex, nil)], days: days, cost: true)) == nil)
    }

    // Refs: US-19, AC-19.05.
    @Test func overviewSharesTheProviderPagesFrameWithoutSessions() async throws {
        _ = NSApplication.shared
        let today = Calendar.current.startOfDay(for: Date())
        let recorded = LocalUsageAmount(tokens: 12_000, estimatedUSD: 0.4, partial: true, pricedTokens: 12_000, unpricedTokens: 0)
        let claudeHistory = LocalUsageModel(reader: FixedUsage(history: .init(days: [.init(date: today, amount: recorded)],
                                                                             sessions: [:], partial: true)))
        claudeHistory.refresh()
        let deadline = ContinuousClock.now + .seconds(2)
        while claudeHistory.snapshot == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let codexHistory = LocalUsageModel(reader: FixedUsage(history: .init(days: [], sessions: [:], partial: false)))
        let account = AccountUsageModel(client: NoAccount())
        let view = ProviderOverview(codexHistory: codexHistory, claudeHistory: claudeHistory, account: account,
                                    providers: [.codex, .claude])
        let hosting = NSHostingView(rootView: view.frame(width: 446))
        hosting.frame = .init(x: 0, y: 0, width: 446, height: 400)
        hosting.layoutSubtreeIfNeeded()
        // The Overview fills exactly the provider pages' frame — a card of their height, the header row and the
        // three-row module — so switching tabs never moves a section; session activity never grows it.
        #expect(abs(hosting.fittingSize.height - PanelStyle.Layout.pageHeight) <= 0.5, "overview \(hosting.fittingSize.height)")
        if ProcessInfo.processInfo.environment["LUNLET_TEST_RENDER_SUMMARY"] == "1" {
            try OverviewRender.write(view, name: "overview-preview")
        }
        await claudeHistory.shutdown(); await codexHistory.shutdown(); await account.shutdown()
    }
}

/// Opt-in offscreen renders for owner review; never part of the default suite.
@MainActor enum OverviewRender {
    static func write(_ view: some View, name: String, height: CGFloat = PanelStyle.Layout.pageHeight) throws {
        let content = NSHostingView(rootView: view.frame(width: 446).padding(PanelStyle.Space.margin)
            .frame(height: height + 2 * PanelStyle.Space.margin, alignment: .top)
            .background(Color(red: 0.13, green: 0.13, blue: 0.14)).environment(\.colorScheme, .dark))
        content.frame = .init(x: 0, y: 0, width: 470, height: height + 2 * PanelStyle.Space.margin)
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".tmp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }
}

/// The Claude card in a state, measured alone and above three session rows.
@MainActor private func claudePage(_ limits: ClaudePlanLimitsModel?, history: LocalUsageModel, sessions: SessionListModel,
                                   hover: UsageHoverPanelController) -> (card: CGFloat, page: CGFloat, view: AnyView) {
    func host(_ view: some View) -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: 446).fixedSize(horizontal: false, vertical: true)
            .environment(\.claudePlanLimits, limits).background(Color(red: 0.13, green: 0.13, blue: 0.14))
            .environment(\.colorScheme, .dark)))
        hosting.frame = .init(x: 0, y: 0, width: 446, height: 300)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }
    let page = VStack(alignment: .leading, spacing: PanelStyle.Grid.margin) {
        ClaudeUsageSummary(history: history, hoverPanel: hover)
        SessionPanel(model: sessions, usage: [.claude: history], provider: .claude)
    }.environment(\.claudePlanLimits, limits)
    return (host(ClaudeUsageSummary(history: history, hoverPanel: hover)).fittingSize.height, host(page).fittingSize.height,
            AnyView(page))
}

// Refs: US-33, AC-33.01, AC-33.04, AC-33.09, AC-33.10; US-19, AC-19.02; US-03, AC-03.09.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_PANEL"] == "1"))
@MainActor func claudePageKeepsTheCodexCardHeightAndThreeCompleteRowsInEveryLimitState() async throws {
    _ = NSApplication.shared
    let today = Calendar.current.startOfDay(for: Date())
    let categories = LocalTokenBreakdown(input: 1_200, output: 45_000, cacheWrite: 120_000, cacheRead: 3_400_000)
    let amount = LocalUsageAmount(tokens: 3_566_200, estimatedUSD: 4.12, partial: true, breakdown: categories)
    let ids = (0..<3).map { _ in UUID() }
    let history = LocalUsageModel(reader: FixedUsage(history: .init(days: [.init(date: today, amount: amount)],
                                                                     sessions: [ids[0]: amount, ids[1]: amount], partial: true)))
    history.refresh()
    let deadline = ContinuousClock.now + .seconds(2)
    while history.snapshot == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let hover = UsageHoverPanelController(observesSystemEvents: false)
    let sessions = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: RecordingCues())
    sessions.setMonitoredProviders([.claude])
    // Rows lead with cost over input and output tokens; one row has no recorded usage yet.
    for (index, id) in ids.enumerated() {
        sessions.receive(.init(observation: .init(sessionID: id, connectionID: UUID(), liveness: .unverified, phase: .running),
                               project: "Synthetic project", turnID: "turn-\(index)", activityConfirmed: true,
                               localPreview: "Synthetic preview \(index)", provider: .claude), origin: .snapshot)
    }
    // The Codex card's height is the budget that leaves exactly three whole rows on the fixed page.
    let account = AccountUsageModel()
    let codex = NSHostingView(rootView: AccountUsageSummary(model: account, hoverPanel: hover).frame(width: 446)
        .fixedSize(horizontal: false, vertical: true))
    codex.frame = .init(x: 0, y: 0, width: 446, height: 300)
    codex.layoutSubtreeIfNeeded()
    // Not connected, and connected with both windows, a pace sentence and today's cost-first usage.
    let fixture = try ClaudeLimitsFixture(); defer { fixture.remove() }
    _ = try fixture.connection.connect()
    let t = Int(Date().timeIntervalSince1970)
    try fixture.write(state: "lunlet-claude-limits 1\nfive_hour 47 \(t + 5_400) \(t - 300)\nseven_day 13 \(t + 4 * 86_400) \(t - 300)\n",
                      log: "\(t - 2 * 86_400) 2 \(t + 4 * 86_400)\n\(t - 86_400) 8 \(t + 4 * 86_400)\n")
    let connected = ClaudePlanLimitsModel(service: fixture.connection)
    connected.setActive(true)
    try await ClaudeLimitsFixture.settle(connected) { connected.limits?.sevenDay != nil }
    #expect(connected.connection == .connected)
    let available = PanelStyle.Layout.pageHeight
    for (name, limits) in [("claude-unknown-preview", nil), ("claude-connected-preview", connected)] as [(String, ClaudePlanLimitsModel?)] {
        let measured = claudePage(limits, history: history, sessions: sessions, hover: hover)
        // Both windows fit the Codex card's limits group, so switching tabs never changes the card's height.
        #expect(abs(measured.card - codex.fittingSize.height) <= 0.5, "\(name): card \(measured.card) of \(codex.fittingSize.height)")
        #expect(2 * PanelStyle.Layout.compactWindow + PanelStyle.Space.tight == PanelStyle.Layout.limitsGroup)
        #expect(measured.page <= available, "\(name): content \(measured.page) of \(available)")
        // Exactly three whole rows: a fourth may reveal only its blank top inset, never a sliver of text.
        #expect(available - measured.page + PanelStyle.Layout.listVerticalInset <= PanelStyle.Layout.rowHighlightInset + 0.5)
        if ProcessInfo.processInfo.environment["LUNLET_TEST_RENDER_SUMMARY"] == "1" { try OverviewRender.write(measured.view, name: name) }
    }
    if ProcessInfo.processInfo.environment["LUNLET_TEST_RENDER_SUMMARY"] == "1" {
        for (name, model) in [("claude-settings-connected-preview", connected), ("claude-settings-preview", .placeholder)] {
            try OverviewRender.write(Form { ClaudePlanLimitsSettings(model: model) }.formStyle(.grouped).controlSize(.small)
                .frame(width: 300), name: name, height: 220)
        }
    }
    await connected.shutdown(); hover.shutdown(); sessions.shutdown(); await history.shutdown()
}

// Refs: US-16, AC-16.03; US-04, AC-04.10.
@Test func eachAgentKeepsOnePaletteVariantAndWarningsNeverTurn() {
    #expect(AgentPalette.hueShift(.codex) == 0 && AgentPalette.hueShift(.claude) == 70.0 / 360)
    let tint = "#856BC7", shift = AgentPalette.hueShift(.claude)
    let codex = AllowancePalette.colors(remaining: 100, tintHex: tint), claude = AllowancePalette.colors(remaining: 100, tintHex: tint, hueShift: shift)
    // Claude's palette is Codex's distinct sibling: a different hue and clearly deeper, not just a nearby tint.
    #expect(codex[1].hex == 0x856BC7 && claude[1].hex == codex[1].agentVariant(turn: shift).hex)
    for base in [0xBAC0EF, 0xAE92DB, 0xB7AFE5, 0x856BC7, 0xC83F49, 0x3A7BD5] {
        let color = AllowanceColor(hex: base), sibling = color.agentVariant(turn: shift)
        let turn = abs(sibling.hue - color.hue), apart = min(turn, 1 - turn) * 360
        #expect(apart >= 60 && max(sibling.red, sibling.green, sibling.blue) <= 0.79 * max(color.red, color.green, color.blue),
                "\(String(format: "%06X", base)) -> \(String(format: "%06X", sibling.hex))")
        // Never a warning yellow or orange.
        #expect(!(20.0...75.0).contains(sibling.hue * 360))
    }
    #expect(AgentPalette.color(.claude, accentHex: tint) == claude[2] && AgentPalette.color(.codex, accentHex: nil) == AllowancePalette.colors(remaining: 100)[2])
    // The low-allowance yellow and red are the same for every agent.
    for remaining in [0.0, 5, 10, 18] {
        #expect(AllowancePalette.colors(remaining: remaining, tintHex: tint, hueShift: shift) == AllowancePalette.colors(remaining: remaining, tintHex: tint))
    }
    // Gray has no hue to turn, and a whole turn returns the same color.
    #expect(AllowanceColor(hex: 0x808080).agentVariant(turn: shift).hex == 0x808080 && codex[1].rotatingHue(by: 1).hex == codex[1].hex)
}

/// An account reader with nothing to report, so limit rows stay unknown without touching a real account.
private struct NoAccount: CodexAccountReading {
    func readLimits() async throws -> AccountLimitsSnapshot { throw CancellationError() }
}
