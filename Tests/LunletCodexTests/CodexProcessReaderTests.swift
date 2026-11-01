// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-02, AC-02.08.
// Refs: US-03, AC-03.02, AC-03.03.
// Refs: US-02, AC-02.01, AC-02.04, AC-02.05; US-11, AC-11.06.
import Darwin
import Foundation
import Testing
@testable import LunletCodex

struct CodexProcessReaderTests {
    // Refs: US-02, AC-02.01, AC-02.05; US-03, AC-03.02.
    @Test func oneBoundedArgumentBufferServesDiscoveryWithoutEnvironmentValues() throws {
        var argc: Int32 = 2
        var buffer = withUnsafeBytes(of: &argc) { Data($0) }
        buffer.append(Data((["/synthetic/codex", "", "", "codex", "resume", "SECRET=synthetic-do-not-retain", ""]).joined(separator: "\0").utf8))
        #expect(CodexProcessReader.arguments(from: buffer) == ["codex", "resume"])
        var overstated = buffer
        argc = 9
        overstated.replaceSubrange(0..<4, with: withUnsafeBytes(of: &argc) { Data($0) })
        #expect(CodexProcessReader.arguments(from: overstated) == nil)
        #expect(CodexProcessReader.arguments(from: Data([1, 0, 0, 0])) == nil)
        // The shared native read returns this process's own launch arguments.
        let own = try #require(CodexProcessReader.argumentBuffer(getpid()))
        #expect(CodexProcessReader.arguments(from: own) == CommandLine.arguments)
        #expect(CodexDestinationReader.launchExecutable(own) != nil)
    }
    @Test func accountingRootsComeOnlyFromSessionRecordPaths() {
        #expect(CodexProcessReader.accountingRoot(for: URL(fileURLWithPath: "/synthetic/custom/sessions/2026/record.jsonl"))?.path == "/synthetic/custom")
        #expect(CodexProcessReader.accountingRoot(for: URL(fileURLWithPath: "/synthetic/custom/history/record.jsonl")) == nil)
        #expect(CodexProcessReader.accountingRoot(for: URL(fileURLWithPath: "/synthetic/custom/sessions/record.txt")) == nil)
    }

    @Test func noninteractiveLaunchesRemainObservationOnly() {
        for args in [["codex", "exec", "task"], ["codex", "review"], ["codex", "app-server"],
                     ["codex", "exec-server"], ["codex", "queue"], ["codex", "--", "app-server"]] {
            #expect(CodexProcessReader.role(arguments: args, terminalAttached: false) == .sharedRuntime)
        }
        #expect(CodexProcessReader.role(arguments: ["codex", "exec", "task"], terminalAttached: true) == .sharedRuntime)
    }

    // Refs: US-02, AC-02.01, AC-02.05: 0.166.0 aliases, tools and option values.
    @Test func codexCommandAliasesToolsAndOptionValuesAreClassifiedExactly() {
        for args in [["codex", "e", "task"], ["codex", "a"], ["codex", "login"], ["codex", "mcp", "list"], ["codex", "cloud"],
                     ["codex", "--local-provider", "synthetic", "exec", "task"], ["codex", "-i", "one.png", "two.png", "-m", "m", "exec"]] {
            #expect(!CodexProcessReader.isInteractive(arguments: args))
        }
        for args in [["codex"], ["codex", "resume"], ["codex", "fork"], ["codex", "--local-provider", "exec"],
                     ["codex", "-i", "one.png", "exec"], ["codex", "--image", "one.png", "two.png"], ["codex", "Fix the layout"]] {
            #expect(CodexProcessReader.isInteractive(arguments: args))
        }
    }

