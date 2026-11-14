// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.02, AC-19.03, AC-19.04, AC-19.07, AC-19.08, AC-19.09, AC-19.11; US-16, AC-16.03.
// Refs: US-33, AC-33.01, AC-33.04, AC-33.08, AC-33.09, AC-33.10, AC-33.11; US-04, AC-04.02, AC-04.03, AC-04.08, AC-04.12, AC-04.17; US-24, AC-24.01, AC-24.02.
// Refs: US-02, AC-02.03, AC-02.05; US-13, AC-13.10.
import SwiftUI
import Charts
import LunletClaude
import LunletCore

/// Which provider page the panel shows: exactly one selected provider is shown directly; with several,
/// the Overview is home and a requested provider page is shown only while that provider stays selected.
enum ProviderPages {
    static func shown(selected: [SessionProvider], requested: SessionProvider?) -> SessionProvider? {
        if selected.count == 1 { return selected[0] }
        return requested.flatMap { selected.contains($0) ? $0 : nil }
    }
    static func homeTitle(selected: [SessionProvider]) -> String {
        selected.count == 1 ? selected[0].displayName : selected.isEmpty ? "Agents" : "Overview"
    }
}

/// The Overview's waiting line (AC-19.11): each agent with sessions waiting for the developer, in selection order.
enum OverviewWaiting {
    static let none = "Nothing needs you"
    static func lines(_ waiting: [SessionProvider: Int], order: [SessionProvider]) -> [(provider: SessionProvider, text: String)] {
        order.compactMap { provider in
            guard let count = waiting[provider], count > 0 else { return nil }
            return (provider, provider.displayName + " · " + (count == 1 ? "1 session needs you" : "\(count) sessions need you"))
        }
    }
}

/// Totals across providers, from each provider's own recorded usage. Missing values are never zero,
/// and allowances are never combined here or anywhere else (AC-19.04).
enum OverviewUsage {
    /// Today's recorded amount, only when the snapshot actually contains today.
    static func today(_ history: LocalUsageHistory?, now: Date = Date(), calendar: Calendar = .current) -> LocalUsageAmount? {
        history?.days.last { calendar.isDate($0.date, inSameDayAs: now) }?.amount
    }
    /// Sums known values. A missing, partial or token-less input makes the result a lower bound; unpriced tokens
    /// keep the cost a known subtotal. Nil when nothing is known.
    static func sum(_ amounts: [LocalUsageAmount?], lowerBound: Bool = false) -> LocalUsageAmount? {
        let known = amounts.compactMap { $0 }
        let tokens = known.compactMap(\.tokens), costs = known.compactMap(\.estimatedUSD)
        guard !tokens.isEmpty || !costs.isEmpty else { return nil }
        let incomplete = lowerBound || known.count < amounts.count || known.contains { $0.partial || $0.tokens == nil }
        return LocalUsageAmount(tokens: tokens.isEmpty ? nil : tokens.reduce(0, +),
                                estimatedUSD: costs.isEmpty ? nil : costs.reduce(0, +), partial: incomplete,
                                pricedTokens: known.reduce(0) { $0 + $1.pricedTokens },
                                unpricedTokens: known.reduce(0) { $0 + $1.unpricedTokens })
    }
    /// The selected range for one provider: every displayed day, so a missing day keeps the total a lower bound.
    static func range(_ history: LocalUsageHistory?) -> LocalUsageAmount? {
        guard let history, !history.days.isEmpty else { return nil }
        return sum(history.days.map(\.amount), lowerBound: history.partial)
    }
    /// Across providers the total is always labeled a lower bound.
    static func combined(_ amounts: [LocalUsageAmount?]) -> LocalUsageAmount? { sum(amounts, lowerBound: true) }
}

/// One provider's recorded value on one local day for the Overview chart; nil is unknown and never drawn as zero.
struct OverviewDailyValue: Identifiable, Equatable {
    let day: Date
    let provider: SessionProvider
    let value: Double?
    let partial: Bool
    var id: String { String(day.timeIntervalSinceReferenceDate) + provider.rawValue }
}

