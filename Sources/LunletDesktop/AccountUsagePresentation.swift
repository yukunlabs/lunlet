// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.01, AC-32.03; US-24, AC-24.02.
// Refs: US-04, AC-04.01, AC-04.03, AC-04.07, AC-04.08, AC-04.09, AC-04.15, AC-04.19.
import Foundation
import LunletCore

/// How long a reported limit window lasts, and the words the panel has for it. A window is told by its length, never
/// by its position in the response (AC-04.07, AC-04.15).
struct AllowanceSpan: Equatable, Hashable, Sendable {
    let minutes: Int
    static let week = AllowanceSpan(minutes: 10_080)
    static let fiveHour = AllowanceSpan(minutes: 300)
    /// A month is reported as 28 to 31 days.
    private static let month = 40_320...44_640

    var seconds: TimeInterval { Double(minutes) * 60 }
    private var isMonth: Bool { Self.month.contains(minutes) }
    private var days: Int? { minutes > 0 && minutes % 1_440 == 0 ? minutes / 1_440 : nil }
    private var hours: Int? { minutes > 0 && minutes % 60 == 0 ? minutes / 60 : nil }

    /// "Week", "Month", "14-day": the word that starts a reset line and a chart's title.
    var name: String {
        if self == .week { return "Week" }
        if isMonth { return "Month" }
        if days == 1 { return "Day" }
        return counted
    }
    /// "weekly", "monthly", "14-day": the word before "limit" or "allowance".
    var adjective: String {
        if self == .week { return "weekly" }
        if isMonth { return "monthly" }
        if days == 1 { return "daily" }
        return counted
    }
    /// A stable name for saved state and notification identifiers; the weekly and five-hour windows keep the keys
    /// they had before any other window was read.
    var key: String {
        if self == .week { return "weekly" }
        if self == .fiveHour { return "fiveHour" }
        return isMonth ? "monthly" : "minutes\(minutes)"
    }
    private var counted: String {
        if let days { return "\(days)-day" }
        if let hours { return "\(hours)-hour" }
        return "\(minutes)-minute"
    }
}

/// One reported Codex window, identified by its duration (AC-04.07, AC-04.15).
struct AllowanceWindow: Equatable {
    let bucketID: String?
    let bucketName: String
    let remainingPercent: Double?
    let resetsAt: Date?
    /// How long the window lasts.
    let span: AllowanceSpan
}

enum AccountUsagePresentation {
    static let weeklyMinutes = AllowanceSpan.week.minutes
    static let fiveHourMinutes = AllowanceSpan.fiveHour.minutes
    /// The shortest window that counts as an account's long limit: one day.
    static let shortestLimitMinutes = 1_440

    static func weekly(in snapshot: AccountLimitsSnapshot) -> AllowanceWindow? { window(in: snapshot, minutes: weeklyMinutes) }
    /// The five-hour window beside the longer one, by its duration and never by its position (AC-04.15).
    static func fiveHour(in snapshot: AccountLimitsSnapshot) -> AllowanceWindow? { window(in: snapshot, minutes: fiveHourMinutes) }

    /// The account's own long limit, which the header, the entry, the forecast and the notifications show: its weekly
    /// window when it reports one, otherwise its longest window of a day or more, such as the 30-day window of a plan
    /// without a weekly one. The five-hour window is never the limit, and no window is inferred (AC-04.03, AC-04.07).
    static func limit(in snapshot: AccountLimitsSnapshot) -> AllowanceWindow? {
        if let weekly = weekly(in: snapshot) { return weekly }
        let lengths = snapshot.buckets.flatMap { [$0.primary, $0.secondary] }.compactMap { $0?.durationMinutes }
        // Several weekly windows that could not be told apart stay ambiguous; a longer window does not settle them.
        guard !lengths.contains(weeklyMinutes),
              let longest = lengths.filter({ $0 >= shortestLimitMinutes }).max() else { return nil }
        return window(in: snapshot, minutes: longest)
    }

