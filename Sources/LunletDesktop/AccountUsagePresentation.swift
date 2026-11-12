// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.01, AC-32.03.
// Refs: US-04, AC-04.01, AC-04.03, AC-04.07, AC-04.08, AC-04.09, AC-04.15.
import Foundation
import LunletCore

/// One reported Codex window, weekly or five-hour, identified by its duration (AC-04.07, AC-04.15).
struct AllowanceWindow: Equatable {
    let bucketID: String?
    let bucketName: String
    let remainingPercent: Double?
    let resetsAt: Date?
}

enum AccountUsagePresentation {
    static let weeklyMinutes = 10_080
    static let fiveHourMinutes = 300

    static func weekly(in snapshot: AccountLimitsSnapshot) -> AllowanceWindow? { window(in: snapshot, minutes: weeklyMinutes) }
    /// The five-hour window beside the weekly one, by its duration and never by its position (AC-04.15).
    static func fiveHour(in snapshot: AccountLimitsSnapshot) -> AllowanceWindow? { window(in: snapshot, minutes: fiveHourMinutes) }

    private static func window(in snapshot: AccountLimitsSnapshot, minutes: Int) -> AllowanceWindow? {
        let weekly = snapshot.buckets.flatMap { bucket in
            [bucket.primary, bucket.secondary].compactMap { window -> AllowanceWindow? in
                guard let window, window.durationMinutes == minutes else { return nil }
                return AllowanceWindow(bucketID: bucket.id, bucketName: bucket.name ?? bucket.id ?? "Codex",
                                       remainingPercent: window.estimatedRemainingPercent,
                                       resetsAt: window.resetsAt)
            }
        }
        // Multiple weekly buckets need an explicit selection policy; never pick an arbitrary one.
        // As for credits, the default Codex limit identifies the account's own weekly window.
        if weekly.count == 1 { return weekly.first }
        let codex = weekly.filter { $0.bucketID == "codex" }
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