/// Daily values per provider for the selected range, and the range's daily average of combined totals.
enum OverviewChart {
    static func days(count: Int, now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<max(1, count)).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }
    static func values(_ histories: [(SessionProvider, LocalUsageHistory?)], days: [Date], cost: Bool,
                       calendar: Calendar = .current) -> [OverviewDailyValue] {
        days.flatMap { day in
            histories.map { provider, history in
                let amount = history?.days.first { calendar.isDate($0.date, inSameDayAs: day) }?.amount
                let value = cost ? amount?.estimatedUSD : amount?.tokens.map(Double.init)
                return OverviewDailyValue(day: day, provider: provider, value: value,
                                          partial: amount.map { $0.partial || (cost && $0.costPartial) } ?? false)
            }
        }
    }
    /// Mean of each day's known combined total, over the days that have any known value.
    /// One drawn segment of a day's stacked bar.
    struct Segment: Identifiable, Equatable {
        let day: Date
        let provider: SessionProvider
        let start: Double
        let end: Double
        var id: String { String(day.timeIntervalSinceReferenceDate) + provider.rawValue }
    }
    /// Known values stacked per day in agent order, with a small gap in value units (2% of the tallest day) between
    /// segments; unknown values draw nothing and never count as zero.
    static func stacked(_ values: [OverviewDailyValue], order: [SessionProvider]) -> [Segment] {
        let totals = Dictionary(grouping: values, by: \.day).mapValues { $0.compactMap(\.value).reduce(0, +) }
        let gap = (totals.values.max() ?? 0) * 0.02
        return Set(values.map(\.day)).sorted().flatMap { day -> [Segment] in
            var top = 0.0, segments: [Segment] = []
            for provider in order {
                guard let value = values.first(where: { $0.day == day && $0.provider == provider })?.value, value > 0 else { continue }
                let start = segments.isEmpty ? 0 : top + gap
                segments.append(.init(day: day, provider: provider, start: start, end: start + value))
                top = start + value
            }
            return segments
        }
    }
    /// Each day's bar top, where the total line's point sits; a day with nothing drawn has no point, never zero.
    static func tops(_ segments: [Segment]) -> [(day: Date, value: Double)] {
        Dictionary(grouping: segments, by: \.day).map { ($0.key, $0.value.map(\.end).max() ?? 0) }.sorted { $0.day < $1.day }
    }
    static func average(_ values: [OverviewDailyValue]) -> Double? {
        let totals = Dictionary(grouping: values.filter { $0.value != nil }, by: \.day).values
            .map { $0.reduce(0) { $0 + ($1.value ?? 0) } }
        return totals.isEmpty ? nil : totals.reduce(0, +) / Double(totals.count)
    }
}

