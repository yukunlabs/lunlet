// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.02, AC-19.03, AC-19.04, AC-19.05; US-16, AC-16.03.
// Refs: US-33, AC-33.01, AC-33.04, AC-33.08, AC-33.09, AC-33.10, AC-33.11; US-04, AC-04.02, AC-04.03, AC-04.08, AC-04.12; US-24, AC-24.01, AC-24.02.
// Refs: US-02, AC-02.03, AC-02.05; US-32, AC-32.05, AC-32.06, AC-32.07, AC-32.08.
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
    /// Tab bar entries in order: nil is the Overview, then each selected provider. One provider shows no tab bar.
    static func tabs(selected: [SessionProvider]) -> [SessionProvider?] {
        selected.count > 1 ? [nil] + selected.map(Optional.some) : []
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

/// The Overview tab: combined recorded usage totals and one limit row per agent window, then a daily chart
/// segmented by provider with the daily average. Limits are never combined, and the page has no navigation or
/// session list; details stay on each provider's tab (AC-19.05).
struct ProviderOverview: View {
    @ObservedObject var codexHistory: LocalUsageModel
    @ObservedObject var claudeHistory: LocalUsageModel
    @ObservedObject var account: AccountUsageModel
    let providers: [SessionProvider]
    /// The selected palette; each agent's chart color is its AgentPalette variant (AC-16.03).
    var accentHex: String? = nil
    @Environment(\.claudePlanLimits) private var claudeLimits
    /// Tokens lead: a subscriber watches usage first, the API-price equivalent second.
    @ViewState private var showCost = false
    @ViewState private var hoveredDay: String?
    var body: some View {
        // The provider pages' frame: a card of the provider cards' height, a header row, then a module of the session
        // list's height, so switching between any two tabs never moves a section (AC-19.05).
        VStack(alignment: .leading, spacing: 0) {
            OverviewLimitsCard(account: account, limits: claudeLimits ?? .placeholder, providers: providers, accentHex: accentHex)
            usageHeader.padding(.top, PanelStyle.Grid.margin)
            chartCard.padding(.top, PanelStyle.Grid.group)
        }
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
                        .cornerRadius(3, style: .continuous)
                }
                ForEach(tops, id: \.day) { point in
                    LineMark(x: .value("Day", label(point.day)), y: .value("Total", point.value), series: .value("Series", "Total"))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.primary.opacity(0.75))
                    PointMark(x: .value("Day", label(point.day)), y: .value("Total", point.value))
                        .symbolSize(30).foregroundStyle(Color.primary.opacity(0.85))
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
        }
        // Exactly the session list's module, so the chart sits where the provider pages show three rows.
        .frame(height: PanelStyle.Layout.threeRows - 2 * PanelStyle.Grid.margin)
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

/// The Overview's first card, exactly the provider cards' height: a title, then one compact window per agent window
/// — the agent's color, name, window and reset over its own meter, with percent left — as on the Claude card. Values
/// are never combined (AC-19.05).
private struct OverviewLimitsCard: View {
    @ObservedObject var account: AccountUsageModel
    @ObservedObject var limits: ClaudePlanLimitsModel
    let providers: [SessionProvider]
    let accentHex: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 0) {
                Text("Limits").font(PanelStyle.Text.title).frame(height: PanelStyle.Layout.line)
                    .accessibilityAddTraits(.isHeader)
                // Three compact windows and the title fill the card: 20 + 10 + 3 × 24 + 2 × 10 = 122 inside the padding.
                VStack(alignment: .leading, spacing: PanelStyle.Space.module) {
                    ForEach(providers, id: \.self) { provider in
                        switch provider {
                        case .codex: codex(now: now)
                        case .claude: claude(now: now)
                        }
                    }
                }
                .padding(.top, PanelStyle.Space.module)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: PanelStyle.Layout.cardHeight - 2 * PanelStyle.Grid.margin)
            .modifier(PanelModule())
        }
        .help("Each agent's own allowance as it reports it. Allowances are never combined.")
    }

    private var weekly: WeeklyAllowance? { account.displayedSnapshot.flatMap(AccountUsagePresentation.weekly) }
    private var readings: ClaudePlanLimits? { limits.connection == .connected ? limits.limits : nil }

    @ViewBuilder private func codex(now: Date) -> some View {
        let remaining = weekly?.remainingPercent
        row(.codex, window: "week", reset: weekly?.resetsAt.map { "resets " + ClaudeLimitsText.moment($0, now: now) } ?? "reset —",
            remaining: remaining, missing: account.state == .loading ? "Refreshing…" : "Unknown") {
            AllowanceBar(remaining: remaining, accentHex: accentHex)
        }
    }

    @ViewBuilder private func claude(now: Date) -> some View {
        let missing = limits.connection == .notConnected ? "Not connected" : "Unknown"
        ForEach([ClaudeLimitsText.Window.session, .week], id: \.self) { window in
            let reading = window == .session ? readings?.fiveHour : readings?.sevenDay
            let remaining = ClaudeLimitsText.remaining(reading, now: now)
            row(.claude, window: window == .session ? "session" : "week", reset: ClaudeLimitsText.resetLine(reading, now: now),
                remaining: remaining, missing: missing) {
                AllowanceBar(remaining: remaining, accentHex: accentHex, agent: .claude,
                             label: "Claude Code " + (window == .session ? "session" : "weekly") + " limit remaining")
            }
        }
    }

    /// One compact window: the agent's color dot and name, the window and its reset, and the percent left in one
    /// secondary line, then the agent's meter at full width.
    private func row(_ provider: SessionProvider, window: String, reset: String, remaining: Double?, missing: String,
                     @ViewBuilder meter: () -> some View) -> some View {
        let percent = remaining.map { ($0 > 0 && $0 < 1 ? "<1" : String(Int($0))) + "%" }
        return VStack(alignment: .leading, spacing: PanelStyle.Space.tight) {
            HStack(spacing: PanelStyle.Space.tight) {
                Circle().fill(AgentPalette.color(provider, accentHex: accentHex).color).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(provider.shortName).foregroundStyle(.primary)
                Text(verbatim: window + " · " + reset).foregroundStyle(.secondary)
                Spacer(minLength: PanelStyle.Space.tight)
                if let percent {
                    Text(percent).fontWeight(.semibold).foregroundStyle(.primary)
                    Text("left").foregroundStyle(.secondary)
                } else {
                    Text(missing).foregroundStyle(.secondary)
                }
            }
            .font(PanelStyle.Text.secondary).lineLimit(1)
            .frame(height: PanelStyle.Layout.secondaryLine)
            meter()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provider.displayName + " " + window)
        .accessibilityValue((percent.map { $0 + " left" } ?? missing) + ", " + reset)
    }
}

