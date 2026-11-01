// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.01, AC-32.02, AC-32.03, AC-32.07.
// Refs: US-04, AC-04.11; US-02, AC-02.08.
// Refs: US-18, AC-18.01, AC-18.02, AC-18.03.
// Refs: US-04, AC-04.02, AC-04.03, AC-04.05, AC-04.08; US-12, AC-12.04.
import Foundation
import Testing
import LunletCore
@testable import LunletCodex

@Suite struct LocalUsageHistoryTests {
    private let session = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-usage-test-\(UUID())")
        try FileManager.default.createDirectory(at: value.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        return value
    }
    private func record(_ type: String, _ payload: [String: Any], at: String = "2026-10-26T12:00:00Z") throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["timestamp": at, "type": type, "payload": payload]), as: UTF8.self)
    }
    private func usage(_ input: Int, _ output: Int, cached: Int = 0, write: Int = 0) -> [String: Int] {
        ["input_tokens": input, "output_tokens": output, "cached_input_tokens": cached,
         "cache_write_input_tokens": write, "reasoning_output_tokens": output / 2, "total_tokens": input + output]
    }
    private func header(_ model: String = "gpt-6.1-sol") throws -> [String] {
        [try record("session_meta", ["id": session.uuidString]), try record("turn_context", ["model": model])]
    }
    private func sample(_ total: [String: Int], last: [String: Int]? = nil, at: String = "2026-10-26T12:00:00Z") throws -> String {
        try record("event_msg", ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": last ?? total]], at: at)
    }
    private func write(_ lines: [String], to root: URL, name: String = "sessions/a.jsonl") throws {
        let target = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: target, atomically: true, encoding: .utf8)
    }

    @Test func weeklyQuotaHistoryReadsRecordedPercentEvenWithoutTokenInfo() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reset = date("2026-10-30T12:00:00Z").timeIntervalSince1970
        let rate: [String: Any] = ["limit_id": "codex", "plan_type": "pro", "secondary": ["used_percent": 23.0, "window_minutes": 10080, "resets_at": reset]]
        let quota = try record("event_msg", ["type": "token_count", "info": NSNull(), "rate_limits": rate], at: "2026-10-26T12:00:00Z")
        try write(try header() + [quota], to: directory)
        let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.quotaHistory.count == 1)
        #expect(result.quotaHistory.first?.remaining == 77)
        #expect(result.quotaHistory.first?.resetAt == date("2026-10-30T12:00:00Z"))
    }

    @Test func quotaLookbackIgnoresTheDisplayedRangeAndCollapsesIdenticalRuns() async throws {
        // AC-32.02, AC-32.07: forecast inputs cover seven days plus the guard's comparison day, whatever range
        // is displayed; interior copies of identical readings carry no pace evidence.
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        func quota(_ at: String, used: Double, reset: String) throws -> String {
            let window: [String: Any] = ["used_percent": used, "window_minutes": 10080, "resets_at": date(reset).timeIntervalSince1970]
            let rate: [String: Any] = ["limit_id": "codex", "plan_type": "pro", "secondary": window]
            return try record("event_msg", ["type": "token_count", "info": NSNull(), "rate_limits": rate], at: at)
        }
        let lines = try header() + [
            quota("2026-10-17T12:00:00Z", used: 90, reset: "2026-10-20T12:00:00Z"),
            quota("2026-10-19T12:00:00Z", used: 10, reset: "2026-10-23T12:00:00Z"),
            quota("2026-10-25T09:00:00Z", used: 40, reset: "2026-10-30T12:00:00Z"),
            quota("2026-10-25T10:00:00Z", used: 40, reset: "2026-10-30T12:00:00Z"),
            quota("2026-10-25T11:00:00Z", used: 40, reset: "2026-10-30T12:00:00Z"),
            quota("2026-10-25T12:00:00Z", used: 41, reset: "2026-10-30T12:00:00Z"),
            quota("2026-10-26T18:00:00Z", used: 41, reset: "2026-10-30T12:00:00Z")
        ]
        try write(lines, to: directory)
        let reader = CodexLocalUsageReader(home: directory)
        let now = date("2026-10-26T20:00:00Z")
        let oneDay = try await reader.readHistory(now: now, calendar: calendar, days: 1)
        #expect(oneDay.quotaHistory == (try await reader.readHistory(now: now, calendar: calendar, days: 7)).quotaHistory)
        // The 2026-10-17 reading is outside eight days; 10:00 is an interior copy; the 2026-10-26 copy of the
        // 12:00 value is another local day and keeps that day's last reading.
        #expect(oneDay.quotaHistory.map(\.at) == ["2026-10-19T12:00:00Z", "2026-10-25T09:00:00Z", "2026-10-25T11:00:00Z",
                                                  "2026-10-25T12:00:00Z", "2026-10-26T18:00:00Z"].map(date))
    }

    @Test func accountingCatalogDeduplicatesRootsAndKeepsOverflowExplicit() {
        let catalog = CodexAccountingCatalog()
        func file(_ index: Int) -> CodexRolloutFile {
            .init(url: URL(fileURLWithPath: "/synthetic/root-\(index)/sessions/record.jsonl"), device: 1, inode: UInt64(index))
        }
        catalog.record([file(0), file(0)])
        #expect(catalog.snapshot().homes.count == 1 && catalog.snapshot().complete)
        catalog.record((1..<32).map(file))
        #expect(catalog.snapshot().homes.count == 32 && catalog.snapshot().complete)
        catalog.record([file(32)])
        #expect(catalog.snapshot().homes.count == 32 && !catalog.snapshot().complete)
        catalog.record([])
        #expect(!catalog.snapshot().complete)
    }

    @Test func allClientSourcesAndRootsShareDeduplicatedAccounting() async throws {
        let primary = try root(), desktop = try root()
        defer { try? FileManager.default.removeItem(at: primary); try? FileManager.default.removeItem(at: desktop) }
        let total = usage(100, 10)
        let clientSources: [Any] = ["cli", "vscode", "appServer", "exec", "unknown", "future-source",
                                    ["subagent": ["thread_spawn": [:]]]]
        for (index, source) in clientSources.enumerated() {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            let lines = try [record("session_meta", ["id": id.uuidString, "source": source, "originator": "Codex Desktop"]),
                             record("turn_context", ["model": "gpt-6.1-sol"]), sample(total)]
            try write(lines, to: index == 0 ? primary : desktop, name: "sessions/source-\(index).jsonl")
            try write(lines, to: primary, name: "archived_sessions/copy-\(index).jsonl")
        }
        let marker = desktop.appendingPathComponent("discovered")
        try Data().write(to: marker)
        let reader = CodexLocalUsageReader(home: primary, limits: .init(), additionalHomes: {
            .init(homes: [primary] + (FileManager.default.fileExists(atPath: marker.path) ? [desktop, desktop] : []))
        })
        let result = try await reader.readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.sessions.count == clientSources.count && !result.partial)
        #expect(result.days.last?.amount.tokens == 770)
        #expect(abs(try #require(result.days.last?.amount.estimatedUSD) - 0.0021) < 0.000001)
        // Remember a discovered accounting root after its process exits.
        try FileManager.default.removeItem(at: marker)
        // A newly appended Desktop event must be read even if an archived copy is unchanged.
        try write(try [record("session_meta", ["id": session.uuidString, "source": "appServer"]),
                       record("turn_context", ["model": "gpt-6.1-sol"]), sample(total),
                       sample(usage(200, 20), last: total, at: "2026-10-26T13:00:00Z")],
                  to: desktop, name: "sessions/continued.jsonl")
        let refreshed = try await reader.readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(refreshed.sessions[session]?.tokens == 220)
        #expect(refreshed.days.last?.amount.tokens == 880)
    }

    @Test func incompleteDiscoveryStillAccountsForNewReadableRoots() async throws {
        let primary = try root(), desktop = try root()
        defer { try? FileManager.default.removeItem(at: primary); try? FileManager.default.removeItem(at: desktop) }
        try write(try header() + [sample(usage(100, 10))], to: desktop)
        let reader = CodexLocalUsageReader(home: primary, limits: .init(), additionalHomes: { .init(homes: [desktop], complete: false) })
        let result = try await reader.readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.partial && result.sessions[session]?.tokens == 110)
    }

    @Test func discoveredRootFailuresPreserveKnownUsageButMarkCoveragePartial() async throws {
        let primary = try root()
        defer { try? FileManager.default.removeItem(at: primary) }
        try write(try header() + [sample(usage(100, 10))], to: primary)
        let reader = CodexLocalUsageReader(home: primary, limits: .init(), additionalHomes: { throw LocalUsageReadFailure.unavailable })
        let result = try await reader.readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.partial && result.days.last?.amount.tokens == 110)
    }

    @Test func cumulativeSnapshotsAreDeduplicatedAcrossArchivesAndPricedByEventModel() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = usage(1_000_000, 100_000, cached: 200_000)
        let second = usage(1_100_000, 150_000, cached: 220_000)
        var lines = try header()
        lines += [try sample(first, at: "2026-10-25T12:00:00Z"), try sample(first, at: "2026-10-25T13:00:00Z")]
        lines += [try record("turn_context", ["model": "gpt-6-astra"]), try sample(second, last: usage(100_000, 50_000, cached: 20_000))]
        try write(lines, to: directory)
        try write(lines, to: directory, name: "archived_sessions/copy.jsonl")
        let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.days.count == 5)
        #expect(result.days.suffix(2).map(\.amount.tokens) == [1_100_000, 150_000])
        #expect(result.days.prefix(3).allSatisfy { $0.amount.tokens == nil })
        #expect(result.sessions[session]?.tokens == 1_250_000)
        #expect(abs(try #require(result.sessions[session]?.estimatedUSD) - 5.94) < 0.000001)
        #expect(!result.partial)
    }

    @Test func missingPricesCacheWritesAndMissingUsageRemainUnknown() async throws {
        for (model, writeCount) in [("unknown-model", 0), ("gpt-6.1-sol", 1)] {
            let directory = try root()
            defer { try? FileManager.default.removeItem(at: directory) }
            try write(try header(model) + [sample(usage(100, 10, write: writeCount))], to: directory)
            let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
            #expect(result.sessions[session]?.tokens == 110)
            #expect(result.sessions[session]?.estimatedUSD == nil)
        }
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(try header() + [record("event_msg", ["type": "token_count", "info": NSNull(), "rate_limits": [:]])], to: directory)
        let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.sessions[session]?.tokens == nil)
        #expect(result.days.allSatisfy { $0.amount.tokens == nil })
    }

    @Test func truncatedBeginningCannotAssignLifetimeUsageToOneDay() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(try header() + [sample(usage(1000, 100), last: usage(10, 1))], to: directory)
        let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.sessions[session]?.tokens == 1100)
        #expect(abs(try #require(result.sessions[session]?.estimatedUSD) - 0.00003) < 0.000000001)
        #expect(result.sessions[session]?.pricedTokens == 11)
        #expect(result.sessions[session]?.unpricedTokens == 0)
        #expect(result.sessions[session]?.costPartial == true)
        #expect(result.days.last?.amount.tokens == 11)
        #expect(result.partial)
    }

    @Test func dayBucketsUseCalendarDatesAcrossDaylightSaving() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(try header() + [sample(usage(10, 1), at: "2026-11-01T08:30:00Z"), sample(usage(20, 2), last: usage(10, 1), at: "2026-11-01T09:30:00Z")], to: directory)
        let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-11-02T20:00:00Z"), calendar: calendar)
        #expect(result.days[3].amount.tokens == 22)
        #expect(result.days[4].date.timeIntervalSince(result.days[3].date) == 25 * 3600)
        #expect(result.days[4].amount.tokens == nil)
    }

    @Test func malformedCategoriesRegressionsAndOversizedLinesArePartial() async throws {
        for bad in [try sample(["total_tokens": 100]), "{broken", String(repeating: "x", count: 3000)] {
            let directory = try root()
            defer { try? FileManager.default.removeItem(at: directory) }
            try write(try header() + [sample(usage(100, 10)), bad], to: directory)
            let reader = CodexLocalUsageReader(home: directory, limits: .init(maxLineBytes: 2048))
            let result = try await reader.readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
            #expect(result.partial)
        }
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(try header() + [sample(usage(100, 10)), sample(usage(10, 1), at: "2026-10-26T13:00:00Z")], to: directory)
        let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.sessions[session]?.tokens == nil)
        #expect(result.partial)
    }

    @Test func refreshReadsAppendsAndBudgetLimitsDoNotReportZero() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var lines = try header() + [sample(usage(100, 10))]
        try write(lines, to: directory)
        let reader = CodexLocalUsageReader(home: directory)
        let first = try await reader.readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(try await reader.readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar) == first)
        lines += [try sample(usage(200, 20), at: "2026-10-26T13:00:00Z")]
        try write(lines, to: directory)
        let next = try await reader.readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(next.sessions[session]?.tokens == 220)
        let bounded = try await CodexLocalUsageReader(home: directory, limits: .init(maxBytes: 1)).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(bounded.partial)
        #expect(bounded.days.allSatisfy { $0.amount.tokens == nil })
    }

    private func append(_ text: String, to root: URL, name: String = "sessions/a.jsonl") throws {
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent(name))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func appendedRolloutsResumeAfterTheirLastCompleteLine() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(try header() + [sample(usage(100, 10))], to: directory)
        let initial = try #require(try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("sessions/a.jsonl").path)[.size] as? Int)
        let next = try sample(usage(200, 20), last: usage(100, 10), at: "2026-10-26T13:00:00Z") + "\n"
        #expect(next.utf8.count < initial)
        // The byte budget admits each increment, plus one byte to observe the end, but not a full reread.
        let reader = CodexLocalUsageReader(home: directory, limits: .init(maxBytes: initial + 1))
        let now = date("2026-10-26T20:00:00Z")
        let first = try await reader.readHistory(now: now, calendar: calendar)
        #expect(first.sessions[session]?.tokens == 110 && !first.partial)
        // A line still being written is incomplete now and is read again once terminated.
        let split = next.index(next.startIndex, offsetBy: next.utf8.count / 2)
        try append(String(next[..<split]), to: directory)
        let writing = try await reader.readHistory(now: now, calendar: calendar)
        #expect(writing.partial && writing.sessions[session]?.tokens == 110)
        try append(String(next[split...]), to: directory)
        let resumed = try await reader.readHistory(now: now, calendar: calendar)
        #expect(resumed.sessions[session]?.tokens == 220 && !resumed.partial)
        #expect(resumed.days.last?.amount.tokens == 220)
        let fresh = try await CodexLocalUsageReader(home: directory, limits: .init(maxBytes: initial + 1)).readHistory(now: now, calendar: calendar)
        #expect(fresh.partial)
    }

    @Test func rewrittenRolloutWithTheSameIdentityIsReadFromTheStart() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(try header() + [sample(usage(100, 10))], to: directory)
        let reader = CodexLocalUsageReader(home: directory)
        let now = date("2026-10-26T20:00:00Z")
        #expect(try await reader.readHistory(now: now, calendar: calendar).sessions[session]?.tokens == 110)
        // Rewrite in place, so the file keeps its identity but its earlier bytes change.
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("sessions/a.jsonl"))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((try header() + [sample(usage(1_000_000, 100_000)), sample(usage(1_000_001, 100_001))])
            .joined(separator: "\n").appending("\n").utf8))
        try handle.close()
        let rewritten = try await reader.readHistory(now: now, calendar: calendar)
        #expect(rewritten.sessions[session]?.tokens == 1_100_002 && !rewritten.partial)
    }

    @Test func deletedDiscoveredRootsStopLimitingCoverageButInaccessibleOnesDoNot() async throws {
        let primary = try root(), discovered = try root(), blocked = try root()
        defer { for url in [primary, discovered, blocked] { try? FileManager.default.removeItem(at: url) } }
        try write(try header() + [sample(usage(100, 10))], to: primary)
        let catalog = CodexAccountingCatalog()
        catalog.record([.init(url: discovered.appendingPathComponent("sessions/record.jsonl"), device: 1, inode: 1)])
        let reader = CodexLocalUsageReader(home: primary, limits: .init(), accounting: catalog)
        let now = date("2026-10-26T20:00:00Z")
        #expect(try await !reader.readHistory(now: now, calendar: calendar).partial)
        try FileManager.default.removeItem(at: discovered)
        let afterDeletion = try await reader.readHistory(now: now, calendar: calendar)
        #expect(!afterDeletion.partial && afterDeletion.days.last?.amount.tokens == 110)
        #expect(catalog.snapshot().homes.isEmpty && catalog.snapshot().complete)

        // A root replaced by another file type, or one behind an unsearchable parent, is not treated as deleted.
        let replaced = blocked.appendingPathComponent("replaced")
        try FileManager.default.createDirectory(at: replaced.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let hidden = blocked.appendingPathComponent("parent/hidden")
        try FileManager.default.createDirectory(at: hidden.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        catalog.record([.init(url: replaced.appendingPathComponent("sessions/record.jsonl"), device: 1, inode: 2),
                        .init(url: hidden.appendingPathComponent("sessions/record.jsonl"), device: 1, inode: 3)])
        #expect(try await !reader.readHistory(now: now, calendar: calendar).partial)
        try FileManager.default.removeItem(at: replaced)
        try Data().write(to: replaced)
        let parent = blocked.appendingPathComponent("parent")
        #expect(chmod(parent.path, 0) == 0)
        defer { chmod(parent.path, 0o700) }
        let limited = try await reader.readHistory(now: now, calendar: calendar)
        #expect(limited.partial && limited.days.last?.amount.tokens == 110)
        #expect(catalog.snapshot().homes.count == 2)
    }

    @Test func defaultDiscoveryReusesTheMonitorCatalogOnceItHasRecordedAScan() throws {
        let standard = try root(), discovered = try root()
        defer { try? FileManager.default.removeItem(at: standard); try? FileManager.default.removeItem(at: discovered) }
        let catalog = CodexAccountingCatalog()
        var scans = 0
        let scan: () throws -> CodexUsageRoots = { scans += 1; return .init(homes: [discovered], complete: false) }
        for accounting in [nil, catalog] {
            let roots = try CodexLocalUsageReader.defaultAdditionalHomes(accounting: accounting, standard: standard, scanProcesses: scan)
            #expect(roots.homes == [standard, discovered] && !roots.complete)
        }
        #expect(scans == 2)
        catalog.record([])
        let reused = try CodexLocalUsageReader.defaultAdditionalHomes(accounting: catalog, standard: standard, scanProcesses: scan)
        #expect(scans == 2 && reused.homes == [standard] && reused.complete)
        let absent = try CodexLocalUsageReader.defaultAdditionalHomes(
            accounting: catalog, standard: standard.appendingPathComponent("absent"), scanProcesses: scan)
        #expect(absent.homes.isEmpty)
    }

    @Test func cancellationAndUnavailableRootDoNotProduceSuccessfulEmptyHistory() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CodexLocalUsageReader(home: directory).readHistory(now: Date(), calendar: calendar)
        }
        do { _ = try await task.value; Issue.record("Cancelled read succeeded") }
        catch { #expect(error is CancellationError) }
        do {
            _ = try await CodexLocalUsageReader(home: directory.appendingPathComponent("missing")).readHistory(now: Date(), calendar: calendar)
            Issue.record("Missing root succeeded")
        } catch { #expect(error is LocalUsageReadFailure) }
    }
    @Test func missingCacheWritePriceAndUnboundRecordsStayUnavailable() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var counts = usage(100, 10)
        counts.removeValue(forKey: "cache_write_input_tokens")
        try write(try header() + [sample(counts)], to: directory)
        let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.sessions[session]?.tokens == 110)
        #expect(result.sessions[session]?.estimatedUSD == nil)
        try write([try sample(usage(20, 2))], to: directory)
        let unbound = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(unbound.sessions.isEmpty)
        #expect(unbound.partial)
        #expect(unbound.days.allSatisfy { $0.amount.tokens == nil })
    }

    @Test func olderBaselineDoesNotBecomeCurrentDayUsage() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(try header() + [sample(usage(100, 10), at: "2026-10-01T12:00:00Z"),
            sample(usage(200, 20), last: usage(100, 10))], to: directory)
        let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.days.last?.amount.tokens == 110)
        #expect(result.sessions[session]?.tokens == 220)
        #expect(!result.partial)
    }

    @Test func malformedInfoAndConflictingSessionIdentityCannotClaimCompleteUsage() async throws {
        for bad in [try record("event_msg", ["type": "token_count", "info": "invalid"]),
                    try record("session_meta", ["id": UUID().uuidString])] {
            let directory = try root()
            defer { try? FileManager.default.removeItem(at: directory) }
            try write(try header() + [sample(usage(100, 10)), bad, sample(usage(200, 20))], to: directory)
            let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
            #expect(result.partial)
            // A malformed usage record preserves only a clearly partial known subtotal;
            // an identity conflict removes the entire session rather than reassigning it.
            if let amount = result.sessions[session] {
                #expect(amount.estimatedUSD != nil)
                #expect(amount.costPartial)
            }
        }
    }

    @Test func fileAndSampleBudgetsRemainExplicitAndSymlinksAreNotFollowed() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(try header() + [sample(usage(100, 10))], to: directory)
        try write(try header() + [sample(usage(200, 20))], to: directory, name: "sessions/b.jsonl")
        let bounded = try await CodexLocalUsageReader(home: directory, limits: .init(maxFiles: 1)).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(bounded.partial)
        #expect(bounded.sessions.values.allSatisfy { $0.partial })
        let sampleBounded = try await CodexLocalUsageReader(home: directory, limits: .init(maxSamples: 1)).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(sampleBounded.partial)
        let external = try root()
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(at: external.appendingPathComponent("sessions/link.jsonl"), withDestinationURL: directory.appendingPathComponent("sessions/a.jsonl"))
        let linked = try await CodexLocalUsageReader(home: external).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(linked.sessions.isEmpty)
    }

    @Test func completeFinalLineWithoutNewlineRemainsReadable() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lines = try header() + [sample(usage(10, 1))]
        try lines.joined(separator: "\n").write(to: directory.appendingPathComponent("sessions/a.jsonl"), atomically: true, encoding: .utf8)
        let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.sessions[session]?.tokens == 11)
        #expect(!result.partial)
    }

    @Test func conflictingDuplicatePricesCannotSelectAnArbitraryModel() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(try header("gpt-6.1-sol") + [sample(usage(100, 10))], to: directory)
        try write(try header("gpt-6-astra") + [sample(usage(100, 10))], to: directory, name: "archived_sessions/copy.jsonl")
        let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.sessions[session]?.tokens == 110)
        #expect(result.sessions[session]?.estimatedUSD == nil)
        #expect(result.days.last?.amount.estimatedUSD == nil)
        #expect(result.partial)
    }

    // AC-04.02, AC-04.03, AC-04.08: unknown prices exclude only their own tokens from estimates.
    @Test func fiveDaysRetainKnownSubtotalWhenEveryDayAlsoHasUnpricedUsage() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var lines = try header()
        for day in 22...26 {
            let offset = (day - 22) * 2
            lines += [try record("turn_context", ["model": "gpt-6.1-sol"]),
                      try sample(usage((offset + 1) * 100, (offset + 1) * 10), last: usage(100, 10), at: "2026-10-\(day)T12:00:00Z"),
                      try record("turn_context", ["model": "codex-auto-review"]),
                      try sample(usage((offset + 2) * 100, (offset + 2) * 10), last: usage(100, 10), at: "2026-10-\(day)T13:00:00Z")]
        }
        try write(lines, to: directory)
        try write(lines, to: directory, name: "archived_sessions/copy.jsonl")
        let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.days.map(\.amount.tokens) == Array(repeating: 220, count: 5))
        for day in result.days {
            #expect(abs(try #require(day.amount.estimatedUSD) - 0.0003) < 0.000000001)
            #expect(!day.amount.partial)
            #expect(day.amount.pricedTokens == 110)
            #expect(day.amount.unpricedTokens == 110)
            #expect(day.amount.costPartial)
        }
        #expect(result.sessions[session]?.pricedTokens == 550)
        #expect(result.sessions[session]?.unpricedTokens == 550)
        #expect(result.sessions[session]?.costPartial == true)
        #expect(result.sessions[session]?.tokens == 1100)
        #expect(abs(try #require(result.sessions[session]?.estimatedUSD) - 0.0015) < 0.000000001)
        #expect(!result.partial)
    }

    // AC-04.03: no priced usage is unknown rather than a zero-dollar estimate.
    @Test func entirelyUnpricedDaysAndSessionsRemainUnavailable() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(try header("gpt-5.6-luna") + [sample(usage(100, 10))], to: directory)
        let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.days.last?.amount.tokens == 110)
        #expect(result.days.last?.amount.estimatedUSD == nil)
        #expect(result.days.last?.amount.pricedTokens == 0)
        #expect(result.days.last?.amount.unpricedTokens == 110)
        #expect(result.sessions[session]?.estimatedUSD == nil)
        #expect(!result.partial)
    }

    // AC-04.03, AC-04.08: regression boundaries must never produce a claimed subtotal.
    @Test func mixedPricesDoNotBypassCounterRegressionSafety() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(try header() + [sample(usage(100, 10)),
            record("turn_context", ["model": "codex-auto-review"]),
            sample(usage(10, 1), at: "2026-10-26T13:00:00Z")], to: directory)
        let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.days.last?.amount.tokens == nil)
        #expect(result.days.last?.amount.estimatedUSD == nil)
        #expect(result.sessions[session]?.estimatedUSD == nil)
        #expect(result.partial)
    }

    // AC-04.03, AC-04.08: independent sessions cannot overflow a daily count or invent cost.
    @Test func overflowAcrossSessionsInvalidatesTheBucketInsteadOfRetainingASubtotal() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counts = usage(Int.max / 2 + 1, 0)
        try write(try header() + [sample(counts)], to: directory)
        try write([try record("session_meta", ["id": "00000000-0000-0000-0000-000000000002"]),
            record("turn_context", ["model": "gpt-6.1-sol"]), sample(counts)], to: directory, name: "sessions/b.jsonl")
        let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        #expect(result.days.last?.amount.tokens == nil)
        #expect(result.days.last?.amount.estimatedUSD == nil)
        #expect(result.days.last?.amount.partial == true)
    }

    // AC-04.02, AC-04.03: unknown prices and missing cache-write categories remain unpriced.
    @Test func laterKnownUsageRetainsSubtotalWithoutPricingEarlierUnknownCategories() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var missingWrite = usage(100, 10)
        missingWrite.removeValue(forKey: "cache_write_input_tokens")
        try write(try header() + [sample(missingWrite),
            sample(usage(200, 20), at: "2026-10-26T13:00:00Z"),
            sample(usage(300, 30), at: "2026-10-26T14:00:00Z")], to: directory)
        let result = try await CodexLocalUsageReader(home: directory).readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar)
        let amount = try #require(result.days.last?.amount)
        #expect(amount.tokens == 330)
        #expect(amount.pricedTokens == 110)
        #expect(amount.unpricedTokens == 220)
        #expect(abs(try #require(amount.estimatedUSD) - 0.0003) < 0.000000001)
        #expect(amount.costPartial && !amount.partial)
    }

    @Test func selectedDayRangeUsesOneThroughSevenLocalCalendarDaysWithoutChangingSessionTotals() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(try header() + [sample(usage(100, 10))], to: directory)
        let reader = CodexLocalUsageReader(home: directory)
        for count in 1...7 {
            let history = try await reader.readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar, days: count)
            #expect(history.days.count == count)
            #expect(history.days.last?.date == calendar.startOfDay(for: date("2026-10-26T20:00:00Z")))
            #expect(history.days.last?.amount.tokens == 110)
            #expect(history.sessions[session]?.tokens == 110)
        }
        for invalid in [0, 8] {
            await #expect(throws: (any Error).self) {
                try await reader.readHistory(now: date("2026-10-26T20:00:00Z"), calendar: calendar, days: invalid)
            }
        }
    }

}
