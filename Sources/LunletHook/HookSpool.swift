// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.01, AC-38.02, AC-38.03, AC-38.04, AC-38.07.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

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
    /// The final reply text kept from a stop signal; the completion notice shows a bounded excerpt of it anyway.
    public static let maximumReplyBytes = 16_384

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
            self.lastAssistantMessage = String(lastAssistantMessage.utf8.prefix(HookSpool.maximumReplyBytes)) ?? ""
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

    /// Bounded read of one small spool file.
    public static func readSmall(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = maximumReplyBytes + maximumTextBytes + 2_048
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
