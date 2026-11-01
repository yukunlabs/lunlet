// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-03, AC-03.02, AC-03.03.
import Darwin
import Foundation
import SQLite3

/// Navigation evidence only; this never establishes Codex input authority.
struct SupersetSessionBindingReader {
    private let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".superset/host", isDirectory: true)
    }

    func matches(sessionID: UUID, destination: CodexTerminalDestination) -> Bool {
        guard let target = Self.target(destination), root.isFileURL,
              let rootIdentity = Self.identity(root, directory: true) else { return false }
        let budget = Budget()
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0, let directory = fdopendir(fd) else { if fd >= 0 { close(fd) }; return false }
        defer { closedir(directory) }
        var organizations: [URL] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name == "." || name == ".." { continue }
            guard organizations.count < 32, !budget.expired else { return false }
            organizations.append(root.appendingPathComponent(name, isDirectory: true))
            errno = 0
        }
        guard errno == 0, !organizations.isEmpty else { return false }
        var identities: [(URL, Identity, Bool)] = [(root, rootIdentity, true)]
        var absent: [URL] = []
        var matches: [(UUID, UUID)] = []
        for organization in organizations {
            guard !budget.expired else { return false }
            // A regular file such as .DS_Store cannot hold organization bindings.
            // Symbolic links and other entry types remain ambiguous.
            var entry = stat()
            guard lstat(organization.path, &entry) == 0 else { return false }
            if entry.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG) { continue }
            guard let owner = Self.identity(organization, directory: true) else { return false }
            identities.append((organization, owner, true))
            let file = organization.appendingPathComponent("host.db")
            // An organization without a database has no bindings; absence is rechecked below.
            if Self.missing(file) { absent.append(file); continue }
            guard let original = Self.identity(file, directory: false),
                  let sidecars = Self.sidecars(file) else { return false }
            identities.append((file, original, false))
            identities.append(contentsOf: sidecars.map { ($0.0, $0.1, false) })
            guard let rows = read(file, sessionID: sessionID, budget: budget) else { return false }
            matches.append(contentsOf: rows)
            guard matches.count <= 1 else { return false }
        }
        guard !budget.expired, identities.allSatisfy({ Self.identity($0.0, directory: $0.2) == $0.1 }),
              absent.allSatisfy(Self.missing), matches.count == 1 else { return false }
        return matches[0].0 == target.0 && matches[0].1 == target.1
    }

    private static func target(_ destination: CodexTerminalDestination) -> (UUID, UUID)? {
        guard destination.applicationID == "com.superset.desktop",
              let url = URLComponents(url: destination.revealURL, resolvingAgainstBaseURL: false),
              url.scheme == "superset", url.host == "v2-workspace", url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil, url.path.hasPrefix("/"),
              let workspace = uuid(String(url.path.dropFirst())) else { return nil }
        let items = url.queryItems ?? []
        guard items.allSatisfy({ $0.name == "terminalId" || $0.name == "focusRequestId" }),
              items.filter({ $0.name == "terminalId" }).count == 1,
              items.filter({ $0.name == "focusRequestId" }).count <= 1,
              let terminal = items.first(where: { $0.name == "terminalId" })?.value.flatMap(uuid) else { return nil }
        if let focus = items.first(where: { $0.name == "focusRequestId" }), focus.value.flatMap(uuid) == nil { return nil }
        return (workspace, terminal)
    }

    private struct Identity: Equatable {
        let device: Int32
        let inode: UInt64
        let mode: UInt16
    }
    private static func identity(_ url: URL, directory: Bool) -> Identity? {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_uid == getuid(),
              value.st_mode & UInt16(S_IFMT) == UInt16(directory ? S_IFDIR : S_IFREG),
              value.st_mode & UInt16(S_IRUSR) != 0,
              !directory || value.st_mode & UInt16(S_IXUSR) != 0,
              value.st_mode & 0o022 == 0 else { return nil }
        return .init(device: value.st_dev, inode: value.st_ino, mode: value.st_mode)
    }

    private static func missing(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) != 0 && errno == ENOENT
    }

    /// Keep normal WAL locking; never claim a changing database is immutable.
    private static func sidecars(_ file: URL) -> [(URL, Identity)]? {
        var result: [(URL, Identity)] = []
        for suffix in ["-wal", "-shm", "-journal"] {
            let url = URL(fileURLWithPath: file.path + suffix)
            var value = stat()
            if lstat(url.path, &value) != 0 {
                guard errno == ENOENT else { return nil }
                continue
            }
            guard let checked = identity(url, directory: false) else { return nil }
            result.append((url, checked))
        }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var header = [UInt8](repeating: 0, count: 100)
        guard pread(fd, &header, header.count, 0) == header.count else { return nil }
        // A read-only WAL connection may otherwise create shared-memory files.
        if header[18] == 2 || header[19] == 2 {
            guard result.contains(where: { $0.0.path == file.path + "-wal" }),
                  result.contains(where: { $0.0.path == file.path + "-shm" }) else { return nil }
        }
        return result
    }

    private final class Budget {
        let deadline = ContinuousClock.now + .milliseconds(250)
        var expired: Bool { ContinuousClock.now >= deadline }
    }

    private func read(_ file: URL, sessionID: UUID, budget: Budget) -> [(UUID, UUID)]? {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard status == SQLITE_OK, let handle else { if let handle { sqlite3_close(handle) }; return nil }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5)
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 65_536)
        sqlite3_limit(handle, SQLITE_LIMIT_SQL_LENGTH, 8_192)
        sqlite3_limit(handle, SQLITE_LIMIT_COLUMN, 128)
        // Apple's SQLite module does not expose extension loading. No plugins
        // or application-defined SQL functions are registered by this reader.
        sqlite3_progress_handler(handle, 1_000, { context in
            guard let context else { return 1 }
            return Unmanaged<Budget>.fromOpaque(context).takeUnretainedValue().expired ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        guard sqlite3_exec(handle, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; BEGIN", nil, nil, nil) == SQLITE_OK,
              schema(handle, table: "terminal_sessions", columns: [
                "id": "TEXT", "origin_workspace_id": "TEXT", "status": "TEXT", "custom_title": "TEXT",
                "created_at": "INTEGER", "last_attached_at": "INTEGER", "ended_at": "INTEGER", "dispose_requested_at": "INTEGER"
              ], primaryKey: "id"),
              schema(handle, table: "terminal_agent_bindings", columns: [
                "terminal_id": "TEXT", "workspace_id": "TEXT", "agent_id": "TEXT", "agent_session_id": "TEXT",
                "definition_id": "TEXT", "started_at": "INTEGER", "last_event_at": "INTEGER", "last_event_type": "TEXT",
                "ended_at": "INTEGER", "end_reason": "TEXT", "resumed_into_terminal_id": "TEXT", "transcript_path": "TEXT"
              ], primaryKey: "terminal_id") else { return nil }
        let sql = """
            SELECT b.workspace_id, b.terminal_id, t.origin_workspace_id
            FROM terminal_agent_bindings AS b JOIN terminal_sessions AS t ON t.id=b.terminal_id
            WHERE b.agent_session_id=? COLLATE NOCASE AND b.agent_id='codex'
              AND b.ended_at IS NULL AND b.end_reason IS NULL AND t.status='active'
              AND t.ended_at IS NULL AND t.dispose_requested_at IS NULL
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let bound = sessionID.uuidString.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard bound == SQLITE_OK else { return nil }
        var rows: [(UUID, UUID)] = []
        while true {
            guard !budget.expired else { return nil }
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return rows
            case SQLITE_ROW:
                guard rows.isEmpty, let workspace = Self.text(statement, 0).flatMap(Self.uuid),
                      let terminal = Self.text(statement, 1).flatMap(Self.uuid),
                      Self.text(statement, 2).flatMap(Self.uuid) == workspace else { return nil }
                rows.append((workspace, terminal))
            default: return nil
            }
        }
    }

    private func schema(_ db: OpaquePointer, table: String, columns: [String: String], primaryKey: String) -> Bool {
        var tableStatement: OpaquePointer?
        // Tables must be native b-trees, never views or executable virtual tables.
        guard sqlite3_prepare_v2(db, "SELECT rootpage FROM sqlite_master WHERE name=? AND type='table'", -1, &tableStatement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(tableStatement) }
        let bound = table.withCString { sqlite3_bind_text(tableStatement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard bound == SQLITE_OK, sqlite3_step(tableStatement) == SQLITE_ROW, sqlite3_column_int(tableStatement, 0) > 0,
              sqlite3_step(tableStatement) == SQLITE_DONE else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_xinfo('\(table)')", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        var actual: [String: String] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return actual == columns
            case SQLITE_ROW:
                guard actual.count < columns.count, let name = Self.text(statement, 1), let type = Self.text(statement, 2),
                      actual[name] == nil, sqlite3_column_int(statement, 6) == 0,
                      sqlite3_column_int(statement, 5) == (name == primaryKey ? 1 : 0) else { return false }
                actual[name] = type.uppercased()
            default: return false
            }
        }
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, sqlite3_column_bytes(statement, column) <= 256,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(bytes: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8)
    }
    private static func uuid(_ value: String) -> UUID? { value.utf8.count == 36 ? UUID(uuidString: value) : nil }
}
