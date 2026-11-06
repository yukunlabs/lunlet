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

    public init(home: ClaudeHome = .current(), spool: HookSpool = .standard()) { self.home = home; self.spool = spool }

    /// The launcher's path as Claude Code's settings name it: under `$HOME` when it lives there, so a synced
    /// settings file still points at this user's folder on another machine.
    public var command: String {
        let path = spool.launcherURL.path, home = FileManager.default.homeDirectoryForCurrentUser.path
        let shown = path.hasPrefix(home + "/") ? "$HOME" + path.dropFirst(home.count) : path
        return "\"" + shown + "\""
    }
    var entry: [String: Any] {
        ["type": "command", "command": command, "timeout": Self.timeoutSeconds, "statusMessage": Self.statusMessage]
    }
    private func isLunlet(_ hook: Any) -> Bool {
        guard let hook = hook as? [String: Any], hook["type"] as? String == "command",
              let command = hook["command"] as? String else { return false }
        return command == self.command || command.contains("com.lunlet/hook/lunlet-hook")
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

    public func connect() throws -> ClaudeHookState {
        try installLauncher()
        let settings = try readSettings()
        let document = try document(settings)
        var hooks = try self.hooks(of: document) ?? [:]
        if containsLunlet(hooks) { return .connected }
        var stops = hooks[Self.event] as? [[String: Any]] ?? []
        stops.insert(["hooks": [entry]], at: 0)
        hooks[Self.event] = stops
        let text = Self.render(hooks, indent: document == nil ? "  " : document?.style.indent, colon: document.map { String(decoding: $0.style.colon, as: UTF8.self) } ?? ": ")
        let updated = try document?.setting(Self.key, to: text)
            ?? Data(("{\n  " + (try ClaudeSettingsDocument.literal(Self.key)) + ": " + text + "\n}\n").utf8)
        try verify(updated, original: document?.object ?? [:], hooks: hooks)
        try replace(settings, with: updated)
        return .connected
    }

    public func disconnect() throws -> ClaudeHookState {
        let settings = try readSettings()
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

/// What the running app does for the hook: announces itself, publishes its bundled helper and sweeps the folders
/// of stops whose helper is gone. Claude Code's settings change only through `ClaudeHookConnection`.
public enum ClaudeHookInstallation {
    public static func prepare(helper: URL?, spool: HookSpool = .standard(), pid: Int32 = getpid(), now: Date = Date()) {
        try? HookSpool.createPrivateDirectory(spool.root)
        if let encoded = try? HookSpool.encoder.encode(HookSpool.AppRecord(pid: pid, startedAt: now)) {
            try? HookSpool.writeAtomically(encoded, to: spool.appRecordURL)
        }
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

    /// Removes the app record at quit, so a hook that fires afterwards exits at once.
    public static func retire(spool: HookSpool = .standard()) {
        try? FileManager.default.removeItem(at: spool.appRecordURL)
    }

    /// Removes stop files whose helper process is gone; a live helper is waiting on the app's verdict.
    public static func sweepStale(spool: HookSpool, isProcessAlive: (Int32) -> Bool) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: spool.stopsDirectory.path)) ?? []
        for name in names {
            guard let session = UUID(uuidString: name) else { continue }
            let directory = spool.stopDirectory(session)
            var live = false
            for url in HookSpool.files(in: directory, suffix: HookSpool.signalSuffix) {
                if let data = try? HookSpool.readSmall(url), let signal = try? HookSpool.decoder.decode(HookSpool.StopSignal.self, from: data),
                   isProcessAlive(signal.pid) { live = true }
            }
            if !live { try? FileManager.default.removeItem(at: directory) }
        }
    }
}
