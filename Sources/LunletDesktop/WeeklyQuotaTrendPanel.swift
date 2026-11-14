// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.01, AC-32.02, AC-32.03, AC-32.04, AC-32.05, AC-32.06, AC-32.07, AC-32.08, AC-32.09.
// Refs: US-33, AC-33.09, AC-33.10; US-16, AC-16.03.
// Refs: US-04, AC-04.08, AC-04.19; US-24, AC-24.01, AC-24.02.
import Charts
import SwiftUI
import LunletCore

/// An agent's hover overview: its weekly trend with the estimate, then daily usage on this Mac. Codex and Claude
/// Code share the layout, and both open their daily usage on tokens (AC-32.06, AC-33.10).
struct UsageOverviewPanel: View {
    @ObservedObject var history: LocalUsageModel
    let provider: SessionProvider
    let trend: (CGFloat) -> AnyView
    /// The metric the daily chart opens on. The panel opens on tokens (AC-33.10); its fit is also checked on cost.
    private let showCost: Bool

    init(account: AccountUsageModel, history: LocalUsageModel, showCost: Bool = false) {
        self.history = history; provider = .codex; self.showCost = showCost
        trend = { AnyView(WeeklyQuotaTrendPanel(account: account, history: history, chartHeight: $0)) }
    }
    init(claudeLimits: ClaudePlanLimitsModel, history: LocalUsageModel, showCost: Bool = false) {
        self.history = history; provider = .claude; self.showCost = showCost
        trend = { AnyView(ClaudeWeeklyTrendPanel(limits: claudeLimits, history: history, chartHeight: $0)) }
    }

    /// How far both charts may shrink, in turn, when the estimate and the footnote each take a second line.
    static let tightening: [CGFloat] = [0, 6, 12]

    var body: some View {
        GeometryReader { geometry in
            // A screen too short for the panel shortens both charts; so do words that need more lines than usual.
            let short = max(0, UsageHoverPanelController.overviewSize.height - geometry.size.height) / 2
            ViewThatFits(in: .vertical) {
                content(reduction: short + Self.tightening[0])
                content(reduction: short + Self.tightening[1])
                content(reduction: short + Self.tightening[2])
            }
        }
    }