/// The Claude page's plan limits in Claude's own terms, then recorded usage with cost first. Percent used and reset
/// times come from Claude Code's status line; model-specific weekly limits and the plan tier are not reported there
/// and are not shown. Recorded usage on this Mac opens in a hover chart, as Codex usage does.
struct ClaudeUsageSummary: View {
    @ObservedObject var history: LocalUsageModel
    let hoverPanel: UsageHoverPanelController
    /// The selected skin's accent, which colors the meters as it colors the Codex allowance.
    var accentHex: String? = nil
    @Environment(\.claudePlanLimits) private var limits

    var body: some View {
        ClaudeUsageCard(history: history, hoverPanel: hoverPanel, limits: limits ?? .placeholder, accentHex: accentHex)
    }
}

private struct ClaudeUsageCard: View {
    @ObservedObject var history: LocalUsageModel
    let hoverPanel: UsageHoverPanelController
    @ObservedObject var limits: ClaudePlanLimitsModel
    let accentHex: String?
    @Environment(\.openSettings) private var openSettings
    /// Set when this card made the connection, so the card can offer Undo for the rest of this panel visit.
    @ViewState private var connectedHere = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in content(now: context.date) }
    }

    /// The Codex card's rhythm and height: a title line, the status line, the two windows stacked in the limits group
    /// (each a compact line over a full-width meter) and a footnote. One size per line.
    private func content(now: Date) -> some View {
        let readings = limits.connection == .connected ? limits.limits : nil
        let pace = ClaudeLimitsText.pace(readings, now: now)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PanelStyle.Space.small) {
                Text("Limits").font(PanelStyle.Text.title).accessibilityAddTraits(.isHeader)
                UsageChartButton(label: "Show Claude usage history", action: hoverPanel.showForKeyboard)
                Spacer(minLength: PanelStyle.Grid.row)
            }
            .frame(height: PanelStyle.Layout.line)
            // The account line, as on the Codex card: who and which plan, then the reading's age or the connection.
            subtitle(pace: pace, now: now)
                .font(PanelStyle.Text.secondary).lineLimit(1).truncationMode(.tail)
                .frame(height: PanelStyle.Layout.secondaryLine)
                .padding(.top, PanelStyle.Grid.row)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: PanelStyle.Space.tight) {
                    window(.session, readings?.fiveHour, even: nil, now: now)
                    window(.week, readings?.sevenDay, even: pace?.evenPace, now: now,
                           estimate: hasReadings ? QuotaForecastText.header(pace, stale: limits.readFailed, now: now) : nil,
                           estimateHelp: QuotaForecastText.help(pace, stale: limits.readFailed, resetAt: readings?.sevenDay?.resetsAt))
                }
                usage.frame(height: PanelStyle.Layout.secondaryLine).padding(.top, PanelStyle.Grid.group)
            }
            .padding(.top, PanelStyle.Grid.group)
            .contentShape(Rectangle())
            .background(UsageHoverAnchor(controller: hoverPanel))
        }
        .modifier(PanelModule())
        .help("Percent used and reset times as Claude Code reported them through Lunlet's status line: official values, "
            + "not estimates. Hover This week for an estimate from those readings, never a guarantee. Model-specific "
            + "weekly limits and the plan tier are only in Claude Code's own /usage. Hover for daily usage on this Mac.")
    }

    /// The source line plus one inline action: Connect while not connected, Undo right after connecting here.
    private func subtitle(pace: QuotaPace?, now: Date) -> some View {
        HStack(spacing: PanelStyle.Space.tight) {
            Image(systemName: "person.crop.circle").accessibilityHidden(true)
            Text(limits.account?.email ?? "Claude Code account").lineLimit(1).truncationMode(.middle)
            Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(limits.account?.plan ?? "Plan —").lineLimit(1).layoutPriority(1)
            Spacer(minLength: PanelStyle.Grid.group)
            status(now: now).layoutPriority(1)
            if limits.isChanging {
                ProgressView().controlSize(.mini).accessibilityLabel("Updating Claude Code's status line")
            } else if (connectedHere || limits.addedAutomatically) && limits.connection == .connected {
                Button("Undo") { connectedHere = false; limits.disconnect() }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                    .help("Restores Claude Code's previous status line exactly.")
            }
        }
    }

    @ViewBuilder private func status(now: Date) -> some View {
        switch limits.connection {
        case .connected:
            if limits.addedAutomatically {
                // Said once, on the first visit after Lunlet connected on its own (AC-33.08).
                Text("Status line added").foregroundStyle(.secondary).help(Self.connectHelp)
            } else if limits.limits == nil && limits.readFailed {
                Text("Unavailable · Refresh").foregroundStyle(.secondary)
            } else if let at = [limits.limits?.fiveHour?.at, limits.limits?.sevenDay?.at].compactMap({ $0 }).max() {
                // The same wording as the Codex card: the user needs the age, not where it came from.
                Text(AccountUsagePresentation.updatedLabel(at: at, now: now) ?? "Updated")
                    .foregroundStyle(.secondary).monospacedDigit()
                    .help("Last update " + at.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text("Awaiting first reading").foregroundStyle(.secondary)
                    .help("Claude Code reports plan limits only for Pro and Max plans, after a session's first response.")
            }
        case .checking: Text("Checking…").foregroundStyle(.secondary)
        case .changedOutsideLunlet:
            Text("Changed outside Lunlet").foregroundStyle(.secondary)
                .help("Claude Code's status line was changed after Lunlet connected; see Settings › Agents.")
        case .unavailable:
            Text("Unavailable · Refresh").foregroundStyle(.secondary)
        case .notConnected:
            // One explicit click connects in place (AC-33.08); the line states what the click changes first.
            if let issue = limits.actionIssue {
                Text("Couldn't connect").foregroundStyle(.secondary).help(ClaudePlanLimitsSettings.message(issue))
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
    private static let connectHelp = "Lunlet adds its status line to Claude Code's settings.json while Claude Code is "
        + "selected, unless you disconnected it; an existing status line keeps running. A custom status line hides most of Claude Code's footer keyboard hints. Lunlet keeps only percent "
        + "used and reset times and reads no credentials. Undo, or Disconnect in Settings › Agents, restores the previous "
        + "setting exactly."

    private var hasReadings: Bool {
        limits.connection == .connected && (limits.limits?.fiveHour != nil || limits.limits?.sevenDay != nil)
    }

    /// One compact window: its label, reset time and percent left on one secondary line, then the meter.
    private func window(_ window: ClaudeLimitsText.Window, _ reading: LimitWindowReading?, even: Double?, now: Date,
                        estimate: String? = nil, estimateHelp: String? = nil) -> some View {
        let remaining = ClaudeLimitsText.remaining(reading, now: now)
        let spoken = remaining.map { _ in
            ClaudeLimitsText.left(reading, now: now) + ", " + ClaudeLimitsText.resetLine(reading, now: now)
                + (even.map { ", even pace " + String(Int($0)) + "% left" } ?? "") + (estimate.map { ". " + $0 } ?? "")
        }
        return VStack(alignment: .leading, spacing: PanelStyle.Space.tight) {
            HStack(spacing: PanelStyle.Space.tight) {
                Text(window.title).foregroundStyle(.primary)
                Text(verbatim: "· " + ClaudeLimitsText.resetLine(reading, now: now)).foregroundStyle(.secondary)
                Spacer(minLength: PanelStyle.Space.tight)
                Text(ClaudeLimitsText.left(reading, now: now)).foregroundStyle(remaining == nil ? .secondary : .primary)
            }
            .font(PanelStyle.Text.secondary).lineLimit(1)
            .frame(height: PanelStyle.Layout.secondaryLine)
            AllowanceBar(remaining: remaining, accentHex: accentHex, agent: .claude, evenPace: remaining == nil ? nil : even,
                         label: window.title + " remaining")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(estimate.map { $0 + (estimateHelp.map { "\n" + $0 } ?? "") } ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.title)
        .accessibilityValue(spoken ?? "Unknown")
    }

    /// Recorded usage today with tokens first and the categories listed separately, so cache reads can be read apart
    /// (AC-33.10); the API-price estimate is in the help. A footnote in one size, with the total in the primary color.
    private var usage: some View {
        let today = OverviewUsage.today(history.snapshot)
        let recorded = today.flatMap(ClaudeLimitsText.spokenBreakdown).map { " Recorded: " + $0 + "." } ?? ""
        return HStack(spacing: PanelStyle.Space.tight) {
            // The help names the source; the short label keeps every token category on the footnote line.
            Text("Today").foregroundStyle(.secondary)
            if let today {
                Text(LocalUsageText.tokens(today)).foregroundStyle(.primary)
                if let categories = ClaudeLimitsText.breakdown(today) {
                    Text(verbatim: "· " + categories).foregroundStyle(.secondary).truncationMode(.tail)
                }
            } else {
                Text(history.isLoading ? "Reading…" : history.unavailable ? "Unavailable · Refresh to try again" : "Unavailable")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(PanelStyle.Text.secondary).lineLimit(1)
        .accessibilityElement(children: .combine)
        .help("Recorded on this Mac from local Claude Code transcripts, each response counted once; a lower bound. "
            + (today.map { "Estimated cost " + LocalUsageText.cost($0) + " at " } ?? "Cost uses ")
            + "published Claude API list prices, not a subscription bill." + recorded)
    }
}
