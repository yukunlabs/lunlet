// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.01, AC-38.02, AC-38.03, AC-38.04, AC-38.05, AC-38.06, AC-38.07; US-08, AC-08.01, AC-08.03, AC-08.04;
// US-10, AC-10.01, AC-10.03, AC-10.04; US-11, AC-11.03; US-13, AC-13.04; US-33, AC-33.07; US-06, AC-06.02.
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

/// A wall clock a test moves forward.
private final class HookClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
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
        let end = ContinuousClock.now + .seconds(60)
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
        // The command tests for the launcher before running it; the form earlier builds wrote was the launcher alone.
        #expect(connection.command == "/bin/sh -c 'if [ -x " + connection.legacyCommand + " ]; then exec " + connection.legacyCommand + "; fi'")
        #expect(connection.legacyCommand.hasPrefix("\"") && connection.legacyCommand.hasSuffix("/lunlet-hook\""))
    }

    /// Runs a settings command the way a shell does, with no input.
    private func run(_ command: String, shell: String = "/bin/sh") throws -> (status: Int32, output: String) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // Refs: US-38, AC-38.01, AC-38.07. The entry outlives Lunlet's own folder when an app cleaner removes it or the
    // settings are synced to a Mac without Lunlet; the command then has to end quietly at every turn end. An entry
    // an earlier build wrote is still Lunlet's: it is brought to this command where it stands and removed like it.
    @Test func theHookCommandEndsQuietlyWithoutLunletsFolderAndAnEarlierEntryStaysLunlets() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let spool = spool(fixture), connection = ClaudeHookConnection(home: fixture.home, spool: spool)
        // No folder, no launcher: nothing printed, success, in each shell that may run it.
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
            let absent = try run(connection.command, shell: shell)
            #expect(absent.status == 0 && absent.output.isEmpty)
        }
        // With the launcher and a published helper the command runs the helper.
        let marker = fixture.root.appendingPathComponent("helper-ran"), helper = fixture.root.appendingPathComponent("helper")
        try Data("#!/bin/sh\necho ran > '\(marker.path)'\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        ClaudeHookInstallation.prepare(helper: helper, spool: spool)
        let original = """
        {
          "model": "opus",
          "hooks": {
            "Stop": [{"hooks": [{"type": "command", "command": "first.sh"}]},
                     {"hooks": [{"type": "command", "command": \(try ClaudeSettingsDocument.literal(connection.legacyCommand)), "timeout": 900}]},
                     {"hooks": [{"type": "command", "command": "last.sh"}]}]
          }
        }

        """
        try Data(original.utf8).write(to: fixture.home.settings)
        // The earlier form counts as connected, and connecting rewrites only that entry's command.
        #expect(try connection.state() == .connected)
        #expect(try connection.connect() == .connected)
        let present = try run(connection.command)
        #expect(present.status == 0 && FileManager.default.fileExists(atPath: marker.path))
        let object = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: fixture.home.settings)) as? [String: Any])
        let stops = try #require((object["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        let commands = stops.compactMap { (($0["hooks"] as? [[String: Any]])?.first)?["command"] as? String }
        #expect(commands == ["first.sh", connection.command, "last.sh"] && connection.command != connection.legacyCommand)
        #expect(object["model"] as? String == "opus")
        // Removal takes out exactly Lunlet's entry, whichever form it has.
        #expect(try connection.disconnect() == .notConnected)
        try Data(original.utf8).write(to: fixture.home.settings)
        #expect(try connection.disconnect() == .notConnected)
        let left = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: fixture.home.settings)) as? [String: Any])
        let remaining = try #require((left["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect(remaining.compactMap { (($0["hooks"] as? [[String: Any]])?.first)?["command"] as? String } == ["first.sh", "last.sh"])
    }

    // Refs: US-38, AC-38.06; US-25, AC-25.01. The monitor asks on every scan whether the hook is connected, only to
    // word a note; the settings are read and parsed again only when the file changed.
    @Test func theHookStateIsReadAgainOnlyWhenTheSettingsChanged() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let connection = ClaudeHookConnection(home: fixture.home, spool: spool(fixture))
        let cache = ClaudeHookStateCache(connection)
        // No settings file yet: not connected, and nothing to remember.
        #expect(!cache.isConnected())
        try Data(#"{"model": "opus"}"#.utf8).write(to: fixture.home.settings)
        #expect(!cache.isConnected() && !cache.isConnected())
        let before = cache.reads
        #expect(!cache.isConnected() && cache.reads == before)
        #expect(try connection.connect() == .connected)
        #expect(cache.isConnected() && cache.isConnected() && cache.reads == before + 1)
        #expect(try connection.disconnect() == .notConnected)
        #expect(!cache.isConnected() && !cache.isConnected() && cache.reads == before + 2)
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

    /// A monitor over the fixture with one interactive session owned by pid 100, observed once.
    private func observedSession(_ fixture: ClaudeFixture, _ spool: HookSpool, _ processes: HookProcesses, _ captured: Captured,
                                 kind: String? = "interactive", lines: [String]? = nil,
                                 wallNow: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_793_354_500) })
        async throws -> (ClaudeSessionMonitor, Task<Void, Never>, URL) {
        try fixture.record(pid: 100, session: F.first, kind: kind)
        let url = try fixture.transcript(lines ?? [F.typed("Start", uuid: "u1", prompt: "p1"),
                                                   F.assistant(stop: "end_turn", content: [["type": "text", "text": "PING"]])], session: F.first)
        processes.start(100)
        let monitor = ClaudeSessionMonitor(home: fixture.home, registry: ClaudeSessionRegistry(directory: fixture.home.sessions),
                                           processes: processes, wallNow: wallNow,
                                           hooks: spool, hookConnected: { true })
        let stream = await monitor.updates()
        let sink = Task { for await update in stream { await captured.append(update) } }
        try await settle(captured) { $0.contains { $0.observation.sessionID == self.first } }
        return (monitor, sink, url)
    }

    // Refs: US-38, AC-38.02; US-06, AC-06.02. The hook keeps as much of the reply as a notice captures, so a longer
    // one reaches the phone marked as shortened instead of ending mid-sentence or arriving empty.
    @Test func aReplyLongerThanTheHookKeepsIsMarkedShortenedInItsNotice() async throws {
        #expect(HookSpool.maximumReplyBytes == NoticeText.captureLimit)
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let spool = spool(fixture), processes = HookProcesses(), captured = Captured()
        let (monitor, sink, _) = try await observedSession(fixture, spool, processes, captured)
        defer { sink.cancel() }
        await monitor.setReplyWindow(true)
        processes.start(200, parent: 100)
        // 60,000 bytes of three-byte characters: a five-character Chinese sentence, written as escapes.
        let sentence = "\u{4E2D}\u{6587}\u{56DE}\u{590D}\u{3002}"
        _ = try signal(spool, session: first, pid: 200, parent: 100, reply: String(repeating: sentence, count: 4_000))
        await monitor.refresh()
        try await settle(captured) { $0.last?.inputPath == .claudeHook }
        let held = try #require(await captured.snapshots.last)
        let result = SessionNotice.prepare(held).result()
        #expect(result.text?.hasPrefix(sentence) == true && result.shortened)
        await monitor.shutdown()
    }

    // Refs: US-38, AC-38.02, AC-38.07. A scripted or otherwise non-interactive run is never kept waiting for a phone reply.
    @Test func onlyAnInteractiveSessionIsHeld() async throws {
        for kind in ["headless", nil] as [String?] {
            let fixture = try ClaudeFixture(); defer { fixture.remove() }
            let spool = spool(fixture), processes = HookProcesses(), captured = Captured()
            let (monitor, sink, _) = try await observedSession(fixture, spool, processes, captured, kind: kind)
            defer { sink.cancel() }
            await monitor.setReplyWindow(true)
            processes.start(200, parent: 100)
            let stop = try signal(spool, session: first, pid: 200, parent: 100)
            await monitor.refresh()
            try await settle(captured) { $0.last?.observation.phase == .idle(completedTurnID: "p1") }
            // The turn still completes from the hook; only the hold is withheld.
            let done = try #require(await captured.snapshots.last)
            #expect(done.observation.phase == .idle(completedTurnID: "p1") && done.inputPath == nil)
            #expect(exists(spool, first, stop, HookSpool.releaseSuffix) && !exists(spool, first, stop, HookSpool.holdSuffix))
            await monitor.shutdown()
        }
    }

    // Refs: US-38, AC-38.02, AC-38.05, AC-38.07; US-13, AC-13.04. A stop is held only when it completes a turn that was
    // not completed before: a second stop of the same turn, or one the transcript's turn does not match, would wait
    // ten minutes for a notice that is never sent.
    @Test func aStopThatCompletesNothingNewIsReleasedAtOnce() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let spool = spool(fixture), processes = HookProcesses(), captured = Captured()
        let (monitor, sink, url) = try await observedSession(fixture, spool, processes, captured)
        defer { sink.cancel() }
        await monitor.setReplyWindow(true)
        processes.start(200, parent: 100)
        let held = try signal(spool, session: first, pid: 200, parent: 100)
        await monitor.refresh()
        try await settle(captured) { $0.last?.inputPath == .claudeHook }
        #expect(exists(spool, first, held, HookSpool.holdSuffix))
        // That helper ends; the hold goes with it.
        processes.end(200)
        await monitor.refresh()
        try await settle(captured) { $0.last?.inputPath == nil }
        // The same turn stops again, as after another hook continued it or an injected turn ended.
        processes.start(201, parent: 100)
        let repeated = try signal(spool, session: first, pid: 201, parent: 100)
        await monitor.refresh()
        #expect(exists(spool, first, repeated, HookSpool.releaseSuffix) && !exists(spool, first, repeated, HookSpool.holdSuffix))
        // A stop whose prompt the transcript's turn does not name completes nothing either.
        processes.start(202, parent: 100)
        let foreign = try signal(spool, session: first, pid: 202, parent: 100, prompt: "n1")
        await monitor.refresh()
        #expect(exists(spool, first, foreign, HookSpool.releaseSuffix) && !exists(spool, first, foreign, HookSpool.holdSuffix))
        let quiet = try #require(await captured.snapshots.last)
        #expect(quiet.inputPath == nil && quiet.observation.phase == .idle(completedTurnID: "p1"))
        // After a follow-up from the phone the turn completes again under a new id, and that stop is held.
        try fixture.append([F.stopHookSummary(followups: ["Go on"])], to: url)
        await monitor.refresh()
        processes.start(203, parent: 100)
        let continued = try signal(spool, session: first, pid: 203, parent: 100)
        await monitor.refresh()
        try await settle(captured) { $0.last?.inputPath == .claudeHook }
        #expect(exists(spool, first, continued, HookSpool.holdSuffix))
        #expect(await captured.snapshots.last?.observation.phase == .idle(completedTurnID: "p1#1"))
        await monitor.shutdown()
    }

    // Refs: US-38, AC-38.07. The helper waits up to three seconds for a verdict, so a stop of a session the monitor
    // does not track (an unverified owner, no transcript yet, over a budget) is answered too, once a scan has looked.
    @Test func aStopOfAnUntrackedSessionIsReleasedOnceAScanHasLooked() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let spool = spool(fixture), processes = HookProcesses(), captured = Captured()
        let (monitor, sink, _) = try await observedSession(fixture, spool, processes, captured)
        defer { sink.cancel() }
        processes.start(400, parent: 999)
        let stray = try signal(spool, session: second, pid: 400, parent: 999)
        // Opening the window looks at the stop folder; the untracked session gets its answer without a held turn.
        await monitor.setReplyWindow(true)
        #expect(exists(spool, second, stray, HookSpool.releaseSuffix) && !exists(spool, second, stray, HookSpool.holdSuffix))
        let later = try signal(spool, session: second, pid: 400, parent: 999)
        await monitor.refresh()
        #expect(exists(spool, second, later, HookSpool.releaseSuffix) && !exists(spool, second, later, HookSpool.holdSuffix))
        // The tracked session is untouched by it.
        #expect(await captured.snapshots.last?.observation.sessionID == first)
        #expect(await captured.snapshots.last?.observation.phase == .running)
        await monitor.shutdown()
    }

    // Refs: US-38, AC-38.01, AC-38.07. Launching Lunlet publishes its helper; only the running Claude source announces
    // an app for the helper to wait on, with the start time that tells its process from a later one with the same pid.
    @Test func onlyTheRunningMonitorAnnouncesTheAppToTheHelper() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let spool = spool(fixture)
        let helper = fixture.root.appendingPathComponent("lunlet-hook-helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        ClaudeHookInstallation.prepare(helper: helper, spool: spool)
        #expect(String(decoding: try Data(contentsOf: spool.helperPathFile), as: UTF8.self) == helper.path + "\n")
        #expect(!FileManager.default.fileExists(atPath: spool.appRecordURL.path))
        let processes = HookProcesses(), captured = Captured()
        let (monitor, sink, _) = try await observedSession(fixture, spool, processes, captured)
        defer { sink.cancel() }
        let record = try HookSpool.decoder.decode(HookSpool.AppRecord.self, from: try HookSpool.readSmall(spool.appRecordURL))
        let started = try #require(HookProcess.startTime(of: getpid()))
        #expect(record.pid == getpid() && abs(record.startedAt.timeIntervalSince(started)) <= 1)
        await monitor.shutdown()
        #expect(!FileManager.default.fileExists(atPath: spool.appRecordURL.path))
    }

    private func stopFiles(_ spool: HookSpool, _ session: UUID) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: spool.stopDirectory(session).path)) ?? []).sorted()
    }

    // Refs: US-38, AC-38.07; US-33, AC-33.07. A helper killed mid-hold cannot remove its own files, which hold the
    // reply text; the app removes them when it sees the hold end that way, instead of answering a process that is gone.
    @Test func aHoldWhoseHelperDiedLeavesNoFilesBehind() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let spool = spool(fixture), processes = HookProcesses(), captured = Captured()
        let (monitor, sink, _) = try await observedSession(fixture, spool, processes, captured)
        defer { sink.cancel() }
        await monitor.setReplyWindow(true)
        processes.start(200, parent: 100)
        let stop = try signal(spool, session: first, pid: 200, parent: 100)
        await monitor.refresh()
        try await settle(captured) { $0.last?.inputPath == .claudeHook }
        #expect(exists(spool, first, stop, HookSpool.holdSuffix))
        processes.end(200)
        await monitor.refresh()
        try await settle(captured) { $0.last?.inputPath == nil }
        // The folder of a session still observed stays, since the monitor watches it for the next stop.
        #expect(stopFiles(spool, first).isEmpty)
        await monitor.shutdown()
    }

    // Refs: US-38, AC-38.07. Lunlet runs for weeks, so what a killed helper left is swept while it runs, not only
    // at the next launch.
    @Test func theMonitorSweepsWhatGoneHelpersLeftWhileItRuns() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let spool = spool(fixture), processes = HookProcesses(), captured = Captured(), clock = HookClock()
        let (monitor, sink, _) = try await observedSession(fixture, spool, processes, captured, wallNow: { clock.now })
        defer { sink.cancel() }
        processes.start(400, parent: 999)
        let stray = try signal(spool, session: second, pid: 400, parent: 999)
        await monitor.refresh()
        #expect(exists(spool, second, stray, HookSpool.releaseSuffix))
        // The helper is killed before it can remove its signal and the verdict.
        processes.end(400)
        clock.advance(120)
        await monitor.refresh()
        #expect(!FileManager.default.fileExists(atPath: spool.stopDirectory(second).path))
        await monitor.shutdown()
    }

    // Refs: US-38, AC-38.07. Stops are remembered so none is answered twice; forgetting them all at once made the
    // next scan read a live hold's signal again and release it.
    @Test func aLiveHoldSurvivesThousandsOfOtherStops() async throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let spool = spool(fixture), processes = HookProcesses(), captured = Captured()
        let (monitor, sink, _) = try await observedSession(fixture, spool, processes, captured)
        defer { sink.cancel() }
        await monitor.setReplyWindow(true)
        processes.start(200, parent: 100)
        let held = try signal(spool, session: first, pid: 200, parent: 100)
        await monitor.refresh()
        try await settle(captured) { $0.last?.inputPath == .claudeHook }
        // Stops that are not the session's own are released and remembered.
        processes.start(300, parent: 999)
        for _ in 0..<4_200 { _ = try signal(spool, session: first, pid: 300, parent: 999) }
        await monitor.refresh()
        await monitor.refresh()
        #expect(exists(spool, first, held, HookSpool.holdSuffix) && !exists(spool, first, held, HookSpool.releaseSuffix))
        #expect(await captured.snapshots.last?.inputPath == .claudeHook)
        await monitor.shutdown()
    }

    // Refs: US-38, AC-38.07. The sweep removes what a gone helper left, stop by stop, and never what a helper or the
    // reply path may still be using: a live helper's files, a fresh receipt or request, a folder just created.
    @Test func theSweepRemovesOnlyWhatAGoneHelperLeft() throws {
        let fixture = try ClaudeFixture(); defer { fixture.remove() }
        let spool = spool(fixture), now = Date()
        func touch(_ session: UUID, _ stop: UUID, _ suffix: String) throws {
            try HookSpool.writeAtomically(Data("{}".utf8), to: spool.file(session, stop: stop, suffix: suffix))
        }
        // A live helper holding.
        let live = try signal(spool, session: first, pid: 10, parent: 1)
        try touch(first, live, HookSpool.holdSuffix)
        // A helper that is gone: its signal and verdicts go at once, a request the reply path wrote stays for now.
        let dead = try signal(spool, session: second, pid: 11, parent: 1)
        try touch(second, dead, HookSpool.holdSuffix); try touch(second, dead, HookSpool.releaseSuffix); try touch(second, dead, HookSpool.pushSuffix)
        // A verdict written after its helper had left, and a folder a helper has just made.
        let orphan = UUID(uuidString: "0b6b2a52-5f0e-4c5c-9d43-3c4f0a1b2c03")!, fresh = UUID(uuidString: "0b6b2a52-5f0e-4c5c-9d43-3c4f0a1b2c04")!
        try HookSpool.createPrivateDirectory(spool.stopDirectory(orphan)); try HookSpool.createPrivateDirectory(spool.stopDirectory(fresh))
        let late = UUID()
        try touch(orphan, late, HookSpool.releaseSuffix)
        ClaudeHookInstallation.sweepStale(spool: spool, isProcessAlive: { $0 == 10 }, now: now, grace: 60)
        #expect(stopFiles(spool, first).count == 2)
        #expect(stopFiles(spool, second) == [dead.uuidString.lowercased() + HookSpool.pushSuffix])
        #expect(stopFiles(spool, orphan).count == 1)
        #expect(FileManager.default.fileExists(atPath: spool.stopDirectory(fresh).path))
        // Past the grace period everything a gone helper left is removed, with its folder; the live hold stays.
        ClaudeHookInstallation.sweepStale(spool: spool, isProcessAlive: { $0 == 10 }, now: now.addingTimeInterval(120), grace: 60)
        #expect(stopFiles(spool, first).count == 2)
        for session in [second, orphan, fresh] { #expect(!FileManager.default.fileExists(atPath: spool.stopDirectory(session).path)) }
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
