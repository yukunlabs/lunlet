// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-14, AC-14.03, AC-14.06, AC-14.07.
import Foundation
import Testing
@testable import LunletCore

@Suite struct DiagnosticFileTests {
    // AC-14.07: errors append to a private file that rotates at its limit and keeps one previous file.
    @Test func appendsPrivatelyAndRotatesKeepingOnePreviousFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-log-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = DiagnosticFile(url: directory.appendingPathComponent("lunlet.log"), maximumBytes: 185)
        let line = String(repeating: "x", count: 59)
        for _ in 0..<3 { file.append(line) }
        file.flush()
        #expect(try String(contentsOf: file.url, encoding: .utf8) == String(repeating: line + "\n", count: 3))
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // The fourth line would pass the limit: the file moves to lunlet.1.log and a new one starts.
        file.append("fourth"); file.flush()
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "fourth\n")
        #expect(try String(contentsOf: file.previous, encoding: .utf8).count == 180)
        // Rotating again replaces the previous file, so at most two files exist.
        for _ in 0..<4 { file.append(line) }
        file.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["lunlet.1.log", "lunlet.log"])
    }

    // AC-14.03, AC-14.06: only failed and uncertain events reach the file, with the allowlisted metadata alone.
    @Test func onlyErrorsReachTheFileWithAllowlistedFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-log-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory); DiagnosticLog.file = nil }
        let file = DiagnosticFile(url: directory.appendingPathComponent("lunlet.log"))
        DiagnosticLog.file = file
        DiagnosticLog.record(.connection, component: .feishu, outcome: .completed, operation: DiagnosticOperation())
        DiagnosticLog.record(.cardDelivery, component: .feishu, outcome: .failed, operation: DiagnosticOperation(),
                             reason: .provider, code: 99_991_663)
        file.flush()
        let lines = try String(contentsOf: file.url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let fields = lines[0].split(separator: " ").dropFirst().map { $0.split(separator: "=").first.map(String.init) ?? "" }
        #expect(fields == ["component", "event", "outcome", "operation", "reason", "code"])
        #expect(lines[0].contains("event=cardDelivery outcome=failed") && lines[0].contains("code=99991663"))
    }
}
