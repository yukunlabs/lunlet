// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.01, AC-38.02, AC-38.03, AC-38.04, AC-38.05, AC-38.06, AC-38.07; US-08, AC-08.01, AC-08.03, AC-08.04;
// US-10, AC-10.01, AC-10.03, AC-10.04; US-11, AC-11.03; US-13, AC-13.04; US-33, AC-33.07.
import Foundation
import Testing
import LunletCore
import LunletHook
@testable import LunletClaude

/// Same-user processes with the parents the test declares.
private final class HookProcesses: ClaudeProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var live: [Int32: ClaudeProcessIdentity] = [:]
    private var parents: [Int32: Int32] = [:]
    @discardableResult func start(_ pid: Int32, parent: Int32? = nil, at seconds: UInt64 = 1_793_354_400) -> ClaudeProcessIdentity {
        lock.lock(); defer { lock.unlock() }
        let identity = ClaudeProcessIdentity(pid: pid, seconds: seconds, microseconds: 250_000)
        live[pid] = identity; parents[pid] = parent ?? 1
        return identity
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
    func parent(of pid: Int32) -> Int32? { lock.lock(); defer { lock.unlock() }; return live[pid] == nil ? nil : parents[pid] }
}

private actor BindingSource: ClaudeSessionObserving {
    private let result: ClaudeBindingResult
    init(_ result: ClaudeBindingResult) { self.result = result }
    func updates() -> AsyncStream<SessionUpdate> { AsyncStream { $0.finish() } }
    func refresh() {}
    func reconcile() {}
    func shutdown() {}
    func continuationBinding(sessionID: UUID, connectionID: UUID, completedTurnID: String) -> ClaudeBindingResult { result }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var events: [String] { lock.withLock { values } }
    var progress: ContinuationProgress {
        ContinuationProgress(recheck: { self.lock.withLock { self.values.append("recheck") }; return nil },
                             submitted: { self.lock.withLock { self.values.append("submitted") } })
    }
}

private actor Captured {
    private(set) var snapshots: [SessionSnapshot] = []
    func append(_ value: SessionUpdate) { if case .snapshot(let s, _) = value { snapshots.append(s) } }
}

struct ClaudeHookTests {
    typealias F = ClaudeFixture
    let first = UUID(uuidString: F.first)!
    let second = UUID(uuidString: F.second)!
    let text = "Rerun the failing test,\nthen summarize"

    private func spool(_ fixture: ClaudeFixture) -> HookSpool { .init(root: fixture.root.appendingPathComponent("hook")) }
    private func signal(_ spool: HookSpool, session: UUID, pid: Int32, parent: Int32, prompt: String? = "p1",
                        reply: String = "PING", at: Date = F.startDate) throws -> UUID {
        let stop = UUID()
        try HookSpool.createPrivateDirectory(spool.stopDirectory(session))
        let value = HookSpool.StopSignal(stopID: stop, sessionID: session, promptID: prompt, lastAssistantMessage: reply,
                                         stopHookActive: false, pid: pid, parentPID: parent, at: at)
        try HookSpool.writeAtomically(try HookSpool.encoder.encode(value), to: spool.file(session, stop: stop, suffix: HookSpool.signalSuffix))
        return stop
    }
    private func exists(_ spool: HookSpool, _ session: UUID, _ stop: UUID, _ suffix: String) -> Bool {
        FileManager.default.fileExists(atPath: spool.file(session, stop: stop, suffix: suffix).path)
    }
    private func settle(_ captured: Captured, until condition: @escaping @Sendable ([SessionSnapshot]) -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !condition(await captured.snapshots), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
    }