/// The Overview under the header: who is waiting, the combined recorded usage totals, then a daily chart segmented by
/// agent with the daily average. Each agent's limit is in the header, never combined, and the page lists no sessions;
/// details stay on each agent's page (AC-19.08, AC-19.11).
struct ProviderOverview: View {
    @ObservedObject var codexHistory: LocalUsageModel
    @ObservedObject var claudeHistory: LocalUsageModel
    let providers: [SessionProvider]
    /// Sessions waiting for the developer, by agent.
    var waiting: [SessionProvider: Int] = [:]
    /// Opens an agent's page from the waiting line.
    var open: (SessionProvider) -> Void = { _ in }
    /// The selected palette; each agent's chart color is its AgentPalette variant (AC-16.03).
    var accentHex: String? = nil
    /// Tokens lead: a subscriber watches usage first, the API-price equivalent second.
    @ViewState private var showCost = false
    @ViewState private var hoveredDay: String?
    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Grid.group) {
            waitingLine
            usageHeader
            chartCard
        }
    }

    /// One line of capsules: each agent with sessions waiting, which opens that agent's page, or that nothing is
    /// waiting. A capsule gives the words their own surface; set straight on the panel's glass they would take the
    /// color of the window behind it.
    private var waitingLine: some View {
        let lines = OverviewWaiting.lines(waiting, order: providers)
        return HStack(spacing: PanelStyle.Space.small) {
            if lines.isEmpty {
                Text(OverviewWaiting.none).foregroundStyle(.secondary).modifier(WaitingCapsule(attention: false))
            } else {
                ForEach(lines, id: \.provider) { line in
                    Button { open(line.provider) } label: {
                        HStack(spacing: PanelStyle.Space.small) {
                            Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
                            Text(verbatim: line.text).fontWeight(.semibold)
                            Image(systemName: "chevron.forward").font(.system(size: 8, weight: .bold)).accessibilityHidden(true)
                        }
                        .foregroundStyle(PanelTone.attention.color)
                        .modifier(WaitingCapsule(attention: true))
                    }
                    .buttonStyle(.plain)
                    .help("Opens this agent's page, where the waiting session is listed.")
                }
            }
            Spacer(minLength: 0)
        }
        .font(PanelStyle.Text.secondary).lineLimit(1)
    }

    private var histories: [(SessionProvider, LocalUsageHistory?)] { providers.map { ($0, history($0).snapshot) } }

    /// Where provider pages switch Active and History: the metric switch, then today's and the range's combined
    /// totals in that metric, the other metric on hover.
    private var usageHeader: some View {
        let snapshots = histories.map(\.1)
        let today = OverviewUsage.combined(snapshots.map { OverviewUsage.today($0) })
        let range = OverviewUsage.combined(snapshots.map(OverviewUsage.range))
        let days = codexHistory.historyDays
        return HStack(spacing: PanelStyle.Space.small) {
            PanelSegmentedControl(selection: $showCost, segments: [.init(value: false, title: "Tokens"),
                                                                   .init(value: true, title: "Cost")],
                                  size: .small, label: "Usage metric")
                .fixedSize()
            Spacer(minLength: PanelStyle.Space.medium)
            total("Today", today)
            if days > 1 {
                Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                total("\(days) days", range)
            }
        }
        // The totals end on the cards' trailing text edge, as Clear does on the provider pages.
        .padding(.trailing, PanelStyle.Grid.textInset)
        .font(PanelStyle.Text.primary).lineLimit(1)
        .frame(height: PanelStyle.Layout.listHeaderHeight)
        .help("Recorded on this Mac · API-price estimates, not a bill. Totals are lower bounds: a missing day or record "
            + "counts as unknown, not zero.")
    }

    private func total(_ title: String, _ amount: LocalUsageAmount?) -> some View {
        let cost = amount?.estimatedUSD == nil ? nil : LocalUsageText.cost(amount)
        let tokens = amount?.tokens.map { (amount?.partial == true ? "≥" : "") + $0.formatted(.number.notation(.compactName)) }
        let shown = showCost ? cost : tokens
        return HStack(spacing: PanelStyle.Space.tight) {
            Text(title).foregroundStyle(.secondary)
            Text(shown ?? "—").fontWeight(.semibold).foregroundStyle(shown == nil ? .tertiary : .primary)
        }
        .help(amount == nil ? "Unavailable · Refresh to try again" : showCost ? LocalUsageText.tokens(amount) : LocalUsageText.cost(amount))
        .accessibilityElement(children: .combine)
    }

    private var chartCard: some View {
        let days = OverviewChart.days(count: codexHistory.historyDays)
        let values = OverviewChart.values(histories, days: days, cost: showCost)
        let average = OverviewChart.average(values)
        let segments = OverviewChart.stacked(values, order: providers)
        let tops = OverviewChart.tops(segments)
        let compact = days.count > 5
        func label(_ date: Date) -> String {
            date.formatted(compact ? .dateTime.weekday(.narrow).day() : .dateTime.weekday(.abbreviated).day())
        }
        return VStack(alignment: .leading, spacing: PanelStyle.Grid.group) {
            Chart {
                // One bar per day, stacked by agent with a thin gap between segments; the total line's points sit on
                // each bar's top center.
                ForEach(segments) { part in
                    BarMark(x: .value("Day", label(part.day)), yStart: .value(showCost ? "Cost" : "Tokens", part.start),
                            yEnd: .value(showCost ? "Cost" : "Tokens", part.end), width: .ratio(0.56))
                        .foregroundStyle(by: .value("Agent", part.provider.displayName))
                        .opacity(hoveredDay == nil || hoveredDay == label(part.day) ? 1 : 0.4)
                        .cornerRadius(4, style: .continuous)
                }
                ForEach(tops, id: \.day) { point in
                    LineMark(x: .value("Day", label(point.day)), y: .value("Total", point.value), series: .value("Series", "Total"))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.primary.opacity(0.62))
                    PointMark(x: .value("Day", label(point.day)), y: .value("Total", point.value))
                        .symbolSize(20).foregroundStyle(Color.primary.opacity(0.9))
                }
                if let average {
                    // Labeled on the line itself, so no axis column takes width from the plot.
                    RuleMark(y: .value("Daily average", average))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(Color.secondary)
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            Text("avg " + format(average)).font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
                                .padding(.horizontal, PanelStyle.Space.tight)
                                .background(.regularMaterial, in: Capsule())
                        }
                }
                if let hoveredDay {
                    RuleMark(x: .value("Day", hoveredDay)).foregroundStyle(.clear)
                        .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            dayDetail(values.filter { label($0.day) == hoveredDay })
                        }
                }
            }
            .chartForegroundStyleScale(domain: providers.map(\.displayName), range: providers.map(color))
            .chartLegend(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: days.map(label))
            .chartXAxis { AxisMarks { _ in AxisValueLabel(centered: true).font(PanelStyle.Text.secondary) } }
            .chartOverlay { proxy in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let location) = phase { hoveredDay = proxy.value(atX: location.x, as: String.self) }
                        else { hoveredDay = nil }
                    }
            }
            .chartYScale(domain: 0...max(1e-9, (tops.map(\.value).max() ?? 0) * 1.1, (average ?? 0) * 1.1))
            .frame(maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Daily usage by agent")
            .accessibilityValue(days.map { day in
                label(day) + ": " + values.filter { $0.day == day }
                    .map { $0.provider.displayName + " " + ($0.value.map(format) ?? "unknown") }.joined(separator: ", ")
            }.joined(separator: "; "))
            legend(values)
            // The one place the two signs are explained.
            Text("Recorded on this Mac · ≈ estimate · ≥ at least").font(PanelStyle.Text.secondary).foregroundStyle(.tertiary)
                .frame(height: PanelStyle.Layout.secondaryLine)
        }
        // The chart takes the rest of the page, where an agent's page lists its sessions.
        .frame(maxHeight: .infinity)
        .modifier(PanelModule())
        .help("Each bar is one day on this Mac, stacked by agent; the solid line joins each day's total at the bar's top and "
            + "the dashed line is the range's daily average. Hover a day for its detail. Missing days are unknown, never zero.")
    }

    /// The legend carries each agent's total for the shown days in the chosen metric; a missing or partial day
    /// makes it a lower bound, and an agent without any known day reads unknown.
    private func legend(_ values: [OverviewDailyValue]) -> some View {
        HStack(spacing: PanelStyle.Grid.margin) {
            ForEach(providers, id: \.self) { provider in
                let own = values.filter { $0.provider == provider }
                let known = own.compactMap(\.value)
                HStack(spacing: PanelStyle.Space.tight) {
                    Circle().fill(color(provider)).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(provider.displayName).foregroundStyle(.secondary)
                    Text(known.isEmpty ? "unknown"
                         : (own.contains { $0.partial || $0.value == nil } ? "≥" : "") + format(known.reduce(0, +)))
                        .foregroundStyle(known.isEmpty ? .secondary : .primary)
                }
                .accessibilityElement(children: .combine)
            }
            // The line's key; its values are the totals in the row above.
            HStack(spacing: PanelStyle.Space.tight) {
                Capsule().fill(Color.primary.opacity(0.75)).frame(width: 12, height: 2).accessibilityHidden(true)
                Text("Daily total").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(PanelStyle.Text.secondary).lineLimit(1)
        .frame(height: PanelStyle.Layout.secondaryLine)
    }
    private func dayDetail(_ items: [OverviewDailyValue]) -> some View {
        let known = items.compactMap(\.value)
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(items) { item in
                HStack(spacing: PanelStyle.Space.tight) {
                    Circle().fill(color(item.provider)).frame(width: 6, height: 6)
                    Text(item.provider.displayName + " " + (item.value.map { (item.partial ? "≥" : "") + format($0) } ?? "unknown"))
                }
            }
            if items.count > 1, !known.isEmpty {
                Text("Total " + (items.contains { $0.partial || $0.value == nil } ? "≥" : "") + format(known.reduce(0, +)))
                    .fontWeight(.semibold)
            }
        }
        .font(PanelStyle.Text.secondary).monospacedDigit().fixedSize()
        .padding(.horizontal, 7).padding(.vertical, PanelStyle.Space.tight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(PanelStyle.separator, lineWidth: 0.5))
    }

    private func format(_ value: Double) -> String {
        showCost ? "$" + value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(value < 10 ? 2 : 0)))
            : Int64(value).formatted(.number.notation(.compactName))
    }
    /// Each agent keeps its one palette color (AC-16.03), named in the legend and in hover detail.
    private func color(_ provider: SessionProvider) -> Color { AgentPalette.color(provider, accentHex: accentHex).color }
    private func history(_ provider: SessionProvider) -> LocalUsageModel { provider == .codex ? codexHistory : claudeHistory }
}

