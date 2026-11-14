// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.01, AC-04.03, AC-04.07, AC-04.08, AC-04.09, AC-04.15, AC-04.19; US-24, AC-24.02.
import AppKit
import SwiftUI
import Foundation
import LunletCodex
import Testing
@testable import LunletCore
@testable import LunletDesktop

@Suite struct AccountUsagePresentationTests {
    private func snapshot(_ json: String) throws -> AccountLimitsSnapshot {
        try AccountLimitsDecoder.decode(Data(json.utf8), observedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func weeklyWindowUsesDurationInEitherPositionAndIdentifiesItsBucket() throws {
        // AC-04.07: A five-hour primary window is never substituted for the weekly window.
        for slot in ["primary", "secondary"] {
            let other = slot == "primary" ? "secondary" : "primary"
            let value = try snapshot("""
            {"rateLimits":{"limitName":"Synthetic allowance","\(slot)":{"usedPercent":23,"windowDurationMins":10080,"resetsAt":1800000600},"\(other)":{"usedPercent":90,"windowDurationMins":300}}}
            """)
            let weekly = try #require(AccountUsagePresentation.weekly(in: value))
            #expect(weekly.bucketName == "Synthetic allowance")
            #expect(weekly.remainingPercent == 77)
            #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_800_000_600))
        }
    }

    @Test func fiveHourWindowIsIdentifiedByDurationAndItsLineStaysUnknownWithoutIt() throws {
        // AC-04.15: the five-hour window is found by its 300-minute duration in either position, never by position.
        var window: AllowanceWindow?, last: AccountLimitsSnapshot?
        for slot in ["primary", "secondary"] {
            let other = slot == "primary" ? "secondary" : "primary"
            let value = try snapshot("""
            {"rateLimits":{"limitName":"Synthetic allowance","\(slot)":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1800003600},"\(other)":{"usedPercent":23,"windowDurationMins":10080}}}
            """)
            window = try #require(AccountUsagePresentation.fiveHour(in: value)); last = value
            #expect(window?.remainingPercent == 60)
            #expect(window?.resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
            // The weekly window is untouched by the five-hour one (AC-04.07).
            #expect(AccountUsagePresentation.weekly(in: value)?.remainingPercent == 77)
        }
        let weeklyOnly = try snapshot(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":10080}}}"#)
        #expect(AccountUsagePresentation.fiveHour(in: weeklyOnly) == nil)
        // The line reads percent left and the reset in the shared wording (AC-04.01).
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let line = try #require(AccountUsagePresentation.fiveHourLine(in: last, now: now))
        #expect(line.left == "60% left" && line.reset == "Resets in 1h")
        // A successful read that reports no five-hour window leaves the line out: the account has none.
        #expect(AccountUsagePresentation.fiveHourLine(in: weeklyOnly, now: now) == nil)
        // Without any successful read the line stays unknown, as the weekly line does (AC-04.03).
        let unknown = try #require(AccountUsagePresentation.fiveHourLine(in: nil, now: now))
        #expect(unknown.left == "—" && unknown.reset == "Reset —")
        let due = try #require(AccountUsagePresentation.fiveHourLine(in: last, now: Date(timeIntervalSince1970: 1_800_003_601)))
        #expect(due.reset == "Reset due")
    }

    @Test func absentOrAmbiguousWeeklyWindowsStayUnavailable() throws {
        // AC-04.03, AC-04.07: No inferred week and no arbitrary bucket selection.
        let fixtures = [
            #"{}"#,
            #"{"rateLimits":{"secondary":{"usedPercent":25}}}"#,
            #"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}"#,
            #"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":10080},"secondary":{"usedPercent":50,"windowDurationMins":10080}}}"#,
            #"{"rateLimitsByLimitId":{"synthetic-a":{"primary":{"usedPercent":25,"windowDurationMins":10080}},"synthetic-b":{"secondary":{"usedPercent":50,"windowDurationMins":10080}}}}"#
        ]
        for fixture in fixtures {
            #expect(AccountUsagePresentation.weekly(in: try snapshot(fixture)) == nil)
        }
    }

    @Test func theDefaultCodexBucketIdentifiesTheWeeklyWindowAmongModelBuckets() throws {
        // AC-04.07: a model-specific weekly bucket does not hide the account's default Codex window.
        let value = try snapshot(#"{"rateLimitsByLimitId":{"codex":{"limitId":"codex","secondary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":1800000600}},"model-special":{"limitName":"Special model","secondary":{"usedPercent":80,"windowDurationMins":10080}}}}"#)
        let weekly = try #require(AccountUsagePresentation.weekly(in: value))
        #expect(weekly.bucketID == "codex" && weekly.remainingPercent == 70)
        let twoCodexWindows = try snapshot(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25,"windowDurationMins":10080},"secondary":{"usedPercent":50,"windowDurationMins":10080}},"model-special":{"secondary":{"usedPercent":80,"windowDurationMins":10080}}}}"#)
        #expect(AccountUsagePresentation.weekly(in: twoCodexWindows) == nil)
    }

    @Test func unknownWeeklyUsageStaysUnknown() throws {
        // AC-04.03, AC-04.07: The presentation preserves missing weekly usage and reset fields.
        let unknown = try snapshot(#"{"rateLimits":{"secondary":{"windowDurationMins":10080}}}"#)
        let unknownWeekly = try #require(AccountUsagePresentation.weekly(in: unknown))
        #expect(unknownWeekly.remainingPercent == nil)
        #expect(unknownWeekly.resetsAt == nil)
    }

    // Refs: US-04, AC-04.19. A window is named by how long it lasts, never by its position in the response.
    @Test func aSpanNamesItsWindowByItsLength() {
        let week = AllowanceSpan(minutes: 10_080)
        #expect(week == .week && week.name == "Week" && week.adjective == "weekly" && week.key == "weekly")
        for minutes in [40_320, 43_200, 44_640] {
            let month = AllowanceSpan(minutes: minutes)
            #expect(month.name == "Month" && month.adjective == "monthly" && month.key == "monthly", "\(minutes)")
        }
        let fortnight = AllowanceSpan(minutes: 20_160)
        #expect(fortnight.name == "14-day" && fortnight.adjective == "14-day" && fortnight.key == "minutes20160")
        #expect(AllowanceSpan(minutes: 1_440).name == "Day" && AllowanceSpan(minutes: 1_440).adjective == "daily")
        #expect(AllowanceSpan.fiveHour.name == "5-hour" && AllowanceSpan.fiveHour.adjective == "5-hour" && AllowanceSpan.fiveHour.key == "fiveHour")
        #expect(AllowanceSpan(minutes: 90).name == "90-minute")
        #expect(AllowanceSpan(minutes: 43_200).seconds == 30 * 86_400)
    }

    // Refs: US-04, AC-04.19, AC-04.03. A plan without a weekly window: one 30-day window, nothing else.
    @Test func theAccountsLimitIsItsWeeklyWindowOrElseItsLongestWindowOfADayOrMore() throws {
        let monthly = try snapshot("""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":0,"windowDurationMins":43200,"resetsAt":1800864000},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"25000.0000000000"},"planType":"free"}}
        """)
        let limit = try #require(AccountUsagePresentation.limit(in: monthly))
        #expect(limit.span == AllowanceSpan(minutes: 43_200) && limit.remainingPercent == 100)
        #expect(limit.resetsAt == Date(timeIntervalSince1970: 1_800_864_000) && limit.bucketID == "codex")
        // It is not a weekly window, and nothing pretends it is.
        #expect(AccountUsagePresentation.weekly(in: monthly) == nil)
        // A weekly window stays the limit beside a longer one, as it was before longer windows were read.
        let both = try snapshot(#"{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":43200},"secondary":{"usedPercent":23,"windowDurationMins":10080}}}"#)
        #expect(AccountUsagePresentation.limit(in: both)?.span == .week && AccountUsagePresentation.limit(in: both)?.remainingPercent == 77)
        // The five-hour window is never the limit, and a window shorter than a day is not one either.
        for short in [300, 600, 1_439] {
            let value = try snapshot(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":\#(short)}}}"#)
            #expect(AccountUsagePresentation.limit(in: value) == nil, "\(short)")
        }
        // The longest of several: a day beside a fortnight.
        let mixed = try snapshot(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":1440},"secondary":{"usedPercent":40,"windowDurationMins":20160}}}"#)
        #expect(AccountUsagePresentation.limit(in: mixed)?.span.minutes == 20_160 && AccountUsagePresentation.limit(in: mixed)?.remainingPercent == 60)
        // Among buckets, the default Codex bucket's; two equally long windows in one bucket are never chosen between.
        let buckets = try snapshot(#"{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":30,"windowDurationMins":43200}},"model-special":{"primary":{"usedPercent":80,"windowDurationMins":43200}}}}"#)
        #expect(AccountUsagePresentation.limit(in: buckets)?.bucketID == "codex" && AccountUsagePresentation.limit(in: buckets)?.remainingPercent == 70)
        let ambiguous = try snapshot(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":43200},"secondary":{"usedPercent":50,"windowDurationMins":43200}}}"#)
        #expect(AccountUsagePresentation.limit(in: ambiguous) == nil)
        #expect(AccountUsagePresentation.limit(in: try snapshot("{}")) == nil)
    }

    // Refs: US-04, AC-04.01. A weekday tells the day only within the coming week.
    @Test func aMomentMoreThanSixDaysAwayIsWrittenWithItsMonthAndDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 15, minute: 30))!
        func at(days: Int, hour: Int = 20, minute: Int = 53) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.date(byAdding: .day, value: days, to: now)!)!
        }
        func weekday(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        func dated(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) + " " + date.formatted(date: .omitted, time: .shortened) }
        #expect(ClaudeLimitsText.moment(at(days: 0), now: now, calendar: calendar) == at(days: 0).formatted(date: .omitted, time: .shortened))
        #expect(ClaudeLimitsText.moment(at(days: 1), now: now, calendar: calendar) == weekday(at(days: 1)))
        #expect(ClaudeLimitsText.moment(at(days: 6), now: now, calendar: calendar) == weekday(at(days: 6)))
        // The same weekday a week on would read as today's; a month on, a weekday says nothing.
        #expect(ClaudeLimitsText.moment(at(days: 7), now: now, calendar: calendar) == dated(at(days: 7)))
        #expect(ClaudeLimitsText.moment(at(days: 30), now: now, calendar: calendar) == dated(at(days: 30)))
        // The month and day are written as this Mac writes dates; the weekday is gone.
        #expect(dated(at(days: 30)) != weekday(at(days: 30)) && dated(at(days: 30)).contains("13"))
        // An earlier moment follows the same rule.
        #expect(ClaudeLimitsText.moment(at(days: -2), now: now, calendar: calendar) == weekday(at(days: -2)))
        #expect(ClaudeLimitsText.moment(at(days: -9), now: now, calendar: calendar) == dated(at(days: -9)))
        // The forecast's run-out times are written the same way.
        #expect(QuotaForecastText.day(at(days: 3), now: now, calendar: calendar) == weekday(at(days: 3)))
        #expect(QuotaForecastText.day(at(days: 12), now: now, calendar: calendar) == dated(at(days: 12)))
    }

    @Test func resetCountdownUsesHoursAndDoesNotPretendAnElapsedQuotaHasRenewed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AccountUsagePresentation.countdown(until: now.addingTimeInterval(6 * 86400 + 17 * 3600 + 59), now: now) == "6d 17h")
        #expect(AccountUsagePresentation.countdown(until: now.addingTimeInterval(3601), now: now) == "1h")
        #expect(AccountUsagePresentation.countdown(until: now.addingTimeInterval(60), now: now) == "<1h")
        #expect(AccountUsagePresentation.countdown(until: now, now: now) == nil)
        #expect(AccountUsagePresentation.countdown(until: now.addingTimeInterval(-3600), now: now) == nil)
    }