    /// The panel's content at its natural height, with both charts shortened by `reduction`.
    func content(reduction: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            trend(max(15, 84 - reduction))
                .padding(.horizontal, 14).padding(.top, PanelStyle.Space.margin)
            Divider().padding(.horizontal, 14).padding(.top, PanelStyle.Space.medium)
            UsageHistoryPanel(model: history, showCost: showCost, chartHeight: max(15, 58 - reduction),
                              provider: provider)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Estimate polylines from the latest reading, clipped to the visible start of the chart.
enum QuotaEstimateGeometry {
    struct Lines: Equatable { let central: [QuotaReading]; let upper: [QuotaReading]; let lower: [QuotaReading] }
    struct BandPoint: Equatable { let at: Date; let low: Double; let high: Double }

    static func lines(_ estimate: QuotaPaceEstimate, from latest: QuotaReading, reset: Date, visibleFrom start: Date) -> Lines {
        func path(_ runOut: Date?, _ remaining: Double) -> [QuotaReading] {
            let end = QuotaReading(at: reset, remaining: runOut == nil ? remaining : 0, resetAt: reset)
            return clipped([latest] + (runOut.map { [QuotaReading(at: $0, remaining: 0, resetAt: reset)] } ?? []) + [end], from: start)
        }
        return .init(central: path(estimate.runOut, estimate.central),
                     upper: path(estimate.latestRunOut, estimate.remainingAtReset.upperBound),
                     lower: path(estimate.earliestRunOut, estimate.remainingAtReset.lowerBound))
    }

    /// The shaded range between the upper and lower lines, sampled at every corner of either line.
    static func band(_ lines: Lines) -> [BandPoint] {
        let times = Set((lines.upper + lines.lower).map(\.at)).sorted()
        return times.compactMap { time in
            guard let low = value(lines.lower, at: time), let high = value(lines.upper, at: time) else { return nil }
            return BandPoint(at: time, low: min(low, high), high: max(low, high))
        }
    }

    private static func value(_ line: [QuotaReading], at time: Date) -> Double? {
        guard let first = line.first, let last = line.last, time >= first.at, time <= last.at else { return nil }
        for (a, b) in zip(line, line.dropFirst()) where time >= a.at && time <= b.at {
            let span = b.at.timeIntervalSince(a.at)
            return span <= 0 ? b.remaining : a.remaining + (b.remaining - a.remaining) * time.timeIntervalSince(a.at) / span
        }
        return line.count == 1 ? first.remaining : nil
    }

    private static func clipped(_ points: [QuotaReading], from start: Date) -> [QuotaReading] {
        var result: [QuotaReading] = []
        for (a, b) in zip(points, points.dropFirst()) where b.at > start {
            if a.at >= start {
                if result.isEmpty { result.append(a) }
            } else {
                let fraction = start.timeIntervalSince(a.at) / max(1, b.at.timeIntervalSince(a.at))
                result.append(.init(at: start, remaining: a.remaining + (b.remaining - a.remaining) * fraction, resetAt: a.resetAt))
            }
            result.append(b)
        }
        return result
    }
}

/// Observed readings split wherever the chart must not connect them, so gaps and resets stay visible.
enum QuotaObservedSegments {
    static func split(_ points: [QuotaReading]) -> [[QuotaReading]] {
        var segments: [[QuotaReading]] = []
        for point in points {
            if let last = segments.last?.last, QuotaChartSegments.connects(last, point) { segments[segments.count - 1].append(point) }
            else { segments.append([point]) }
        }
        return segments
    }
}

/// One agent's limit window as the trend chart draws it, in remaining terms for every agent (AC-33.09).
struct WeeklyTrendInput {
    /// How long the window lasts: the even budget, the estimate's lookback and the axis follow it.
    var span = AllowanceSpan.week
    let title: String
    let display: QuotaTrendDisplay
    let resetAt: Date?
    /// The selected number of local calendar days of observations shown before the forecast.
    let days: Int
    /// The compact forecast wording: the hover tip over the estimate region and VoiceOver's summary (AC-32.06).
    let summary: String
    let summaryHelp: String
    /// The forecast stated once in words above the trend, or the reason there is none (AC-32.09).
    let estimate: String
    /// Remaining against the even pace at the latest reading; never a forecast (AC-32.05).
    let evenPace: String?
    let unavailable: String
}

/// Codex: account readings plus locally recorded allowance observations.
struct WeeklyQuotaTrendPanel: View {
    @ObservedObject var account: AccountUsageModel
    @ObservedObject var history: LocalUsageModel
    var chartHeight: CGFloat = 84

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let trend = account.weeklyTrend
            // The account's own limit window: a week unless the account reports another (AC-04.07).
            let span = trend.span ?? .week
            // Points and resets follow the selected range; the pace uses every comparable reading.
            let start = QuotaChartTimeline.start(now: context.date, days: history.historyDays) ?? context.date
            let display = trend.display(local: history.snapshot?.quotaHistory ?? [], now: context.date, since: start)
            let stale = account.latestReadFailed
            WeeklyTrendChart(input: .init(
                span: span,
                title: TrendChartText.title(.codex, span: span), display: display, resetAt: trend.resetAt, days: history.historyDays,
                summary: QuotaForecastText.header(display.pace, stale: stale, now: context.date),
                summaryHelp: QuotaForecastText.help(display.pace, stale: stale, resetAt: trend.resetAt, span: span),
                estimate: TrendChartText.estimate(display.pace, stale: stale, now: context.date),
                evenPace: TrendChartText.now(display.pace, now: context.date),
                unavailable: account.state == .unavailable ? "Allowance unavailable · Refresh to try again" : "Allowance unavailable"),
                now: context.date, chartHeight: chartHeight)
        }
    }
}

