// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.04, AC-33.06, AC-33.07, AC-33.10.
// Refs: US-04, AC-04.02, AC-04.03, AC-04.08; US-18, AC-18.01, AC-18.02, AC-18.03; US-12, AC-12.04; US-25, AC-25.01.
import Darwin
import Foundation
import LunletCore

/// Bounds the initial scan as well as refreshes. Complete, unchanged files are cached;
/// appended files resume after their last complete line.
struct ClaudeUsageReadLimits: Sendable {
    var maxBytes: Int = 1_073_741_824
    var maxLineBytes: Int = 2_097_152
    var maxFiles: Int = 10_000
    var maxDirectoryEntries: Int = 30_000
    var maxMessages: Int = 200_000
    var maxSeconds: Double = 30
}

/// Recorded Claude Code usage on this Mac from main and subagent transcripts. Each API response is counted
/// once by `message.id`; transcripts omit some usage, so every amount is a lower bound. Only usage metadata is
/// retained; plan limits have no local credential-free source and are never inferred.
public actor ClaudeLocalUsageReader: LocalUsageReading {
    private nonisolated let executor = DispatchSerialQueue(label: "com.lunlet.claude.usage", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let home: ClaudeHome
    private let limits: ClaudeUsageReadLimits
    private var cache: [URL: CachedFile] = [:]

    public init(home: ClaudeHome = .current()) { self.home = home; limits = .init() }
    init(home: ClaudeHome, limits: ClaudeUsageReadLimits) { self.home = home; self.limits = limits }

    public func readHistory(now: Date, calendar: Calendar, days: Int) async throws -> LocalUsageHistory {
        guard (1...7).contains(days) else { throw LocalUsageReadFailure.invalidRange }
        try Task.checkCancellation()
        let deadline = ContinuousClock.now + .seconds(limits.maxSeconds)
        var partial = false
        guard ClaudeProjects.isDirectory(home.projects) else { throw LocalUsageReadFailure.unavailable }
        let files = try discover(deadline: deadline, partial: &partial)
        var budget = limits.maxBytes, remaining = limits.maxMessages
        var parsed: [ParsedFile] = [], nextCache: [URL: CachedFile] = [:]
        // Recent writes first make bounded, incomplete scans useful without implying full coverage.
        for file in files.sorted(by: { $0.stamp.modified == $1.stamp.modified ? $0.url.path < $1.url.path
                                                                               : $0.stamp.modified > $1.stamp.modified }) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline, remaining > 0 else { partial = true; break }
            if let cached = cache[file.url], cached.stamp == file.stamp {
                guard cached.value.messages.count <= remaining else { partial = true; break }
                remaining -= cached.value.messages.count
                parsed.append(cached.value); nextCache[file.url] = cached
                continue
            }
            guard budget > 0 else { partial = true; break }
            do {
                let resume = cache[file.url]?.resume.flatMap { $0.stamp.sameFile(as: file.stamp) ? $0 : nil }
                let (value, next) = try read(file, resume: resume, byteBudget: &budget, remaining: &remaining, deadline: deadline)
                parsed.append(value)
                // A concurrently appended or replaced file is not reused as-is; it resumes or is reread.
                if value.complete, Self.stamp(file.url) == file.stamp {
                    nextCache[file.url] = .init(stamp: file.stamp, value: value, resume: next)
                } else {
                    partial = true
                    if let next { nextCache[file.url] = .init(stamp: nil, value: value, resume: next) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { partial = true }
        }
        cache = nextCache
        return try aggregate(parsed, now: now, calendar: calendar, dayCount: days)
    }

    /// Lists only `<project>/<session>.jsonl` and `<project>/<session>/subagents/agent-*.jsonl`.
    private func discover(deadline: ContinuousClock.Instant, partial: inout Bool) throws -> [DiscoveredFile] {
        var entries = 0, files: [DiscoveredFile] = []
        func list(_ directory: URL) -> [String]? {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { partial = true; return nil }
            entries += names.count
            guard entries <= limits.maxDirectoryEntries, ContinuousClock.now < deadline else { partial = true; return nil }
            return names.sorted()
        }
        func add(_ url: URL, session: UUID) {
            guard files.count < limits.maxFiles else { partial = true; return }
            guard let stamp = Self.stamp(url) else { partial = true; return }
            files.append(.init(url: url, session: session, stamp: stamp))
        }
        guard let projects = list(home.projects) else { throw LocalUsageReadFailure.unavailable }
        for project in projects where !project.hasPrefix(".") {
            try Task.checkCancellation()
            let directory = home.projects.appendingPathComponent(project, isDirectory: true)
            guard ClaudeProjects.isDirectory(directory), let names = list(directory) else { continue }
            for name in names {
                if name.hasSuffix(".jsonl"), let session = Self.session(String(name.dropLast(6))) {
                    add(directory.appendingPathComponent(name), session: session)
                } else if let session = Self.session(name) {
                    // A subagent transcript counts under its parent session; it is never a separate conversation.
                    let subagents = directory.appendingPathComponent(name, isDirectory: true)
                        .appendingPathComponent("subagents", isDirectory: true)
                    guard ClaudeProjects.isDirectory(subagents), let agents = list(subagents) else { continue }
                    for agent in agents where agent.hasPrefix("agent-") && agent.hasSuffix(".jsonl") {
                        add(subagents.appendingPathComponent(agent), session: session)
                    }
                }
            }
        }
        return files
    }

    private func read(_ file: DiscoveredFile, resume: Resume?, byteBudget: inout Int, remaining: inout Int,
                      deadline: ContinuousClock.Instant) throws -> (ParsedFile, Resume?) {
        let fd = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw LocalUsageReadFailure.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == file.stamp.device, info.st_ino == file.stamp.inode else {
            throw LocalUsageReadFailure.unavailable
        }
        var parser = Parser(session: file.session)
        // Offset after the last newline-terminated line consumed by the parser.
        var lineEnd: UInt64 = 0
        if let resume, resume.parser.value.messages.count <= remaining, Self.matches(handle, resume, size: file.stamp.size) {
            parser = resume.parser; lineEnd = resume.offset; remaining -= parser.value.messages.count
        } else { try handle.seek(toOffset: 0) }
        var position = lineEnd, line = Data(), dropping = false
        while byteBudget > 0, remaining > 0, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(65_536, byteBudget)) ?? Data()
            if chunk.isEmpty {
                // A trailing unterminated line may still be written; resume before it.
                let checkpoint = parser
                if dropping { parser.value.partial = true }
                else if !line.isEmpty { remaining -= parser.consume(line) }
                parser.value.complete = true
                return (parser.value, Self.resumePoint(handle, stamp: file.stamp, offset: lineEnd, parser: checkpoint))
            }
            let chunkStart = position
            position += UInt64(chunk.count); byteBudget -= chunk.count
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                let end = chunk[cursor...].firstIndex(of: 10) ?? chunk.endIndex
                if !dropping {
                    // An oversized line is skipped and marks coverage partial; it never fails the read.
                    if line.count + end - cursor > limits.maxLineBytes {
                        dropping = true; line.removeAll(keepingCapacity: true); parser.value.partial = true
                    } else { line.append(chunk[cursor..<end]) }
                }
                if end < chunk.endIndex {
                    if !dropping, !line.isEmpty { remaining -= parser.consume(line) }
                    line.removeAll(keepingCapacity: true); dropping = false
                    lineEnd = chunkStart + UInt64(end - chunk.startIndex + 1)
                    if remaining <= 0 { parser.value.partial = true; return (parser.value, nil) }
                }
                cursor = end < chunk.endIndex ? end + 1 : end
            }
        }
        parser.value.partial = true
        return (parser.value, nil)
    }

    private func aggregate(_ files: [ParsedFile], now: Date, calendar: Calendar, dayCount: Int) throws -> LocalUsageHistory {
        let today = calendar.startOfDay(for: now)
        let dates = ((1 - dayCount)...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        // The same response can appear in a main and a subagent transcript, or in a copied history.
        // It counts once; the earliest record's session owns it.
        var responses: [String: (session: UUID, message: Message)] = [:]
        for file in files.sorted(by: { $0.session.uuidString < $1.session.uuidString }) {
            try Task.checkCancellation()
            for (id, message) in file.messages {
                guard let existing = responses[id] else { responses[id] = (file.session, message); continue }
                let earlier = message.date < existing.message.date
                    || (message.date == existing.message.date && file.session.uuidString < existing.session.uuidString)
                responses[id] = (earlier ? file.session : existing.session, existing.message.merged(with: message))
            }
        }
        var days: [Date: Accumulator] = [:], sessions: [UUID: Accumulator] = [:]
        for (session, message) in responses.values {
            let cost = message.key.flatMap { ClaudePricing.cost(message.counts, key: $0) }
            sessions[session, default: .init()].add(message.counts, cost: cost)
            let day = calendar.startOfDay(for: message.date)
            if message.date <= now, dates.contains(day) { days[day, default: .init()].add(message.counts, cost: cost) }
        }
        return LocalUsageHistory(
            days: dates.map { LocalUsageDay(date: $0, amount: days[$0]?.amount ?? .init(tokens: nil, estimatedUSD: nil, partial: true)) },
            sessions: sessions.mapValues(\.amount), partial: true)
    }

    private static func session(_ name: String) -> UUID? { ClaudeProjects.isSessionName(name) ? UUID(uuidString: name) : nil }
    static func stamp(_ url: URL) -> ClaudeUsageStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size >= 0 else { return nil }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        return .init(size: UInt64(info.st_size), modified: modified, device: info.st_dev, inode: info.st_ino)
    }
    /// Transcripts are append-only; resume only while the identity, size and preceding bytes match.
    private static func matches(_ handle: FileHandle, _ resume: Resume, size: UInt64) -> Bool {
        guard resume.offset <= size, (try? handle.seek(toOffset: resume.offset - UInt64(resume.tail.count))) != nil,
              let tail = try? handle.read(upToCount: resume.tail.count) else { return false }
        return tail == resume.tail
    }
    private static func resumePoint(_ handle: FileHandle, stamp: ClaudeUsageStamp, offset: UInt64, parser: Parser) -> Resume? {
        let count = min(offset, 64)
        guard offset > 0, (try? handle.seek(toOffset: offset - count)) != nil,
              let tail = try? handle.read(upToCount: Int(count)), tail.count == Int(count) else { return nil }
        return .init(stamp: stamp, offset: offset, tail: tail, parser: parser)
    }
}