    @Test func terminalDescriptorsEstablishAttachmentWithoutAControllingTerminalFlag() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-terminal-\(UUID())/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let executable = directory.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let rollout = directory.appendingPathComponent("owned.jsonl")
        let helper = CodexSessionReaderTests()
        try (helper.header(helper.first) + helper.event("task_started", "owned-turn")).write(to: rollout)
        let output = try FileHandle(forWritingTo: rollout)
        defer { try? output.close() }
        var master: Int32 = -1, slave: Int32 = -1
        #expect(openpty(&master, &slave, nil, nil, nil) == 0)
        guard master >= 0, slave >= 0 else { return }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        defer { close(master); try? terminal.close() }
        let process = Process()
        process.executableURL = executable; process.arguments = ["30"]
        process.standardInput = terminal; process.standardOutput = terminal; process.standardError = output
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let info = try #require(CodexProcessReader.info(process.processIdentifier))
        #expect(info.pbi_flags & UInt32(PROC_FLAG_CONTROLT) == 0)
        #expect(CodexProcessReader.terminalAttached(process.processIdentifier, info: info))
        let scan = try CodexProcessReader().scan()
        let candidate = try #require(scan.candidates.first { $0.process.pid == process.processIdentifier })
        #expect(candidate.files.contains { $0.url.resolvingSymlinksInPath() == rollout.resolvingSymlinksInPath() })
        let file = try #require(candidate.files.first { $0.url.resolvingSymlinksInPath() == rollout.resolvingSymlinksInPath() })
        var reader = CodexSessionReader(file: file)
        let observed = try reader.read()
        #expect(observed.content.id == helper.first && observed.content.phase == .running && observed.content.turn == "owned-turn")

        // A shared/nonterminal service holding the same file is not a CLI owner.
        let service = Process()
        service.executableURL = executable; service.arguments = ["30"]
        service.standardInput = FileHandle.nullDevice; service.standardOutput = FileHandle.nullDevice; service.standardError = output
        try service.run()
        defer { if service.isRunning { service.terminate() }; service.waitUntilExit() }
        let next = try CodexProcessReader().scan()
        let observedService = try #require(next.candidates.first { $0.process.pid == service.processIdentifier })
        #expect(observedService.role == .sharedRuntime && observedService.files.contains(file))
    }
}

// Opt-in native compatibility probe: the manifest must identify only a dedicated synthetic CLI.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_OWNED_CODEX_SMOKE"] != nil))
func ownedDefaultDaemonCLIProvidesReadOnlyActivity() throws {
    let manifest = try #require(ProcessInfo.processInfo.environment["LUNLET_OWNED_CODEX_SMOKE"])
    let values = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifest))) as? [[String: String]])
    let value = try #require(values.first)
    let path = try #require(value["path"]), id = try #require(value["id"]), cwd = try #require(value["cwd"])
    #expect(cwd.hasSuffix("/.tmp/hook-validation"))
    let candidates = try CodexProcessReader().scan().candidates
    let owner = try #require(candidates.first { $0.files.contains { $0.url.path == path } })
    #expect(owner.role == .sharedRuntime)
    let file = try #require(owner.files.first { $0.url.path == path })
    var reader = CodexSessionReader(file: file)
    let result = try reader.read()
    #expect(result.content.id == UUID(uuidString: id))
    if case .idle = result.content.phase {} else { Issue.record("Expected dedicated completed-turn state") }
    print("Owned Codex 0.164.0 daemon activity: exact writable owner, UUID and completed turn verified")
}

// Refs: US-02, AC-02.08. Explicit native coverage check reads bounded rollout data; reports counts only, without identities or message text.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_LOCAL_CODEX_METADATA"] == "1"))
func localCodexWritableMetadataCoverage() throws {
    let scan = try CodexProcessReader().scan()
    let files = Set(scan.candidates.flatMap(\.files))
    var accepted = 0, desktop = 0, structured = 0
    for file in files.prefix(256) {
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 2_097_152) ?? Data()
        let first = bytes.prefix { $0 != 10 }
        guard let object = try? JSONSerialization.jsonObject(with: first) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let rawID = payload["id"] as? String, UUID(uuidString: rawID) != nil else { continue }
        var reader = CodexSessionReader(file: file)
        _ = try reader.read(); accepted += 1
        if (payload["originator"] as? String ?? "").localizedCaseInsensitiveContains("desktop") { desktop += 1 }
        if payload["source"] is [String: Any] { structured += 1 }
    }
    #expect(scan.complete)
    print("Local Codex metadata: \(scan.candidates.count) processes, \(files.count) writable records, \(accepted) accepted, \(desktop) Desktop-labelled, \(structured) structured sources")
}
