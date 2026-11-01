// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-03, AC-03.02, AC-03.03.
import Darwin
import Foundation
import SQLite3
import Testing
@testable import LunletCodex

private let bindingSession = "11111111-1111-4111-8111-111111111111"
private let bindingWorkspace = "22222222-2222-4222-8222-222222222222"
private let bindingTerminal = "33333333-3333-4333-8333-333333333333"
private let otherTerminal = "44444444-4444-4444-8444-444444444444"

private final class SupersetBindingFixture {
    enum Failure: Error { case sqlite }
    let root: URL
    private var connections: [OpaquePointer] = []
    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-binding-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let resolved = realpath(directory.path, nil) else { throw Failure.sqlite }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
    deinit {
        for db in connections { sqlite3_close(db) }
        try? FileManager.default.removeItem(at: root)
    }
    func database(_ organization: String = "organization", wal: Bool = false) throws -> OpaquePointer {
        let directory = root.appendingPathComponent(organization)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("host.db").path, &connection) == SQLITE_OK,
              let connection else { throw Failure.sqlite }
        connections.append(connection)
        try execute(connection, "PRAGMA journal_mode = \(wal ? "WAL" : "DELETE"); PRAGMA wal_autocheckpoint = 0;")
        try execute(connection, """
            CREATE TABLE terminal_sessions (
                id TEXT PRIMARY KEY, origin_workspace_id TEXT, status TEXT NOT NULL DEFAULT 'active', custom_title TEXT,
                created_at INTEGER NOT NULL, last_attached_at INTEGER, ended_at INTEGER, dispose_requested_at INTEGER);
            CREATE TABLE terminal_agent_bindings (
                terminal_id TEXT PRIMARY KEY REFERENCES terminal_sessions(id), workspace_id TEXT NOT NULL,
                agent_id TEXT NOT NULL, agent_session_id TEXT, definition_id TEXT, started_at INTEGER NOT NULL,
                last_event_at INTEGER NOT NULL, last_event_type TEXT NOT NULL, ended_at INTEGER, end_reason TEXT,
                resumed_into_terminal_id TEXT, transcript_path TEXT);
            INSERT INTO terminal_sessions (id, origin_workspace_id, created_at)
                VALUES ('\(bindingTerminal)', '\(bindingWorkspace)', 100);
            INSERT INTO terminal_agent_bindings
                (terminal_id, workspace_id, agent_id, agent_session_id, started_at, last_event_at, last_event_type)
                VALUES ('\(bindingTerminal)', '\(bindingWorkspace)', 'codex', '\(bindingSession)', 100, 200, 'Start');
            """)
        return connection
    }
    func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.sqlite }
    }
    var destination: CodexTerminalDestination {
        .init(applicationID: "com.superset.desktop", applicationURL: URL(fileURLWithPath: "/synthetic/Superset.app"),
              applicationPID: 42, revealURL: URL(string: "superset://v2-workspace/\(bindingWorkspace)?terminalId=\(bindingTerminal)&focusRequestId=\(otherTerminal)")!)
    }
    func matches(_ destination: CodexTerminalDestination? = nil) -> Bool {
        SupersetSessionBindingReader(root: root).matches(sessionID: UUID(uuidString: bindingSession)!, destination: destination ?? self.destination)
    }
}

struct SupersetSessionBindingReaderTests {
    @Test(arguments: [false, true])
    func exactActiveBindingMatchesInRollbackAndWALDatabases(wal: Bool) throws {
        let fixture = try SupersetBindingFixture()
        _ = try fixture.database(wal: wal)
        #expect(fixture.matches())
    }

    @Test(arguments: [
        "UPDATE terminal_agent_bindings SET ended_at=300, end_reason='detached'",
        "UPDATE terminal_sessions SET status='exited'",
        "UPDATE terminal_sessions SET dispose_requested_at=300",
        "UPDATE terminal_sessions SET ended_at=300",
        "UPDATE terminal_agent_bindings SET agent_id='claude'",
        "UPDATE terminal_agent_bindings SET workspace_id='invalid'",
        "UPDATE terminal_sessions SET origin_workspace_id='44444444-4444-4444-8444-444444444444'",
        "UPDATE terminal_agent_bindings SET agent_session_id='invalid'"
    ])
    func inactiveOrMismatchedMetadataCannotEstablishNavigation(change: String) throws {
        let fixture = try SupersetBindingFixture(), db = try fixture.database()
        try fixture.execute(db, change)
        #expect(!fixture.matches())
    }