struct ClaudeUsageStamp: Equatable, Sendable {
    let size: UInt64
    let modified: Date
    let device: Int32
    let inode: UInt64
    func sameFile(as other: Self) -> Bool { device == other.device && inode == other.inode }
}
private struct DiscoveredFile { let url: URL; let session: UUID; let stamp: ClaudeUsageStamp }
/// A nil stamp marks a file that changed while it was read: resume it, never reuse its value.
private struct CachedFile: Sendable { let stamp: ClaudeUsageStamp?; let value: ParsedFile; let resume: Resume? }
private struct Resume: Sendable { let stamp: ClaudeUsageStamp; let offset: UInt64; let tail: Data; let parser: Parser }
private struct ParsedFile: Sendable {
    let session: UUID
    var messages: [String: Message] = [:]
    var partial = false
    var complete = false
}
private struct Message: Sendable {
    var date: Date
    var counts: ClaudeTokenCounts
    /// Nil when the model, modifiers or cache-write category cannot be priced exactly.
    var key: ClaudePricingKey?
    func merged(with other: Self) -> Self {
        .init(date: min(date, other.date), counts: counts.merged(with: other.counts), key: key == other.key ? key : nil)
    }
}

private struct Parser: Sendable {
    var value: ParsedFile
    init(session: UUID) { value = .init(session: session) }

