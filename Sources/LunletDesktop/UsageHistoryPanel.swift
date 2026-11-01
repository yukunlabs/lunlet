// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-18, AC-18.02, AC-18.03; US-33, AC-33.04, AC-33.10.
// Refs: US-25, AC-25.02; US-24, AC-24.01, AC-24.02.
// Refs: US-04, AC-04.02, AC-04.03, AC-04.08, AC-04.12; US-03, AC-03.08, AC-03.10.
import Charts
import SwiftUI
import LunletCore

struct UsageHistoryPanel: View {
    @ObservedObject var model: LocalUsageModel
    private let chartHeight: CGFloat
    /// Whose local records the chart shows; it selects source and estimate labels only.
    private let provider: SessionProvider
    @ViewState private var showCost = false

    init(model: LocalUsageModel, showCost: Bool = false, chartHeight: CGFloat = 96, provider: SessionProvider = .codex) {
        self.model = model
        self.chartHeight = chartHeight; self.provider = provider
        _showCost = ViewState(initialValue: showCost)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.medium) {
            HStack(alignment: .center, spacing: PanelStyle.Space.small) {
                Text("Daily usage").font(PanelStyle.Text.title)
                if model.isLoading { ProgressView().controlSize(.mini).accessibilityLabel("Refreshing local usage") }
                Spacer(minLength: PanelStyle.Space.medium)
                // Both metrics use the same selected days and keep their unknown and estimate distinctions; the
                // switch matches the Overview's in style and order.
                PanelSegmentedControl(selection: $showCost, segments: [.init(value: false, title: "Tokens"),
                                                                       .init(value: true, title: "Cost")],
                                      size: .small, label: "Chart metric")
                    .fixedSize()
            }
            if let snapshot = model.snapshot {
                chart(snapshot.days)
            } else {
                VStack(spacing: PanelStyle.Space.small) {
                    Image(systemName: "chart.bar").font(.title3).foregroundStyle(.tertiary).accessibilityHidden(true)
                    Text(model.isLoading ? "Reading local usage…"
                         : model.unavailable ? "Local usage unavailable · Refresh to try again" : "Local usage unavailable")
                        .font(Font.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: chartHeight + 34)
            }
            sourceLine
        }.padding(.horizontal, 14).padding(.vertical, PanelStyle.Space.module)
    }

