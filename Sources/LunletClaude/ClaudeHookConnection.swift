// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.01, AC-38.06, AC-38.07, AC-38.08; US-33, AC-33.07.
import Darwin
import Foundation
import LunletHook

public enum ClaudeHookState: Equatable, Sendable { case notConnected, connected }

public enum ClaudeHookFailure: Error, Equatable, Sendable {
    /// No Claude Code configuration directory; Lunlet does not create one.
    case claudeDirectoryMissing
    case settingsUnreadable
    /// Not a strict JSON object, `hooks` appears twice, or `hooks` is not an object of event arrays.
    case settingsInvalid
    /// The settings changed while Lunlet was editing them; nothing is written.
    case settingsChanged
    case storageUnavailable
    case writeFailed
}

/// The explicit connect and disconnect actions for Lunlet's Stop hook. Only the `hooks` member of `settings.json`
/// changes, and inside it only Lunlet's own `Stop` entry, recognized by its command: connecting adds the entry
/// beside any others, disconnecting removes exactly it. Everything else in the file keeps its bytes.
public struct ClaudeHookConnection: Sendable {
    public let home: ClaudeHome
    public let spool: HookSpool
    static let key = "hooks"
    static let event = "Stop"
    static let statusMessage = "Lunlet: waiting for your phone reply"
    /// Longer than the reply window, so the hold never ends by Claude Code's timeout first.
    static let timeoutSeconds = 900
    private static let maximumSettingsBytes = 4 * 1_048_576
    /// Test seams standing in for another writer: run once the settings were read, and once they were replaced.
    var afterRead: (@Sendable () -> Void)?
    var afterWrite: (@Sendable () -> Void)?

    public init(home: ClaudeHome = .current(), spool: HookSpool = .standard()) { self.home = home; self.spool = spool }

    /// The launcher's path as Claude Code's settings name it: under `$HOME` when it lives there, so a synced
    /// settings file still points at this user's folder on another machine.
    private var launcherReference: String {
        let path = spool.launcherURL.path, home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "$HOME" + path.dropFirst(home.count) : path
    }
    /// The command builds up to 2026-11-12 wrote: the launcher alone. Still recognized as Lunlet's entry, so it is
    /// removed exactly and brought to the current command on the next connect.
    var legacyCommand: String { "\"" + launcherReference + "\"" }
    /// The entry's command: the launcher when it is there, and nothing, successfully, when it is not, so the entry
    /// never fails a turn end after Lunlet's folder was removed or the settings reached a Mac without Lunlet
    /// (AC-38.01). The test runs inside an explicit `/bin/sh`, in single quotes, so whichever shell runs the settings
    /// command only has to pass one quoted word along. A path that those quotes cannot hold keeps the plain form.
    public var command: String {
        let reference = launcherReference
        let plain = reference.hasPrefix("$HOME") ? String(reference.dropFirst(5)) : reference
        guard !plain.contains(where: { "'\"\\$`".contains($0) }) else { return legacyCommand }
        return "/bin/sh -c 'if [ -x \"" + reference + "\" ]; then exec \"" + reference + "\"; fi'"
    }
    var entry: [String: Any] {
        ["type": "command", "command": command, "timeout": Self.timeoutSeconds, "statusMessage": Self.statusMessage]
    }
    private func isLunlet(_ hook: Any) -> Bool {
        guard let hook = hook as? [String: Any], hook["type"] as? String == "command",
              let command = hook["command"] as? String else { return false }
        return command == self.command || command == legacyCommand || command.contains("com.lunlet/hook/lunlet-hook")
    }
    /// The hooks with every entry of Lunlet's that has another command than this build's replaced where it stands;
    /// nil when there is none.
    private func upgrading(_ hooks: [String: Any]) -> [String: Any]? {
        guard let stops = hooks[Self.event] as? [[String: Any]] else { return nil }
        var changed = false
        let upgraded = stops.map { group -> [String: Any] in
            guard let entries = group["hooks"] as? [Any] else { return group }
            var copy = group
            copy["hooks"] = entries.map { hook -> Any in
                guard isLunlet(hook), (hook as? [String: Any])?["command"] as? String != command else { return hook }
                changed = true
                return entry
            }
            return copy
        }
        guard changed else { return nil }
        var result = hooks
        result[Self.event] = upgraded
        return result
    }
    private func containsLunlet(_ hooks: [String: Any]) -> Bool {
        guard let stops = hooks[Self.event] as? [[String: Any]] else { return false }
        return stops.contains { ($0["hooks"] as? [Any])?.contains(where: isLunlet) == true }
    }

