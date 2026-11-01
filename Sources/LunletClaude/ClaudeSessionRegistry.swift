// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.01, AC-33.02, AC-33.03, AC-33.07.
import Darwin
import Foundation

/// The allowlisted fields of one `sessions/<pid>.json` record that Lunlet uses; nothing else is retained.
struct ClaudeRegistryRecord: Equatable, Sendable {
    let pid: Int32
    let sessionID: UUID
    /// The transcript file stem. Claude writes lowercase UUIDs.
    let sessionName: String
    let cwd: String?
    /// Kernel process start time at whole-second precision; nil when the format is unrecognized.
    let processStart: Date?
    let version: String?
    let status: String?
    let waitingFor: String?
    let statusUpdatedAt: Date?
    let file: URL
}

struct ClaudeRegistryScan: Sendable {
    let records: [ClaudeRegistryRecord]
    /// False when an entry was skipped for budget, a torn or unreadable record, or an inspection failure.
    let complete: Bool
}

protocol ClaudeRegistryReading: Sendable {
    func scan() throws -> ClaudeRegistryScan
}

enum ClaudeRegistryFailure: Error { case unavailable }

/// Reads Claude's own per-process records without hooks, settings changes or sockets.
struct ClaudeSessionRegistry: ClaudeRegistryReading {
    static let maximumBytes = 262_144
    static let maximumEntries = 1_024
    let directory: URL

    func scan() throws -> ClaudeRegistryScan {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch {
            // No directory yet means no Claude sessions, not an outage.
            var info = stat()
            if lstat(directory.path, &info) != 0, errno == ENOENT { return .init(records: [], complete: true) }
            throw ClaudeRegistryFailure.unavailable
        }
        var complete = true
        let candidates = names.filter(Self.isRecordName).sorted()
        if candidates.count > Self.maximumEntries { complete = false }
        var records: [ClaudeRegistryRecord] = []
        for name in candidates.prefix(Self.maximumEntries) {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard let pid = Int32(name.dropLast(5)) else { continue }
            switch Self.read(url, pid: pid) {
            case .record(let record): records.append(record)
            case .absent: continue
            case .unreadable: complete = false
            }
        }
        return .init(records: records, complete: complete)
    }

    enum ReadResult: Equatable { case record(ClaudeRegistryRecord), absent, unreadable }

    /// Claude rewrites records in place, so one torn read is retried once before it is treated as unreadable.
    /// Complete JSON that fails validation is ignored like a stale record; it never binds a session.
    static func read(_ url: URL, pid: Int32, load: (URL) -> Bounded = bounded) -> ReadResult {
        for _ in 0..<2 {
            switch load(url) {
            case .missing: return .absent
            case .unreadable: return .unreadable
            case .data(let data):
                guard let object = try? JSONSerialization.jsonObject(with: data) else { continue }
                return decode(object, pid: pid, file: url).map(ReadResult.record) ?? .absent
            }
        }
        return .unreadable
    }

    static func isRecordName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(5)
        return (1...10).contains(stem.count) && stem.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func decode(_ value: Any, pid: Int32, file: URL) -> ClaudeRegistryRecord? {
        guard let object = value as? [String: Any], let rawPID = integer(object["pid"]), rawPID == Int64(pid), pid > 0,
              let rawSession = object["sessionId"] as? String, rawSession.utf8.count == 36,
              let sessionID = UUID(uuidString: rawSession) else { return nil }
        let cwd = (object["cwd"] as? String).flatMap { $0.hasPrefix("/") && $0.utf8.count <= 4_096 ? $0 : nil }
        // `startedAt`, `kind` and `entrypoint` are also allowlisted but not needed for binding or state.
        return .init(pid: pid, sessionID: sessionID, sessionName: rawSession.lowercased(), cwd: cwd,
                     processStart: (object["procStart"] as? String).flatMap(ClaudeProcessStart.date(from:)),
                     version: token(object["version"]), status: token(object["status"]), waitingFor: token(object["waitingFor"]),
                     statusUpdatedAt: milliseconds(object["statusUpdatedAt"]), file: file)
    }

    enum Bounded { case data(Data), missing, unreadable }
    static func bounded(_ url: URL) -> Bounded {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= maximumBytes,
              let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else { return .unreadable }
        return .data(data)
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int64(exactly: number.doubleValue)
    }
    /// Epoch milliseconds, as written by Claude Code 2.1.
    private static func milliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1_000)
    }
    /// Short status-like strings only; anything longer or with control characters is dropped.
    private static func token(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 128,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
}

/// Claude records `procStart` in the `ps -o lstart` form, rendered in UTC: `Thu Oct 30 15:37:00 2026`.
enum ClaudeProcessStart {
    private static let weekdays: Set<String> = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func date(from text: String) -> Date? {
        guard text.utf8.count <= 64 else { return nil }
        let parts = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 5, weekdays.contains(parts[0]), let month = months.firstIndex(of: parts[1]),
              let day = Int(parts[2]), (1...31).contains(day), let year = Int(parts[4]), (1970...9999).contains(year) else { return nil }
        let clock = parts[3].split(separator: ":").map { Int($0) }
        guard clock.count == 3, let hour = clock[0], let minute = clock[1], let second = clock[2],
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let components = DateComponents(year: year, month: month + 1, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day else { return nil }
        return date
    }
}
