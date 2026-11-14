// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.01, AC-38.02, AC-38.03, AC-38.04, AC-38.07.
import Foundation
import Testing
@testable import LunletHook

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isRaised: Bool { lock.withLock { value } }
    func raise() { lock.withLock { value = true } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Drives the helper the way Claude Code does, against a temporary spool instead of the user's folder.
struct HookRuntimeTests {
    let session = UUID(uuidString: "5E551011-0000-4000-8000-000000000001")!

    private func spool() throws -> HookSpool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-hook-" + UUID().uuidString, isDirectory: true)
        try HookSpool.createPrivateDirectory(root)
        return HookSpool(root: root)
    }
    /// When the announced app process started, as the kernel reports it.
    static let appStart = Date(timeIntervalSince1970: 1_793_354_000.25)
    private func announce(_ spool: HookSpool, pid: Int32 = 4242) throws {
        try HookSpool.writeAtomically(try HookSpool.encoder.encode(HookSpool.AppRecord(pid: pid, startedAt: Self.appStart)), to: spool.appRecordURL)
    }
    private func input(active: Bool = false, event: String = "Stop") -> Data {
        Data("""
        {"session_id":"\(session.uuidString.lowercased())","transcript_path":"/tmp/x.jsonl","cwd":"/tmp","hook_event_name":"\(event)",
         "stop_hook_active":\(active),"prompt_id":"p1","last_assistant_message":"PING","permission_mode":"default"}
        """.utf8)
    }
    private func runtime(_ spool: HookSpool, alive: Set<Int32> = [4242], started: Date = appStart, verdict: TimeInterval = 0.5,
                         hold: TimeInterval = 1) -> HookRuntime {
        HookRuntime(spool: spool, isProcessAlive: { alive.contains($0) }, processStartedAt: { alive.contains($0) ? started : nil },
                    verdictTimeout: verdict, holdLimit: hold, pollInterval: 0.01, holdPollInterval: 0.01)
    }
    /// Answers the next signal of the session with `suffix`, after `delay`, from another thread.
    private func answer(_ spool: HookSpool, suffix: String, delay: TimeInterval = 0.05, push text: String? = nil) {
        Thread {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if let signal = HookSpool.files(in: spool.stopDirectory(self.session), suffix: HookSpool.signalSuffix).first,
                   let stop = HookSpool.stopID(of: signal, suffix: HookSpool.signalSuffix) {
                    Thread.sleep(forTimeInterval: delay)
                    try? HookSpool.writeAtomically(Data("{}".utf8), to: spool.file(self.session, stop: stop, suffix: suffix))
                    if let text {
                        Thread.sleep(forTimeInterval: 0.05)
                        let request = HookSpool.PushRequest(stopID: stop, text: text)
                        try? HookSpool.writeAtomically(try! HookSpool.encoder.encode(request), to: spool.file(self.session, stop: stop, suffix: HookSpool.pushSuffix))
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }.start()
    }

    @Test func withoutAStopEventOrARunningAppNothingIsWritten() throws {
        let spool = try spool(); defer { try? FileManager.default.removeItem(at: spool.root) }
        var lines: [Data] = []
        #expect(runtime(spool).run(input: input(event: "SessionStart"), pid: 100, parentPID: 50) { lines.append($0) } == .ignored)
        #expect(runtime(spool).run(input: input(), pid: 100, parentPID: 50) { lines.append($0) } == .ignored)
        try announce(spool, pid: 9999)
        #expect(runtime(spool, alive: []).run(input: input(), pid: 100, parentPID: 50) { lines.append($0) } == .ignored)
        #expect(lines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: spool.stopDirectory(session).path))
    }

    // Refs: US-38, AC-38.07. After a crash or restart the recorded pid can belong to another process of this user;
    // a pid alone would make every turn wait for a verdict that never comes.
    @Test func aRecordedPidThatNowNamesAnotherProcessIsNotARunningApp() throws {
        let spool = try spool(); defer { try? FileManager.default.removeItem(at: spool.root) }
        try announce(spool)
        var lines: [Data] = []
        // The pid is alive, but its process started an hour after the one that wrote the record.
        let reused = runtime(spool, started: Self.appStart.addingTimeInterval(3_600), verdict: 0.6)
        let began = Date()
        #expect(reused.run(input: input(), pid: 100, parentPID: 50) { lines.append($0) } == .ignored)
        #expect(Date().timeIntervalSince(began) < 0.4 && lines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: spool.stopDirectory(session).path))
        // The record keeps whole seconds, so the same process still matches within one.
        answer(spool, suffix: HookSpool.releaseSuffix)
        #expect(runtime(spool, started: Self.appStart.addingTimeInterval(0.7)).run(input: input(), pid: 100, parentPID: 50) { lines.append($0) } == .released)
        // This process's own start is readable, which is what the app records.
        let own = try #require(HookProcess.startTime(of: getpid()))
        #expect(own < Date() && own > Date(timeIntervalSinceNow: -86_400))
        #expect(HookProcess.startTime(of: -1) == nil)
    }

    @Test func signalCarriesTheTurnAndWaitsOnlyBrieflyForAVerdict() throws {
        let spool = try spool(); defer { try? FileManager.default.removeItem(at: spool.root) }
        try announce(spool)
        var seen: HookSpool.StopSignal?
        let watcher = Thread {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, seen == nil {
                if let url = HookSpool.files(in: spool.stopDirectory(self.session), suffix: HookSpool.signalSuffix).first,
                   let data = try? HookSpool.readSmall(url) { seen = try? HookSpool.decoder.decode(HookSpool.StopSignal.self, from: data) }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        watcher.start()
        let started = Date()
        #expect(runtime(spool, verdict: 0.3).run(input: input(), pid: 100, parentPID: 50) { _ in } == .released)
        #expect(Date().timeIntervalSince(started) < 1.5)
        let signal = try #require(seen)
        #expect(signal.sessionID == session && signal.promptID == "p1" && signal.lastAssistantMessage == "PING")
        #expect(signal.pid == 100 && signal.parentPID == 50 && !signal.stopHookActive)
        #expect(HookSpool.files(in: spool.stopDirectory(session), suffix: HookSpool.signalSuffix).isEmpty)
    }

    @Test func aHeldStopHandsOneFollowupOverAndLeavesAReceipt() throws {
        let spool = try spool(); defer { try? FileManager.default.removeItem(at: spool.root) }
        try announce(spool)
        var lines: [Data] = []
        answer(spool, suffix: HookSpool.holdSuffix, push: "Rerun the failing test")
        #expect(runtime(spool, hold: 3).run(input: input(), pid: 100, parentPID: 50) { lines.append($0) } == .continued)
        #expect(lines.count == 1)
        let object = try #require(try JSONSerialization.jsonObject(with: lines[0]) as? [String: Any])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "Stop")
        #expect(HookOutput.followup(in: specific["additionalContext"] as? String ?? "") == "Rerun the failing test")
        let receipts = HookSpool.files(in: spool.stopDirectory(session), suffix: HookSpool.receiptSuffix)
        #expect(receipts.count == 1)
        #expect(HookSpool.files(in: spool.stopDirectory(session), suffix: HookSpool.pushSuffix).isEmpty)
        #expect(HookSpool.files(in: spool.stopDirectory(session), suffix: HookSpool.holdSuffix).isEmpty)
    }

    @Test func aReleasedOrExpiredHoldHandsNothingOver() throws {
        let spool = try spool(); defer { try? FileManager.default.removeItem(at: spool.root) }
        try announce(spool)
        var lines: [Data] = []
        answer(spool, suffix: HookSpool.releaseSuffix)
        #expect(runtime(spool).run(input: input(), pid: 100, parentPID: 50) { lines.append($0) } == .released)
        answer(spool, suffix: HookSpool.holdSuffix)
        #expect(runtime(spool, hold: 0.3).run(input: input(), pid: 100, parentPID: 50) { lines.append($0) } == .expired)
        #expect(lines.isEmpty)
    }

    // Refs: US-38, AC-38.02. A reply longer than the signal keeps is cut between characters, never emptied, and the
    // encoded signal stays within what the app's bounded read accepts.
    @Test func aLongReplyIsCutBetweenCharactersAndItsSignalStaysReadable() throws {
        let limit = HookSpool.maximumReplyBytes
        // Chinese text is three bytes a character; one leading letter, when needed, puts the limit inside a character.
        let text = String(repeating: "a", count: limit % 3 == 0 ? 1 : 0) + String(repeating: "\u{4E2D}", count: limit / 3 + 2)
        let signal = HookSpool.StopSignal(stopID: session, sessionID: session, promptID: "p1", lastAssistantMessage: text,
                                          stopHookActive: false, pid: 100, parentPID: 50, at: Date(timeIntervalSince1970: 1_793_354_400))
        let kept = signal.lastAssistantMessage
        #expect(!kept.isEmpty && text.hasPrefix(kept))
        #expect(kept.utf8.count <= limit && kept.utf8.count > limit - 4)
        // Quotes and line breaks double when encoded; the bounded read still takes the whole signal.
        let spool = try spool(); defer { try? FileManager.default.removeItem(at: spool.root) }
        let escaped = HookSpool.StopSignal(stopID: session, sessionID: session, promptID: "p1",
                                           lastAssistantMessage: String(repeating: "\"\n", count: limit),
                                           stopHookActive: false, pid: 100, parentPID: 50, at: Date(timeIntervalSince1970: 1_793_354_400))
        #expect(escaped.lastAssistantMessage.utf8.count == limit)
        let url = spool.root.appendingPathComponent("escaped.stop")
        try HookSpool.writeAtomically(try HookSpool.encoder.encode(escaped), to: url)
        let read = try HookSpool.decoder.decode(HookSpool.StopSignal.self, from: try HookSpool.readSmall(url))
        #expect(read == escaped)
    }

    // Refs: US-38, AC-38.07. Quitting Claude Code mid-hold ends the helper with TERM or HUP; it then removes its
    // files, which hold the reply text, and hands nothing over.
    @Test func anInterruptedHelperRemovesItsFilesAndHandsNothingOver() throws {
        let spool = try spool(); defer { try? FileManager.default.removeItem(at: spool.root) }
        try announce(spool)
        let interrupted = Flag()
        answer(spool, suffix: HookSpool.holdSuffix)
        Thread { Thread.sleep(forTimeInterval: 0.3); interrupted.raise() }.start()
        let runtime = HookRuntime(spool: spool, isProcessAlive: { $0 == 4242 }, processStartedAt: { _ in Self.appStart },
                                  verdictTimeout: 0.5, holdLimit: 5, pollInterval: 0.01, isInterrupted: { interrupted.isRaised })
        var lines: [Data] = []
        let began = Date()
        #expect(runtime.run(input: input(), pid: 100, parentPID: 50) { lines.append($0) } == .released)
        #expect(Date().timeIntervalSince(began) < 2 && lines.isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: spool.stopDirectory(session).path)) ?? []
        #expect(left.isEmpty)
        // The real handlers: a delivered HUP only raises the flag.
        #expect(!HookInterrupt.isRaised)
        // Ignored first, so a missing handler fails the expectation below instead of ending the test process.
        signal(SIGHUP, SIG_IGN)
        HookInterrupt.install()
        // Sent to the process, as Claude Code does: test threads keep signals blocked, another thread takes it.
        kill(getpid(), SIGHUP)
        let deadline = Date().addingTimeInterval(2)
        while !HookInterrupt.isRaised, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        #expect(HookInterrupt.isRaised)
        signal(SIGHUP, SIG_DFL); signal(SIGTERM, SIG_DFL)
    }

    // Refs: US-38, AC-38.07; US-25, AC-25.01. A hold lasts up to ten minutes. The helper looks for its files a few
    // times a second and asks whether the app still runs about once a second, not twenty times; an app that is gone
    // still ends the hold within that second.
    @Test func aHoldChecksTheAppRarelyAndStillEndsWhenItIsGone() throws {
        let spool = try spool(); defer { try? FileManager.default.removeItem(at: spool.root) }
        try announce(spool)
        let checks = Counter(), gone = Flag()
        answer(spool, suffix: HookSpool.holdSuffix)
        let runtime = HookRuntime(spool: spool, isProcessAlive: { _ in checks.increment(); return !gone.isRaised },
                                  processStartedAt: { _ in Self.appStart }, verdictTimeout: 0.5, holdLimit: 1.3, pollInterval: 0.01,
                                  holdPollInterval: 0.02, appCheckInterval: 0.5)
        #expect(runtime.run(input: input(), pid: 100, parentPID: 50) { _ in } == .expired)
        // Once before the signal is written, then about every half second of a 1.3 second hold.
        #expect(checks.value >= 2 && checks.value <= 5)
        answer(spool, suffix: HookSpool.holdSuffix)
        Thread { Thread.sleep(forTimeInterval: 0.3); gone.raise() }.start()
        let began = Date()
        let ending = HookRuntime(spool: spool, isProcessAlive: { _ in !gone.isRaised }, processStartedAt: { _ in Self.appStart },
                                 verdictTimeout: 0.5, holdLimit: 10, pollInterval: 0.01, holdPollInterval: 0.02, appCheckInterval: 0.5)
        #expect(ending.run(input: input(), pid: 100, parentPID: 50) { _ in } == .released)
        #expect(Date().timeIntervalSince(began) < 3)
    }

    @Test func inputParsingAndOutputFormsAreTheDocumentedOnes() {
        #expect(HookInput(Data("not json".utf8)) == nil)
        #expect(HookInput(Data(#"{"hook_event_name":"Stop"}"#.utf8)) == nil)
        let hook = HookInput(input(active: true))
        #expect(hook?.sessionID == session && hook?.stopHookActive == true && hook?.promptID == "p1")
        let line = String(decoding: HookOutput.continuation(text: "Go on"), as: UTF8.self)
        #expect(line.contains("\"hookEventName\":\"Stop\"") && line.contains("through Lunlet") && !line.contains("\n"))
        #expect(HookOutput.followup(in: "Please run the tests") == nil)
        #expect(HookSpool.launcherScript.hasPrefix("#!/bin/sh\n") && HookSpool.launcherScript.contains("helper-path"))
        #expect(HookSpool.standard().root.pathComponents.suffix(3) == ["Application Support", "com.lunlet", "hook"])
        #expect(HookSpool.standard().file(session, stop: session, suffix: HookSpool.pushSuffix).lastPathComponent == "5e551011-0000-4000-8000-000000000001.push")
        #expect(!HookSpool.PushRequest(stopID: session, text: " \n").isAcceptable)
        #expect(!HookSpool.PushRequest(stopID: session, text: String(repeating: "x", count: 8_193)).isAcceptable)
    }
}
