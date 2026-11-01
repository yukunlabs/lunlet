// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.01, AC-33.02, AC-33.03, AC-33.07.
import Darwin
import Foundation
import Testing
@testable import LunletClaude

struct ClaudeSessionRegistryTests {
    // Refs: US-33, AC-33.01, AC-33.07.
    @Test func liveRecordKeepsOnlyAllowlistedFields() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let url = try fixture.record(pid: 4242, session: ClaudeFixture.first.uppercased(), status: "waiting",
                                     waitingFor: "permission prompt")
        // Unrelated fields, including an environment-like value, are never retained.
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["env"] = ["SYNTHETIC_TOKEN": "synthetic-secret"]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let scan = try ClaudeSessionRegistry(directory: fixture.home.sessions).scan()
        #expect(scan.complete && scan.records.count == 1)
        let record = try #require(scan.records.first)
        #expect(record.pid == 4242 && record.sessionID == UUID(uuidString: ClaudeFixture.first))
        #expect(record.sessionName == ClaudeFixture.first && record.cwd == ClaudeFixture.cwd)
        #expect(record.processStart == ClaudeFixture.startDate && record.version == "2.1.314")
        #expect(record.status == "waiting" && record.waitingFor == "permission prompt")
        #expect(record.statusUpdatedAt == Date(timeIntervalSince1970: 1_793_354_405))
        #expect(!String(describing: record).contains("synthetic-secret"))
    }

    // Refs: US-33, AC-33.01.
    @Test func processStartUsesTheLstartFormInUTCAndRejectsOtherForms() {
        #expect(ClaudeProcessStart.date(from: "Fri Oct 30 10:00:00 2026") == ClaudeFixture.startDate)
        // `ps` pads single-digit days with a space.
        #expect(ClaudeProcessStart.date(from: "Mon Oct  5 09:07:03 2026") == Date(timeIntervalSince1970: 1_791_191_223))
        for invalid in ["1793354400000", "2026-10-30T10:00:00Z", "Fri Oct 31 10:00:00 2026x", "Fri Feb 30 10:00:00 2026",
                        "Xyz Oct 30 10:00:00 2026", "Fri Oct 30 25:00:00 2026", ""] {
            #expect(ClaudeProcessStart.date(from: invalid) == nil)
        }
    }

    // Refs: US-33, AC-33.01, AC-33.03.
    @Test func invalidStaleShapedAndForeignNamesNeverBind() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        // A numeric start time is not the recorded format: it stays unverified rather than guessed.
        try fixture.record(pid: 11, session: ClaudeFixture.first, procStart: 1_793_354_400_000)
        // The pid inside must match the file name.
        let mismatched = try fixture.record(pid: 12, session: ClaudeFixture.second)
        try FileManager.default.moveItem(at: mismatched, to: fixture.home.sessions.appendingPathComponent("13.json"))
        try Data("{}".utf8).write(to: fixture.home.sessions.appendingPathComponent("notes.json"))
        try Data("{\"pid\":14,\"sessionId\":\"not-a-uuid\"}".utf8).write(to: fixture.home.sessions.appendingPathComponent("14.json"))
        let scan = try ClaudeSessionRegistry(directory: fixture.home.sessions).scan()
        #expect(scan.complete)
        #expect(scan.records.count == 1 && scan.records.first?.processStart == nil)
    }

    // Refs: US-33, AC-33.03.
    @Test func tornRecordIsRetriedOnceThenLeftUnreadableWithoutFailingTheScan() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let url = try fixture.record(pid: 21, session: ClaudeFixture.first)
        let valid = try Data(contentsOf: url)
        var loads = 0
        let healed = ClaudeSessionRegistry.read(url, pid: 21) { _ in
            loads += 1; return loads == 1 ? .data(valid.prefix(20)) : .data(valid)
        }
        #expect(loads == 2)
        guard case .record(let record) = healed else { Issue.record("torn record was not retried"); return }
        #expect(record.pid == 21)
        try valid.prefix(20).write(to: url)
        let scan = try ClaudeSessionRegistry(directory: fixture.home.sessions).scan()
        #expect(!scan.complete && scan.records.isEmpty)
    }

    // Refs: US-33, AC-33.07.
    @Test func oversizedLinkedAndMissingRecordsAreBounded() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let big = fixture.home.sessions.appendingPathComponent("31.json")
        try Data(repeating: 32, count: ClaudeSessionRegistry.maximumBytes + 1).write(to: big)
        let target = try fixture.record(pid: 99, session: ClaudeFixture.first)
        let moved = fixture.root.appendingPathComponent("elsewhere.json")
        try FileManager.default.moveItem(at: target, to: moved)
        try FileManager.default.createSymbolicLink(at: fixture.home.sessions.appendingPathComponent("32.json"),
                                                   withDestinationURL: moved)
        let scan = try ClaudeSessionRegistry(directory: fixture.home.sessions).scan()
        #expect(!scan.complete && scan.records.isEmpty)
        let absent = ClaudeSessionRegistry(directory: fixture.root.appendingPathComponent("missing"))
        let empty = try absent.scan()
        #expect(empty.complete && empty.records.isEmpty)
    }
}