    private func chart(_ days: [LocalUsageDay]) -> some View {
        let metric = showCost ? "Estimated cost" : "Tokens"
        let compact = days.count > 5
        // Categorical days keep each label centered under its own bar whatever the record's time of day.
        func label(_ date: Date) -> String {
            date.formatted(compact ? .dateTime.weekday(.narrow).day() : .dateTime.weekday(.abbreviated).day())
        }
        return Chart(days) { day in
            // A missing record has no bar and is labeled unknown; it is never drawn as zero.
            BarMark(x: .value("Day", label(day.date)), y: .value(metric, value(day.amount) ?? 0))
                .foregroundStyle(.tint.opacity(value(day.amount) == nil ? 0 : 0.9))
                .cornerRadius(4)
                .annotation(position: .top, spacing: 2) {
                    Text(valueLabel(day.amount)).font(Font.caption).monospacedDigit().lineLimit(1)
                        .foregroundStyle(value(day.amount) == nil ? .tertiary : .secondary)
                }
                .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                .accessibilityValue(LocalUsageText.tokens(day.amount) + ", " + LocalUsageText.costHelp(day.amount, provider: provider))
        }
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(maximum(days) * 1.18))
        .chartXScale(domain: days.map { label($0.date) })
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel(centered: true).font(Font.caption) }
        }
        .frame(height: chartHeight + 14)
        .accessibilityChartDescriptor(DailyUsageDescriptor(days: days, cost: showCost, provider: provider))
        .help(days.map { day in
            // Claude days list cost first and each token category, as the Claude page does (AC-33.10).
            day.date.formatted(.dateTime.weekday(.abbreviated).day()) + ": " + (provider == .claude
                ? LocalUsageText.cost(day.amount) + (ClaudeLimitsText.breakdown(day.amount).map { " · " + $0 } ?? "")
                : LocalUsageText.tokens(day.amount) + " · " + LocalUsageText.cost(day.amount))
        }.joined(separator: "\n"))
    }

    private var sourceLine: some View {
        let claude = provider == .claude
        // Claude history is always a lower bound, which its own label states.
        let unpriced = model.snapshot?.days.contains(where: { $0.amount.unpricedTokens > 0 }) == true
        let incomplete = [model.snapshot?.partial == true && !claude ? "Partial history" : nil,
                showCost && unpriced ? "Partial pricing" : nil]
                .compactMap { $0 }.joined(separator: " · ")
        let source = claude ? (showCost ? "This Mac · API list-price estimate · Lower bound"
                                        : "This Mac · Recorded usage · Lower bound")
            : showCost ? "This Mac · Estimated USD" : "This Mac · local Codex records"
        let estimate = claude ? "Claude API list prices, not a subscription bill. " : "Standard API estimate, not a subscription bill. "
        return Label(([source, incomplete].filter { !$0.isEmpty }).joined(separator: " · "), systemImage: "laptopcomputer")
            .font(Font.caption).foregroundStyle(.secondary)
            .help(showCost ? estimate + LocalUsageText.coverage(model.snapshot?.days.map(\.amount) ?? [])
                : claude ? "Recorded Claude Code transcripts on this Mac, each response counted once. Unrecorded usage is missing."
                : "Local Codex usage records.")
    }

    private func value(_ amount: LocalUsageAmount) -> Double? {
        showCost ? amount.estimatedUSD : amount.tokens.map(Double.init)
    }
    private func maximum(_ days: [LocalUsageDay]) -> Double { max(1e-12, days.compactMap { value($0.amount) }.max() ?? 1) }
    private func valueLabel(_ amount: LocalUsageAmount) -> String {
        if showCost { return LocalUsageText.costBar(amount) }
        return amount.tokens.map { (amount.partial ? "≥" : "") + $0.formatted(.number.notation(.compactName)) } ?? "—"
    }
}

/// VoiceOver and Audio Graphs: named axes and one series; unknown days carry no value rather than zero.
private struct DailyUsageDescriptor: AXChartDescriptorRepresentable {
    let days: [LocalUsageDay]
    let cost: Bool
    let provider: SessionProvider
    func makeChartDescriptor() -> AXChartDescriptor {
        let labels = days.map { $0.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
        let values = days.map { cost ? $0.amount.estimatedUSD : $0.amount.tokens.map(Double.init) }
        let x = AXCategoricalDataAxisDescriptor(title: "Day", categoryOrder: labels)
        let y = AXNumericDataAxisDescriptor(title: cost ? "Estimated cost in US dollars" : "Recorded tokens",
                                            range: 0...max(1, values.compactMap { $0 }.max() ?? 1), gridlinePositions: []) { value in
            cost ? "$" + value.formatted(.number.precision(.fractionLength(0...2))) : value.formatted(.number.notation(.compactName))
        }
        let points = zip(labels, days).compactMap { label, day -> AXDataPoint? in
            guard let value = cost ? day.amount.estimatedUSD : day.amount.tokens.map(Double.init) else { return nil }
            return AXDataPoint(x: label, y: value, label: LocalUsageText.tokens(day.amount) + ", " + LocalUsageText.cost(day.amount))
        }
        let name = cost ? (provider == .claude ? "API list-price estimate" : "Standard API estimate") : "Tokens"
        return AXChartDescriptor(title: "Daily usage on this Mac",
                                 summary: "\(points.count) of \(days.count) days have recorded values; missing days are unknown.",
                                 xAxis: x, yAxis: y, additionalAxes: [],
                                 series: [AXDataSeriesDescriptor(name: name, isContinuous: false, dataPoints: points)])
    }
}
