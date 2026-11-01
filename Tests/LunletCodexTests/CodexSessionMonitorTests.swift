// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-15, AC-15.06.
// Refs: US-02, AC-02.08.
// Refs: US-02, AC-02.01, AC-02.02, AC-02.04, AC-02.05, AC-02.06; US-11, AC-11.03, AC-11.04, AC-11.05, AC-11.06.
// Refs: US-13, AC-13.01, AC-13.04; US-12, AC-12.04; US-15, AC-15.05; US-03, AC-03.02, AC-03.03; US-25, AC-25.01.
import Foundation
import Testing
import LunletCore
@testable import LunletCodex

private final class SyntheticProcesses: CodexProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var value = CodexProcessScan(candidates: [], complete: true)
    private var ended: Set<CodexProcessIdentity> = []
    private var scanned = 0
    private var cancelling = false
    func set(_ candidates: [CodexProcessCandidate], complete: Bool = true) {
        lock.lock(); defer { lock.unlock() }; value = .init(candidates: candidates, complete: complete)
    }
    func end(_ identity: CodexProcessIdentity) { lock.lock(); defer { lock.unlock() }; ended.insert(identity) }
    /// Simulates a scan interrupted by its caller's cancellation.
    func cancelScans(_ value: Bool) { lock.lock(); defer { lock.unlock() }; cancelling = value }
    var scans: Int { lock.lock(); defer { lock.unlock() }; return scanned }
    func scan() throws -> CodexProcessScan {
        lock.lock(); defer { lock.unlock() }
        if cancelling { throw CancellationError() }
        scanned += 1; return value
    }
    func presence(of process: CodexProcessIdentity) -> CodexProcessPresence {
        lock.lock(); defer { lock.unlock() }; return ended.contains(process) ? .ended : .same
    }
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private actor CompletionFlag {
    var completed = false
    func finish() { completed = true }
}
private final class BindingSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    func disable() { lock.lock(); defer { lock.unlock() }; enabled = false }
    func isEnabled() -> Bool { lock.lock(); defer { lock.unlock() }; return enabled }
}
private final class SyntheticWallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; value = date }
}
private actor CapturedUpdates {
    private var values: [SessionUpdate] = []
    func append(_ value: SessionUpdate) { values.append(value) }
    var snapshots: [(SessionSnapshot, Bool)] { values.compactMap { if case .snapshot(let s, let b) = $0 { return (s,b) }; return nil } }
    var availability: (Bool, Bool)? { values.reversed().lazy.compactMap { if case .availability(let c, let p) = $0 { return (c, p) }; return nil }.first }
    var count: Int { snapshots.count }
}
struct CodexSessionMonitorTests {
    let helper = CodexSessionReaderTests()
    let a = CodexProcessIdentity(pid: 42, seconds: 100, microseconds: 0)
    let b = CodexProcessIdentity(pid: 43, seconds: 101, microseconds: 0)
    private func wait(_ capture: CapturedUpdates, liveness: CLILiveness) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while await capture.snapshots.last?.0.observation.liveness != liveness, ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func wait(_ capture: CapturedUpdates, for count: Int) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while await capture.count < count, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await capture.count >= count)
    }
    // Refs: US-02, AC-02.03, AC-02.06; US-13, AC-13.01, AC-13.04.
    @Test func newlyDiscoveredRecentWorkIsLiveButOldWorkNeverReplays() async throws {
        let start = try #require(ISO8601DateFormatter().date(from: "2026-10-28T10:00:00Z"))
        let (r1, f1) = try helper.fixture(helper.header(helper.first) + helper.timedEvent("task_started", "new", at: "2026-10-28T10:00:02Z"))
        let (r2, f2) = try helper.fixture(helper.header(helper.second) + helper.timedEvent("task_started", "old", at: "2026-10-28T09:59:00Z"))
        defer { try? FileManager.default.removeItem(at: r1); try? FileManager.default.removeItem(at: r2) }
        let clock = SyntheticWallClock(start), processes = SyntheticProcesses()
        let monitor = CodexSessionMonitor(processes: processes, wallNow: { clock.now() })
        let capture = CapturedUpdates(), updates = await monitor.updates()
        let sink = Task { for await update in updates { await capture.append(update) } }
        await monitor.refresh()
        clock.set(start.addingTimeInterval(3))
        processes.set([.init(process: a, files: [f1]), .init(process: b, files: [f2])])
        await monitor.refresh(); try await wait(capture, for: 2)
        let values = await capture.snapshots
        #expect(values.first { $0.0.observation.sessionID == helper.first }?.1 == false)
        #expect(values.first { $0.0.observation.sessionID == helper.second }?.1 == true)
        await monitor.shutdown(); await sink.value
    }
    // Refs: US-02, AC-02.03, AC-02.06; US-13, AC-13.01, AC-13.04.
    @Test func startupAndIncompleteScansNeverReplayFreshLookingEvents() async throws {
        let start = try #require(ISO8601DateFormatter().date(from: "2026-10-28T10:00:00Z"))
        let (r1, f1) = try helper.fixture(helper.header(helper.first) + helper.timedEvent("task_started", "startup", at: "2026-10-28T10:00:00Z"))
        let (r2, f2) = try helper.fixture(helper.header(helper.second) + helper.timedEvent("task_complete", "done", at: "2026-10-28T10:00:02Z"))
        defer { try? FileManager.default.removeItem(at: r1); try? FileManager.default.removeItem(at: r2) }
        let clock = SyntheticWallClock(start), processes = SyntheticProcesses()
        processes.set([.init(process: a, files: [f1])])
        let monitor = CodexSessionMonitor(processes: processes, wallNow: { clock.now() })
        let capture = CapturedUpdates(), updates = await monitor.updates()
        let sink = Task { for await update in updates { await capture.append(update) } }
        await monitor.refresh(); try await wait(capture, for: 1)
        #expect(await capture.snapshots.first?.1 == true)
        processes.set([.init(process: a, files: [f1])], complete: false)
        await monitor.refresh()
        clock.set(start.addingTimeInterval(3))
        processes.set([.init(process: a, files: [f1]), .init(process: b, files: [f2])])
        await monitor.refresh(); try await wait(capture, for: 2)
        #expect(await capture.snapshots.first { $0.0.observation.sessionID == helper.second }?.1 == true)
        await monitor.shutdown(); await sink.value
    }
    // Refs: US-02, AC-02.03; US-13, AC-13.01, AC-13.04; US-05, AC-05.06.
    @Test func fastCompletedTurnDiscoveredBetweenScansIsLive() async throws {
        let start = try #require(ISO8601DateFormatter().date(from: "2026-10-28T10:00:00Z"))
        let (root, file) = try helper.fixture(helper.header(helper.first) + helper.timedEvent("task_complete", "done", at: "2026-10-28T10:00:02Z"))
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = SyntheticWallClock(start), processes = SyntheticProcesses()
        let monitor = CodexSessionMonitor(processes: processes, wallNow: { clock.now() })
        let capture = CapturedUpdates(), updates = await monitor.updates()
        let sink = Task { for await update in updates { await capture.append(update) } }
        await monitor.refresh()
        clock.set(start.addingTimeInterval(3)); processes.set([.init(process: a, files: [file])])
        await monitor.refresh(); try await wait(capture, for: 1)
        #expect(await capture.snapshots.first?.0.observation.phase == .idle(completedTurnID: "done"))
        #expect(await capture.snapshots.first?.1 == false)
        await monitor.shutdown(); await sink.value
    }
    // Refs: US-02, AC-02.07; US-15, AC-15.02, AC-15.05.
    @Test func nativeInputMetadataAdvancesWithinTheSameTurnWithoutExternalEvents() async throws {
        let initial = try helper.header(helper.first) + helper.event("task_started", "same")
            + helper.line("response_item", ["type":"message", "role":"user", "id":"input-one"])
        let (root, file) = try helper.fixture(initial)
        defer { try? FileManager.default.removeItem(at: root) }
        let processes = SyntheticProcesses(); processes.set([.init(process: a, files: [file], role: .sharedRuntime)])
        let monitor = CodexSessionMonitor(processes: processes), capture = CapturedUpdates()
        let stream = await monitor.updates(), sink = Task { for await update in stream { await capture.append(update) } }
        await monitor.refresh(); try await wait(capture, for: 1)
        try helper.append(helper.line("response_item", ["type":"message", "role":"user", "id":"input-two"]), to: file)
        await monitor.refresh(); try await wait(capture, for: 2)
        let input = try #require(await capture.snapshots.last)
        #expect(input.0.inputActivityID == "input-two" && input.0.turnID == "same" && !input.1)
        #expect(input.0.observation.phase == .running && input.0.hasConfirmedActivity)
        await monitor.refresh(); #expect(await capture.count == 2)
        try helper.append(helper.event("task_complete", "different-turn"), to: file)
        await monitor.refresh(); #expect(await capture.snapshots.last?.0.observation.phase == .running)
        try helper.append(helper.event("task_complete", "same"), to: file)
        await monitor.refresh(); try await wait(capture, for: 3)
        #expect(await capture.snapshots.last?.0.observation.phase == .idle(completedTurnID: "same"))
        await monitor.shutdown(); await sink.value
    }

    @Test func sourceActivityTimeSurvivesObservationOutageAndProcessExit() async throws {
        let time = "2026-10-28T10:00:00Z"
        let (root, file) = try helper.fixture(helper.header(helper.first) + helper.timedEvent("task_started", "one", at: time))
        defer { try? FileManager.default.removeItem(at: root) }
        let processes = SyntheticProcesses(); processes.set([.init(process: a, files: [file], role: .sharedRuntime)])
        let monitor = CodexSessionMonitor(processes: processes), capture = CapturedUpdates()
        let stream = await monitor.updates(), sink = Task { for await update in stream { await capture.append(update) } }
        await monitor.refresh(); try await wait(capture, for: 1)
        let expected = ISO8601DateFormatter().date(from: time)
        #expect(await capture.snapshots.last?.0.lastActivityAt == expected)
        processes.set([]); await monitor.refresh(); try await wait(capture, for: 2)
        #expect(await capture.snapshots.last?.0.lastActivityAt == expected)
        processes.end(a); await monitor.refresh(); try await wait(capture, for: 3)
        #expect(await capture.snapshots.last?.0.lastActivityAt == expected)
        await monitor.shutdown(); await sink.value
    }

    // Refs: US-04, AC-04.11.
    @Test func accountingRetainsARecordedRootAfterItsProcessExitsBeforeTheFirstUsageRefresh() async throws {
        let (root, file) = try helper.fixture(helper.header(helper.first))
        defer { try? FileManager.default.removeItem(at: root) }
        let counters = ["input_tokens": 100, "output_tokens": 10, "cached_input_tokens": 0, "cache_write_input_tokens": 0, "total_tokens": 110]
        let usage = try helper.line("event_msg", ["type": "token_count", "info": ["total_token_usage": counters, "last_token_usage": counters]])
        var object = try #require(JSONSerialization.jsonObject(with: usage) as? [String: Any])
        object["timestamp"] = "2026-10-26T12:00:00Z"
        try helper.append(helper.line("turn_context", ["model": "gpt-6.1-sol"]) + JSONSerialization.data(withJSONObject: object) + Data([10]), to: file)
        let primary = root.appendingPathComponent("primary")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        let catalog = CodexAccountingCatalog(), processes = SyntheticProcesses()
        processes.set([.init(process: a, files: [file], role: .sharedRuntime)])
        let monitor = CodexSessionMonitor(processes: processes, accounting: catalog), capture = CapturedUpdates()
        let stream = await monitor.updates(), sink = Task { for await update in stream { await capture.append(update) } }
        await monitor.refresh(); try await wait(capture, for: 1)
        processes.end(a); processes.set([]); await monitor.refresh()
        let reader = CodexLocalUsageReader(home: primary, limits: .init(), accounting: catalog)
        let result = try await reader.readHistory(now: ISO8601DateFormatter().date(from: "2026-10-26T20:00:00Z")!, calendar: Calendar(identifier: .gregorian))
        #expect(result.sessions[helper.first]?.tokens == 110 && !result.partial)
        await monitor.shutdown(); await sink.value
    }

    @Test func desktopAndChildRecordsShareOneRuntimeWithoutReceivingInputAuthority() async throws {
        let appHeader = try helper.line("session_meta", ["id": helper.first.uuidString, "source": "vscode", "originator": "Codex Desktop", "cwd": "/synthetic/project"])
        let childHeader = try helper.header(helper.second, source: ["subagent": ["thread_spawn": ["parent_thread_id": helper.first.uuidString]]])
        let (r1, f1) = try helper.fixture(appHeader + helper.event("task_started", "desktop"))
        let (r2, f2) = try helper.fixture(childHeader + helper.event("task_started", "child"))
        defer { try? FileManager.default.removeItem(at: r1); try? FileManager.default.removeItem(at: r2) }
        let processes = SyntheticProcesses()
        // Even a terminal-attached process may own multiple root/child records.
        processes.set([.init(process: a, files: [f1, f2])])
        let monitor = CodexSessionMonitor(processes: processes), capture = CapturedUpdates()
        let stream = await monitor.updates(), sink = Task { for await update in stream { await capture.append(update) } }
        await monitor.refresh(); try await wait(capture, for: 2)
        #expect(Set(await capture.snapshots.map { $0.0.observation.sessionID }) == [helper.first, helper.second])
        #expect(await capture.snapshots.first { $0.0.observation.sessionID == helper.second }?.0.parentSessionID == helper.first)
        #expect(await capture.snapshots.allSatisfy { $0.0.hasConfirmedActivity && !$0.0.navigationAvailable && $0.0.observation.liveness == .unverified })
        #expect(await monitor.activeConnections().isEmpty)
        try helper.append(helper.event("task_complete", "desktop"), to: f1)
        await monitor.refresh(); try await wait(capture, for: 3)
        #expect(await capture.snapshots.last?.0.observation.phase == .idle(completedTurnID: "desktop"))
        #expect(await capture.snapshots.last?.1 == false)
        processes.end(a); await monitor.refresh(); try await wait(capture, for: 5)
        #expect(await capture.snapshots.suffix(2).allSatisfy { !$0.0.hasConfirmedActivity })
        #expect(await capture.snapshots.last { $0.0.observation.sessionID == helper.second }?.0.parentSessionID == helper.first)
        await monitor.shutdown(); await sink.value
    }

    @Test func daemonCLIActivityIsVisibleWithoutGrantingOriginalClientAuthority() async throws {
        func runtimeHeader(_ id: UUID) throws -> Data {
            try helper.line("session_meta", ["id": id.uuidString, "source": "vscode", "originator": "codex-tui", "cwd": "/synthetic/shared-project"])
        }
        let (r1, f1) = try helper.fixture(runtimeHeader(helper.first) + helper.event("task_started", "one"))
        let (r2, f2) = try helper.fixture(runtimeHeader(helper.second) + helper.event("task_started", "two"))
        defer { try? FileManager.default.removeItem(at: r1); try? FileManager.default.removeItem(at: r2) }
        let processes = SyntheticProcesses()
        processes.set([.init(process: a, files: [f1, f2], role: .sharedRuntime)])
        let monitor = CodexSessionMonitor(processes: processes), capture = CapturedUpdates()
        let stream = await monitor.updates(), sink = Task { for await u in stream { await capture.append(u) } }
        await monitor.refresh(); try await wait(capture, for: 2)
        let first = await capture.snapshots
        #expect(Set(first.map { $0.0.observation.sessionID }) == [helper.first, helper.second])
        #expect(first.allSatisfy { $0.0.hasConfirmedActivity && $0.0.observation.liveness == .unverified && $0.1 })
        #expect(await monitor.activeConnections().isEmpty)
        try helper.append(helper.event("task_complete", "one"), to: f1)
        await monitor.refresh(); try await wait(capture, for: 3)
        let completed = try #require(await capture.snapshots.last)
        #expect(completed.0.observation.sessionID == helper.first)
        #expect(completed.0.observation.phase == .idle(completedTurnID: "one") && !completed.1)
        let gate = ContinuationGate()
        gate.setAccess(.init(owner: .init(applicationID: "test", tenantID: "test", userID: "test"), connected: true, awayMode: true, inputEnabled: true))
        gate.observe(completed.0.observation)
        #expect(gate.issueControl(for: helper.first, now: 0) == nil)
        processes.set([]); await monitor.refresh(); try await wait(capture, for: 5)
        #expect(await capture.snapshots.suffix(2).allSatisfy { !$0.0.hasConfirmedActivity })
        processes.set([.init(process: a, files: [f1, f2], role: .sharedRuntime)])
        await monitor.refresh(); try await wait(capture, for: 7)
        #expect(await capture.snapshots.suffix(2).allSatisfy { $0.1 && $0.0.hasConfirmedActivity })
        await monitor.shutdown(); await sink.value
    }

    // Refs: US-03, AC-03.02, AC-03.03.
    @Test(arguments: ["cli", "vscode", "future-client"])
    func navigationEvidenceIsSeparateAndClearedWhenOwnershipBecomesUncertain(source: String) async throws {
        let (root, file) = try helper.fixture(helper.header(helper.first, source: source) + helper.event("task_started", "turn"))
        defer { try? FileManager.default.removeItem(at: root) }
        let processes = SyntheticProcesses(); processes.set([.init(process: a, files: [file])])
        let destination = CodexTerminalDestination(applicationID: "synthetic.host", applicationURL: URL(fileURLWithPath: "/synthetic/Host.app"),
            applicationPID: 42, revealURL: URL(string: "synthetic://exact/session")!)
        let monitor = CodexSessionMonitor(processes: processes, resolveDestination: { _ in destination })
        let capture = CapturedUpdates(), updates = await monitor.updates()
        let sink = Task { for await update in updates { await capture.append(update) } }
        await monitor.refresh(); try await wait(capture, for: 1)
        let snapshot = try #require(await capture.snapshots.first?.0)
        #expect(snapshot.navigationAvailable)
        #expect(snapshot.navigationApplicationName == "Host")
        #expect(snapshot.observation.liveness == (source == "cli" ? .alive : .unverified))
        #expect(await monitor.activeConnections().count == (source == "cli" ? 1 : 0))
        #expect(await monitor.destination(sessionID: helper.first, connectionID: UUID()) == nil)
        #expect(await monitor.destination(sessionID: helper.first, connectionID: snapshot.observation.connectionID) == destination)
        processes.set([]); await monitor.refresh(); try await wait(capture, for: 2)
        #expect(await capture.snapshots.last?.0.navigationAvailable == false)
        #expect(await capture.snapshots.last?.0.navigationApplicationName == nil)
        #expect(await monitor.destination(sessionID: helper.first, connectionID: snapshot.observation.connectionID) == nil)
        await monitor.shutdown(); await sink.value
    }

    // Refs: US-03, AC-03.02, AC-03.03; US-11, AC-11.03, AC-11.06.
    @Test func navigationRejectsSharedMultipleAndAmbiguousOwnersDespiteAResolvableHost() async throws {
        let (root, file) = try helper.fixture(helper.header(helper.first, source: "vscode") + helper.event("task_started", "turn"))
        let (otherRoot, otherFile) = try helper.fixture(helper.header(helper.second))
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: otherRoot) }
        let processes = SyntheticProcesses(); processes.set([.init(process: a, files: [file])])
        let destination = CodexTerminalDestination(applicationID: "synthetic.host", applicationURL: URL(fileURLWithPath: "/synthetic/Host.app"),
            applicationPID: 42, revealURL: URL(string: "synthetic://exact/session")!)
        let monitor = CodexSessionMonitor(processes: processes, resolveDestination: { _ in destination })
        let capture = CapturedUpdates(), updates = await monitor.updates()
        let sink = Task { for await update in updates { await capture.append(update) } }
        await monitor.refresh(); try await wait(capture, for: 1)
        let snapshot = try #require(await capture.snapshots.first?.0)
        #expect(await monitor.destination(sessionID: helper.first, connectionID: snapshot.observation.connectionID) == destination)
        for candidates: [CodexProcessCandidate] in [
            [.init(process: a, files: [file], role: .sharedRuntime)],
            [.init(process: a, files: [file, otherFile])],
            [.init(process: a, files: [file]), .init(process: b, files: [file])]
        ] {
            processes.set(candidates)
            #expect(await monitor.destination(sessionID: helper.first, connectionID: snapshot.observation.connectionID) == nil)
        }
        processes.set([.init(process: a, files: [file])]); processes.end(a)
        #expect(await monitor.destination(sessionID: helper.first, connectionID: snapshot.observation.connectionID) == nil)
        await monitor.shutdown(); await sink.value
    }

    // Refs: US-03, AC-03.02, AC-03.03; US-11, AC-11.03, AC-11.06.
    @Test func multipleRecordsNavigateOnlyWithAnExactCurrentBinding() async throws {
        let (r1, f1) = try helper.fixture(helper.header(helper.first) + helper.event("task_started", "one"))
        let (r2, f2) = try helper.fixture(helper.header(helper.second) + helper.event("task_started", "two"))
        defer { try? FileManager.default.removeItem(at: r1); try? FileManager.default.removeItem(at: r2) }
        let processes = SyntheticProcesses(); processes.set([.init(process: a, files: [f1, f2])])
        let destination = CodexTerminalDestination(applicationID: "synthetic.host", applicationURL: URL(fileURLWithPath: "/synthetic/Host.app"), applicationPID: 42, revealURL: URL(string: "synthetic://exact/session")!)
        let binding = BindingSwitch()
        let monitor = CodexSessionMonitor(processes: processes, resolveDestination: { _ in destination }, matchesSessionDestination: { id, actual in id == helper.first && actual == destination && binding.isEnabled() })
        let capture = CapturedUpdates(), updates = await monitor.updates()
        let sink = Task { for await update in updates { await capture.append(update) } }
        await monitor.refresh(); try await wait(capture, for: 2)
        let first = try #require(await capture.snapshots.first { $0.0.observation.sessionID == helper.first }?.0)
        let second = try #require(await capture.snapshots.first { $0.0.observation.sessionID == helper.second }?.0)
        #expect(first.navigationAvailable && !second.navigationAvailable)
        let connections = await monitor.activeConnections()
        #expect(first.observation.liveness == .unverified && connections.isEmpty)
        #expect(await monitor.destination(sessionID: helper.first, connectionID: first.observation.connectionID) == destination)
        #expect(await monitor.destination(sessionID: helper.second, connectionID: second.observation.connectionID) == nil)
        binding.disable()
        #expect(await monitor.destination(sessionID: helper.first, connectionID: first.observation.connectionID) == nil)
        processes.set([.init(process: a, files: [f1, f2]), .init(process: b, files: [f1])])
        #expect(await monitor.destination(sessionID: helper.first, connectionID: first.observation.connectionID) == nil)
        await monitor.shutdown(); await sink.value
    }

    // Refs: US-02, AC-02.05, AC-02.06.
    @Test func aCancelledRefreshIsNotAnObservationOutage() async throws {
        let (root, file) = try helper.fixture(helper.header(helper.first) + helper.event("task_started", "turn"))
        defer { try? FileManager.default.removeItem(at: root) }
        let processes = SyntheticProcesses(); processes.set([.init(process: a, files: [file])])
        let monitor = CodexSessionMonitor(processes: processes)
        let capture = CapturedUpdates(), updates = await monitor.updates()
        let sink = Task { for await update in updates { await capture.append(update) } }
        await monitor.refresh(); try await wait(capture, for: 1)
        let published = await capture.count
        processes.cancelScans(true)
        await monitor.refresh()
        #expect(await monitor.activeConnections().count == 1)
        processes.cancelScans(false)
        await monitor.refresh()
        #expect(await capture.count == published)
        #expect(await capture.snapshots.allSatisfy { $0.0.observation.liveness == .alive })
        #expect(await capture.availability?.0 == true)
        await monitor.shutdown(); await sink.value
    }

    // Refs: US-03, AC-03.02, AC-03.03; US-25, AC-25.01.
    @Test func navigationResolvesOncePerBindingWhileAnUnmatchedSessionBindingRetries() async throws {
        let (r1, f1) = try helper.fixture(helper.header(helper.first) + helper.event("task_started", "one"))
        let (r2, f2) = try helper.fixture(helper.header(helper.second) + helper.event("task_started", "two"))
        defer { try? FileManager.default.removeItem(at: r1); try? FileManager.default.removeItem(at: r2) }
        let destination = CodexTerminalDestination(applicationID: "synthetic.host",
            applicationURL: URL(fileURLWithPath: "/synthetic/Host.app"), applicationPID: 42,
            revealURL: URL(string: "synthetic://exact/session")!)
        let resolutions = Counter()
        let processes = SyntheticProcesses(); processes.set([.init(process: a, files: [f1])])
        let direct = CodexSessionMonitor(processes: processes, resolveDestination: { _ in resolutions.increment(); return destination })
        let directUpdates = await direct.updates()
        let directSink = Task { for await _ in directUpdates {} }
        for _ in 0..<3 { await direct.refresh() }
        #expect(processes.scans >= 3 && resolutions.value == 1)
        await direct.shutdown(); await directSink.value

        // A host may write its session binding after discovery, so only unmatched bindings retry.
        let pending = Counter(), unwritten = BindingSwitch(), shared = SyntheticProcesses()
        shared.set([.init(process: b, files: [f1, f2])])
        let bound = CodexSessionMonitor(processes: shared, resolveDestination: { _ in pending.increment(); return destination },
            matchesSessionDestination: { id, _ in id == helper.first && !unwritten.isEnabled() })
        let capture = CapturedUpdates(), updates = await bound.updates()
        let sink = Task { for await update in updates { await capture.append(update) } }
        // The poll loop's first scan publishes both sessions, then it sleeps past this test.
        try await wait(capture, for: 2)
        await bound.refresh()
        #expect(pending.value == 2 * shared.scans)
        #expect(await capture.snapshots.allSatisfy { !$0.0.navigationAvailable })
        unwritten.disable()
        await bound.refresh()
        let (matchedResolutions, matchedScans) = (pending.value, shared.scans)
        await bound.refresh(); await bound.refresh()
        #expect(pending.value - matchedResolutions == shared.scans - matchedScans)
        #expect(await capture.snapshots.last { $0.0.observation.sessionID == helper.first }?.0.navigationAvailable == true)
        await bound.shutdown(); await sink.value
    }

    @Test func sameDirectorySessionsRemainSeparateAndOnlyNewTransitionsAreLive() async throws {
        let (r1,f1) = try helper.fixture(helper.header(helper.first) + helper.event("task_started", "t1"))
        let (r2,f2) = try helper.fixture(helper.header(helper.second) + helper.event("task_started", "t2"))
        defer { try? FileManager.default.removeItem(at: r1); try? FileManager.default.removeItem(at: r2) }
        let processes = SyntheticProcesses()
        processes.set([.init(process:a,files:[f1]),.init(process:b,files:[f2])])
        let monitor = CodexSessionMonitor(processes: processes)
        let updates = await monitor.updates(), capture = CapturedUpdates()
        let sink = Task { for await update in updates { await capture.append(update) } }
        await monitor.refresh(); try await wait(capture, for: 2)
        let baseline = await capture.snapshots
        #expect(await monitor.activeConnections().count == 2)
        #expect(Set(baseline.map { $0.0.observation.sessionID }) == [helper.first,helper.second])
        #expect(baseline.allSatisfy { $0.1 && $0.0.observation.liveness == .alive })
        try helper.append(helper.event("task_complete", "t1", extra:["last_agent_message":"Done"]), to:f1)
        await monitor.refresh(); try await wait(capture, for: 3)
        let live = await capture.snapshots.last
        #expect(live?.0.observation.sessionID == helper.first && live?.1 == false)
        #expect(live?.0.observation.phase == .idle(completedTurnID:"t1"))
        // Refs: US-06, AC-06.03: the final reply reaches the snapshot a notice is prepared from.
        #expect(live?.0.publicConclusion == "Done")
        processes.set([.init(process:b,files:[f2])]); processes.end(a)
        await monitor.refresh(); try await wait(capture, for: 4)
        #expect(await capture.snapshots.last?.0.observation.liveness == .ended)
        await monitor.shutdown(); await sink.value
    }
    @Test func missingDescriptorIsUncertaintyAndRecoveryHasNoReplay() async throws {
        let (root,file) = try helper.fixture(helper.header(helper.first) + helper.event("task_started", "t"))
        defer { try? FileManager.default.removeItem(at: root) }
        let processes = SyntheticProcesses(); processes.set([.init(process:a,files:[file])])
        let monitor = CodexSessionMonitor(processes: processes), capture = CapturedUpdates()
        let stream = await monitor.updates()
        let sink = Task { for await update in stream { await capture.append(update) } }
        await monitor.refresh(); try await wait(capture, for:1)
        let connection = await capture.snapshots.first?.0.observation.connectionID
        processes.set([]); await monitor.refresh(); try await wait(capture, for:2)
        #expect(await capture.snapshots.last?.0.observation.liveness == .unverified)
        processes.set([.init(process:a,files:[file])]); await monitor.refresh(); try await wait(capture, for:3)
        #expect(await capture.snapshots.last?.1 == true)
        #expect(await capture.snapshots.last?.0.observation.connectionID == connection)
        await monitor.shutdown(); await sink.value
        let total = await capture.count; await monitor.refresh(); #expect(await capture.count == total)
    }
    @Test func ambiguousOwnersCannotCreateLiveSessionsAndProcessReuseGetsFreshBinding() async throws {
        let (root,file) = try helper.fixture(helper.header(helper.first))
        defer { try? FileManager.default.removeItem(at:root) }
        let processes = SyntheticProcesses(); processes.set([.init(process:a,files:[file])])
        let monitor = CodexSessionMonitor(processes:processes), capture = CapturedUpdates()
        let stream = await monitor.updates(); let sink = Task { for await u in stream { await capture.append(u) } }
        await monitor.refresh(); try await wait(capture,for:1)
        let original = await capture.snapshots.first?.0.observation.connectionID
        processes.set([.init(process:a,files:[file]),.init(process:b,files:[file])])
        await monitor.refresh(); try await wait(capture,for:2)
        #expect(await capture.snapshots.last?.0.observation.liveness == .unverified)
        processes.end(a)
        let reused = CodexProcessIdentity(pid:42,seconds:200,microseconds:0)
        processes.set([.init(process:reused,files:[file])]); await monitor.refresh(); try await wait(capture,for:4)
        // Retirement and rediscovery are distinct snapshots. Wait for both,
        // rather than racing the stream after only the old ended binding.
        #expect(await capture.snapshots[2].0.observation.liveness == .ended)
        #expect(await capture.snapshots.last?.0.observation.connectionID != original)
        #expect(await capture.snapshots.last?.1 == true)
        await monitor.shutdown(); await sink.value
    }
    @Test func unreadableSecondRootAndAmbiguousOwnersNeverProveUniqueness() async throws {
        let (r1,f1) = try helper.fixture(helper.header(helper.first))
        let (r2,f2) = try helper.fixture(Data("{unfinished".utf8))
        defer { try? FileManager.default.removeItem(at:r1); try? FileManager.default.removeItem(at:r2) }
        let processes = SyntheticProcesses(); processes.set([.init(process:a,files:[f1])])
        let monitor=CodexSessionMonitor(processes:processes), capture=CapturedUpdates()
        let stream=await monitor.updates();let sink=Task { for await u in stream { await capture.append(u) } }
        await monitor.refresh();try await wait(capture,for:1)
        processes.set([.init(process:a,files:[f1,f2])]);await monitor.refresh()
        try await wait(capture, liveness: .unverified)
        #expect(await capture.snapshots.last?.0.observation.liveness == .unverified)
        #expect(await monitor.activeConnections().isEmpty)
        try helper.header(helper.second).write(to:f2.url)
        processes.set([.init(process:a,files:[f1,f2]),.init(process:b,files:[f1])])
        await monitor.refresh();try await wait(capture, liveness: .unverified)
        #expect(await capture.snapshots.last?.0.observation.liveness == .unverified)
        await monitor.shutdown();await sink.value
    }

    // Refs: US-02, AC-02.05, AC-02.06; US-11, AC-11.03.
    @Test func aLiveOwnerThatReleasesItsRecordEndsOnlyThatBindingAfterACompleteScan() async throws {
        let (r1, f1) = try helper.fixture(helper.header(helper.first) + helper.event("task_complete", "old"))
        let (r2, f2) = try helper.fixture(helper.header(helper.second) + helper.event("task_started", "new"))
        defer { try? FileManager.default.removeItem(at: r1); try? FileManager.default.removeItem(at: r2) }
        let processes = SyntheticProcesses(); processes.set([.init(process: a, files: [f1])])
        let monitor = CodexSessionMonitor(processes: processes), capture = CapturedUpdates()
        let stream = await monitor.updates(), sink = Task { for await u in stream { await capture.append(u) } }
        await monitor.refresh(); try await wait(capture, for: 1)
        // An incomplete scan cannot prove release: keep uncertainty, not an ended state.
        processes.set([.init(process: a, files: [f2])], complete: false)
        await monitor.refresh(); try await wait(capture, for: 3)
        #expect(await capture.snapshots.last { $0.0.observation.sessionID == helper.first }?.0.observation.liveness == .unverified)
        let uncertain = await capture.availability
        #expect(uncertain?.1 == true)
        // The same live process now writes a new conversation's record only.
        processes.set([.init(process: a, files: [f2])])
        await monitor.refresh(); try await wait(capture, for: 4)
        let old = try #require(await capture.snapshots.last { $0.0.observation.sessionID == helper.first })
        #expect(old.0.observation.liveness == .ended && old.1)
        let availability = await capture.availability
        #expect(availability?.0 == true && availability?.1 == false)
        #expect(Set(await monitor.activeConnections().keys) == [helper.second])
        await monitor.shutdown(); await sink.value
    }

    // Refs: US-02, AC-02.06; US-13, AC-13.01; US-11, AC-11.03.
    @Test func appendsToAConfirmedBindingAreReadWithoutAProcessScanAndExitStillRescans() async throws {
        let owner = CodexProcessIdentity(pid: getpid(), seconds: 100, microseconds: 0)
        let (root, file) = try helper.fixture(helper.header(helper.first) + helper.event("task_started", "turn"))
        defer { try? FileManager.default.removeItem(at: root) }
        let processes = SyntheticProcesses(); processes.set([.init(process: owner, files: [file])])
        let monitor = CodexSessionMonitor(processes: processes, watchingFiles: true), capture = CapturedUpdates()
        let stream = await monitor.updates(), sink = Task { for await u in stream { await capture.append(u) } }
        await monitor.refresh(); try await wait(capture, for: 1)
        try await Task.sleep(for: .milliseconds(50))
        let scans = processes.scans
        try helper.append(helper.event("task_complete", "turn"), to: file)
        try await wait(capture, for: 2)
        let finished = try #require(await capture.snapshots.last)
        #expect(finished.0.observation.phase == .idle(completedTurnID: "turn") && !finished.1)
        #expect(finished.0.observation.liveness == .alive && processes.scans == scans)
        // A record write cannot keep an exited owner alive; it falls back to a scan.
        processes.end(owner)
        try helper.append(helper.event("task_started", "after-exit"), to: file)
        try await wait(capture, for: 3)
        #expect(await capture.snapshots.last?.0.observation.liveness == .ended)
        #expect(processes.scans > scans)
        #expect(await monitor.activeConnections().isEmpty)
        await monitor.shutdown(); await sink.value
    }

    @Test func overlappingShutdownsWaitForNativeWatchCancellation() async throws {
        let (root,file) = try helper.fixture(helper.header(helper.first))
        defer { try? FileManager.default.removeItem(at:root) }
        let processes=SyntheticProcesses();processes.set([.init(process:a,files:[file])])
        let queue=DispatchQueue(label:"lunlet.synthetic.watch-cancellation")
        queue.suspend()
        let monitor=CodexSessionMonitor(processes:processes,watchingFiles:true,eventQueue:queue)
        let stream = await monitor.updates();await monitor.refresh()
        let first=Task { await monitor.shutdown() }
        try await Task.sleep(for:.milliseconds(30))
        let flag=CompletionFlag()
        let second=Task { await monitor.shutdown();await flag.finish() }
        try await Task.sleep(for:.milliseconds(30))
        #expect(await flag.completed == false)
        queue.resume()
        await first.value;await second.value
        #expect(await flag.completed)
        withExtendedLifetime(stream) {}
    }

}
