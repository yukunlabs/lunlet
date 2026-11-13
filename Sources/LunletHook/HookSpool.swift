// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.01, AC-38.02, AC-38.03, AC-38.04, AC-38.07.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// A live process's start time as the kernel reports it. With the pid it names one process, so a pid the system
/// handed to another process is never mistaken for the app that wrote a record.
public enum HookProcess {
    /// Nil when there is no such process, it cannot be inspected, or the platform has no reading.
    public static func startTime(of pid: Int32) -> Date? {
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
        #else
        return nil
        #endif
    }
    /// Records keep whole seconds, so two readings of one process may differ by up to one.
    public static let startTolerance: TimeInterval = 1
    /// False where `startTime` always answers nil, so a missing reading there is not evidence against a process.
    public static var canReadStartTimes: Bool {
        #if canImport(Darwin)
        true
        #else
        false
        #endif
    }
}

/// The helper's answer to being told to end: Claude Code ends its hooks with TERM or HUP when a session is quit
/// mid-hold. The handlers only raise a flag; the helper's waits end on it, so it removes its files and exits 0.
public enum HookInterrupt {
    /// Written only by the signal handlers, which may do nothing else safely.
    private nonisolated(unsafe) static var raised: sig_atomic_t = 0
    public static var isRaised: Bool { raised != 0 }
    public static func install() {
        // Touched first, so a handler never runs the flag's one-time initialization.
        raised = 0
        for number in [SIGTERM, SIGHUP] { signal(number) { _ in HookInterrupt.raised = 1 } }
    }
}