    // Refs: US-38, AC-38.01, AC-38.07, AC-38.08.
    @Test func connectAddsOnlyLunletsStopEntryAndDisconnectRemovesExactlyIt() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let spool = spool(fixture), connection = ClaudeHookConnection(home: fixture.home, spool: spool)
        let original = """
        {
          "model": "opus",
          "hooks": {
            "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo pre"}]}],
            "Stop": [{"hooks": [{"type": "command", "command": "notify.sh"}]}]
          },
          "statusLine": {"type": "command", "command": "status.sh"}
        }

        """
        try Data(original.utf8).write(to: fixture.home.settings)
        #expect(try connection.state() == .notConnected)
        #expect(try connection.connect() == .connected)
        #expect(try connection.state() == .connected)
        let written = try Data(contentsOf: fixture.home.settings)
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["model"] as? String == "opus")
        #expect((object["statusLine"] as? [String: Any])?["command"] as? String == "status.sh")
        let hooks = try #require(object["hooks"] as? [String: Any])
        #expect((hooks["PreToolUse"] as? [[String: Any]])?.count == 1)
        let stops = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stops.count == 2)
        let lunlet = try #require((stops[0]["hooks"] as? [[String: Any]])?.first)
        #expect(lunlet["type"] as? String == "command" && lunlet["command"] as? String == connection.command)
        #expect(lunlet["timeout"] as? Int == 900 && lunlet["statusMessage"] as? String == "Lunlet: waiting for your phone reply")
        #expect(((stops[1]["hooks"] as? [[String: Any]])?.first)?["command"] as? String == "notify.sh")
        // Bytes outside the hooks member are untouched; the launcher is installed, user-only and executable.
        let text = String(decoding: written, as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"model\": \"opus\",\n  \"hooks\": ") && text.hasSuffix("  \"statusLine\": {\"type\": \"command\", \"command\": \"status.sh\"}\n}\n"))
        #expect(try Data(contentsOf: spool.launcherURL) == Data(HookSpool.launcherScript.utf8))
        #expect(FileManager.default.isExecutableFile(atPath: spool.launcherURL.path))
        #expect(try connection.connect() == .connected)
        #expect(try connection.disconnect() == .notConnected)
        let restored = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: fixture.home.settings)) as? [String: Any])
        let expected = try #require(try JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        #expect(NSDictionary(dictionary: restored).isEqual(to: expected))
        #expect(connection.command.hasPrefix("\"") && connection.command.hasSuffix("/lunlet-hook\""))
    }

    // Refs: US-38, AC-38.01, AC-38.07.
    @Test func connectionCreatesOrRemovesTheHooksMemberAndRefusesBrokenSettings() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let connection = ClaudeHookConnection(home: fixture.home, spool: spool(fixture))
        // No settings file: one is created with only the hook; disconnecting leaves an empty object.
        #expect(try connection.state() == .notConnected)
        #expect(try connection.connect() == .connected)
        var object = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: fixture.home.settings)) as? [String: Any])
        #expect(object.keys.sorted() == ["hooks"])
        #expect(try connection.disconnect() == .notConnected)
        object = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: fixture.home.settings)) as? [String: Any])
        #expect(object.isEmpty)
        // Other members stay, single-line style included.
        try Data(#"{"model": "opus"}"#.utf8).write(to: fixture.home.settings)
        #expect(try connection.connect() == .connected)
        let single = String(decoding: try Data(contentsOf: fixture.home.settings), as: UTF8.self)
        #expect(single.hasPrefix(#"{"model": "opus","hooks": {"Stop": [{"hooks": [{"#) && !single.contains("\n"))
        #expect(try connection.disconnect() == .notConnected)
        #expect(String(decoding: try Data(contentsOf: fixture.home.settings), as: UTF8.self) == #"{"model": "opus"}"#)
        try Data("not json".utf8).write(to: fixture.home.settings)
        #expect(throws: ClaudeHookFailure.settingsInvalid) { try connection.state() }
        try Data(#"{"hooks": ["bad"]}"#.utf8).write(to: fixture.home.settings)
        #expect(throws: ClaudeHookFailure.settingsInvalid) { try connection.connect() }
    }

    // Refs: US-38, AC-38.04, AC-38.05; US-10, AC-10.01, AC-10.03.
    @Test func deliveryWatchConfirmsOnlyLunletsOwnFollowupAndTheReaderCountsContinuations() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let url = try fixture.transcript([F.typed("Start", uuid: "u1", prompt: "p1"), F.assistant(stop: "end_turn")], session: F.first)
        var watch = try #require(ClaudeDeliveryWatch(file: try fixture.file(url), text: text))
        #expect(watch.poll() == .pending)
        try fixture.append([F.stopHookSummary(otherContexts: ["Please run the test suite before finishing"])], to: url)
        #expect(watch.poll() == .pending)
        try fixture.append([F.stopHookSummary(followups: ["  Rerun the failing test,\nthen summarize \n"])], to: url)
        #expect(watch.poll() == .delivered)
        var other = try #require(ClaudeDeliveryWatch(file: try fixture.file(url), text: text))
        try fixture.append([F.stopHookSummary(followups: ["something else"])], to: url)
        #expect(other.poll() == .mismatched)
        // The reader: a hook continuation runs the same turn again and completes it under a suffixed id.
        var reader = ClaudeTranscriptReader(file: try fixture.file(url), sessionName: F.first)
        let continued = try reader.read().content
        #expect(continued.phase == .running && continued.turn == "p1" && continued.continuations == 2)
        #expect(continued.localPreview == "something else")
        try fixture.append([F.assistant(stop: "end_turn", id: "msg_2", content: [["type": "text", "text": "Done"]]),
                            F.turnDuration(uuid: "c0ffee00-0000-4000-8000-000000000002")], to: url)
        let done = try reader.read().content
        #expect(done.phase == .idle(completedTurnID: "p1#2") && done.turn == "p1" && done.conclusion == "Done")
        #expect(ClaudeTurnID.compose("p1", continuations: 0) == "p1")
    }

    // Refs: US-38, AC-38.02, AC-38.03, AC-38.05; US-08, AC-08.03; US-11, AC-11.03; US-13, AC-13.04.
    @Test func monitorCompletesFromAVerifiedStopHoldsItWhileLockedAndBindsOnlyThatTurn() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let spool = spool(fixture), processes = HookProcesses()
        try fixture.record(pid: 100, session: F.first)
        let url = try fixture.transcript([F.typed("Start", uuid: "u1", prompt: "p1"),
                                          F.assistant(stop: "end_turn", content: [["type": "text", "text": "PING"]])], session: F.first)
        processes.start(100)
        let monitor = ClaudeSessionMonitor(home: fixture.home, registry: ClaudeSessionRegistry(directory: fixture.home.sessions),
                                           processes: processes, wallNow: { Date(timeIntervalSince1970: 1_793_354_500) },
                                           hooks: spool, hookConnected: { true })
        let captured = Captured(), stream = await monitor.updates()
        let sink = Task { for await update in stream { await captured.append(update) } }
        defer { sink.cancel() }
        try await settle(captured) { $0.contains { $0.observation.sessionID == self.first } }
        #expect(FileManager.default.fileExists(atPath: spool.appRecordURL.path))
        let running = try #require(await captured.snapshots.last)
        #expect(running.observation.phase == .running && running.inputPath == nil)
        #expect(running.inputPathNote == "Takes phone replies after its next turn ends")
        // A signal from a process that is not the session's child is released and changes nothing.
        processes.start(300, parent: 999)
        let foreign = try signal(spool, session: first, pid: 300, parent: 999)
        await monitor.setReplyWindow(true)
        await monitor.refresh()
        #expect(exists(spool, first, foreign, HookSpool.releaseSuffix) && !exists(spool, first, foreign, HookSpool.holdSuffix))
        #expect(await captured.snapshots.last?.observation.phase == .running)
        // The session's own hook: completion with the hook's reply text, held while the window is open.
        processes.start(200, parent: 100)
        let stop = try signal(spool, session: first, pid: 200, parent: 100)
        await monitor.refresh()
        try await settle(captured) { $0.last?.inputPath == .claudeHook }
        let held = try #require(await captured.snapshots.last)
        #expect(held.observation.phase == .idle(completedTurnID: "p1") && held.publicConclusion == "PING")
        #expect(held.observation.liveness == .alive && held.inputPathNote == nil)
        #expect(exists(spool, first, stop, HookSpool.holdSuffix))
        let connection = held.observation.connectionID
        let bound = await monitor.continuationBinding(sessionID: first, connectionID: connection, completedTurnID: "p1")
        guard case .bound(let binding) = bound else { Issue.record("expected a binding, got \(bound)"); return }
        let file = try fixture.file(url)
        #expect(binding.stopID == stop && binding.transcript == file)
        #expect(await monitor.continuationBinding(sessionID: first, connectionID: connection, completedTurnID: "p0") == .refused(.superseded))
        #expect(await monitor.continuationBinding(sessionID: first, connectionID: UUID(), completedTurnID: "p1") == .refused(.sessionEnded))
        // Unlocking releases the hold: no path, no liveness claim, no binding; the completion stands.
        await monitor.setReplyWindow(false)
        try await settle(captured) { $0.last?.inputPath == nil }
        let released = try #require(await captured.snapshots.last)
        #expect(exists(spool, first, stop, HookSpool.releaseSuffix))
        #expect(released.observation.phase == .idle(completedTurnID: "p1") && released.observation.liveness == .unverified)
        #expect(released.inputPathNote == "Takes phone replies while the Mac is locked")
        #expect(await monitor.continuationBinding(sessionID: first, connectionID: connection, completedTurnID: "p1") == .refused(.unverified))
        // The transcript's own record of that turn end completes nothing anew: the turn id stays the hook's.
        let count = await captured.snapshots.count
        try fixture.append([F.stopHookSummary(), F.turnDuration()], to: url)
        await monitor.refresh()
        try await Task.sleep(for: .milliseconds(50))
        let later = await captured.snapshots.dropFirst(count)
        #expect(later.allSatisfy { $0.observation.phase == .idle(completedTurnID: "p1") && $0.publicConclusion == "PING" })
        await monitor.shutdown()
        #expect(!FileManager.default.fileExists(atPath: spool.appRecordURL.path))
    }

    private func binding(_ fixture: ClaudeFixture, url: URL, connection: UUID, stop: UUID) throws -> ClaudeContinuationBinding {
        .init(sessionID: first, connectionID: connection, completedTurnID: "p1",
              process: ClaudeProcessIdentity(pid: 100, seconds: 1_793_354_400, microseconds: 250_000),
              transcript: try fixture.file(url), stopID: stop)
    }
    /// A stand-in hook helper: the push becomes a receipt and, if `records`, the transcript's hook record.
    private func fakeHook(_ spool: HookSpool, stop: UUID, transcript: URL, fixture: ClaudeFixture, records: Bool) -> Thread {
        let push = spool.file(first, stop: stop, suffix: HookSpool.pushSuffix)
        let thread = Thread {
            while !Thread.current.isCancelled {
                if let data = try? HookSpool.readSmall(push),
                   let request = try? HookSpool.decoder.decode(HookSpool.PushRequest.self, from: data) {
                    try? FileManager.default.removeItem(at: push)
                    let receipt = HookSpool.PushReceipt(stopID: stop, pushedAt: Date())
                    try? HookSpool.writeAtomically(try! HookSpool.encoder.encode(receipt), to: spool.file(self.first, stop: stop, suffix: HookSpool.receiptSuffix))
                    if records { try? fixture.append([F.stopHookSummary(followups: [request.text])], to: transcript) }
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        thread.start()
        return thread
    }

    // Refs: US-38, AC-38.03, AC-38.04; US-08, AC-08.01; US-10, AC-10.01, AC-10.03, AC-10.04.
    @Test func adapterHandsTheFollowupToTheHeldHookAndConfirmsFromTheTranscript() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let spool = spool(fixture), stop = UUID()
        try HookSpool.createPrivateDirectory(spool.stopDirectory(first))
        let url = try fixture.transcript([F.typed("Start", uuid: "u1", prompt: "p1"), F.assistant(stop: "end_turn")], session: F.first)
        let connection = UUID(), log = ProgressLog()
        let source = BindingSource(.bound(try binding(fixture, url: url, connection: connection, stop: stop)))
        let hook = fakeHook(spool, stop: stop, transcript: url, fixture: fixture, records: true)
        defer { hook.cancel() }
        let adapter = ClaudeHookAdapter(spool: spool, receiptTimeout: .seconds(3), confirmationTimeout: .seconds(3),
                                        pollInterval: .milliseconds(5), receiptPollInterval: .milliseconds(5))
        let request = ClaudeContinuationRequest(sessionID: first, connectionID: connection, completedTurnID: "p1", text: text)
        #expect(await adapter.continueSession(request, in: source, progress: log.progress) == .delivered)
        #expect(log.events == ["recheck", "submitted"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: spool.stopDirectory(first).path)
        #expect(leftovers.filter { $0.hasSuffix(".push") || $0.hasSuffix(".pushed") }.isEmpty)
        // Without a hook taking it, the request is withdrawn and the outcome is a failure; a receipt without the
        // transcript record is submitted but not confirmed; a refused binding writes nothing.
        let silent = ClaudeHookAdapter(spool: spool, receiptTimeout: .milliseconds(150), confirmationTimeout: .milliseconds(150),
                                       pollInterval: .milliseconds(5), receiptPollInterval: .milliseconds(5))
        let failed = ProgressLog()
        #expect(await silent.continueSession(request, in: source, progress: failed.progress) == .failed)
        #expect(failed.events == ["recheck"] && HookSpool.files(in: spool.stopDirectory(first), suffix: HookSpool.pushSuffix).isEmpty)
        let quiet = fakeHook(spool, stop: stop, transcript: url, fixture: fixture, records: false)
        defer { quiet.cancel() }
        let unconfirmed = ProgressLog()
        let quick = ClaudeHookAdapter(spool: spool, receiptTimeout: .seconds(3), confirmationTimeout: .milliseconds(200),
                                      pollInterval: .milliseconds(5), receiptPollInterval: .milliseconds(5))
        #expect(await quick.continueSession(request, in: source, progress: unconfirmed.progress) == .notConfirmed)
        #expect(unconfirmed.events == ["recheck", "submitted"])
        let refused = ProgressLog()
        #expect(await quick.continueSession(request, in: BindingSource(.refused(.sessionRunning)), progress: refused.progress) == .refused(.sessionRunning))
        #expect(refused.events.isEmpty)
    }
}