    private static func window(in snapshot: AccountLimitsSnapshot, minutes: Int) -> AllowanceWindow? {
        let matching = snapshot.buckets.flatMap { bucket in
            [bucket.primary, bucket.secondary].compactMap { window -> AllowanceWindow? in
                guard let window, window.durationMinutes == minutes else { return nil }
                return AllowanceWindow(bucketID: bucket.id, bucketName: bucket.name ?? bucket.id ?? "Codex",
                                       remainingPercent: window.estimatedRemainingPercent,
                                       resetsAt: window.resetsAt, span: AllowanceSpan(minutes: minutes))
            }
        }
        // Several buckets with such a window need an explicit selection policy; never pick an arbitrary one.
        // As for credits, the default Codex limit identifies the account's own window.
        if matching.count == 1 { return matching.first }
        let codex = matching.filter { $0.bucketID == "codex" }
        return codex.count == 1 ? codex.first : nil
    }

    /// The five-hour line (AC-04.15): nil when a successful read reports no such window, because the account has none;
    /// unknown when there is no successful read at all (AC-04.03).
    static func fiveHourLine(in snapshot: AccountLimitsSnapshot?, now: Date) -> (left: String, reset: String)? {
        guard let snapshot else { return windowLine(nil, now: now) }
        guard let window = fiveHour(in: snapshot) else { return nil }
        return windowLine(window, now: now)
    }

    /// A window's compact line: percent left and the reset in the AC-04.01 wording; unknown stays unknown (AC-04.03).
    static func windowLine(_ window: AllowanceWindow?, now: Date) -> (left: String, reset: String) {
        let left = window?.remainingPercent.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "% left" } ?? "—"
        guard let reset = window?.resetsAt else { return (left, "Reset —") }
        guard let remaining = countdown(until: reset, now: now) else { return (left, "Reset due") }
        return (left, "Resets in " + remaining)
    }

    static func countdown(until date: Date, now: Date) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return nil }
        let days = Int(seconds / 86_400), hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3_600)
        if days > 0 { return "\(days)d" + (hours > 0 ? " \(hours)h" : "") }
        return hours > 0 ? "\(hours)h" : "<1h"
    }

    /// The reset credits line for assistive tools (AC-24.02): the count and the expiry the line shows, since the
    /// group's own label replaces its children's text.
    static func resetCreditsSpoken(_ resets: EarnedResets?, now: Date) -> String {
        guard let count = resets?.availableCount else { return "unknown" }
        let expiry = resetExpiryLabels(resets, now: now).map { $0 == "—" ? "unknown" : $0 }
        return "\(count) available" + (expiry.isEmpty ? "" : ", expiring in " + expiry.joined(separator: ", "))
    }

    static func resetExpiryLabels(_ resets: EarnedResets?, now: Date) -> [String] {
        guard let count = resets?.availableCount, count > 0 else { return [] }
        let grouped = Dictionary(grouping: resets?.details?.filter { $0.status == "available" } ?? [], by: \.id)
        guard grouped.count <= count else { return ["—"] }
        let dates: [Date?] = grouped.values.map { rows in
            let values = Set(rows.map(\.expiresAt))
            return values.count == 1 ? rows.first?.expiresAt : nil
        }
        let sorted = dates.compactMap { $0 }.sorted()
        var labels = sorted.prefix(2).map { countdown(until: $0, now: now) ?? "Expired" }
        let unknown = count - sorted.count
        if unknown > 0 { labels.append("—") }
        if sorted.count > 2 { labels.append("+\(sorted.count - 2)") }
        return labels
    }


    static func updatedLabel(at date: Date, now: Date) -> String? {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed.isFinite, elapsed >= 0, elapsed < Double(Int.max) else { return nil }
        if elapsed < 60 { return "Updated just now" }
        if elapsed < 3_600 { return "Updated \(Int(elapsed / 60))m ago" }
        if elapsed < 86_400 { return "Updated \(Int(elapsed / 3_600))h ago" }
        return "Updated \(Int(elapsed / 86_400))d ago"
    }

    static func creditBalance(_ raw: String) -> String {
        guard raw.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else { return "—" }
        let minimum = Decimal(string: "0.01")!
        if value > 0, value < minimum { return "<0.01" }
        if value < 0, value > -minimum { return ">−0.01" }
        return value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0...2)))
    }

}
