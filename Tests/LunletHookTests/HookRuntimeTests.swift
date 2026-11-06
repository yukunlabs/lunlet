// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.01, AC-38.02, AC-38.03, AC-38.04, AC-38.07.
import Foundation
import Testing
@testable import LunletHook

/// Drives the helper the way Claude Code does, against a temporary spool instead of the user's folder.
struct HookRuntimeTests {
    let session = UUID(uuidString: "5E551011-0000-4000-8000-000000000001")!

    private func spool() throws -> HookSpool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-hook-" + UUID().uuidString, isDirectory: true)
        try HookSpool.createPrivateDirectory(root)
        return HookSpool(root: root)
    }
    private func announce(_ spool: HookSpool, pid: Int32 = 4242) throws {
        try HookSpool.writeAtomically(try HookSpool.encoder.encode(HookSpool.AppRecord(pid: pid, startedAt: Date())), to: spool.appRecordURL)
    }
    private func input(active: Bool = false, event: String = "Stop") -> Data {
        Data("""
        {"session_id":"\(session.uuidString.lowercased())","transcript_path":"/tmp/x.jsonl","cwd":"/tmp","hook_event_name":"\(event)",
         "stop_hook_active":\(active),"prompt_id":"p1","last_assistant_message":"PING","permission_mode":"default"}
        """.utf8)
    }
    private func runtime(_ spool: HookSpool, alive: Set<Int32> = [4242], verdict: TimeInterval = 0.5, hold: TimeInterval = 1) -> HookRuntime {
        HookRuntime(spool: spool, isProcessAlive: { alive.contains($0) }, verdictTimeout: verdict, holdLimit: hold, pollInterval: 0.01)
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