/// Claude Code: the weekly readings Lunlet's status line logged, with the same estimator and wording as Codex.
struct ClaudeWeeklyTrendPanel: View {
    @ObservedObject var limits: ClaudePlanLimitsModel
    @ObservedObject var history: LocalUsageModel
    var chartHeight: CGFloat = 84

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let readings = limits.connection == .connected ? limits.limits : nil
            let reset = readings?.sevenDay?.resetsAt
            let pace = ClaudeLimitsText.pace(readings, now: now)
            let start = QuotaChartTimeline.start(now: now, days: history.historyDays) ?? now
            let chart = reset.map {
                WeeklyQuotaTrend.chart(WeeklyQuotaEstimator.consistentReadings(readings?.weekly ?? [], now: now),
                                       resetAt: $0, now: now, since: start)
            }
            WeeklyTrendChart(input: .init(
                title: TrendChartText.title(.claude),
                display: .init(points: chart?.points ?? [], resets: chart?.resets ?? [], pace: pace),
                resetAt: reset, days: history.historyDays,
                summary: pace == nil ? "Awaiting a weekly reading" : QuotaForecastText.header(pace, stale: limits.readFailed, now: now),
                summaryHelp: QuotaForecastText.help(pace, stale: limits.readFailed, resetAt: reset),
                estimate: pace == nil ? "Awaiting a weekly reading"
                    : TrendChartText.estimate(pace, stale: limits.readFailed, now: now),
                evenPace: TrendChartText.now(pace, now: now),
                unavailable: limits.connection == .notConnected ? "Plan limits not connected" : "Awaiting a weekly reading"),
                now: now, chartHeight: chartHeight)
        }
    }
}

/// The weekly trend chart shared by every agent: the selected days of observed readings as a smooth curve through
/// the readings that changed, over a faint fill, then the estimate with its range through the reset; the even budget
/// as a faint guide and dashed markers at detected resets.
struct WeeklyTrendChart: View {
    let input: WeeklyTrendInput
    let now: Date
    var chartHeight: CGFloat = 84
    @ViewState private var hoverLocation: CGFloat?
    @Environment(\.agentChartColor) private var agentColor

    /// The fill under the observed line: the agent's color fading downwards, or a flat tint where no color is known.
    private var observedFill: AnyShapeStyle {
        agentColor.map { AnyShapeStyle(LinearGradient(colors: [$0.opacity(0.18), $0.opacity(0)], startPoint: .top, endPoint: .bottom)) }
            ?? AnyShapeStyle(.tint.opacity(0.08))
    }