/// The surface of one item on the Overview's waiting line: a module-colored capsule, tinted while a session waits.
private struct WaitingCapsule: ViewModifier {
    let attention: Bool
    func body(content: Content) -> some View {
        content.padding(.horizontal, PanelStyle.Space.module).frame(height: PanelStyle.Layout.listHeaderHeight)
            .background(attention ? AnyShapeStyle(PanelTone.attention.color.opacity(0.14)) : AnyShapeStyle(PanelStyle.moduleFill),
                        in: Capsule())
            .contentShape(Capsule())
    }
}

/// The top of the Claude Code page under the header: the account line with the status line's state, then today's
/// recorded usage (AC-04.17, AC-33.11). The weekly limit is in the header; percent used and the reset time come from
/// Claude Code's status line, and model-specific weekly limits, usage credits and the plan tier are not reported there.
struct ClaudeUsageSummary: View {
    @ObservedObject var history: LocalUsageModel
    let hoverPanel: UsageHoverPanelController
    /// The panel's global Refresh, offered on the account line after a failed read (AC-04.12).
    var refresh: () -> Void = {}
    @Environment(\.claudePlanLimits) private var limits

    var body: some View {
        ClaudeUsageTop(history: history, hoverPanel: hoverPanel, limits: limits ?? .placeholder, refresh: refresh)
    }
}

