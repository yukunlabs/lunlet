// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-25, AC-25.01, AC-25.02; US-02, AC-02.06; US-04, AC-04.05.
// Refs: US-03, AC-03.01, AC-03.05; US-12, AC-12.04.
import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
import LunletCore
@testable import LunletCodex
@testable import LunletDesktop

private struct BenchmarkProcesses: CodexProcessInspecting {
    let candidates: [CodexProcessCandidate]
    func scan() -> CodexProcessScan { .init(candidates: candidates, complete: true) }
    func presence(of process: CodexProcessIdentity) -> CodexProcessPresence { .same }
}
private struct BenchmarkHistory: LocalUsageReading {
    func readHistory(now: Date, calendar: Calendar, days: Int) async throws -> LocalUsageHistory {
        .init(days: [], sessions: [:], partial: false)
    }
}
@MainActor private final class BenchmarkCueSink: TaskCuePresenting {
    func show(_ cues: [TaskCue]) {}
    func hide() {}
}

private struct ProcessSample {
    let time = ContinuousClock.now
    let usage: rusage_info_v4
    let cpuSeconds: Double
    init() throws {
        var value = rusage_info_v4()
        let result = withUnsafeMutableBytes(of: &value) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
        }
        guard result == 0 else { throw POSIXError(.ESRCH) }
        usage = value
        var cpu = rusage()
        guard getrusage(RUSAGE_SELF, &cpu) == 0 else { throw POSIXError(.ESRCH) }
        cpuSeconds = Double(cpu.ru_utime.tv_sec + cpu.ru_stime.tv_sec)
            + Double(cpu.ru_utime.tv_usec + cpu.ru_stime.tv_usec) / 1_000_000
    }
    func report(_ name: String, from previous: Self) -> [String: Any] {
        let parts = previous.time.duration(to: time).components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        let cpu = cpuSeconds - previous.cpuSeconds
        return ["workload": name, "elapsedMS": seconds * 1000, "cpuMS": cpu * 1000,
                "cpuPercentOfOneCore": seconds > 0 ? 100 * cpu / seconds : 0,
                "footprintMiB": Double(usage.ri_phys_footprint) / 1_048_576,
                "footprintDeltaMiB": (Double(usage.ri_phys_footprint) - Double(previous.usage.ri_phys_footprint)) / 1_048_576,
                "physicalReadBytes": usage.ri_diskio_bytesread - previous.usage.ri_diskio_bytesread,
                "idleWakeups": usage.ri_pkg_idle_wkups - previous.usage.ri_pkg_idle_wkups,
                "interruptWakeups": usage.ri_interrupt_wkups - previous.usage.ri_interrupt_wkups]
    }
}

