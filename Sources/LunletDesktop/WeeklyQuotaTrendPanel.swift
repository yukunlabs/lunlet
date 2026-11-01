// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.01, AC-32.02, AC-32.03, AC-32.04, AC-32.05, AC-32.06, AC-32.07, AC-32.08.
// Refs: US-33, AC-33.09, AC-33.10; US-16, AC-16.03.
// Refs: US-04, AC-04.08; US-24, AC-24.01, AC-24.02.
import Charts
import SwiftUI
import LunletCore

/// An agent's hover overview: its weekly trend with the estimate, then daily usage on this Mac. Codex and Claude
/// Code share the layout, and both open their daily usage on tokens (AC-32.06, AC-33.10).
struct UsageOverviewPanel: View {
    @ObservedObject var history: LocalUsageModel
    let provider: SessionProvider
    let trend: (CGFloat) -> AnyView

    init(account: AccountUsageModel, history: LocalUsageModel) {
        self.history = history; provider = .codex
        trend = { AnyView(WeeklyQuotaTrendPanel(account: account, history: history, chartHeight: $0)) }
    }
    init(claudeLimits: ClaudePlanLimitsModel, history: LocalUsageModel) {
        self.history = history; provider = .claude
        trend = { AnyView(ClaudeWeeklyTrendPanel(limits: claudeLimits, history: history, chartHeight: $0)) }
    }

