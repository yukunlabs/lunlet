// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.01, AC-33.02, AC-33.03, AC-33.05, AC-33.06.
// Refs: US-13, AC-13.01, AC-13.04; US-15, AC-15.05; US-12, AC-12.04.
import Foundation
import Testing
import LunletCore
@testable import LunletClaude

/// Same-user processes the test declares live, keyed by pid with their kernel start time.
private final class SyntheticClaudeProcesses: ClaudeProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var live: [Int32: ClaudeProcessIdentity] = [:]
    @discardableResult func start(_ pid: Int32, at seconds: UInt64 = 1_793_354_400) -> ClaudeProcessIdentity {
        lock.lock(); defer { lock.unlock() }
        let identity = ClaudeProcessIdentity(pid: pid, seconds: seconds, microseconds: 250_000)
        live[pid] = identity; return identity
    }
    func end(_ pid: Int32) { lock.lock(); defer { lock.unlock() }; live.removeValue(forKey: pid) }
    func verify(pid: Int32, startedAt: Date) -> ClaudeProcessCheck {
        lock.lock(); defer { lock.unlock() }
        guard let identity = live[pid], abs(Double(identity.seconds) - startedAt.timeIntervalSince1970) <= 1 else { return .stale }
        return .verified(identity)
    }
    func presence(of process: ClaudeProcessIdentity) -> ClaudeProcessPresence {
        lock.lock(); defer { lock.unlock() }; return live[process.pid] == process ? .same : .ended
    }
}
private struct FailingRegistry: ClaudeRegistryReading {
    func scan() throws -> ClaudeRegistryScan { throw ClaudeRegistryFailure.unavailable }
}
private actor Captured {
    private(set) var values: [SessionUpdate] = []
    func append(_ value: SessionUpdate) { values.append(value) }
    var snapshots: [(SessionSnapshot, Bool)] { values.compactMap { if case .snapshot(let s, let b) = $0 { return (s, b) }; return nil } }
    var availability: (Bool, Bool)? {
        values.reversed().lazy.compactMap { if case .availability(let c, let p) = $0 { return (c, p) }; return nil }.first
    }
    var reconciled: [UUID: UUID]? { values.reversed().lazy.compactMap { if case .reconciled(let v) = $0 { return v }; return nil }.first }
}

struct ClaudeSessionMonitorTests {
    typealias F = ClaudeFixture
    let first = UUID(uuidString: F.first)!
    let second = UUID(uuidString: F.second)!