    public func state() throws -> ClaudeHookState {
        let settings = try readSettings()
        guard let hooks = try hooks(of: try document(settings)) else { return .notConnected }
        return containsLunlet(hooks) ? .connected : .notConnected
    }

    /// Each change is one read-modify-write run by the settings file's single editor, so it never overlaps the
    /// status line's and starts over when another writer changed the file underneath.
    public func connect() throws -> ClaudeHookState {
        try ClaudeSettingsEditor.edit(startingOverOn: ClaudeHookFailure.settingsChanged) { try connectOnce() }
    }
    public func disconnect() throws -> ClaudeHookState {
        try ClaudeSettingsEditor.edit(startingOverOn: ClaudeHookFailure.settingsChanged) { try disconnectOnce() }
    }

    private func connectOnce() throws -> ClaudeHookState {
        try installLauncher()
        let settings = try readSettings()
        afterRead?()
        let document = try document(settings)
        var hooks = try self.hooks(of: document) ?? [:]
        if containsLunlet(hooks) {
            // An entry an earlier build wrote gets this build's command where it stands; nothing else moves.
            guard let upgraded = upgrading(hooks) else { return .connected }
            hooks = upgraded
        } else {
            var stops = hooks[Self.event] as? [[String: Any]] ?? []
            stops.insert(["hooks": [entry]], at: 0)
            hooks[Self.event] = stops
        }
        let text = Self.render(hooks, indent: document == nil ? "  " : document?.style.indent, colon: document.map { String(decoding: $0.style.colon, as: UTF8.self) } ?? ": ")
        let updated = try document?.setting(Self.key, to: text)
            ?? Data(("{\n  " + (try ClaudeSettingsDocument.literal(Self.key)) + ": " + text + "\n}\n").utf8)
        try verify(updated, original: document?.object ?? [:], hooks: hooks)
        try replace(settings, with: updated)
        afterWrite?()
        return .connected
    }

    private func disconnectOnce() throws -> ClaudeHookState {
        let settings = try readSettings()
        afterRead?()
        let document = try document(settings)
        guard let document, var hooks = try hooks(of: document), containsLunlet(hooks) else { return .notConnected }
        var stops = (hooks[Self.event] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
            var copy = group
            let remaining = (group["hooks"] as? [Any] ?? []).filter { !isLunlet($0) }
            if remaining.isEmpty, (group["hooks"] as? [Any])?.isEmpty == false { return nil }
            copy["hooks"] = remaining
            return copy
        }
        stops.removeAll { ($0["hooks"] as? [Any])?.isEmpty == true && $0.count == 1 }
        if stops.isEmpty { hooks[Self.event] = nil } else { hooks[Self.event] = stops }
        let updated: Data
        if hooks.isEmpty {
            updated = try document.removing(Self.key)
        } else {
            let text = Self.render(hooks, indent: document.style.indent, colon: String(decoding: document.style.colon, as: UTF8.self))
            updated = try document.setting(Self.key, to: text)
        }
        try verify(updated, original: document.object, hooks: hooks.isEmpty ? nil : hooks)
        try replace(settings, with: updated)
        afterWrite?()
        return .notConnected
    }

    // MARK: Settings

    private struct SettingsFile { let url: URL; let data: Data?; let mode: mode_t }