    var body: some View {
        GeometryReader { geometry in
            let reduction = max(0, UsageHoverPanelController.overviewSize.height - geometry.size.height) / 2
            VStack(alignment: .leading, spacing: 0) {
                trend(max(15, 84 - reduction))
                    .padding(.horizontal, 14).padding(.top, PanelStyle.Space.margin)
                Divider().padding(.horizontal, 14).padding(.top, PanelStyle.Space.medium)
                UsageHistoryPanel(model: history, chartHeight: max(15, 58 - reduction),
                                  provider: provider)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
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

/// One agent's weekly window as the trend chart draws it, in remaining terms for every agent (AC-33.09).
struct WeeklyTrendInput {
    let title: String
    let display: QuotaTrendDisplay
    let resetAt: Date?
    let days: Int
    /// The forecast sentence: the hover tip over the estimate, or a short note when there is no estimate.
    let summary: String
    let summaryHelp: String
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
            let start = QuotaChartTimeline.start(now: context.date, days: history.historyDays) ?? context.date
            // Points and resets follow the selected range; the pace uses every comparable reading.
            let display = trend.display(local: history.snapshot?.quotaHistory ?? [], now: context.date, since: start)
            let stale = account.latestReadFailed
            WeeklyTrendChart(input: .init(
                title: "Weekly allowance", display: display, resetAt: trend.resetAt, days: history.historyDays,
                summary: QuotaForecastText.header(display.pace, stale: stale, now: context.date),
                summaryHelp: QuotaForecastText.help(display.pace, stale: stale, resetAt: trend.resetAt),
                evenPace: QuotaForecastText.evenPace(display.pace, now: context.date),
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
                title: "Weekly limit", display: .init(points: chart?.points ?? [], resets: chart?.resets ?? [], pace: pace),
                resetAt: reset, days: history.historyDays,
                summary: pace == nil ? "Awaiting a weekly reading" : QuotaForecastText.header(pace, stale: limits.readFailed, now: now),
                summaryHelp: QuotaForecastText.help(pace, stale: limits.readFailed, resetAt: reset),
                evenPace: QuotaForecastText.evenPace(pace, now: now),
                unavailable: limits.connection == .notConnected ? "Plan limits not connected" : "Awaiting a weekly reading"),
                now: now, chartHeight: chartHeight)
        }
    }
}

/// The weekly trend chart shared by every agent: observed readings, even pace, the estimate with its range, and
/// resets.
struct WeeklyTrendChart: View {
    let input: WeeklyTrendInput
    let now: Date
    var chartHeight: CGFloat = 84
    @ViewState private var hoverLocation: CGFloat?

    var body: some View {
        let display = input.display
        // An estimate is drawn on the chart and explained on hover; only states without one keep a short note.
        let estimating: Bool = { if case .estimate = display.pace?.forecast { true } else { false } }()
        VStack(alignment: .leading, spacing: PanelStyle.Space.small) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: PanelStyle.Space.tight) {
                    title(reset: input.resetAt)
                    Spacer(minLength: PanelStyle.Space.tight)
                    if !estimating { headerText(input.summary, help: input.summaryHelp, pace: display.pace).lineLimit(1).fixedSize() }
                }
                VStack(alignment: .leading, spacing: PanelStyle.Space.hairline) {
                    title(reset: input.resetAt)
                    if !estimating {
                        headerText(input.summary, help: input.summaryHelp, pace: display.pace).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let pace = display.pace, let reset = input.resetAt {
                chart(points: display.points, resets: display.resets, reset: reset, now: now,
                      days: input.days, pace: pace, summary: input.summary)
                if let even = input.evenPace {
                    Text(even).font(Font.caption).foregroundStyle(.secondary)
                        .help("Even pace is what an even budget across this weekly window would show at the latest "
                            + "reading's time. It is not a forecast.")
                }
                legend
            } else {
                Text(input.unavailable)
                    .font(Font.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            }
        }
        .help("Even pace runs evenly across this weekly window to its reset. Observed values come from recorded "
            + "readings. Vertical lines mark detected resets; their positions can be approximate. The estimate starts at "
            + "the latest reading; its shaded range uses every comparable reading from the past seven days, whatever range "
            + "is displayed, and assumes no additional reset. It is recalculated when a reading arrives.")
    }

    private func title(reset: Date?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(input.title).font(PanelStyle.Text.title).lineLimit(1).fixedSize()
            if let reset {
                Text("Resets " + reset.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    .font(Font.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
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

    private func headerText(_ text: String, help: String, pace: QuotaPace?) -> some View {
        let projected: Bool
        if case .estimate = pace?.forecast { projected = true } else { projected = false }
        return Text(text).font(Font.caption.weight(projected ? .semibold : .regular))
            .foregroundStyle(projected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)).help(help)
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
        let idealStart = max(windowStart, reset.addingTimeInterval(-7 * 86_400))
        let ideal = WeeklyQuotaEstimator.idealRemaining(at: idealStart, resetAt: reset)
        let segments = QuotaObservedSegments.split(points)
        let shown = resets.filter { $0.at >= windowStart && $0.at <= reset }
        return Chart {
            ForEach(Array(band.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("Time", point.at), yStart: .value("Low", point.low), yEnd: .value("High", point.high),
                         series: .value("Series", "Estimate range"))
                    .foregroundStyle(.tint.opacity(0.18))
                    .accessibilityLabel("Estimate range")
                    .accessibilityValue(bandDescription(point))
            }
            if let ideal {
                ForEach([(idealStart, ideal), (reset, 0.0)], id: \.0) { at, remaining in
                    LineMark(x: .value("Time", at), y: .value("Remaining", remaining), series: .value("Series", "Even pace"))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [1.5, 3]))
                        .accessibilityLabel("Even pace")
                        .accessibilityValue(percent(remaining) + " at " + time(at))
                }
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                ForEach(segment, id: \.at) { point in
                    LineMark(x: .value("Time", point.at), y: .value("Remaining", point.remaining),
                             series: .value("Series", "Observed \(index)"))
                        .foregroundStyle(.tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .symbol { Circle().fill(.tint).frame(width: 3.5, height: 3.5) }
                        .accessibilityLabel("Observed")
                        .accessibilityValue(percent(point.remaining) + " at " + time(point.at))
                }
            }
            if let central = lines?.central, central.count > 1 {
                ForEach(central, id: \.at) { point in
                    LineMark(x: .value("Time", point.at), y: .value("Remaining", point.remaining),
                             series: .value("Series", "Estimate"))
                        .foregroundStyle(.tint.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .accessibilityLabel("Estimate")
                        .accessibilityValue(percent(point.remaining) + " at " + time(point.at))
                }
            }
            if let latest = pace.latest, latest.at >= windowStart {
                PointMark(x: .value("Time", latest.at), y: .value("Remaining", latest.remaining))
                    .foregroundStyle(.tint).symbolSize(28)
                    .accessibilityLabel("Latest reading")
                    .accessibilityValue(percent(latest.remaining) + " at " + time(latest.at))
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, marker in
                RuleMark(x: .value("Reset", marker.at))
                    .foregroundStyle(Color.secondary.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityLabel(marker.approximate ? "Detected reset, approximate" : "Detected reset")
                    .accessibilityValue(time(marker.at))
            }
            RuleMark(x: .value("Reset", reset))
                .foregroundStyle(Color.secondary.opacity(0.8)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .accessibilityLabel("Next scheduled reset").accessibilityValue(time(reset))
        }
        .chartXScale(domain: windowStart...reset)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(Font.caption) }
            }
        }
        .chartXAxis {
            AxisMarks(values: QuotaChartTimeline.dates(now: now, reset: reset, days: days)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel(format: .dateTime.day(), centered: false).font(Font.caption)
            }
        }
        .chartPlotStyle { $0.clipped() }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY)
                        .onContinuousHover { phase in
                            if case .active(let location) = phase { hoverLocation = location.x } else { hoverLocation = nil }
                        }
                    if let x = hoverLocation,
                       let marker = QuotaResetHitTesting.nearest(x: x, width: frame.width, start: windowStart, reset: reset,
                                                                 markers: resets) {
                        let markerX = frame.width * marker.at.timeIntervalSince(windowStart) / max(1, reset.timeIntervalSince(windowStart))
                        hoverTip(QuotaResetHitTesting.label(marker), x: markerX, frame: frame)
                    } else if let x = hoverLocation, estimate != nil, let latest = pace.latest,
                              x >= frame.width * latest.at.timeIntervalSince(windowStart) / max(1, reset.timeIntervalSince(windowStart)) {
                        // Hovering the estimate region explains it; the chart itself carries no forecast sentence.
                        hoverTip(summary, x: x, frame: frame)
                    }
                }
            }
        }
        .frame(height: chartHeight + 16)
        .accessibilityChartDescriptor(QuotaTrendDescriptor(points: points, band: band, central: lines?.central ?? [],
                                                           start: windowStart, reset: reset, summary: summary,
                                                           title: input.title))
        .help(resets.isEmpty ? "Right edge: next scheduled reset. No resets detected in the displayed history." :
            "Right edge: next scheduled reset. Detected resets: " + resets.prefix(5).map {
                $0.at.formatted(date: .abbreviated, time: .shortened) + ($0.approximate ? " (approx.)" : "")
            }.joined(separator: ", "))
    }

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PanelStyle.Space.module) { legendItems }
            VStack(alignment: .leading, spacing: PanelStyle.Space.tight) {
                HStack(spacing: PanelStyle.Space.module) {
                    LegendLine(label: "Observed", style: AnyShapeStyle(.tint), dash: nil)
                    LegendBand()
                }
                HStack(spacing: PanelStyle.Space.module) {
                    LegendLine(label: "Even pace", style: AnyShapeStyle(Color.secondary), dash: [1.5, 3])
                    LegendReset()
                }
            }
        }
        .font(Font.caption)
    }
    @ViewBuilder private var legendItems: some View {
        LegendLine(label: "Observed", style: AnyShapeStyle(.tint), dash: nil)
        LegendBand()
        LegendLine(label: "Even pace", style: AnyShapeStyle(Color.secondary), dash: [1.5, 3])
        LegendReset()
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
                .stroke(style, style: StrokeStyle(lineWidth: dash == nil ? 2 : 1.5, lineCap: .round, dash: dash ?? []))
                .frame(width: 14, height: 4).accessibilityHidden(true)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

private struct LegendBand: View {
    var body: some View {
        HStack(spacing: PanelStyle.Space.tight) {
            ZStack {
                RoundedRectangle(cornerRadius: 1).fill(.tint.opacity(0.18)).frame(width: 14, height: 8)
                Path { path in path.move(to: .init(x: 0, y: 2)); path.addLine(to: .init(x: 14, y: 2)) }
                    .stroke(.tint.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])).frame(width: 14, height: 4)
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
        }.help("Vertical dashed lines mark detected resets and the next scheduled reset. Hover a line for its time; "
            + "historical timing can be approximate.")
    }
}