    var body: some View {
        let display = input.display
        VStack(alignment: .leading, spacing: PanelStyle.Space.small) {
            // The window and the agent, with the reset moment at the trailing end; a narrow panel stacks them.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: PanelStyle.Space.tight) {
                    title
                    Spacer(minLength: PanelStyle.Space.tight)
                    resetMoment
                }
                VStack(alignment: .leading, spacing: 1) { title; resetMoment }
            }
            if let pace = display.pace, let reset = input.resetAt {
                VStack(alignment: .leading, spacing: PanelStyle.Space.hairline) {
                    if let even = input.evenPace {
                        Text(even).lineLimit(1)
                            .help("Even pace is what an even budget across this \(input.span.adjective) window would show at the "
                                + "latest reading's time. It is not a forecast.")
                    }
                    // The forecast in words, once; without one, the reason there is none (AC-32.09).
                    Text(input.estimate).lineLimit(2).fixedSize(horizontal: false, vertical: true).help(input.summaryHelp)
                }
                .font(Font.caption).foregroundStyle(.secondary)
                chart(points: display.points, resets: display.resets, reset: reset, now: now, days: input.days, pace: pace,
                      summary: input.summary)
                legend(resets: !display.resets.isEmpty)
            } else {
                Text(input.unavailable)
                    .font(Font.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            }
        }
        .help("The chart shows the selected days of recorded readings, then the estimate through the next reset at the "
            + "right edge. The faint straight line is an even budget across the current window. The estimate starts at the "
            + "latest reading; its shaded range uses every comparable reading from the past \(QuotaForecastText.lookback(input.span)), whatever range is "
            + "displayed, and assumes no additional reset. It is recalculated when a reading arrives. Dashed vertical lines "
            + "mark detected resets; hover one for its time, which can be approximate.")
    }

    private var title: some View {
        Text(input.title).font(PanelStyle.Text.title).lineLimit(1).fixedSize().accessibilityAddTraits(.isHeader)
    }
    /// The same wording as the limit rows: a time today, otherwise the weekday and time.
    @ViewBuilder private var resetMoment: some View {
        if let reset = input.resetAt {
            Text(TrendChartText.resets(reset, now: now)).font(Font.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }

    private func hoverTip(_ text: String, x: CGFloat, frame: CGRect) -> some View {
        Text(text)
            .font(Font.caption.weight(.medium)).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, PanelStyle.Space.tight)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(PanelStyle.separator, lineWidth: 0.5))
            .position(x: frame.minX + min(max(x, min(130, frame.width / 2)), max(frame.width - 130, frame.width / 2)),
                      y: frame.minY + 11)
            .allowsHitTesting(false)
    }

    /// The band's extent at one moment, for VoiceOver; built outside the chart builder so it type-checks quickly.
    private func bandDescription(_ point: QuotaEstimateGeometry.BandPoint) -> String {
        percent(point.low) + " to " + percent(point.high) + " at " + time(point.at)
    }
    private func chart(points: [QuotaReading], resets: [QuotaResetMarker], reset: Date, now: Date, days: Int,
                       pace: QuotaPace, summary: String) -> some View {
        let windowStart = QuotaChartTimeline.start(now: now, days: days) ?? now
        let estimate: QuotaPaceEstimate?
        if case .estimate(let value) = pace.forecast { estimate = value } else { estimate = nil }
        let lines = pace.latest.flatMap { latest in
            estimate.map { QuotaEstimateGeometry.lines($0, from: latest, reset: reset, visibleFrom: windowStart) }
        }
        let band = lines.map(QuotaEstimateGeometry.band) ?? []
        let idealStart = max(windowStart, reset.addingTimeInterval(-input.span.seconds))
        let ideal = WeeklyQuotaEstimator.idealRemaining(at: idealStart, resetAt: reset, window: input.span.seconds)
        let segments = QuotaObservedSegments.split(points)
        let shown = resets.filter { $0.at >= windowStart && $0.at < reset }
        // The "Reset" label at the right edge needs room: day labels within two days of it, or within about a seventh
        // of the span, are left out. A long window's ticks are days apart and carry dates instead of weekdays.
        let clearance = max(48 * 3600, reset.timeIntervalSince(windowStart) * 0.15)
        let stride = QuotaChartTimeline.tickStride(start: windowStart, reset: reset)
        let ticks = QuotaChartTimeline.dayTicks(start: windowStart, reset: reset).filter { reset.timeIntervalSince($0) > clearance }
        return Chart {
            ForEach(Array(band.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("Time", point.at), yStart: .value("Low", point.low), yEnd: .value("High", point.high),
                         series: .value("Series", "Estimate range"))
                    .foregroundStyle(.tint.opacity(0.1))
                    .accessibilityLabel("Estimate range")
                    .accessibilityValue(bandDescription(point))
            }
            if let ideal {
                ForEach([(idealStart, ideal), (reset, 0.0)], id: \.0) { at, remaining in
                    LineMark(x: .value("Time", at), y: .value("Remaining", remaining), series: .value("Series", "Even pace"))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [2, 3]))
                        .accessibilityLabel("Even pace")
                        .accessibilityValue(percent(remaining) + " at " + time(at))
                }
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                // The fill needs some width to read as a fill; under a stub of a few hours it would be a sliver.
                if let first = segment.first, let last = segment.last, last.at.timeIntervalSince(first.at) >= 6 * 3600 {
                    ForEach(segment, id: \.at) { point in
                        AreaMark(x: .value("Time", point.at), y: .value("Remaining", point.remaining),
                                 series: .value("Series", "Observed fill \(index)"))
                            .foregroundStyle(observedFill)
                            .interpolationMethod(.monotone)
                            .accessibilityHidden(true)
                    }
                }
                ForEach(segment, id: \.at) { point in
                    LineMark(x: .value("Time", point.at), y: .value("Remaining", point.remaining),
                             series: .value("Series", "Observed \(index)"))
                        .foregroundStyle(.tint)
                        .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                        .accessibilityLabel("So far")
                        .accessibilityValue(percent(point.remaining) + " at " + time(point.at))
                }
            }
            if let central = lines?.central, central.count > 1 {
                ForEach(central, id: \.at) { point in
                    LineMark(x: .value("Time", point.at), y: .value("Remaining", point.remaining),
                             series: .value("Series", "Estimate"))
                        .foregroundStyle(.tint.opacity(0.75))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4]))
                        .accessibilityLabel("Estimate")
                        .accessibilityValue(percent(point.remaining) + " at " + time(point.at))
                }
            }
            if let latest = pace.latest, latest.at >= windowStart {
                PointMark(x: .value("Time", latest.at), y: .value("Remaining", latest.remaining))
                    .foregroundStyle(.tint).symbolSize(30)
                    .accessibilityLabel("Latest reading")
                    .accessibilityValue(percent(latest.remaining) + " at " + time(latest.at))
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, marker in
                RuleMark(x: .value("Reset", marker.at))
                    .foregroundStyle(Color.secondary.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityLabel(marker.approximate ? "Detected reset, approximate" : "Detected reset")
                    .accessibilityValue(time(marker.at))
            }
        }
        .chartXScale(domain: windowStart...reset)
        .chartYScale(domain: 0...100, range: .plotDimension(endPadding: 4))
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(Font.caption) }
            }
        }
        .chartXAxis {
            // Day labels; when the span is long, colliding labels give way in order.
            AxisMarks(values: ticks) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel(collisionResolution: .greedy(minimumSpacing: 6)) {
                        Text(QuotaChartTimeline.tickLabel(date, stride: stride)).font(Font.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { $0.clipped() }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    // The next reset is the right edge: named there, in the axis label row.
                    Text("Reset").font(Font.caption).foregroundStyle(.primary)
                        .frame(width: 60, alignment: .trailing)
                        .position(x: frame.maxX - 30, y: frame.maxY + 10)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY)
                        .onContinuousHover { phase in
                            if case .active(let location) = phase { hoverLocation = location.x } else { hoverLocation = nil }
                        }
                    if let x = hoverLocation,
                       let marker = QuotaResetHitTesting.nearest(x: x, width: frame.width, start: windowStart, reset: reset,
                                                                 markers: shown) {
                        let markerX = frame.width * marker.at.timeIntervalSince(windowStart) / max(1, reset.timeIntervalSince(windowStart))
                        hoverTip(QuotaResetHitTesting.label(marker), x: markerX, frame: frame)
                    } else if let x = hoverLocation, estimate != nil, let latest = pace.latest,
                              x >= frame.width * latest.at.timeIntervalSince(windowStart) / max(1, reset.timeIntervalSince(windowStart)) {
                        // Hovering the estimate region repeats the forecast beside the pointer (AC-32.06).
                        hoverTip(summary, x: x, frame: frame)
                    }
                }
            }
        }
        .frame(height: chartHeight + 16)
        .accessibilityChartDescriptor(QuotaTrendDescriptor(points: points, band: band, central: lines?.central ?? [],
                                                           start: windowStart, reset: reset, summary: summary,
                                                           title: input.title, window: input.span.adjective))
        .help(shown.isEmpty ? "Right edge: the next reset. No resets detected in the displayed days." :
            "Right edge: the next reset. Detected resets: " + shown.prefix(5).map {
                $0.at.formatted(date: .abbreviated, time: .shortened) + ($0.approximate ? " (approx.)" : "")
            }.joined(separator: ", "))
    }

    private func legend(resets: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PanelStyle.Space.module) { legendItems(resets: resets) }
            VStack(alignment: .leading, spacing: PanelStyle.Space.tight) {
                HStack(spacing: PanelStyle.Space.module) {
                    LegendLine(label: "So far", style: AnyShapeStyle(.tint), dash: nil)
                    LegendBand()
                }
                HStack(spacing: PanelStyle.Space.module) {
                    LegendLine(label: "Even pace", style: AnyShapeStyle(Color.secondary.opacity(0.6)), dash: [2, 3])
                    if resets { LegendReset() }
                }
            }
        }
        .font(Font.caption)
    }
    @ViewBuilder private func legendItems(resets: Bool) -> some View {
        LegendLine(label: "So far", style: AnyShapeStyle(.tint), dash: nil)
        LegendBand()
        LegendLine(label: "Even pace", style: AnyShapeStyle(Color.secondary.opacity(0.6)), dash: [2, 3])
        if resets { LegendReset() }
    }

    private func percent(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) + "%" }
    private func time(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}