    private func readSettings() throws -> SettingsFile {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: home.root.path, isDirectory: &directory), directory.boolValue else {
            throw ClaudeHookFailure.claudeDirectoryMissing
        }
        var info = stat()
        let url = home.settings.resolvingSymlinksInPath()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT, FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path)
            else { throw ClaudeHookFailure.claudeDirectoryMissing }
            return .init(url: url, data: nil, mode: 0o600)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= Self.maximumSettingsBytes else {
            throw ClaudeHookFailure.settingsUnreadable
        }
        do {
            return .init(url: url, data: try ClaudeStatusLineConnection.readOwnedFile(url, limit: Self.maximumSettingsBytes), mode: info.st_mode & 0o777)
        } catch { throw ClaudeHookFailure.settingsUnreadable }
    }
    private func document(_ settings: SettingsFile) throws -> ClaudeSettingsDocument? {
        guard let data = settings.data else { return nil }
        do {
            let document = try ClaudeSettingsDocument(data)
            _ = try document.valueText(Self.key)
            return document
        } catch { throw ClaudeHookFailure.settingsInvalid }
    }
    /// The `hooks` object, nil when absent; any other shape is refused rather than rewritten.
    private func hooks(of document: ClaudeSettingsDocument?) throws -> [String: Any]? {
        guard let document, let text = try document.valueText(Self.key) else { return nil }
        guard let value = ClaudeStatusLineConnection.value(text) as? [String: Any] else { throw ClaudeHookFailure.settingsInvalid }
        for (_, groups) in value where !(groups is [[String: Any]]) { throw ClaudeHookFailure.settingsInvalid }
        return value
    }
    /// Every other top-level key must be unchanged, and `hooks` must be exactly what was intended.
    private func verify(_ data: Data, original: [String: Any], hooks: [String: Any]?) throws {
        guard let edited = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeHookFailure.writeFailed }
        var before = original, after = edited
        before[Self.key] = nil
        let written = after.removeValue(forKey: Self.key)
        guard NSDictionary(dictionary: before).isEqual(to: after) else { throw ClaudeHookFailure.writeFailed }
        switch (written, hooks) {
        case (nil, nil): return
        case let (written?, hooks?): guard NSDictionary(dictionary: hooks).isEqual(to: written) else { throw ClaudeHookFailure.writeFailed }
        default: throw ClaudeHookFailure.writeFailed
        }
    }
    private func replace(_ settings: SettingsFile, with data: Data) throws {
        let latest = try readSettings()
        guard latest.url == settings.url, latest.data == settings.data else { throw ClaudeHookFailure.settingsChanged }
        do { try ClaudeStatusLineConnection.writeAtomically(data, to: settings.url, mode: settings.mode) }
        catch { throw ClaudeHookFailure.writeFailed }
    }
    private func installLauncher() throws {
        do {
            try HookSpool.createPrivateDirectory(spool.root)
            try HookSpool.writeAtomically(Data(HookSpool.launcherScript.utf8), to: spool.launcherURL, mode: 0o700)
        } catch { throw ClaudeHookFailure.storageUnavailable }
    }

    /// A JSON rendering of the `hooks` member in the document's style: sorted keys, one level deeper than the
    /// member itself, or on one line in a single-line document. Only this member is ever rendered.
    static func render(_ value: Any, indent: String?, colon: String, depth: Int = 1) -> String {
        let inner = indent.map { String(repeating: $0, count: depth + 1) }, outer = indent.map { String(repeating: $0, count: depth) }
        let open = inner.map { "\n" + $0 } ?? "", separator = inner.map { ",\n" + $0 } ?? ", ", close = outer.map { "\n" + $0 } ?? ""
        switch value {
        case let object as [String: Any]:
            guard !object.isEmpty else { return "{}" }
            let members = object.keys.sorted().map { key in
                ((try? ClaudeSettingsDocument.literal(key)) ?? "\"\"") + colon + render(object[key]!, indent: indent, colon: colon, depth: depth + 1)
            }
            return "{" + open + members.joined(separator: separator) + close + "}"
        case let array as [Any]:
            guard !array.isEmpty else { return "[]" }
            return "[" + open + array.map { render($0, indent: indent, colon: colon, depth: depth + 1) }.joined(separator: separator) + close + "]"
        case let text as String:
            return (try? ClaudeSettingsDocument.literal(text)) ?? "\"\""
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return (try? JSONSerialization.data(withJSONObject: number, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) } ?? "0"
        case is NSNull:
            return "null"
        default:
            return "null"
        }
    }
}

/// Whether Lunlet's hook is in Claude Code's settings, for the session monitor, which asks on every scan only to
/// word a note. The settings are read and parsed again only when the file changed.
final class ClaudeHookStateCache: @unchecked Sendable {
    private struct Stamp: Equatable { let device: Int32; let inode: UInt64; let size: Int64; let seconds: Int; let nanoseconds: Int }
    private let connection: ClaudeHookConnection
    private let lock = NSLock()
    private var stamp: Stamp?
    private var connected = false
    /// How often the settings were actually read.
    private(set) var reads = 0