    private func observe(_ fixture: ClaudeFixture, _ processes: SyntheticClaudeProcesses,
                         registry: (any ClaudeRegistryReading)? = nil,
                         now: Date = Date(timeIntervalSince1970: 1_793_354_500))
        async -> (ClaudeSessionMonitor, Captured, Task<Void, Never>) {
        let monitor = ClaudeSessionMonitor(home: fixture.home,
            registry: registry ?? ClaudeSessionRegistry(directory: fixture.home.sessions), processes: processes, wallNow: { now })
        let captured = Captured(), stream = await monitor.updates()
        let sink = Task { for await update in stream { await captured.append(update) } }
        return (monitor, captured, sink)
    }
    private func settle(_ captured: Captured, until condition: @escaping @Sendable ([(SessionSnapshot, Bool)]) -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !condition(await captured.snapshots), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
    }
    /// The sink appends asynchronously; wait for a stream marker before reading it.
    private func settled<T: Sendable>(_ captured: Captured, _ read: @escaping @Sendable (Captured) async -> T?) async throws -> T? {
        let end = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < end {
            if let value = await read(captured) { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    // Refs: US-33, AC-33.01, AC-33.03, AC-33.05; US-13, AC-13.04.
    @Test func liveRecordBindsTheExactTranscriptAsBaselineThenReportsLiveCompletion() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let processes = SyntheticClaudeProcesses(); processes.start(501)
        try fixture.record(pid: 501, session: F.first)
        let url = try fixture.transcript([F.typed("Earlier work", uuid: "u0", prompt: "p0"), F.assistant(stop: "end_turn"),
                                          F.turnDuration(), F.typed("Run checks", uuid: "u1", prompt: "p1")], session: F.first)
        let (monitor, captured, sink) = await observe(fixture, processes)
        await monitor.refresh(); try await settle(captured) { !$0.isEmpty }
        let (baseline, isBaseline) = try #require(await captured.snapshots.first)
        #expect(isBaseline && baseline.provider == .claude && baseline.project == "project-a")
        #expect(baseline.observation.sessionID == first && baseline.observation.phase == .running)
        // A live owner is not an original-client connection: no input authority, but confirmed activity.
        #expect(baseline.observation.liveness == .unverified && baseline.hasConfirmedActivity && !baseline.navigationAvailable)
        #expect(baseline.localPreview == "Run checks")
        try fixture.append([F.assistant(stop: "end_turn", id: "msg_7"), F.turnDuration()], to: url)
        await monitor.refresh(); try await settle(captured) { $0.count >= 2 }
        let (finished, finishedBaseline) = try #require(await captured.snapshots.last)
        #expect(!finishedBaseline && finished.observation.phase == .idle(completedTurnID: "p1"))
        #expect(finished.observation.connectionID == baseline.observation.connectionID)
        // The final reply reaches the snapshot the notice is prepared from; the earlier turn's never does.
        #expect(baseline.publicConclusion == nil && finished.publicConclusion == "Synthetic reply")
        let available = await captured.availability
        #expect(available?.0 == true && available?.1 == false)
        await monitor.reconcile()
        let reconciled = try await settled(captured) { await $0.reconciled }
        #expect(reconciled == [first: baseline.observation.connectionID])
        await monitor.shutdown(); await sink.value
    }

    // Refs: US-33, AC-33.01, AC-33.03.
    @Test func staleAndMismatchedStartRecordsAreIgnored() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let processes = SyntheticClaudeProcesses()
        processes.start(601, at: 1_793_354_400 + 120)  // A reused pid with a different start time.
        try fixture.record(pid: 601, session: F.first)
        try fixture.record(pid: 602, session: F.second)  // A crash left this record; no such process.
        try fixture.transcript([F.typed("A", uuid: "u1", prompt: "p1")], session: F.first)
        try fixture.transcript([F.typed("B", uuid: "u2", prompt: "p2", session: F.second)], session: F.second)
        let (monitor, captured, sink) = await observe(fixture, processes)
        await monitor.refresh()
        let available = try await settled(captured) { await $0.availability }
        #expect(await captured.snapshots.isEmpty)
        #expect(available?.0 == true && available?.1 == false)
        await monitor.shutdown(); await sink.value
    }

    // Refs: US-33, AC-33.02.
    @Test func sessionsInOneDirectoryStayAttributedAndDuplicateOwnersStayAmbiguous() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let processes = SyntheticClaudeProcesses(); processes.start(701); processes.start(702); processes.start(703)
        try fixture.record(pid: 701, session: F.first)
        try fixture.record(pid: 702, session: F.second)
        let one = try fixture.transcript([F.typed("A", uuid: "a1", prompt: "pa")], session: F.first)
        try fixture.transcript([F.typed("B", uuid: "b1", prompt: "pb", session: F.second)], session: F.second)
        let (monitor, captured, sink) = await observe(fixture, processes)
        await monitor.refresh(); try await settle(captured) { $0.count >= 2 }
        try fixture.append([F.assistant(stop: "end_turn"), F.turnDuration()], to: one)
        await monitor.refresh(); try await settle(captured) { $0.count >= 3 }
        let latest = await captured.snapshots
        #expect(latest.last?.0.observation.sessionID == first && latest.last?.0.observation.phase == .idle(completedTurnID: "pa"))
        #expect(latest.filter { $0.0.observation.sessionID == second }.allSatisfy { $0.0.observation.phase == .running })
        // The same session resumed in a second live process is observation-only with unknown state.
        try fixture.record(pid: 703, session: F.second)
        await monitor.refresh()
        try await settle(captured) { $0.contains { $0.0.observation.sessionID == self.second && !$0.0.hasConfirmedActivity } }
        let ambiguous = try #require(await captured.snapshots.last { $0.0.observation.sessionID == second })
        #expect(ambiguous.0.observation.phase == .unknown && ambiguous.1 && !ambiguous.0.hasConfirmedActivity)
        // Availability follows the snapshot on the stream; wait for it rather than reading it immediately.
        let partial = try await settled(captured) { await $0.availability?.1 == true ? true : nil }
        #expect(partial == true)
        await monitor.reconcile()
        let reconciled = try await settled(captured) { await $0.reconciled }
        #expect(reconciled?[second] == nil && reconciled?[first] != nil)
        await monitor.shutdown(); await sink.value
    }