private struct LegendLine: View {
    let label: String
    let style: AnyShapeStyle
    let dash: [CGFloat]?
    var body: some View {
        HStack(spacing: PanelStyle.Space.tight) {
            Path { path in path.move(to: .init(x: 0, y: 2)); path.addLine(to: .init(x: 14, y: 2)) }
                .stroke(style, style: StrokeStyle(lineWidth: dash == nil ? 1.75 : 1, lineCap: .round, dash: dash ?? []))
                .frame(width: 14, height: 4).accessibilityHidden(true)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

private struct LegendBand: View {
    var body: some View {
        HStack(spacing: PanelStyle.Space.tight) {
            ZStack {
                RoundedRectangle(cornerRadius: 1).fill(.tint.opacity(0.12)).frame(width: 14, height: 8)
                Path { path in path.move(to: .init(x: 0, y: 2)); path.addLine(to: .init(x: 14, y: 2)) }
                    .stroke(.tint.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3])).frame(width: 14, height: 4)
            }.accessibilityHidden(true)
            Text("Estimate range").foregroundStyle(.secondary)
        }.help("Dashed: central estimate from the latest reading. Shaded: estimated range. Not a guarantee.")
    }
}

private struct LegendReset: View {
    var body: some View {
        HStack(spacing: PanelStyle.Space.tight) {
            Path { path in path.move(to: .init(x: 2, y: 0)); path.addLine(to: .init(x: 2, y: 10)) }
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: 4, height: 10)
                .accessibilityHidden(true)
            Text("Reset").foregroundStyle(.secondary)
        }.help("A dashed vertical line marks a detected reset. Hover it for its time; historical timing can be approximate.")
    }
}