struct ClaudeProcessReaderTests {
    // Refs: US-33, AC-33.01.
    @Test func onlyClaudeCodeExecutablesAreAccepted() {
        let none: () -> String? = { nil }
        #expect(ClaudeProcessReader.isClaudeExecutable("/Users/synthetic/.local/share/claude/versions/2.1.314", script: none))
        #expect(ClaudeProcessReader.isClaudeExecutable("/Users/synthetic/.local/bin/claude", script: none))
        #expect(ClaudeProcessReader.isClaudeExecutable("/opt/homebrew/bin/node") {
            "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        })
        #expect(!ClaudeProcessReader.isClaudeExecutable("/opt/homebrew/bin/node") { "/tmp/other/cli.js" })
        #expect(!ClaudeProcessReader.isClaudeExecutable("/usr/bin/python3", script: none))
        #expect(!ClaudeProcessReader.isClaudeExecutable("/Users/synthetic/other/versions/2.1.314", script: none))
    }

    // Refs: US-33, AC-33.07.
    @Test func interpreterScriptIsTheOnlyDecodedArgument() {
        var bytes = withUnsafeBytes(of: Int32(3)) { Array($0) }
        bytes += Array("/opt/homebrew/bin/node".utf8) + [0, 0, 0]
        bytes += Array("node".utf8) + [0] + Array("/synthetic/@anthropic-ai/claude-code/cli.js".utf8) + [0]
        bytes += Array("private prompt text".utf8) + [0] + Array("SYNTHETIC_TOKEN=secret".utf8) + [0]
        #expect(ClaudeProcessReader.scriptArgument(from: Data(bytes)) == "/synthetic/@anthropic-ai/claude-code/cli.js")
        let single = withUnsafeBytes(of: Int32(1)) { Array($0) } + Array("/bin/claude".utf8) + [0, 0] + Array("claude".utf8) + [0]
        #expect(ClaudeProcessReader.scriptArgument(from: Data(single)) == nil)
    }

    // Refs: US-33, AC-33.01, AC-33.03.
    @Test func liveProcessNeedsMatchingStartTimeAndClaudeExecutable() throws {
        let reader = ClaudeProcessReader()
        let own = try #require(ClaudeProcessReader.info(getpid()))
        let start = Date(timeIntervalSince1970: TimeInterval(own.pbi_start_tvsec))
        // This test process is the same user and start time but not Claude Code.
        #expect(reader.verify(pid: getpid(), startedAt: start) == .stale)
        #expect(reader.verify(pid: getpid(), startedAt: start.addingTimeInterval(-30)) == .stale)
        #expect(reader.verify(pid: Int32.max, startedAt: start) == .stale)
        #expect(reader.presence(of: ClaudeProcessReader.identity(own)) == .same)
        #expect(reader.presence(of: .init(pid: getpid(), seconds: own.pbi_start_tvsec + 5, microseconds: 0)) == .ended)
    }
}
