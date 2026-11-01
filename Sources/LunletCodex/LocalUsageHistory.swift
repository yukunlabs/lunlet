// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-32, AC-32.01, AC-32.02, AC-32.03, AC-32.04, AC-32.07.
// Refs: US-04, AC-04.11; US-25, AC-25.01.
// Refs: US-18, AC-18.01, AC-18.02, AC-18.03.
// Refs: US-04, AC-04.02, AC-04.03, AC-04.05, AC-04.08; US-12, AC-12.04.
import Foundation
import LunletCore

/// Bounds the initial scan as well as refreshes. Complete, unchanged files are cached;
/// appended files resume after their last complete line.
struct LocalUsageReadLimits: Sendable {
    var maxBytes: Int = 1_073_741_824
    var maxLineBytes: Int = 2_097_152
    var maxFiles: Int = 10_000
    var maxDirectoryEntries: Int = 30_000
    var maxSamples: Int = 200_000
    var maxSeconds: Double = 30
}

public actor CodexLocalUsageReader: LocalUsageReading {
    /// Bounded scans read files synchronously, so they stay off the shared cooperative pool.
    private nonisolated let executor = DispatchSerialQueue(label: "com.lunlet.codex.usage", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let accounting: CodexAccountingCatalog?
    private let home: URL
    private let limits: LocalUsageReadLimits
    private let additionalHomes: @Sendable () throws -> CodexUsageRoots
    private var knownHomes: Set<URL> = []
    private var cache: [URL: CachedUsageFile] = [:]

    public init(home: URL? = nil, accounting: CodexAccountingCatalog? = nil) {
        self.accounting = accounting
        self.home = home ?? Self.defaultHome()
        self.limits = .init()
        if home == nil {
            self.additionalHomes = {
                let standard = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
                return try Self.defaultAdditionalHomes(accounting: accounting, standard: standard) {
                    let scan = try CodexProcessReader().scan()
                    return .init(homes: scan.candidates.flatMap(\.files).compactMap { CodexProcessReader.accountingRoot(for: $0.url) },
                                 complete: scan.complete)
                }
            }
        } else { self.additionalHomes = { .init(homes: []) } }
    }

    /// The session monitor records the roots of every scan in the shared catalog. Once it
    /// has, a usage refresh reuses that record instead of scanning all processes again.
    static func defaultAdditionalHomes(accounting: CodexAccountingCatalog?, standard: URL,
                                       scanProcesses: () throws -> CodexUsageRoots) throws -> CodexUsageRoots {
        let standardHomes = FileManager.default.fileExists(atPath: standard.path) ? [standard] : []
        if accounting?.hasRecordedScan == true { return .init(homes: standardHomes) }
        let scanned = try scanProcesses()
        return .init(homes: standardHomes + scanned.homes, complete: scanned.complete)
    }

    init(home: URL, limits: LocalUsageReadLimits, additionalHomes: @escaping @Sendable () throws -> CodexUsageRoots = { .init(homes: []) }, accounting: CodexAccountingCatalog? = nil) {
        self.accounting = accounting
        self.home = home; self.limits = limits; self.additionalHomes = additionalHomes
    }

    private static func defaultHome() -> URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public func readHistory(now: Date, calendar: Calendar, days: Int) async throws -> LocalUsageHistory {
        guard (1...7).contains(days) else { throw LocalUsageReadFailure.invalidRange }
        return try scan(now: now, calendar: calendar, dayCount: days)
    }

    private func scan(now: Date, calendar: Calendar, dayCount: Int) throws -> LocalUsageHistory {
        try Task.checkCancellation()
        let manager = FileManager.default
        let deadline = ContinuousClock.now + .seconds(limits.maxSeconds)
        var partial = false
        knownHomes.insert(home.standardizedFileURL)
        let recorded = accounting?.snapshot() ?? .init(homes: [])
        var discovered = recorded.homes
        partial = !recorded.complete
        do {
            let current = try additionalHomes()
            discovered += current.homes
            partial = partial || !current.complete
        } catch is CancellationError { throw CancellationError() }
        catch { partial = true }
        for root in discovered.sorted(by: { $0.path < $1.path }) {
            let root = root.standardizedFileURL
            if knownHomes.contains(root) { continue }
            guard knownHomes.count < CodexAccountingCatalog.maximumRoots else { partial = true; break }
            knownHomes.insert(root)
        }
        var readableHomes: [URL] = []
        for root in knownHomes.sorted(by: { $0.path < $1.path }) {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                // A deleted discovered root holds no records; an inaccessible one still limits coverage.
                if root != home.standardizedFileURL, Self.vanished(root) {
                    knownHomes.remove(root); accounting?.forget(root); continue
                }
                partial = true; continue
            }
            readableHomes.append(root)
        }
        guard !readableHomes.isEmpty else { throw LocalUsageReadFailure.unavailable }
        var files: [(URL, UsageFileStamp)] = []
        var entries = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        for root in readableHomes {
            for name in ["sessions", "archived_sessions"] {
                let directory = root.appendingPathComponent(name)
                guard manager.fileExists(atPath: directory.path) else { continue }
                // Do not follow symbolic links out of the selected accounting root.
                guard let directoryValues = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]), directoryValues.isSymbolicLink != true else {
                    partial = true; continue
                }
                var enumerationFailed = false
                guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: keys,
                        options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationFailed = true; return true }) else {
                    partial = true; continue
                }
                for case let file as URL in enumerator {
                    try Task.checkCancellation()
                    entries += 1
                    guard entries <= limits.maxDirectoryEntries, files.count < limits.maxFiles, ContinuousClock.now < deadline else {
                        partial = true; break
                    }
                    guard let values = try? file.resourceValues(forKeys: Set(keys)) else { partial = true; continue }
                    if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    guard values.isRegularFile == true, file.pathExtension == "jsonl" else { continue }
                    guard let stamp = UsageFileStamp(values) else { partial = true; continue }
                    files.append((file, stamp))
                }
                partial = partial || enumerationFailed
            }
        }
        // Recent writes first make bounded, incomplete scans useful without implying full coverage.
        files.sort { $0.1.modified == $1.1.modified ? $0.0.path < $1.0.path : $0.1.modified > $1.1.modified }
        var budget = limits.maxBytes
        var remainingSamples = limits.maxSamples
        var parsed: [ParsedUsageFile] = []
        var nextCache: [URL: CachedUsageFile] = [:]
        for (file, stamp) in files {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline, remainingSamples > 0 else { partial = true; break }
            if let cached = cache[file], cached.stamp == stamp {
                guard cached.value.samples.count + cached.value.quotaSamples.count <= remainingSamples else { partial = true; break }
                remainingSamples -= cached.value.samples.count + cached.value.quotaSamples.count
                parsed.append(cached.value); nextCache[file] = cached
                continue
            }
            guard budget > 0 else { partial = true; break }
            do {
                let resume = cache[file]?.resume.flatMap { $0.identity == stamp.identity ? $0 : nil }
                let (value, next) = try readFile(file, stamp: stamp, resume: resume, byteBudget: &budget,
                                                 remainingSamples: &remainingSamples, deadline: deadline)
                parsed.append(value)
                // A concurrently appended/replaced file is not reused as-is; it resumes or is reread.
                let after = try file.resourceValues(forKeys: Set(keys))
                if value.complete, UsageFileStamp(after) == stamp {
                    nextCache[file] = CachedUsageFile(stamp: stamp, value: value, resume: next)
                } else {
                    partial = true
                    if let next { nextCache[file] = CachedUsageFile(stamp: nil, value: value, resume: next) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { partial = true }
        }
        cache = nextCache
        return try aggregate(parsed, now: now, calendar: calendar, dayCount: dayCount, partial: partial)
    }

    private func readFile(_ file: URL, stamp: UsageFileStamp, resume: UsageResume?, byteBudget: inout Int, remainingSamples: inout Int,
                          deadline: ContinuousClock.Instant) throws -> (ParsedUsageFile, UsageResume?) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var parser = UsageFileParser()
        // Offset after the last newline-terminated line consumed by the parser.
        var lineEnd: UInt64 = 0
        if let resume, resume.parser.sampleCount <= remainingSamples, Self.matches(handle, resume, size: stamp.size) {
            parser = resume.parser; lineEnd = resume.offset; remainingSamples -= parser.sampleCount
        } else { try handle.seek(toOffset: 0) }
        var position = lineEnd
        var line = Data()
        var dropping = false
        while byteBudget > 0, remainingSamples > 0, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(65_536, byteBudget)) ?? Data()
            if chunk.isEmpty {
                // A trailing unterminated line may still be written; resume before it.
                let checkpoint = parser
                if dropping { parser.value.partial = true }
                else if !line.isEmpty {
                    let oldCount = parser.sampleCount
                    parser.consume(line)
                    remainingSamples -= parser.sampleCount - oldCount
                }
                parser.value.complete = true
                return (parser.value, Self.resumePoint(handle, identity: stamp.identity, offset: lineEnd, parser: checkpoint))
            }
            let chunkStart = position
            position += UInt64(chunk.count)
            byteBudget -= chunk.count
            var offset = chunk.startIndex
            let newline = Data([10])
            while offset < chunk.endIndex {
                let end = chunk.range(of: newline, in: offset..<chunk.endIndex)?.lowerBound ?? chunk.endIndex
                if !dropping {
                    if line.count + end - offset > limits.maxLineBytes {
                        dropping = true; line.removeAll(keepingCapacity: true); parser.value.partial = true
                    } else { line.append(chunk[offset..<end]) }
                }
                if end < chunk.endIndex {
                    if !dropping, !line.isEmpty {
                        let oldCount = parser.sampleCount
                        parser.consume(line)
                        remainingSamples -= parser.sampleCount - oldCount
                    }
                    line.removeAll(keepingCapacity: true); dropping = false
                    lineEnd = chunkStart + UInt64(end - chunk.startIndex + 1)
                    if remainingSamples <= 0 { parser.value.partial = true; return (parser.value, nil) }
                }
                offset = end < chunk.endIndex ? end + 1 : end
            }
        }
        parser.value.partial = true
        return (parser.value, nil)
    }

    /// Rollouts are append-only; resume only while the identity, size and preceding bytes match.
    private static func matches(_ handle: FileHandle, _ resume: UsageResume, size: Int) -> Bool {
        guard resume.offset <= UInt64(size) else { return false }
        guard (try? handle.seek(toOffset: resume.offset - UInt64(resume.tail.count))) != nil,
              let tail = try? handle.read(upToCount: resume.tail.count) else { return false }
        return tail == resume.tail
    }

    private static func resumePoint(_ handle: FileHandle, identity: String, offset: UInt64, parser: UsageFileParser) -> UsageResume? {
        let count = min(offset, 64)
        guard offset > 0, (try? handle.seek(toOffset: offset - count)) != nil,
              let tail = try? handle.read(upToCount: Int(count)), tail.count == Int(count) else { return nil }
        return UsageResume(identity: identity, offset: offset, tail: tail, parser: parser)
    }

    private static func vanished(_ root: URL) -> Bool {
        var info = stat()
        return lstat(root.path, &info) != 0 && (errno == ENOENT || errno == ENOTDIR)
    }

    private func aggregate(_ files: [ParsedUsageFile], now: Date, calendar: Calendar, dayCount: Int, partial: Bool) throws -> LocalUsageHistory {
        let today = calendar.startOfDay(for: now)
        let dates = ((1 - dayCount)...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        var dayAmounts: [Date: UsageAccumulator] = [:]
        var groups: [UUID: [UsageSample]] = [:]
        var damagedSessions: Set<UUID> = []
        var anyPartial = partial
        for file in files {
            anyPartial = anyPartial || file.partial
            guard let id = file.session else { continue }
            groups[id, default: []] += file.samples
            if file.partial { damagedSessions.insert(id) }
        }
        var sessions: [UUID: LocalUsageAmount] = [:]
        for (id, unordered) in groups {
            try Task.checkCancellation()
            var conflictingDuplicates = false
            let snapshots = Dictionary(grouping: Set(unordered)) { UsageSnapshotKey(date: $0.date, total: $0.total) }
            let samples = snapshots.values.map { copies -> UsageSample in
                let first = copies[0]
                let matchingPrices = copies.allSatisfy { $0.price == first.price }
                let matchingLast = copies.allSatisfy { $0.last == first.last }
                conflictingDuplicates = conflictingDuplicates || !matchingPrices || !matchingLast
                return UsageSample(date: first.date, total: first.total,
                    last: matchingLast ? first.last : nil, price: matchingPrices ? first.price : nil)
            }.sorted {
                if $0.date == $1.date { return $0.total.total < $1.total.total }
                return $0.date < $1.date
            }
            var previous: UsageCounters?
            var sessionAmount = UsageAccumulator()
            var sessionPartial = partial || conflictingDuplicates || damagedSessions.contains(id)
            var invalidTotal = false
            for sample in samples {
                guard sample.date <= now else { sessionPartial = true; continue }
                if previous == sample.total { continue }
                var truncated = false
                let delta: UsageCounters?
                if let previous {
                    delta = sample.total.subtracting(previous)
                    if delta == nil { invalidTotal = true; sessionPartial = true }
                } else if sample.last == sample.total {
                    delta = sample.total
                } else {
                    delta = sample.last
                    truncated = true; sessionPartial = true
                }
                previous = sample.total
                let day = calendar.startOfDay(for: sample.date)
                guard let delta else {
                    if dates.contains(day) { dayAmounts[day, default: .init()].invalidate() }
                    sessionAmount.invalidate()
                    continue
                }
                let cost = sample.price?.cost(delta)
                sessionAmount.add(delta.total, cost: cost, partial: truncated)
                if dates.contains(day) {
                    dayAmounts[day, default: .init()].add(delta.total, cost: cost, partial: truncated || damagedSessions.contains(id))
                }
            }
            anyPartial = anyPartial || sessionPartial
            let recorded = sessionAmount.amount(globalPartial: sessionPartial)
            sessions[id] = LocalUsageAmount(tokens: invalidTotal ? nil : previous?.total,
                estimatedUSD: recorded.estimatedUSD, partial: sessionPartial,
                pricedTokens: recorded.pricedTokens, unpricedTokens: recorded.unpricedTokens)
        }
        // Quota readings use the forecast's own lookback, independent of the displayed day range: seven
        // days of pace plus one day used only for the changed-week comparison (US-32).
        let quotaStart = now.addingTimeInterval(-WeeklyQuotaEstimator.inputHorizon())
        let quotaHistory = Self.collapsed(Set(files.filter { $0.session != nil }.flatMap(\.quotaSamples))
            .filter { $0.at >= quotaStart && $0.at <= now }, calendar: calendar)
        return LocalUsageHistory(days: dates.map {
            LocalUsageDay(date: $0, amount: dayAmounts[$0]?.amount(globalPartial: anyPartial)
                ?? LocalUsageAmount(tokens: nil, estimatedUSD: nil, partial: anyPartial))
        }, sessions: sessions, partial: anyPartial, quotaHistory: quotaHistory)
    }

    /// Keeps the first and last reading of each run of identical readings per bucket, plan and local day.
    /// Interior copies add no pace evidence, and each day keeps its last reading for the chart.
    static func collapsed(_ readings: Set<LocalQuotaObservation>, calendar: Calendar) -> [LocalQuotaObservation] {
        struct Series: Hashable { let bucket: String; let plan: String? }
        var kept: [LocalQuotaObservation] = []
        for series in Dictionary(grouping: readings, by: { Series(bucket: $0.bucketID, plan: $0.plan) }).values {
            let ordered = series.sorted {
                ($0.at, $0.remaining, $0.resetAt) < ($1.at, $1.remaining, $1.resetAt)
            }
            func same(_ a: LocalQuotaObservation, _ b: LocalQuotaObservation) -> Bool {
                a.remaining == b.remaining && a.resetAt == b.resetAt && calendar.isDate(a.at, inSameDayAs: b.at)
            }
            for (index, reading) in ordered.enumerated() {
                if index == 0 || index == ordered.count - 1 || !same(ordered[index - 1], reading)
                    || !same(reading, ordered[index + 1]) { kept.append(reading) }
            }
        }
        return kept.sorted { ($0.at, $0.bucketID, $0.remaining) < ($1.at, $1.bucketID, $1.remaining) }
    }
}