private struct ClaudeUsageTop: View {
    @ObservedObject var history: LocalUsageModel
    let hoverPanel: UsageHoverPanelController
    @ObservedObject var limits: ClaudePlanLimitsModel
    let refresh: () -> Void
    @Environment(\.openSettings) private var openSettings
    /// Set when this page made the connection, so it can offer Undo for the rest of this panel visit.
    @ViewState private var connectedHere = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in content(now: context.date) }
    }

    private func content(now: Date) -> some View {
        let today = OverviewUsage.today(history.snapshot)
        let recorded = today.flatMap(ClaudeLimitsText.spokenBreakdown).map { " Recorded: " + $0 + "." } ?? ""
        return AgentSummaryCard(account: limits.account?.email ?? "Claude Code account", plan: limits.account?.plan,
                                accountHelp: ClaudeLimitsText.cardHelp,
                                figures: [AgentFigures.today(today, reading: history.isLoading)],
                                help: ["Today": "Recorded on this Mac from local Claude Code transcripts, each response counted once; a lower bound."
                                    + recorded + " Cost uses published Claude API list prices, not a subscription bill."
                                    + (today == nil && history.unavailable ? " Refresh to try again." : "")],
                                hoverPanel: hoverPanel, label: "Claude Code usage") {
            HStack(spacing: PanelStyle.Space.tight) {
                status(now: now)
                if limits.isChanging {
                    ProgressView().controlSize(.mini).accessibilityLabel("Updating Claude Code's status line")
                } else if (connectedHere || limits.addedAutomatically) && limits.connection == .connected {
                    Button("Undo") { connectedHere = false; limits.disconnect() }
                        .buttonStyle(.plain).foregroundStyle(.tint)
                        .help("Restores Claude Code's previous status line exactly.")
                }
            }
        }
    }

    /// The reading's age, or the status line's state with the one action it calls for (AC-33.08).
    @ViewBuilder private func status(now: Date) -> some View {
        switch limits.connection {
        case .connected:
            if limits.addedAutomatically {
                // Said once, on the first visit after Lunlet connected on its own (AC-33.08).
                Text("Status line added").help(Self.connectHelp)
            } else if limits.limits == nil && limits.readFailed {
                refreshButton
            } else if let at = limits.limits?.sevenDay?.at {
                // The same wording as the Codex page: the user needs the age, not where it came from.
                Text(AccountUsagePresentation.updatedLabel(at: at, now: now) ?? "Updated").monospacedDigit()
                    .help("Last update " + at.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text("Awaiting first reading")
                    .help("Claude Code reports plan limits only for Pro and Max plans, after a session's first response.")
            }
        case .checking: Text("Checking…")
        case .changedOutsideLunlet:
            Text("Changed outside Lunlet")
                .help("Claude Code's status line was changed after Lunlet connected; see Settings › Agents.")
        case .unavailable:
            refreshButton
        case .notConnected:
            // One explicit click connects in place (AC-33.08); the line states what the click changes first.
            if let issue = limits.actionIssue {
                Text("Couldn't connect").help(ClaudePlanLimitsSettings.message(issue))
                if let openSettings {
                    Button("Details…") { openSettings(.agents) }.buttonStyle(.plain).foregroundStyle(.tint)
                        .accessibilityHint("Opens Settings › Agents")
                }
            } else {
                // The button names what the click changes (AC-33.08).
                Button("Add status line") { connectedHere = true; limits.connect() }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                    .help(Self.connectHelp).accessibilityHint(Self.connectHelp)
            }
        }
    }
    private var refreshButton: some View {
        Button("Refresh", action: refresh).buttonStyle(.plain).foregroundStyle(.tint)
            .help("The limit could not be read; Refresh tries again.")
    }
    private static let connectHelp = ClaudeLimitsText.connectHelp
}