/// Explicit measurement, never part of the normal edit loop. Uses owned synthetic
/// files/process bindings and windows; no credentials, accounts or personal records.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_PERFORMANCE"] == "1"))
@MainActor struct PerformanceBudgetTests {
    @Test func measureLargeHistoryIdleObservationAndPanelOpening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-benchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = "2026-10-27T04:00:00Z"
        func record(_ type: String, _ payload: [String: Any]) throws -> Data {
            var result = try JSONSerialization.data(withJSONObject: ["timestamp": stamp, "type": type, "payload": payload])
            result.append(10); return result
        }
        var candidates: [CodexProcessCandidate] = []
        var totalBytes = 0
        var expectedCompletions = Set<UUID>()
        for index in 0..<1000 {
            try autoreleasepool {
                let id = UUID()
                var data = try record("session_meta", ["id": id.uuidString, "source": "cli", "cwd": "/synthetic/project"])
                data.append(try record("turn_context", ["model": "gpt-6.1-sol"]))
                data.append(try record("event_msg", ["type": "task_started", "turn_id": "initial"]))
                for request in 1...20 {
                    let amount = ["input_tokens": request * 100, "output_tokens": request * 10,
                                  "cached_input_tokens": 0, "reasoning_output_tokens": 0, "total_tokens": request * 110]
                    let last = ["input_tokens": 100, "output_tokens": 10, "cached_input_tokens": 0,
                                "reasoning_output_tokens": 0, "total_tokens": 110]
                    data.append(try record("event_msg", ["type": "token_count", "info": ["total_token_usage": amount, "last_token_usage": last]]))
                }
                let url = directory.appendingPathComponent("sample-\(index).jsonl")
                try data.write(to: url); totalBytes += data.count
                if index < 20 { expectedCompletions.insert(id) }
                if index < 200 {
                    var status = stat()
                    guard lstat(url.path, &status) == 0 else { throw POSIXError(.ENOENT) }
                    candidates.append(.init(process: .init(pid: Int32(10000 + index), seconds: 1, microseconds: 0),
                        files: [.init(url: url, device: status.st_dev, inode: status.st_ino)]))
                }
            }
        }
        var reports: [[String: Any]] = []
        let reader = CodexLocalUsageReader(home: root)
        let now = try #require(ISO8601DateFormatter().date(from: stamp))
        let cold = try ProcessSample()
        let first = try await reader.readHistory(now: now, calendar: .current, days: 7)
        reports.append(try ProcessSample().report("history-cold-1000-sessions-20000-samples", from: cold))
        #expect(first.sessions.count == 1000 && !first.partial)
        let warm = try ProcessSample()
        let second = try await reader.readHistory(now: now, calendar: .current, days: 7)
        reports.append(try ProcessSample().report("history-warm-unchanged", from: warm))
        #expect(first == second)

        let monitor = CodexSessionMonitor(processes: BenchmarkProcesses(candidates: candidates))
        do {
            let observation = try ProcessSample()
            let stream = await monitor.updates()
            var iterator = stream.makeAsyncIterator()
            var snapshots: [SessionSnapshot] = []
            while let event = await iterator.next() {
                if case .snapshot(let value, _) = event { snapshots.append(value) }
                if case .availability = event { break }
            }
            #expect(snapshots.count == 200)
            reports.append(try ProcessSample().report("observation-cold-200-sessions", from: observation))
            let idle = try ProcessSample()
            try await Task.sleep(for: .seconds(12))
            reports.append(try ProcessSample().report("observation-idle-12-seconds", from: idle))
            for candidate in candidates.prefix(20) {
                let handle = try FileHandle(forWritingTo: candidate.files[0].url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: record("event_msg", ["type": "task_complete", "turn_id": "initial"]))
            }
            let active = try ProcessSample()
            await monitor.reconcile()
            var completed = Set<UUID>()
            while let event = await iterator.next() {
                if case .snapshot(let value, _) = event, case .idle("initial") = value.observation.phase {
                    completed.insert(value.observation.sessionID)
                }
                if case .reconciled = event { break }
            }
            #expect(completed == expectedCompletions)
            reports.append(try ProcessSample().report("observation-20-completions", from: active))
            await monitor.shutdown()

            _ = NSApplication.shared
            let model = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: BenchmarkCueSink())
            for value in snapshots { model.receive(value, origin: .snapshot) }
            let usage = LocalUsageModel(reader: BenchmarkHistory())
            let controller = CompanionPanelController(motionAllowed: { false }, observesSystemEvents: false, screen: {
                .init(frame: .init(x: 0, y: 0, width: 1512, height: 982),
                      visibleFrame: .init(x: 0, y: 90, width: 1512, height: 859), safeTop: 32)
            })
            controller.setContent { AnyView(ScrollView { SessionPanel(model: model, usage: usage).padding(16) }) }
            defer { controller.shutdown(); model.shutdown() }
            for name in ["panel-cold-200-sessions", "panel-reopen-200-sessions"] {
                let opened = try ProcessSample()
                controller.show()
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                controller.window?.displayIfNeeded()
                #expect(controller.isVisible)
                reports.append(try ProcessSample().report(name, from: opened))
                controller.hide(animated: false)
            }
            await usage.shutdown()
            let envelope: [String: Any] = ["fixtureBytes": totalBytes, "build": "debug", "reports": reports]
            print("LUNLET_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            await monitor.shutdown()
            throw error
        }
    }
}
