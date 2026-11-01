// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.08, AC-33.09; US-04, AC-04.03.
// Runs the exact installed script against synthetic status-line input in per-test temporary directories.
import Foundation
import Testing
@testable import LunletClaude

/// A synthetic Lunlet directory holding the installed script, plus a separate scratch directory for inputs.
struct StatusLineSandbox {
    let root: URL
    var location: ClaudeStatusLineLocation { .init(directory: root.appendingPathComponent("lunlet", isDirectory: true)) }
    var scratch: URL { root.appendingPathComponent("scratch", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-status-line-\(UUID().uuidString)",
                                                                             isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lunlet"), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scratch"), withIntermediateDirectories: true)
        try Data(ClaudeStatusLineScript.source.utf8).write(to: location.script)
    }
    func remove() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: location.directory.path)
        try? FileManager.default.removeItem(at: root)
    }

    struct Run { let output: String; let status: Int32; let seconds: Double }
    func run(_ input: String) throws -> Run { try run(Data(input.utf8)) }
    func run(_ input: Data) throws -> Run {
        let file = scratch.appendingPathComponent("input-\(UUID().uuidString)")
        try input.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [location.script.path]
        process.standardInput = try FileHandle(forReadingFrom: file)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let started = ContinuousClock.now
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let elapsed = ContinuousClock.now - started
        return .init(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus,
                     seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }
    func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    var entries: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: location.directory.path)) ?? []).sorted() }
    func setPrevious(_ command: String) throws {
        try JSONSerialization.data(withJSONObject: ["version": 1, "previousCommand": command]).write(to: location.backup)
    }

    /// Claude Code's documented status-line input with every non-limit field the script must discard.
    static func input(fiveHour: (Double, Int)? = nil, sevenDay: (Double, Int)? = nil, extra: String = "") -> String {
        var windows: [String] = []
        if let fiveHour { windows.append(#""five_hour":{"used_percentage":\#(fiveHour.0),"resets_at":\#(fiveHour.1)}"#) }
        if let sevenDay { windows.append(#""seven_day":{"used_percentage":\#(sevenDay.0),"resets_at":\#(sevenDay.1)}"#) }
        windows.append(#""spend_limit":{"used_percentage":62.8,"resets_at":1740787200,"used_usd":314.12}"#)
        return #"""
        {"session_id":"synthetic-session-7f3a","transcript_path":"/tmp/synthetic/transcript.jsonl","cwd":"/tmp/synthetic/project",
        "model":{"id":"claude-opus-5-5","display_name":"Opus"},"workspace":{"current_dir":"/tmp/synthetic/project"},
        "cost":{"total_cost_usd":0.4242},"context_window":{"current_usage":null,"used_percentage":null}\#(extra),
        "rate_limits":{\#(windows.joined(separator: ","))}}
        """#
    }
}

@Suite struct ClaudeStatusLineScriptTests {
    typealias Sandbox = StatusLineSandbox
    var now: Int { Int(Date().timeIntervalSince1970) }

    // Refs: US-33, AC-33.08.
    @Test func keepsOnlyBothWindowsAndPrintsTheCompactLine() throws {
        let box = try Sandbox(); defer { box.remove() }
        let five = now + 83 * 60 + 40, week = now + 3 * 86_400 + 3_640
        let run = try box.run(Sandbox.input(fiveHour: (23.5, five), sevenDay: (41.2, week)))
        #expect(run.status == 0 && run.output == "5h 23% · 7d 41% · resets 1h23m\n")
        let lines = try #require(box.text(box.location.limits)).split(separator: "\n").map(String.init)
        #expect(lines.count == 3 && lines[0] == "lunlet-claude-limits 1")
        #expect(lines[1].hasPrefix("five_hour 23.5 \(five) ") && lines[2].hasPrefix("seven_day 41.2 \(week) "))
        // Only the two windows' numbers and observation times are stored; nothing else from the input survives.
        let stored = try #require(box.text(box.location.limits)) + (box.text(box.location.weeklyLog) ?? "")
        for secret in ["synthetic-session", "/tmp/synthetic", "opus", "0.4242", "62.8", "314", "1740787200"] {
            #expect(!stored.contains(secret), "\(secret) persisted")
        }
        #expect(stored.range(of: #"^[a-z0-9_ .\n-]+$"#, options: .regularExpression) != nil)
        #expect(box.entries == ["claude-status-line.sh", "limits", "weekly-readings.log"])
        for url in [box.location.limits, box.location.weeklyLog] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
        #expect(box.text(box.location.weeklyLog)?.split(separator: "\n").count == 1)
    }

    // Refs: US-33, AC-33.08, AC-33.09.
    @Test func eachWindowMayBeAbsentAndNothingMisleadingIsPrinted() throws {
        let box = try Sandbox(); defer { box.remove() }
        let week = now + 2 * 86_400 + 4 * 3_600 + 60
        let weekly = try box.run(Sandbox.input(sevenDay: (41, week)))
        #expect(weekly.status == 0 && weekly.output == "7d 41% · resets 2d4h\n")
        #expect(box.text(box.location.limits)?.contains("five_hour") == false)
        // A session before its first response, an API-key account and a gateway-only window report no plan limits.
        for input in [Sandbox.input(), #"{"model":{"id":"m"}}"#] {
            let run = try box.run(input)
            #expect(run.status == 0 && run.output.isEmpty)
        }
        #expect(box.text(box.location.limits)?.contains("seven_day 41 \(week)") == true)
    }

    // Refs: US-33, AC-33.08; US-04, AC-04.03.
    @Test func malformedInputAndInvalidValuesNeverFailAndStoreNothing() throws {
        let box = try Sandbox(); defer { box.remove() }
        let reset = now + 3_600
        let inputs = ["", "{", "[1,2]", "null", #"{"rate_limits":null}"#, #"{"rate_limits":{"five_hour":null}}"#,
                      #"{"rate_limits":{"five_hour":{"used_percentage":"23","resets_at":\#(reset)}}}"#,
                      #"{"rate_limits":{"five_hour":{"used_percentage":101,"resets_at":\#(reset)}}}"#,
                      #"{"rate_limits":{"five_hour":{"used_percentage":-1,"resets_at":\#(reset)}}}"#,
                      #"{"rate_limits":{"five_hour":{"used_percentage":1e-9,"resets_at":\#(reset)}}}"#,
                      #"{"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":"soon"}}}"#,
                      #"{"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":\#(now + 30 * 86_400)}}}"#,
                      #"{"rate_limits":{"five_hour":{"used_percentage":20}}}"#,
                      #"{"rate_limits":{"five_hour":{"nested":{"used_percentage":20,"resets_at":\#(reset)}}}}"#,
                      "\u{0}\u{1}binary"]
        for input in inputs {
            let run = try box.run(input)
            #expect(run.status == 0 && run.output.isEmpty, "\(input)")
        }
        #expect(box.entries == ["claude-status-line.sh"])
    }

    // Refs: US-33, AC-33.08.
    @Test func hugeInputIsNotParsedButReachesTheChainedCommandUnchanged() throws {
        let box = try Sandbox(); defer { box.remove() }
        let received = box.scratch.appendingPathComponent("received")
        try box.setPrevious("cat > " + ClaudeStatusLineLocation.quoted(received.path) + "; printf 'previous\\n'")
        let padding = String(repeating: "x", count: 1_100_000)
        let input = Sandbox.input(fiveHour: (10, now + 3_600), extra: #","padding":"\#(padding)""#) + "\n\n"
        let run = try box.run(input)
        #expect(run.status == 0 && run.output == "previous\n")
        #expect(try Data(contentsOf: received) == Data(input.utf8))
        #expect(box.text(box.location.limits) == nil)
    }

    // Refs: US-33, AC-33.08.
    @Test func chainsTheReplacedCommandWithTheSameInputAndShowsItsOutputOnlyOnSuccess() throws {
        let box = try Sandbox(); defer { box.remove() }
        let received = box.scratch.appendingPathComponent("received")
        try box.setPrevious("cat > " + ClaudeStatusLineLocation.quoted(received.path) + "; printf 'first\\nsecond\\n'")
        let input = Sandbox.input(fiveHour: (5, now + 630)) + "\n"
        let run = try box.run(input)
        #expect(run.status == 0 && run.output == "first\nsecond\n5h 5% · resets 10m\n")
        #expect(try Data(contentsOf: received) == Data(input.utf8))
        // A failing replaced command would have left Claude Code's line blank; its partial output stays hidden.
        try box.setPrevious("printf 'partial'; exit 3")
        let failed = try box.run(input)
        #expect(failed.status == 0 && failed.output == "5h 5% · resets 10m\n")
        // Without readings the replaced line is shown unchanged and nothing is added.
        try box.setPrevious("printf 'only mine\\n'")
        #expect(try box.run(#"{"model":{}}"#).output == "only mine\n")
        // An unwritable Lunlet directory still chains and still exits 0.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: box.location.directory.path)
        let locked = try box.run(Sandbox.input(fiveHour: (6, now + 630)))
        #expect(locked.status == 0 && locked.output == "only mine\n5h 6% · resets 10m\n")
    }

    // Refs: US-33, AC-33.09.
    @Test func olderResponsesFromIdleSessionsNeverLowerAWindow() throws {
        let box = try Sandbox(); defer { box.remove() }
        let start = now, five = start + 4 * 3_600, week = start + 5 * 86_400
        _ = try box.run(Sandbox.input(fiveHour: (40, five), sevenDay: (30, week)))
        // An idle session re-runs its line with its last, lower response and with a window that already reset.
        let replay = try box.run(Sandbox.input(fiveHour: (12, five + 60), sevenDay: (20, week - 7 * 86_400 + 600)))
        #expect(replay.output == "5h 40% · 7d 30% · resets 4h0m\n" || replay.output == "5h 40% · 7d 30% · resets 3h59m\n")
        let limits = try #require(box.text(box.location.limits))
        #expect(limits.contains("five_hour 40 \(five) ") && limits.contains("seven_day 30 \(week) "))
        // More use in the same window, and a later window, replace the stored value.
        _ = try box.run(Sandbox.input(fiveHour: (41.75, five), sevenDay: (31, week)))
        #expect(try #require(box.text(box.location.limits)).contains("five_hour 41.75 \(five) "))
        // Once a window has reset, the next window's first value replaces it even though it is lower.
        let passed = try #require(box.text(box.location.limits)).replacingOccurrences(of: "five_hour 41.75 \(five)",
                                                                                     with: "five_hour 41.75 \(start - 60)")
        try Data(passed.utf8).write(to: box.location.limits)
        _ = try box.run(Sandbox.input(fiveHour: (2, start + 5 * 3_600)))
        #expect(try #require(box.text(box.location.limits)).contains("five_hour 2 \(start + 5 * 3_600) "))
        // The weekly log never records the replayed lower reading.
        let log = try #require(box.text(box.location.weeklyLog)).split(separator: "\n").map { $0.split(separator: " ")[1] }
        #expect(log == ["30", "31"])
    }

    // Refs: US-33, AC-33.09; US-04, AC-04.05.
    @Test func weeklyLogIsDeduplicatedHourlyAndKeptForEightDays() throws {
        let box = try Sandbox(); defer { box.remove() }
        let week = now + 5 * 86_400
        for _ in 0..<3 { _ = try box.run(Sandbox.input(sevenDay: (30, week))) }
        #expect(box.text(box.location.weeklyLog)?.split(separator: "\n").count == 1)
        // The same value two hours later is recorded again, so the forecast knows use stayed flat; a nine-day-old
        // reading is pruned on the next append.
        let old = now - 9 * 86_400, earlier = now - 7_200
        try Data("\(old) 10 \(old + 3_600)\n\(earlier) 30 \(week)\n".utf8).write(to: box.location.weeklyLog)
        try Data("lunlet-claude-limits 1\nseven_day 30 \(week) \(earlier)\n".utf8).write(to: box.location.limits)
        _ = try box.run(Sandbox.input(sevenDay: (30, week)))
        let lines = try #require(box.text(box.location.weeklyLog)).split(separator: "\n")
        #expect(lines.count == 2 && lines[0] == "\(earlier) 30 \(week)" && lines[1].hasSuffix(" 30 \(week)"))
        #expect(box.entries == ["claude-status-line.sh", "limits", "weekly-readings.log"])
    }

    // Refs: US-33, AC-33.08; US-04, AC-04.05.
    @Test func staysWithinItsTimingBudget() throws {
        let box = try Sandbox(); defer { box.remove() }
        let input = Sandbox.input(fiveHour: (23.5, now + 3_600), sevenDay: (41.2, now + 86_400))
        let times = try (0..<7).map { _ in try box.run(input).seconds }.sorted()
        // About 25 ms when measured alone; the bound leaves room for a loaded shared runner while still failing if the
        // script ever shelled out to an interpreter or the network.
        #expect(times[3] < 0.5, "median \(times[3])s")
        #expect(!ClaudeStatusLineScript.source.contains("jq") && !ClaudeStatusLineScript.source.contains("python")
                && !ClaudeStatusLineScript.source.contains("curl"))
    }
}
