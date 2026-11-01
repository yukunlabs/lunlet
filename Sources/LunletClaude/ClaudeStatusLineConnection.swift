// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.08, AC-33.07; US-04, AC-04.03.
import Darwin
import Foundation

/// Whether Claude Code runs Lunlet's status line, judged from Claude's settings and Lunlet's backup.
public enum ClaudeStatusLineState: Equatable, Sendable {
    case notConnected
    case connected
    /// Lunlet connected earlier, but the status line was changed afterwards; Lunlet leaves it unchanged.
    case changedOutsideLunlet
}

public enum ClaudeStatusLineFailure: Error, Equatable, Sendable {
    /// No Claude Code configuration directory; Lunlet does not create one.
    case claudeDirectoryMissing
    case settingsUnreadable
    /// Not a strict JSON object, or `statusLine` appears twice; nothing is written.
    case settingsInvalid
    /// An existing status line that is not a `command`; Lunlet cannot chain it, so it is not replaced.
    case unsupportedStatusLine
    /// The settings changed while Lunlet was editing them; nothing is written.
    case settingsChanged
    case storageUnavailable
    case writeFailed
}

/// The explicit connect and disconnect actions. Only the `statusLine` member of `settings.json` changes, only on
/// request: connecting backs up the previous value (or its absence) and chains its command; disconnecting restores
/// exactly that value. A status line changed after connecting is never overwritten. No credential is read.
public struct ClaudeStatusLineConnection: Sendable {
    public let home: ClaudeHome
    public let location: ClaudeStatusLineLocation
    static let key = "statusLine"
    private static let maximumSettingsBytes = 4 * 1_048_576

    public init(home: ClaudeHome = .current(), location: ClaudeStatusLineLocation = .standard) {
        self.home = home; self.location = location
    }

    public func state() throws -> ClaudeStatusLineState {
        let settings = try readSettings()
        let current = try document(settings)?.valueText(Self.key)
        if isLunlet(current) { return .connected }
        if let backup = readBackup(), !Self.equivalent(current, backup.previous) { return .changedOutsideLunlet }
        return .notConnected
    }