    init(_ connection: ClaudeHookConnection) { self.connection = connection }

    func isConnected() -> Bool {
        // The file the connection edits: a linked settings file is judged at its target.
        var info = stat()
        guard stat(connection.home.settings.resolvingSymlinksInPath().path, &info) == 0 else {
            lock.lock(); defer { lock.unlock() }
            stamp = nil; connected = false
            return false
        }
        let current = Stamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                            seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
        lock.lock(); defer { lock.unlock() }
        if current == stamp { return connected }
        reads += 1
        connected = (try? connection.state()) == .connected
        stamp = current
        return connected
    }
}

/// What the launched app does for the hook: publishes its bundled helper and sweeps the folders of stops whose
/// helper is gone. It does not announce a running app: only the Claude session monitor answers stops, so only it
/// writes the app record, and a helper never waits on an app that is not listening. Claude Code's settings change
/// only through `ClaudeHookConnection`.
public enum ClaudeHookInstallation {
    public static func prepare(helper: URL?, spool: HookSpool = .standard()) {
        try? HookSpool.createPrivateDirectory(spool.root)
        if let helper, FileManager.default.isExecutableFile(atPath: helper.path) {
            try? HookSpool.writeAtomically(Data((helper.path + "\n").utf8), to: spool.helperPathFile)
        }
        // A launcher Claude Code already names is kept current with this build's script.
        if FileManager.default.fileExists(atPath: spool.launcherURL.path),
           (try? Data(contentsOf: spool.launcherURL)) != Data(HookSpool.launcherScript.utf8) {
            try? HookSpool.writeAtomically(Data(HookSpool.launcherScript.utf8), to: spool.launcherURL, mode: 0o700)
        }
        sweepStale(spool: spool, isProcessAlive: { kill($0, 0) == 0 })
    }

    /// Removes what a gone helper left, stop by stop. A stop whose signal names a live helper keeps every file. A
    /// stop whose helper is gone loses its signal and verdicts at once. A follow-up request or receipt, which the
    /// reply path may still be reading, a file with no signal beside it and an empty folder go only once they are
    /// older than `grace`, so nothing a helper or the reply path is using right now is taken away. Folders of the
    /// `keeping` sessions stay even when empty, because the running monitor watches them.
    public static func sweepStale(spool: HookSpool, isProcessAlive: (Int32) -> Bool, keeping: Set<UUID> = [],
                                  now: Date = Date(), grace: TimeInterval = 60) {
        func isOld(_ url: URL) -> Bool {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return false }
            return now.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > grace
        }
        let verdicts = [HookSpool.signalSuffix, HookSpool.holdSuffix, HookSpool.releaseSuffix]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: spool.stopsDirectory.path)) ?? [] {
            guard let session = UUID(uuidString: name) else { continue }
            let directory = spool.stopDirectory(session)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            var live = Set<String>(), gone = Set<String>()
            for file in files where file.hasSuffix(HookSpool.signalSuffix) && !file.hasPrefix(".") {
                let stop = String(file.dropLast(HookSpool.signalSuffix.count))
                if let data = try? HookSpool.readSmall(directory.appendingPathComponent(file, isDirectory: false)),
                   let signal = try? HookSpool.decoder.decode(HookSpool.StopSignal.self, from: data), isProcessAlive(signal.pid) {
                    live.insert(stop)
                } else { gone.insert(stop) }
            }
            for file in files {
                // Every file of a stop starts with its id; a temporary sibling has a leading dot before it.
                let stop = file.split(separator: ".").first.map(String.init) ?? file
                guard !live.contains(stop) else { continue }
                let url = directory.appendingPathComponent(file, isDirectory: false)
                let left = gone.contains(stop) && !file.hasPrefix(".") && verdicts.contains(where: file.hasSuffix)
                if left || isOld(url) { try? FileManager.default.removeItem(at: url) }
            }
            // Succeeds only for an empty folder.
            if !keeping.contains(session), isOld(directory) { rmdir(directory.path) }
        }
    }
}