private struct UsageFileStamp: Equatable, Sendable {
    let size: Int
    let modified: Date
    let identity: String
    init?(_ values: URLResourceValues) {
        guard let size = values.fileSize, let modified = values.contentModificationDate,
              let identity = values.fileResourceIdentifier else { return nil }
        self.size = size; self.modified = modified; self.identity = String(describing: identity)
    }
}
/// A nil stamp marks a file that changed while it was read: resume it, never reuse its value.
private struct CachedUsageFile: Sendable { let stamp: UsageFileStamp?; let value: ParsedUsageFile; let resume: UsageResume? }
private struct UsageResume: Sendable {
    let identity: String
    let offset: UInt64
    let tail: Data
    let parser: UsageFileParser
}
private struct ParsedUsageFile: Sendable {
    var session: UUID?
    var samples: [UsageSample] = []
    var quotaSamples: [LocalQuotaObservation] = []
    var partial = false
    var complete = false
}
private struct UsageSnapshotKey: Hashable { let date: Date; let total: UsageCounters }
private struct UsageSample: Hashable, Sendable {
    let date: Date
    let total: UsageCounters
    let last: UsageCounters?
    let price: UsagePrice?
}

private struct UsageCounters: Equatable, Hashable, Sendable {
    let input: Int64
    let cached: Int64
    let writes: Int64?
    let output: Int64
    var total: Int64 { input + output }
    init?(_ raw: [String: Any]?) {
        guard let raw, let input = Self.integer(raw["input_tokens"]),
              let output = Self.integer(raw["output_tokens"]), let cached = Self.integer(raw["cached_input_tokens"]),
              let total = Self.integer(raw["total_tokens"]), cached <= input,
              input <= Int64.max - output, total == input + output else { return nil }
        let writes: Int64?
        if let value = raw["cache_write_input_tokens"] {
            guard let parsed = Self.integer(value), parsed <= input else { return nil }
            writes = parsed
        } else { writes = nil }
        if let value = raw["reasoning_output_tokens"] {
            guard let reasoning = Self.integer(value), reasoning <= output else { return nil }
        }
        self.input = input; self.output = output; self.cached = cached; self.writes = writes
    }
    private init(input: Int64, output: Int64, cached: Int64, writes: Int64?) {
        self.input = input; self.output = output; self.cached = cached; self.writes = writes
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let parsed = Int64(number.stringValue), parsed >= 0 else { return nil }
        return parsed
    }
    func subtracting(_ other: Self) -> Self? {
        guard input >= other.input, output >= other.output, cached >= other.cached,
              cached - other.cached <= input - other.input else { return nil }
        let writeDelta: Int64?
        if let writes, let oldWrites = other.writes {
            guard writes >= oldWrites, writes - oldWrites <= input - other.input else { return nil }
            writeDelta = writes - oldWrites
        } else { writeDelta = nil }
        return Self(input: input - other.input, output: output - other.output, cached: cached - other.cached, writes: writeDelta)
    }
}