    // Refs: US-33, AC-33.03.
    @Test func registryWaitShowsApprovalOrInputOnTheMacUntilItResolves() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let processes = SyntheticClaudeProcesses(); processes.start(801)
        try fixture.record(pid: 801, session: F.first, status: "waiting", waitingFor: "permission prompt")
        try fixture.transcript([F.typed("Deploy", uuid: "u1", prompt: "p1"), F.assistant(stop: "tool_use")], session: F.first)
        let (monitor, captured, sink) = await observe(fixture, processes)
        await monitor.refresh(); try await settle(captured) { !$0.isEmpty }
        #expect(await captured.snapshots.last?.0.observation.phase == .approval)
        try fixture.record(pid: 801, session: F.first, status: "waiting", waitingFor: "input needed")
        await monitor.refresh(); try await settle(captured) { $0.count >= 2 }
        let input = try #require(await captured.snapshots.last?.0)
        #expect(input.awaitsUser && input.observation.phase != .approval)
        #expect(!SessionNotice.prepare(input).allowsFollowup && SessionNotice.prepare(input).questions.isEmpty)
        try fixture.record(pid: 801, session: F.first, status: "busy")
        await monitor.refresh(); try await settle(captured) { $0.count >= 3 }
        #expect(await captured.snapshots.last?.0.observation.phase == .running)
        await monitor.shutdown(); await sink.value
    }

    // Refs: US-33, AC-33.01, AC-33.03; US-12, AC-12.04.
    @Test func exitAndClearEndTheBindingWithoutInventingCompletion() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let processes = SyntheticClaudeProcesses(); processes.start(901); processes.start(902)
        try fixture.record(pid: 901, session: F.first)
        let record = try fixture.record(pid: 902, session: F.second)
        try fixture.transcript([F.typed("A", uuid: "u1", prompt: "p1")], session: F.first)
        try fixture.transcript([F.typed("B", uuid: "u2", prompt: "p2", session: F.second)], session: F.second)
        let (monitor, captured, sink) = await observe(fixture, processes)
        await monitor.refresh(); try await settle(captured) { $0.count >= 2 }
        processes.end(901)
        // `/clear` keeps the process but its record now names a new session.
        let third = "0b6b2a52-5f0e-4c5c-9d43-3c4f0a1b2c03"
        try FileManager.default.removeItem(at: record)
        try fixture.record(pid: 902, session: third)
        try fixture.transcript([F.typed("C", uuid: "u3", prompt: "p3", session: third)], session: third)
        await monitor.refresh(); try await settle(captured) { $0.count >= 5 }
        let values = await captured.snapshots
        for id in [first, second] {
            let ended = try #require(values.last { $0.0.observation.sessionID == id })
            #expect(ended.0.isEnded && ended.1 && ended.0.observation.phase == .ended)
        }
        #expect(values.contains { $0.0.observation.sessionID == UUID(uuidString: third) && $0.1 })
        await monitor.shutdown(); await sink.value
    }

    // Refs: US-33, AC-33.06.
    @Test func subagentTranscriptsNeverBecomeSessionsOrDriveTheParent() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let processes = SyntheticClaudeProcesses(); processes.start(1001)
        try fixture.record(pid: 1001, session: F.first)
        try fixture.transcript([F.typed("Parent", uuid: "u1", prompt: "p1")], session: F.first)
        try fixture.subagent([F.typed("Child", uuid: "c1", prompt: "c"), F.assistant(stop: "end_turn"), F.turnDuration()],
                             session: F.first)
        let (monitor, captured, sink) = await observe(fixture, processes)
        await monitor.refresh(); try await settle(captured) { !$0.isEmpty }
        let values = await captured.snapshots
        #expect(Set(values.map(\.0.observation.sessionID)) == [first])
        #expect(values.last?.0.observation.phase == .running && values.last?.0.parentSessionID == nil)
        await monitor.shutdown(); await sink.value
    }

    // Refs: US-33, AC-33.03, AC-33.05; US-12, AC-12.04.
    @Test func watchedAppendsAndReplacedRecordsArriveWithoutWaitingForThePoll() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let processes = SyntheticClaudeProcesses(); processes.start(1201)
        let record = try fixture.record(pid: 1201, session: F.first)
        let url = try fixture.transcript([F.typed("Watch", uuid: "u1", prompt: "p1")], session: F.first)
        let monitor = ClaudeSessionMonitor(home: fixture.home, registry: ClaudeSessionRegistry(directory: fixture.home.sessions),
                                           processes: processes, watchingFiles: true)
        let captured = Captured(), stream = await monitor.updates()
        let sink = Task { for await update in stream { await captured.append(update) } }
        await monitor.refresh(); try await settle(captured) { !$0.isEmpty }
        // No explicit refresh follows: only the transcript watch can deliver this completion within the poll interval.
        try fixture.append([F.assistant(stop: "end_turn"), F.turnDuration()], to: url)
        try await settle(captured) { $0.last?.0.observation.phase == .idle(completedTurnID: "p1") }
        #expect(await captured.snapshots.last?.1 == false)
        // An atomically replaced process record is picked up through its structural event.
        let replacement = fixture.root.appendingPathComponent("replacement.json")
        try FileManager.default.copyItem(at: record, to: replacement)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: replacement)) as? [String: Any])
        object["status"] = "waiting"; object["waitingFor"] = "permission prompt"
        try JSONSerialization.data(withJSONObject: object).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(record, withItemAt: replacement)
        try await settle(captured) { $0.last?.0.observation.phase == .approval }
        #expect(await captured.snapshots.last?.0.observation.phase == .approval)
        await monitor.shutdown(); await sink.value
    }

    // Refs: US-33, AC-33.03.
    @Test func unreadableRegistryIsAnOutageAndUnsupportedVersionIsUnknown() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let processes = SyntheticClaudeProcesses(); processes.start(1101)
        try fixture.record(pid: 1101, session: F.first, version: "3.0.0")
        try fixture.transcript([F.typed("A", uuid: "u1", prompt: "p1")], session: F.first)
        let (monitor, captured, sink) = await observe(fixture, processes)
        await monitor.refresh(); try await settle(captured) { !$0.isEmpty }
        let unknown = try #require(await captured.snapshots.first?.0)
        #expect(unknown.observation.phase == .unknown && !unknown.hasConfirmedActivity)
        await monitor.shutdown(); await sink.value
        let (failing, outage, failingSink) = await observe(fixture, processes, registry: FailingRegistry())
        await failing.refresh()
        let availability = try await settled(outage) { await $0.availability }
        #expect(availability?.0 == false)
        await failing.shutdown(); await failingSink.value
    }
}