/// The user-only folder through which Claude Code's Stop hook and the app meet. Each time a session's turn ends,
/// the hook helper writes `stops/<session>/<stop>.stop`; the app answers with `<stop>.hold` or `<stop>.release`;
/// while holding, the app may write `<stop>.push` with one follow-up, which the helper answers with `<stop>.pushed`
/// after handing it to Claude Code. The app announces itself in `app.json` and publishes its helper for the launcher.
public struct HookSpool: Equatable, Sendable {
    public static let formatVersion = 1
    public static let signalSuffix = ".stop"
    public static let holdSuffix = ".hold"
    public static let releaseSuffix = ".release"
    public static let pushSuffix = ".push"
    public static let receiptSuffix = ".pushed"
    /// A follow-up above this size is refused by the app before it is written, and by the helper if it ever is.
    public static let maximumTextBytes = 8_192
    /// The final reply text kept from a stop signal: as many bytes as a notice captures from any agent's reply
    /// (`NoticeText.captureLimit`), so a longer reply reaches the notice at that size and is marked as shortened there.
    public static let maximumReplyBytes = 36_864

    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }

    /// Lunlet's own folder under the user's Application Support, beside its credential file.
    public static func standard(fileManager: FileManager = .default) -> HookSpool {
        .init(root: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.lunlet", isDirectory: true).appendingPathComponent("hook", isDirectory: true))
    }

    /// The running app's record; a helper that finds no live app exits at once.
    public var appRecordURL: URL { root.appendingPathComponent("app.json", isDirectory: false) }
    /// Where the running app publishes the path of its bundled helper for the launcher.
    public var helperPathFile: URL { root.appendingPathComponent("helper-path", isDirectory: false) }
    /// The launcher Claude Code's settings name; it runs the published helper and exits quietly without one.
    public var launcherURL: URL { root.appendingPathComponent("lunlet-hook", isDirectory: false) }
    public var stopsDirectory: URL { root.appendingPathComponent("stops", isDirectory: true) }
    public func stopDirectory(_ sessionID: UUID) -> URL {
        stopsDirectory.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
    }
    public func file(_ sessionID: UUID, stop: UUID, suffix: String) -> URL {
        stopDirectory(sessionID).appendingPathComponent(stop.uuidString.lowercased() + suffix, isDirectory: false)
    }

    public struct AppRecord: Codable, Equatable, Sendable {
        public var version: Int
        public var pid: Int32
        /// When the app's process started, as the kernel reports it; the helper compares it with the live process
        /// of that pid, so a pid reused after a crash or restart is not taken for a running app.
        public var startedAt: Date
        public init(pid: Int32, startedAt: Date) { version = HookSpool.formatVersion; self.pid = pid; self.startedAt = startedAt }
    }
    /// Written by the helper when a turn ends; the app accepts it only after checking the processes it names.
    public struct StopSignal: Codable, Equatable, Sendable {
        public var version: Int
        public var stopID: UUID
        public var sessionID: UUID
        public var promptID: String?
        public var lastAssistantMessage: String
        public var stopHookActive: Bool
        public var pid: Int32
        public var parentPID: Int32
        public var at: Date
        public init(stopID: UUID, sessionID: UUID, promptID: String?, lastAssistantMessage: String, stopHookActive: Bool,
                    pid: Int32, parentPID: Int32, at: Date) {
            version = HookSpool.formatVersion
            self.stopID = stopID; self.sessionID = sessionID; self.promptID = promptID
            self.lastAssistantMessage = HookSpool.prefix(lastAssistantMessage, utf8Limit: HookSpool.maximumReplyBytes)
            self.stopHookActive = stopHookActive; self.pid = pid; self.parentPID = parentPID; self.at = at
        }
    }
    /// One follow-up for the held stop; the file name carries the same stop id.
    public struct PushRequest: Codable, Equatable, Sendable {
        public var version: Int
        public var stopID: UUID
        public var text: String
        public init(stopID: UUID, text: String) { version = HookSpool.formatVersion; self.stopID = stopID; self.text = text }
        public var isAcceptable: Bool {
            version == HookSpool.formatVersion && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && text.utf8.count <= HookSpool.maximumTextBytes
        }
    }
    public struct PushReceipt: Codable, Equatable, Sendable {
        public var version: Int
        public var stopID: UUID
        public var pushedAt: Date
        public init(stopID: UUID, pushedAt: Date) { version = HookSpool.formatVersion; self.stopID = stopID; self.pushedAt = pushedAt }
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The launcher Claude Code runs at every turn end: the published helper when the app installed one, else nothing.
    public static let launcherScript = """
    #!/bin/sh
    # Lunlet's Claude Code Stop hook. It runs the hook helper that the installed Lunlet app publishes here and
    # exits quietly when there is none, so a removed Lunlet never leaves Claude Code with a failing hook.
    lunlet_dir=$(dirname "$0")
    if [ -r "$lunlet_dir/helper-path" ]; then
        lunlet_helper=$(head -n 1 "$lunlet_dir/helper-path")
        if [ -n "$lunlet_helper" ] && [ -x "$lunlet_helper" ]; then
            exec "$lunlet_helper"
        fi
    fi
    exit 0

    """

    /// Creates a user-only directory, including its parents, and tightens an existing one.
    public static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Writes a user-only file through a temporary sibling and one rename, so readers never see a partial file.
    public static func writeAtomically(_ data: Data, to url: URL, mode: Int = 0o600) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".tmp-" + UUID().uuidString.prefix(8), isDirectory: false)
        try data.write(to: temporary, options: [])
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else {
            let failure = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    /// At most `limit` UTF-8 bytes of `text`, cut where a character starts, so a cut never empties or corrupts it.
    public static func prefix(_ text: String, utf8Limit limit: Int) -> String {
        let bytes = text.utf8
        guard bytes.count > limit, limit > 0 else { return limit > 0 ? text : "" }
        var end = bytes.index(bytes.startIndex, offsetBy: limit)
        // A continuation byte at the cut means the limit fell inside a character: back off to its first byte.
        while end > bytes.startIndex, bytes[end] & 0xC0 == 0x80 { end = bytes.index(before: end) }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    /// Bounded read of one small spool file. Encoding escapes quotes, slashes and line breaks to two bytes and
    /// control characters to six, so the bound allows for six times the largest text a file may carry.
    public static func readSmall(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = 6 * (maximumReplyBytes + maximumTextBytes) + 2_048
        guard let data = try handle.read(upToCount: limit + 1) else { return Data() }
        guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    /// The files of one kind in a stop directory, oldest name first.
    public static func files(in directory: URL, suffix: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(suffix) && !$0.hasPrefix(".") }.sorted()
            .map { directory.appendingPathComponent($0, isDirectory: false) }
    }
    public static func stopID(of url: URL, suffix: String) -> UUID? {
        let name = url.lastPathComponent
        guard name.hasSuffix(suffix) else { return nil }
        return UUID(uuidString: String(name.dropLast(suffix.count)))
    }
}
