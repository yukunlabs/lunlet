// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.09; US-32, AC-32.03, AC-32.07; US-04, AC-04.03; US-19, AC-19.04.
import Darwin
import Foundation
import LunletCore

/// Claude plan limits as Claude Code reported them to Lunlet's status line: official percent-used values,
/// never estimates. A window that was not reported, or failed validation, stays nil (unknown).
public struct ClaudePlanLimits: Equatable, Sendable {
    public let fiveHour: LimitWindowReading?
    public let sevenDay: LimitWindowReading?
    /// Seven-day readings for the provider-independent pace estimator, as remaining percentages, oldest first.
    public let weekly: [QuotaReading]
    public init(fiveHour: LimitWindowReading?, sevenDay: LimitWindowReading?, weekly: [QuotaReading]) {
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.weekly = weekly
    }
    public static let fiveHourWindow: TimeInterval = 5 * 3600
    public static let sevenDayWindow: TimeInterval = WeeklyQuotaEstimator.week
}

/// Reads only Lunlet's own status-line files. Each value is bounded and validated: percentages within 0...100,
/// Unix epoch seconds, a reset after its reading and within one window of it, and no reading from the future.
public struct ClaudePlanLimitsReader: Sendable {
    public let location: ClaudeStatusLineLocation
    private static let stateLimit = 4_096, logLimit = 1_048_576
    /// Clock differences between the status line and Lunlet.
    private static let skew: TimeInterval = 300

    public init(location: ClaudeStatusLineLocation = .standard) { self.location = location }

    /// Nil when the status line has never stored a reading.
    public func read(now: Date) throws -> ClaudePlanLimits? {
        var info = stat()
        if lstat(location.limits.path, &info) != 0, errno == ENOENT { return nil }
        let state = try ClaudeStatusLineConnection.readOwnedFile(location.limits, limit: Self.stateLimit)
        var lines = String(decoding: state, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "lunlet-claude-limits 1" else { throw ClaudeStatusLineFailure.storageUnavailable }
        lines.removeFirst()
        var fiveHour: LimitWindowReading?, sevenDay: LimitWindowReading?
        for line in lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { continue }
            let span: TimeInterval
            switch fields[0] {
            case "five_hour": span = ClaudePlanLimits.fiveHourWindow
            case "seven_day": span = ClaudePlanLimits.sevenDayWindow
            default: continue
            }
            let reading = Self.window(fields[1], fields[2], fields[3], span: span, now: now)
            if fields[0] == "five_hour" { fiveHour = reading } else { sevenDay = reading }
        }
        return .init(fiveHour: fiveHour, sevenDay: sevenDay, weekly: weeklyReadings(latest: sevenDay, now: now))
    }

    /// Logged readings within the estimator's input horizon plus the latest, at most one per instant. Within one
    /// window use never decreases, so a lower value after a higher one is an older response and is dropped.
    private func weeklyReadings(latest: LimitWindowReading?, now: Date) -> [QuotaReading] {
        var readings: [LimitWindowReading] = []
        if let data = try? ClaudeStatusLineConnection.readOwnedFile(location.weeklyLog, limit: Self.logLimit) {
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 3,
                      let reading = Self.window(fields[1], fields[2], fields[0], span: ClaudePlanLimits.sevenDayWindow, now: now)
                else { continue }
                readings.append(reading)
            }
        }
        if let latest { readings.append(latest) }
        let horizon = now.addingTimeInterval(-WeeklyQuotaEstimator.inputHorizon())
        var byInstant: [Date: LimitWindowReading] = [:]
        for reading in readings where reading.at >= horizon {
            if let existing = byInstant[reading.at], !Self.sameWindow(existing, reading) || existing.usedPercent >= reading.usedPercent {
                continue
            }
            byInstant[reading.at] = reading
        }
        var kept: [LimitWindowReading] = []
        for reading in byInstant.values.sorted(by: { $0.at < $1.at }) {
            if let earlier = kept.last(where: { Self.sameWindow($0, reading) }), reading.usedPercent < earlier.usedPercent { continue }
            // A window older than one already seen is an idle session replaying an earlier response.
            if let newest = kept.last, reading.resetsAt.timeIntervalSince(newest.resetsAt) < -WeeklyQuotaEstimator.resetTimeTolerance {
                continue
            }
            kept.append(reading)
        }
        return kept.map(\.remaining)
    }

    private static func sameWindow(_ a: LimitWindowReading, _ b: LimitWindowReading) -> Bool {
        abs(a.resetsAt.timeIntervalSince(b.resetsAt)) <= WeeklyQuotaEstimator.resetTimeTolerance
    }

    static func window(_ used: String, _ reset: String, _ at: String, span: TimeInterval, now: Date) -> LimitWindowReading? {
        guard let used = percent(used), let reset = seconds(reset), let at = seconds(at),
              at <= now.addingTimeInterval(skew), reset > at, reset.timeIntervalSince(at) <= span + skew else { return nil }
        return .init(usedPercent: used, resetsAt: reset, at: at)
    }
    private static func percent(_ text: String) -> Double? {
        guard text.range(of: #"^[0-9]{1,3}(\.[0-9]{1,6})?$"#, options: .regularExpression) != nil,
              let value = Double(text), value <= 100 else { return nil }
        return value
    }
    private static func seconds(_ text: String) -> Date? {
        guard text.range(of: #"^[1-9][0-9]{0,10}$"#, options: .regularExpression) != nil, let value = Double(text) else { return nil }
        return Date(timeIntervalSince1970: value)
    }
}