    /// Decodes transiently and keeps only response identity, time, model, modifiers and token counts.
    /// Returns the number of newly recorded responses.
    mutating func consume(_ line: Data) -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { value.partial = true; return 0 }
        guard object["type"] as? String == "assistant", let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return 0 }
        guard let id = message["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
              let raw = object["timestamp"] as? String, raw.utf8.count <= 64,
              let date = ClaudeTimestamps.shared.date(from: raw),
              let input = Self.integer(usage["input_tokens"]), let output = Self.integer(usage["output_tokens"]) else {
            value.partial = true; return 0
        }
        let read = Self.integer(usage["cache_read_input_tokens"]) ?? 0
        let total = Self.integer(usage["cache_creation_input_tokens"])
        let creation = usage["cache_creation"] as? [String: Any]
        let short = creation.flatMap { Self.integer($0["ephemeral_5m_input_tokens"]) }
        let long = creation.flatMap { Self.integer($0["ephemeral_1h_input_tokens"]) }
        var counts = ClaudeTokenCounts(input: input, cacheRead: read, output: output)
        var classified = true
        if let short, let long, total == nil || total == short + long {
            counts.cacheWrite5m = short; counts.cacheWrite1h = long
        } else if let total, total > 0 {
            // Writes without a matching duration breakdown are counted but left unpriced.
            counts.cacheWrite5m = total; classified = false
        }
        let model = (message["model"] as? String).flatMap { $0.utf8.count <= 128 ? $0 : nil }
        let key = classified ? model.map {
            ClaudePricingKey(model: $0, inferenceGeo: Self.token(usage["inference_geo"]), speed: Self.token(usage["speed"]),
                             serviceTier: Self.token(usage["service_tier"]))
        } : nil
        let next = Message(date: date, counts: counts, key: key)
        if let existing = value.messages[id] { value.messages[id] = existing.merged(with: next); return 0 }
        value.messages[id] = next
        return 1
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let parsed = Int64(exactly: number.doubleValue), parsed >= 0, parsed <= 1_000_000_000_000 else { return nil }
        return parsed
    }
    private static func token(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 64 else { return nil }
        return text
    }
}

private struct Accumulator {
    var tokens: Int64 = 0, cost: Double?, priced: Int64 = 0, unpriced: Int64 = 0
    /// Categories stay separate so cache reads never dominate a single figure (AC-33.10).
    var breakdown = LocalTokenBreakdown()
    mutating func add(_ counts: ClaudeTokenCounts, cost added: Double?) {
        let count = counts.total
        tokens += count
        breakdown.input += counts.input; breakdown.output += counts.output
        breakdown.cacheWrite += counts.cacheWrite5m + counts.cacheWrite1h; breakdown.cacheRead += counts.cacheRead
        if let added { cost = (cost ?? 0) + added; priced += count } else { unpriced += count }
    }
    /// Recorded transcripts are a lower bound, so every amount is marked partial.
    var amount: LocalUsageAmount {
        .init(tokens: tokens, estimatedUSD: cost, partial: true, pricedTokens: priced, unpricedTokens: unpriced, breakdown: breakdown)
    }
}