    @Test func resetCreditExpiryIsSortedDeduplicatedAndNeverGuessesMissingDates() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let value = try snapshot(#"{"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"later","status":"available","expiresAt":1800360000},{"id":"soon","status":"available","expiresAt":1800090000},{"id":"soon","status":"available","expiresAt":1800090000},{"id":"used","status":"used","expiresAt":1800000100}]}}"#)
        #expect(AccountUsagePresentation.resetExpiryLabels(value.earnedResets, now: now) == ["1d 1h", "4d 4h"])
        let partial = try snapshot(#"{"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"soon","status":"available","expiresAt":1800090000}]}}"#)
        #expect(AccountUsagePresentation.resetExpiryLabels(partial.earnedResets, now: now) == ["1d 1h", "—"])
        #expect(AccountUsagePresentation.resetExpiryLabels(nil, now: now).isEmpty)
        let empty = try snapshot(#"{"rateLimitResetCredits":{"availableCount":0}}"#)
        #expect(AccountUsagePresentation.resetExpiryLabels(empty.earnedResets, now: now).isEmpty)
        // Refs: US-24, AC-24.02. Assistive tools hear the count and the expiry the line shows, with unknown said as
        // a word, never dropped behind the group's label.
        #expect(AccountUsagePresentation.resetCreditsSpoken(value.earnedResets, now: now) == "2 available, expiring in 1d 1h, 4d 4h")
        #expect(AccountUsagePresentation.resetCreditsSpoken(partial.earnedResets, now: now) == "2 available, expiring in 1d 1h, unknown")
        #expect(AccountUsagePresentation.resetCreditsSpoken(empty.earnedResets, now: now) == "0 available")
        #expect(AccountUsagePresentation.resetCreditsSpoken(nil, now: now) == "unknown")
    }


    @Test func relativeAccountFreshnessUsesTheActualSuccessTimestampAndCompactCreditValues() {
        let updated = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AccountUsagePresentation.updatedLabel(at: updated, now: updated) == "Updated just now")
        #expect(AccountUsagePresentation.updatedLabel(at: updated, now: updated.addingTimeInterval(125)) == "Updated 2m ago")
        #expect(AccountUsagePresentation.updatedLabel(at: updated, now: updated.addingTimeInterval(7200)) == "Updated 2h ago")
        #expect(AccountUsagePresentation.updatedLabel(at: updated, now: updated.addingTimeInterval(-60)) == nil)
        #expect(AccountUsagePresentation.creditBalance("75000.000000000000") == "75,000")
        #expect(AccountUsagePresentation.creditBalance("12.3456") == "12.35")
        #expect(AccountUsagePresentation.creditBalance("0.00001") == "<0.01")
        #expect(AccountUsagePresentation.creditBalance("0") == "0")
        #expect(AccountUsagePresentation.creditBalance("unknown") == "—")
    }

}

// Refs: US-04, AC-04.01, AC-04.03, AC-04.09; US-03, AC-03.09.
private actor SyntheticAccountCardReader: CodexAccountReading {
    let snapshot: AccountLimitsSnapshot
    init(snapshot: AccountLimitsSnapshot) { self.snapshot = snapshot }
    func readLimits() async throws -> AccountLimitsSnapshot { snapshot }
}
@MainActor private final class LayoutCueSink: TaskCuePresenting {
    func show(_ cues: [TaskCue]) {}
    func hide() {}
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_PANEL"] == "1"))
@MainActor func theCodexPageTopFitsItsBudgetAboveThreeCompleteSessionCards() async throws {
    _ = NSApplication.shared
    let now = Date(), epoch = Int(now.timeIntervalSince1970)
    let snapshot = try AccountLimitsDecoder.decode(Data("""
    {"rateLimits":{"secondary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":\(epoch + 6*86400 + 17*3600)},"credits":{"balance":"75000.000000000000","hasCredits":true,"unlimited":false}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"synthetic-a","status":"available","expiresAt":\(epoch + 3*86400 + 4*3600)},{"id":"synthetic-b","status":"available","expiresAt":\(epoch + 11*86400 + 8*3600)}]}}
    """.utf8), observedAt: now.addingTimeInterval(-120), accountData: Data(#"{"account":{"type":"chatgpt","email":"synthetic@example.invalid","planType":"pro"}}"#.utf8))
    let model = AccountUsageModel(client: SyntheticAccountCardReader(snapshot: snapshot))
    model.start()
    let deadline = ContinuousClock.now + .seconds(60)
    while model.state == .loading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.displayedSnapshot == snapshot)
    let hover = UsageHoverPanelController()
    let history = LocalUsageModel()
    let top = PanelStyle.Layout.summaryCard(lines: 2)
    let hosting = NSHostingView(rootView: AccountUsageSummary(model: model, history: history, hoverPanel: hover)
        .frame(width: 446).background(Color(red: 0.13, green: 0.13, blue: 0.14)).environment(\.colorScheme, .dark))
    hosting.frame = .init(x: 0, y: 0, width: 446, height: top)
    hosting.layoutSubtreeIfNeeded()
    // The account line and the figures row hold their budget (AC-04.17).
    #expect(hosting.fittingSize.height <= top + 0.5, "top \(hosting.fittingSize.height) of \(top)")
    let sessions = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: LayoutCueSink())
    for index in 0..<3 {
        let session = SessionSnapshot(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive, phase: .running),
                                      project: "Synthetic project", title: "Session \(index)", turnID: "turn-\(index)")
        sessions.receive(session, origin: .snapshot)
    }
    let content = NSHostingView(rootView: VStack(alignment: .leading, spacing: PanelStyle.Grid.margin) {
        AccountUsageSummary(model: model, history: history, hoverPanel: hover)
        SessionPanel(model: sessions, usage: history)
    }.frame(width: 446).fixedSize(horizontal: false, vertical: true)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14)).environment(\.colorScheme, .dark))
    content.frame = .init(x: 0, y: 0, width: 446, height: 300)
    content.layoutSubtreeIfNeeded()
    // The page between the header and footer below a 32-point notch.
    let available = PanelStyle.Layout.pageHeight
    // Exactly three whole cards: the page ends with the third, with no sliver of a fourth.
    #expect(content.fittingSize.height <= available + 0.5, "content \(content.fittingSize.height) of \(available)")
    if ProcessInfo.processInfo.environment["LUNLET_TEST_RENDER_SUMMARY"] == "1",
       let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".tmp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("codex-summary-preview.png"))
        if let layout = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: layout)
            try layout.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("codex-layout-preview.png"))
        }
    }
    hover.shutdown()
    sessions.shutdown()
    await history.shutdown()
    await model.shutdown()
}