    public func connect() throws -> ClaudeStatusLineState {
        let settings = try readSettings()
        let document = try document(settings)
        let current = try document?.valueText(Self.key)
        if isLunlet(current) { try install(); return .connected }
        var previousCommand: String?, carried: [(String, String)] = []
        if let current {
            guard let value = Self.value(current) as? [String: Any], value["type"] as? String == "command",
                  let command = value["command"] as? String, !command.isEmpty, command.utf8.count <= 65_536 else {
                throw ClaudeStatusLineFailure.unsupportedStatusLine
            }
            previousCommand = command
            // The replaced line keeps its spacing and timer; Lunlet's extraction runs on the same schedule.
            for name in ["padding", "refreshInterval"] {
                if let number = value[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                   number.doubleValue.isFinite, number.doubleValue >= 0, let text = Self.text(number) {
                    carried.append((name, text))
                }
            }
        }
        // A new file uses Claude Code's own two-space style; an existing one keeps its indentation or single line.
        let indent: String? = document.map { $0.style.indent } ?? "  "
        let colon = document.map { String(decoding: $0.style.colon, as: UTF8.self) } ?? ": "
        let installed = try Self.render(command: location.command, carried: carried, indent: indent, colon: colon)
        // The script exists before Claude Code's settings name it.
        try install()
        try writeBackup(.init(version: 1, settingsPath: settings.url.path, fileExisted: settings.data != nil,
                              previous: current, previousCommand: previousCommand, installed: installed))
        do {
            let updated = try document?.setting(Self.key, to: installed)
                ?? Data(("{\n  " + (try ClaudeSettingsDocument.literal(Self.key)) + ": " + installed + "\n}\n").utf8)
            try verify(updated, original: document?.object ?? [:], statusLine: installed)
            try replace(settings, with: updated)
        } catch {
            unlink(location.backup.path)
            throw error
        }
        return .connected
    }

    public func disconnect() throws -> ClaudeStatusLineState {
        let settings = try readSettings()
        let document = try document(settings)
        let current = try document?.valueText(Self.key)
        let backup = readBackup()
        guard let document, isLunlet(current) else {
            if let backup, !Self.equivalent(current, backup.previous) { return .changedOutsideLunlet }
            removeLunletFiles(keepScript: current?.contains(location.script.path) == true)
            return .notConnected
        }
        var updated: Data?
        if let previous = backup?.previous {
            updated = try document.setting(Self.key, to: previous)
        } else {
            let removed = try document.removing(Self.key)
            // A settings file that Lunlet created holds nothing else, so it is removed rather than left empty.
            let empty = (try? JSONSerialization.jsonObject(with: removed) as? [String: Any])?.isEmpty == true
            updated = backup?.fileExisted == false && empty ? nil : removed
        }
        if let updated { try verify(updated, original: document.object, statusLine: backup?.previous) }
        try replace(settings, with: updated)
        removeLunletFiles(keepScript: false)
        return .notConnected
    }

    /// After an outside change, drops only Lunlet's backup; Claude Code's settings stay as they are.
    public func forget() throws -> ClaudeStatusLineState {
        unlink(location.backup.path)
        return try state()
    }

    /// Rewrites an outdated installed script, so a Lunlet update takes effect while the setting stays unchanged.
    public func updateInstalledScript() throws {
        guard try state() == .connected else { return }
        if (try? Data(contentsOf: location.script)) != Data(ClaudeStatusLineScript.source.utf8) { try install() }
    }

    // MARK: Settings

    private struct SettingsFile { let url: URL; let data: Data?; let mode: mode_t }

    private func readSettings() throws -> SettingsFile {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: home.root.path, isDirectory: &directory), directory.boolValue else {
            throw ClaudeStatusLineFailure.claudeDirectoryMissing
        }
        var info = stat()
        // A linked settings file, as dotfile managers create, is edited at its target.
        let url = home.settings.resolvingSymlinksInPath()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT, FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path)
            else { throw ClaudeStatusLineFailure.claudeDirectoryMissing }
            return .init(url: url, data: nil, mode: 0o600)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= Self.maximumSettingsBytes else {
            throw ClaudeStatusLineFailure.settingsUnreadable
        }
        do {
            return .init(url: url, data: try Self.readOwnedFile(url, limit: Self.maximumSettingsBytes), mode: info.st_mode & 0o777)
        } catch { throw ClaudeStatusLineFailure.settingsUnreadable }
    }

    private func document(_ settings: SettingsFile) throws -> ClaudeSettingsDocument? {
        guard let data = settings.data else { return nil }
        do {
            let document = try ClaudeSettingsDocument(data)
            _ = try document.valueText(Self.key)
            return document
        } catch { throw ClaudeStatusLineFailure.settingsInvalid }
    }

    private func isLunlet(_ text: String?) -> Bool {
        guard let text, let value = Self.value(text) as? [String: Any] else { return false }
        return value["type"] as? String == "command" && value["command"] as? String == location.command
    }

    /// Every other top-level key must be unchanged, and `statusLine` must be exactly what was intended.
    private func verify(_ data: Data, original: [String: Any], statusLine: String?) throws {
        guard let edited = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeStatusLineFailure.writeFailed
        }
        var before = original, after = edited
        before[Self.key] = nil
        let written = after.removeValue(forKey: Self.key)
        guard NSDictionary(dictionary: before).isEqual(to: after),
              Self.equivalent(written.map { $0 as AnyObject }, statusLine.flatMap(Self.value).map { $0 as AnyObject })
        else { throw ClaudeStatusLineFailure.writeFailed }
    }

    /// Atomically replaces, or removes, the settings file, but only while it still holds the bytes that were read.
    private func replace(_ settings: SettingsFile, with data: Data?) throws {
        let latest = try readSettings()
        guard latest.url == settings.url, latest.data == settings.data else { throw ClaudeStatusLineFailure.settingsChanged }
        guard let data else {
            guard unlink(settings.url.path) == 0 else { throw ClaudeStatusLineFailure.writeFailed }
            return
        }
        try Self.writeAtomically(data, to: settings.url, mode: settings.mode)
    }

    // MARK: Lunlet's files

    private struct Backup: Codable {
        let version: Int
        let settingsPath: String
        let fileExisted: Bool
        /// The exact source text of the replaced value; nil when there was none.
        let previous: String?
        /// The replaced command, which the installed script runs with the same input.
        let previousCommand: String?
        let installed: String
    }

    private func readBackup() -> Backup? {
        guard let data = try? Self.readOwnedFile(location.backup, limit: 262_144),
              let backup = try? JSONDecoder().decode(Backup.self, from: data), backup.version == 1 else { return nil }
        return backup
    }

    private func writeBackup(_ backup: Backup) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(backup) else { throw ClaudeStatusLineFailure.storageUnavailable }
        try Self.writeAtomically(data, to: location.backup, mode: 0o600)
    }

    /// Creates Lunlet's private directory and writes the current script.
    private func install() throws {
        do {
            try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw ClaudeStatusLineFailure.storageUnavailable }
        var info = stat()
        guard lstat(location.directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw ClaudeStatusLineFailure.storageUnavailable
        }
        chmod(location.directory.path, 0o700)
        try Self.writeAtomically(Data(ClaudeStatusLineScript.source.utf8), to: location.script, mode: 0o600)
    }

    /// The script stays while a status line the owner wrote still names it.
    private func removeLunletFiles(keepScript: Bool) {
        for url in [location.backup, location.limits, location.weeklyLog] { unlink(url.path) }
        if !keepScript { unlink(location.script.path); rmdir(location.directory.path) }
    }

    // MARK: Helpers

    static func writeAtomically(_ data: Data, to url: URL, mode: mode_t) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".lunlet-"
            + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw ClaudeStatusLineFailure.writeFailed }
        var written = true
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count <= 0 { written = false; return }
                offset += count
            }
        }
        let synced = fchmod(fd, mode) == 0 && fsync(fd) == 0
        close(fd)
        guard written, synced, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw ClaudeStatusLineFailure.writeFailed
        }
    }

    /// A bounded read of a regular file owned by this user; a link is refused, never followed.
    static func readOwnedFile(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ClaudeStatusLineFailure.storageUnavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw ClaudeStatusLineFailure.storageUnavailable
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ClaudeStatusLineFailure.storageUnavailable }
        return data
    }

    static func value(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }
    static func equivalent(_ a: String?, _ b: String?) -> Bool {
        equivalent(a.flatMap(value).map { $0 as AnyObject }, b.flatMap(value).map { $0 as AnyObject })
    }
    private static func equivalent(_ a: AnyObject?, _ b: AnyObject?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): a.isEqual(b)
        default: false
        }
    }
    private static func text(_ number: NSNumber) -> String? {
        (try? JSONSerialization.data(withJSONObject: number, options: .fragmentsAllowed))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// The installed value in the document's style: one member per line when it is indented, else on one line.
    static func render(command: String, carried: [(String, String)], indent: String?, colon: String) throws -> String {
        let members = [("type", try ClaudeSettingsDocument.literal("command")),
                       ("command", try ClaudeSettingsDocument.literal(command))] + carried
        let parts = try members.map { try ClaudeSettingsDocument.literal($0.0) + colon + $0.1 }
        guard let indent else { return "{" + parts.joined(separator: ", ") + "}" }
        return "{\n" + parts.map { indent + indent + $0 }.joined(separator: ",\n") + "\n" + indent + "}"
    }
}