/// VoiceOver and Audio Graphs: time and remaining-percent axes with Observed, Estimate and Estimate range series.
private struct QuotaTrendDescriptor: AXChartDescriptorRepresentable {
    let points: [QuotaReading]
    let band: [QuotaEstimateGeometry.BandPoint]
    let central: [QuotaReading]
    let start: Date
    let reset: Date
    let summary: String
    let title: String
    func makeChartDescriptor() -> AXChartDescriptor {
        let origin = start.timeIntervalSince1970
        let x = AXNumericDataAxisDescriptor(title: "Time", range: origin...max(origin + 1, reset.timeIntervalSince1970),
                                            gridlinePositions: []) { value in
            Date(timeIntervalSince1970: value).formatted(date: .abbreviated, time: .shortened)
        }
        let y = AXNumericDataAxisDescriptor(title: "Remaining weekly allowance", range: 0...100, gridlinePositions: [0, 50, 100]) {
            $0.formatted(.number.precision(.fractionLength(0))) + " percent"
        }
        func series(_ name: String, _ values: [(Date, Double)]) -> AXDataSeriesDescriptor {
            AXDataSeriesDescriptor(name: name, isContinuous: true,
                                   dataPoints: values.map { AXDataPoint(x: $0.0.timeIntervalSince1970, y: $0.1) })
        }
        var all = [series("Observed", points.map { ($0.at, $0.remaining) })]
        if central.count > 1 { all.append(series("Estimate", central.map { ($0.at, $0.remaining) })) }
        if !band.isEmpty {
            all.append(series("Estimate range, low", band.map { ($0.at, $0.low) }))
            all.append(series("Estimate range, high", band.map { ($0.at, $0.high) }))
        }
        return AXChartDescriptor(title: title, summary: summary, xAxis: x, yAxis: y, additionalAxes: [], series: all)
    }
}