    @Test func duplicateLiveBindingsAcrossOrganizationsNeverSelectTheNewest() throws {
        let fixture = try SupersetBindingFixture()
        _ = try fixture.database()
        let other = try fixture.database("other-organization")
        try fixture.execute(other, "UPDATE terminal_agent_bindings SET last_event_at=999999")
        #expect(!fixture.matches())
        try fixture.execute(other, "UPDATE terminal_agent_bindings SET ended_at=300, end_reason='detached'")
        #expect(fixture.matches())
    }

    @Test(arguments: [
        "ALTER TABLE terminal_sessions RENAME COLUMN dispose_requested_at TO unexpected",
        "ALTER TABLE terminal_agent_bindings ADD COLUMN unexpected TEXT",
        "ALTER TABLE terminal_agent_bindings ADD COLUMN unexpected TEXT GENERATED ALWAYS AS ('synthetic') VIRTUAL"
    ])
    func unknownSchemaFailsClosed(change: String) throws {
        let fixture = try SupersetBindingFixture(), db = try fixture.database()
        try fixture.execute(db, change)
        #expect(!fixture.matches())
    }

    @Test func unreadableAndSymlinkedDatabasesFailClosed() throws {
        let fixture = try SupersetBindingFixture()
        _ = try fixture.database()
        let file = fixture.root.appendingPathComponent("organization/host.db")
        #expect(chmod(file.path, 0) == 0)
        #expect(!fixture.matches())
        #expect(chmod(file.path, 0o600) == 0)
        let moved = fixture.root.appendingPathComponent("organization/real.db")
        try FileManager.default.moveItem(at: file, to: moved)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: moved)
        #expect(!fixture.matches())
    }

    @Test func strayFilesAndOrganizationsWithoutADatabaseDoNotHideAUniqueBinding() throws {
        let fixture = try SupersetBindingFixture()
        _ = try fixture.database()
        try Data("synthetic".utf8).write(to: fixture.root.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("missing-database"), withIntermediateDirectories: true)
        #expect(fixture.matches())
        // A database path of another type or a linked organization remains ambiguous.
        let shadow = fixture.root.appendingPathComponent("missing-database/host.db")
        try FileManager.default.createDirectory(at: shadow, withIntermediateDirectories: false)
        #expect(!fixture.matches())
        try FileManager.default.removeItem(at: shadow)
        let linked = fixture.root.appendingPathComponent("linked-organization")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.root.appendingPathComponent("organization"))
        #expect(!fixture.matches())
        try FileManager.default.removeItem(at: linked)
        #expect(fixture.matches())
    }

    @Test func incompleteOrOversizedOrganizationDiscoveryFailsClosed() throws {
        let fixture = try SupersetBindingFixture()
        #expect(!fixture.matches())
        _ = try fixture.database()
        for index in 0..<32 {
            try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("extra-\(index)"), withIntermediateDirectories: true)
        }
        #expect(!fixture.matches())
        let missing = SupersetSessionBindingReader(root: fixture.root.appendingPathComponent("absent"))
        #expect(!missing.matches(sessionID: UUID(uuidString: bindingSession)!, destination: fixture.destination))
    }

    @Test(arguments: [
        "superset://v2-workspace/22222222-2222-4222-8222-222222222222?terminalId=44444444-4444-4444-8444-444444444444",
        "superset://v2-workspace/44444444-4444-4444-8444-444444444444?terminalId=33333333-3333-4333-8333-333333333333",
        "superset://v2-workspace/invalid?terminalId=33333333-3333-4333-8333-333333333333",
        "superset://v2-workspace/22222222-2222-4222-8222-222222222222?terminalId=invalid",
        "superset://v2-workspace/22222222-2222-4222-8222-222222222222?terminalId=33333333-3333-4333-8333-333333333333&terminalId=33333333-3333-4333-8333-333333333333",
        "superset://v2-workspace/22222222-2222-4222-8222-222222222222?terminalId=33333333-3333-4333-8333-333333333333&command=unsafe",
        "iterm2:reveal?sessionid=33333333-3333-4333-8333-333333333333"
    ])
    func revealMustIdentifyOnlyTheExpectedExistingWorkspaceAndTerminal(url: String) throws {
        let fixture = try SupersetBindingFixture()
        _ = try fixture.database()
        let original = fixture.destination
        let destination = CodexTerminalDestination(applicationID: original.applicationID, applicationURL: original.applicationURL,
            applicationPID: original.applicationPID, revealURL: URL(string: url)!)
        #expect(!fixture.matches(destination))
        let unsupported = CodexTerminalDestination(applicationID: "unsupported.host", applicationURL: original.applicationURL,
            applicationPID: original.applicationPID, revealURL: original.revealURL)
        #expect(!fixture.matches(unsupported))
    }
}
