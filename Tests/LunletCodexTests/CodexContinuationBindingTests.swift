// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-08, AC-08.01, AC-08.03; US-09, AC-09.03; US-10, AC-10.04; US-11, AC-11.03, AC-11.04, AC-11.06.
import Darwin
import Foundation
import MachO
import Testing
import LunletCore
@testable import LunletCodex

/// Process facts keyed by PID, so a reused PID with another start time is a different process.
private final class LiveProcesses: CodexProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var candidates: [CodexProcessCandidate] = []
    private var live: [Int32: CodexProcessIdentity] = [:]
    private var image: URL? = URL(fileURLWithPath: "/synthetic/codex/bin/codex")
    func set(_ values: [CodexProcessCandidate]) {
        lock.withLock { candidates = values; live = Dictionary(uniqueKeysWithValues: values.map { ($0.process.pid, $0.process) }) }
    }
    func exit(_ pid: Int32) { lock.withLock { candidates.removeAll { $0.process.pid == pid }; live[pid] = nil } }
    func hideImage() { lock.withLock { image = nil } }
    func scan() throws -> CodexProcessScan { lock.withLock { .init(candidates: candidates, complete: true) } }
    func presence(of process: CodexProcessIdentity) -> CodexProcessPresence {
        lock.withLock { live[process.pid] == process ? .same : .ended }
    }
    func executable(of process: CodexProcessIdentity) -> URL? {
        lock.withLock { live[process.pid] == process ? image : nil }
    }
}

private actor Updates {
    private(set) var snapshots: [SessionSnapshot] = []
    func append(_ update: SessionUpdate) { if case .snapshot(let value, _) = update { snapshots.append(value) } }
}

struct CodexContinuationBindingTests {
    let helper = CodexSessionReaderTests()
    let original = CodexProcessIdentity(pid: 42, seconds: 100, microseconds: 0)

    /// A started monitor with one terminal-attached CLI that owns only this record.
    private func monitor(_ content: Data, role: CodexProcessRole = .terminalCLI)
        async throws -> (CodexSessionMonitor, LiveProcesses, CodexRolloutFile, URL, UUID, Task<Void, Never>) {
        let (root, file) = try helper.fixture(content)
        let processes = LiveProcesses()
        processes.set([.init(process: original, files: [file], role: role)])
        let monitor = CodexSessionMonitor(processes: processes)
        let updates = Updates(), stream = await monitor.updates()
        let sink = Task { for await update in stream { await updates.append(update) } }
        await monitor.refresh()
        for _ in 0..<1_000 where await updates.snapshots.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        let connection = try #require(await updates.snapshots.last?.observation.connectionID)
        return (monitor, processes, file, root, connection, sink)
    }
    private func completed(_ turn: String = "turn_one") throws -> Data {
        try helper.header(helper.first) + helper.event("task_started", turn) + helper.event("task_complete", turn)
    }

    @Test func anIdleTerminalCLIAtTheCardsTurnIsBoundToItsOwnImageHomeAndRecord() async throws {
        let (monitor, _, file, root, connection, sink) = try await monitor(completed())
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .bound(let binding) = await monitor.continuationBinding(sessionID: helper.first, connectionID: connection,
                                                                           completedTurnID: "turn_one") else {
            Issue.record("An idle CLI at the card's turn must be bound"); return
        }
        #expect(binding.process == original && binding.rollout.isSamePath(as: file))
        #expect(binding.executable.path == "/synthetic/codex/bin/codex")
        #expect(binding.codexHome.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path)
        await monitor.shutdown(); await sink.value
    }

    @Test func otherTurnsLaterStatesAndOtherConnectionsAreRefused() async throws {
        let (monitor, processes, file, root, connection, sink) = try await monitor(completed())
        defer { try? FileManager.default.removeItem(at: root) }
        let first = helper.first
        func binding(_ connectionID: UUID? = nil, turn: String = "turn_one") async -> CodexBindingResult {
            await monitor.continuationBinding(sessionID: first, connectionID: connectionID ?? connection, completedTurnID: turn)
        }
        #expect(await binding(turn: "turn_zero") == .refused(.superseded))
        #expect(await binding(UUID()) == .refused(.sessionEnded))
        // New input typed on the Mac, then a running turn, are new work.
        try helper.append(helper.line("response_item", ["type": "message", "role": "user", "id": "typed",
                                                        "content": [["type": "input_text", "text": "Next"]]]), to: file)
        #expect(await binding() == .refused(.sessionRunning))
        try helper.append(helper.event("task_started", "turn_two"), to: file)
        #expect(await binding() == .refused(.sessionRunning))
        try helper.append(helper.event("task_complete", "turn_two"), to: file)
        #expect(await binding() == .refused(.superseded))
        processes.hideImage()
        #expect(await binding(turn: "turn_two") == .refused(.unverified))
        await monitor.shutdown(); await sink.value
    }

    @Test func aReusedPIDWithAnotherStartTimeOrAnExitedProcessEndsTheBinding() async throws {
        for reuse in [true, false] {
            let (monitor, processes, file, root, connection, sink) = try await monitor(completed())
            defer { try? FileManager.default.removeItem(at: root) }
            if reuse {
                let successor = CodexProcessIdentity(pid: original.pid, seconds: original.seconds + 60, microseconds: 0)
                processes.set([.init(process: successor, files: [file])])
            } else {
                processes.exit(original.pid)
            }
            #expect(await monitor.continuationBinding(sessionID: helper.first, connectionID: connection,
                                                      completedTurnID: "turn_one") == .refused(.sessionEnded))
            await monitor.shutdown(); await sink.value
        }
    }

    @Test func aSharedRuntimeIsObservedButNeverBound() async throws {
        let (monitor, _, _, root, connection, sink) = try await monitor(completed(), role: .sharedRuntime)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await monitor.continuationBinding(sessionID: helper.first, connectionID: connection,
                                                  completedTurnID: "turn_one") == .refused(.unverified))
        await monitor.shutdown(); await sink.value
    }

    @Test func theExecutableIsTheKernelsImagePathForTheExactProcess() throws {
        let reader = CodexProcessReader()
        let own = CodexProcessReader.identity(try #require(CodexProcessReader.info(getpid())))
        let image = try #require(reader.executable(of: own))
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        #expect(_NSGetExecutablePath(&buffer, &size) == 0)
        let expected = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        #expect(image.resolvingSymlinksInPath().path == expected)
        let reused = CodexProcessIdentity(pid: own.pid, seconds: own.seconds + 1, microseconds: own.microseconds)
        #expect(reader.executable(of: reused) == nil)
    }
}