/// VoiceOver and Audio Graphs: time and remaining-percent axes with So far, Estimate and Estimate range series.
private struct QuotaTrendDescriptor: AXChartDescriptorRepresentable {
    let points: [QuotaReading]
    let band: [QuotaEstimateGeometry.BandPoint]
    let central: [QuotaReading]
    let start: Date
    let reset: Date
    let summary: String
    let title: String
    /// "weekly" or "monthly": the window whose allowance the vertical axis measures.
    let window: String
    func makeChartDescriptor() -> AXChartDescriptor {
        let origin = start.timeIntervalSince1970
        let x = AXNumericDataAxisDescriptor(title: "Time", range: origin...max(origin + 1, reset.timeIntervalSince1970),
                                            gridlinePositions: []) { value in
            Date(timeIntervalSince1970: value).formatted(date: .abbreviated, time: .shortened)
        }
        let y = AXNumericDataAxisDescriptor(title: "Remaining \(window) allowance", range: 0...100, gridlinePositions: [0, 50, 100]) {
            $0.formatted(.number.precision(.fractionLength(0))) + " percent"
        }
        func series(_ name: String, _ values: [(Date, Double)]) -> AXDataSeriesDescriptor {
            AXDataSeriesDescriptor(name: name, isContinuous: true,
                                   dataPoints: values.map { AXDataPoint(x: $0.0.timeIntervalSince1970, y: $0.1) })
        }
        var all = [series("So far", points.map { ($0.at, $0.remaining) })]
        if central.count > 1 { all.append(series("Estimate", central.map { ($0.at, $0.remaining) })) }
        if !band.isEmpty {
            all.append(series("Estimate range, low", band.map { ($0.at, $0.low) }))
            all.append(series("Estimate range, high", band.map { ($0.at, $0.high) }))
        }
        return AXChartDescriptor(title: title, summary: summary, xAxis: x, yAxis: y, additionalAxes: [], series: all)
    }
}