/// Published standard API equivalent USD rates per million tokens, verified 2026-10-26.
/// Source: https://developers.openai.com/api/docs/pricing . Not a subscription bill or service-tier charge.
private enum UsagePrice: String, Hashable, Sendable {
    case sol = "gpt-6.1-sol", astra = "gpt-6-astra", luna = "gpt-6-luna", previousSol = "gpt-5.6-sol"
    func cost(_ usage: UsageCounters) -> Double? {
        guard usage.writes == 0 else { return nil }
        let rate: (Double, Double, Double)
        switch self {
        case .sol: rate = (2, 0.10, 10)
        case .astra: rate = (10, 1, 50)
        case .luna: rate = (0.10, 0.01, 0.50)
        case .previousSol: rate = (4, 0.40, 20)
        }
        return (Double(usage.input - usage.cached) * rate.0 + Double(usage.cached) * rate.1 + Double(usage.output) * rate.2) / 1_000_000
    }
}

private struct UsageFileParser: Sendable {
    var value = ParsedUsageFile()
    var price: UsagePrice?
    var invalidIdentity = false
    var sampleCount: Int { value.samples.count + value.quotaSamples.count }
    mutating func consume(_ line: Data) {
        guard !invalidIdentity else { return }
        // Decode transiently and retain only accounting metadata; never retain message/tool text.
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String, let payload = object["payload"] as? [String: Any] else {
            value.partial = true; return
        }
        switch type {
        case "session_meta":
            guard let raw = (payload["id"] ?? payload["session_id"]) as? String, let id = UUID(uuidString: raw),
                  value.session == nil || value.session == id else {
                value.partial = true; value.session = nil; value.samples.removeAll(); value.quotaSamples.removeAll(); invalidIdentity = true
                return
            }
            value.session = id
        case "turn_context": price = (payload["model"] as? String).flatMap(UsagePrice.init(rawValue:))
        case "event_msg":
            guard payload["type"] as? String == "token_count" else { return }
            if value.session != nil, let raw = payload["rate_limits"] as? [String: Any],
               let bucketID = raw["limit_id"] as? String, !bucketID.isEmpty,
               let timestamp = object["timestamp"] as? String,
               let date = RolloutTimestamps.shared.date(from: timestamp) {
                let windows = [raw["primary"], raw["secondary"]].compactMap { $0 as? [String: Any] }
                    .filter { value in
                        guard let n = value["window_minutes"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
                        return n.doubleValue == 10_080
                    }
                if windows.count == 1, let used = windows[0]["used_percent"] as? NSNumber,
                   let reset = windows[0]["resets_at"] as? NSNumber,
                   CFGetTypeID(used) != CFBooleanGetTypeID(), CFGetTypeID(reset) != CFBooleanGetTypeID(),
                   used.doubleValue.isFinite, (0...100).contains(used.doubleValue),
                   reset.doubleValue.isFinite {
                    let resetAt = Date(timeIntervalSince1970: reset.doubleValue)
                    if resetAt > date, resetAt.timeIntervalSince(date) <= 7 * 86_400 {
                        value.quotaSamples.append(.init(at: date, resetAt: resetAt, remaining: 100 - used.doubleValue,
                                                        bucketID: bucketID, plan: raw["plan_type"] as? String))
                    }
                }
            }
            if payload["info"] is NSNull { return }
            guard value.session != nil, let info = payload["info"] as? [String: Any] else {
                value.partial = true; return
            }
            guard let total = UsageCounters(info["total_token_usage"] as? [String: Any]),
                  let timestamp = object["timestamp"] as? String,
                  let date = RolloutTimestamps.shared.date(from: timestamp) else {
                value.partial = true; return
            }
            let last = UsageCounters(info["last_token_usage"] as? [String: Any])
            value.samples.append(UsageSample(date: date, total: total, last: last, price: price))
        default: break
        }
    }
}

private struct UsageAccumulator {
    var tokens: Int64?
    var cost: Double?
    var pricedTokens: Int64 = 0
    var unpricedTokens: Int64 = 0
    var partial = false
    var invalid = false
    mutating func invalidate() {
        partial = true; invalid = true; tokens = nil; cost = nil
        pricedTokens = 0; unpricedTokens = 0
    }
    mutating func add(_ count: Int64, cost addedCost: Double?, partial addedPartial: Bool) {
        partial = partial || addedPartial
        guard !invalid else { return }
        let current = tokens ?? 0
        guard current <= Int64.max - count else { invalidate(); return }
        tokens = current + count
        if let addedCost {
            cost = (cost ?? 0) + addedCost
            pricedTokens += count
        } else {
            unpricedTokens += count
        }
    }
    func amount(globalPartial: Bool) -> LocalUsageAmount {
        LocalUsageAmount(tokens: tokens, estimatedUSD: cost, partial: partial || globalPartial,
                         pricedTokens: pricedTokens, unpricedTokens: unpricedTokens)
    }
}
