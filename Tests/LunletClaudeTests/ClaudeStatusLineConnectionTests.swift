// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.08, AC-33.07.
// Synthetic Claude settings in per-test temporary directories; the owner's real ~/.claude is never touched.
import Foundation
import Testing
@testable import LunletClaude

@Suite struct ClaudeStatusLineConnectionTests {
    struct Fixture {
        let box: StatusLineSandbox
        var claude: URL { box.root.appendingPathComponent("claude", isDirectory: true) }
        var settings: URL { claude.appendingPathComponent("settings.json") }
        var connection: ClaudeStatusLineConnection {
            .init(home: .init(root: claude), location: .init(directory: box.root.appendingPathComponent("support/lunlet")))
        }
        init(settings text: String?) throws {
            box = try StatusLineSandbox()
            try FileManager.default.createDirectory(at: box.root.appendingPathComponent("claude"), withIntermediateDirectories: true)
            if let text { try Data(text.utf8).write(to: box.root.appendingPathComponent("claude/settings.json")) }
        }
        var bytes: Data? { try? Data(contentsOf: settings) }
        var text: String? { bytes.map { String(decoding: $0, as: UTF8.self) } }
        var statusLine: [String: Any]? {
            (bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["statusLine"] as? [String: Any]
        }
        var backupExists: Bool { FileManager.default.fileExists(atPath: connection.location.backup.path) }
    }

    /// Claude Code's own two-space style with keys in a user-chosen order and spellings JSONSerialization would change.
    static let twoSpace = """
    {
      "model": "opus",
      "permissions": {
        "allow": ["Bash(git status)", "Read(//tmp/**)"],
        "defaultMode": "acceptEdits"
      },
      "cleanupPeriodDays": 30,
      "temperatureHint": 1.50,
      "path": "/usr/local/bin"
    }

    """

    // Refs: US-33, AC-33.08.
    @Test func connectingAddsOnlyTheStatusLineAndDisconnectingRestoresTheExactFile() throws {
        let fixture = try Fixture(settings: Self.twoSpace); defer { fixture.box.remove() }
        let original = try #require(fixture.bytes)
        #expect(try fixture.connection.state() == .notConnected)
        #expect(try fixture.connection.connect() == .connected)
        #expect(fixture.statusLine?["type"] as? String == "command")
        #expect(fixture.statusLine?["command"] as? String == fixture.connection.location.command)
        let text = try #require(fixture.text)
        // Every other byte is kept; the member is appended in the file's own two-space style.
        #expect(text.hasPrefix(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"/usr/local/bin\"\n}\n",
                                                                                         with: "\"/usr/local/bin\"")))
        #expect(text.contains(",\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \"/bin/sh '"))
        #expect(text.contains("\"temperatureHint\": 1.50") && text.contains("Read(//tmp/**)"))
        #expect(FileManager.default.fileExists(atPath: fixture.connection.location.script.path) && fixture.backupExists)
        #expect(try fixture.connection.connect() == .connected && fixture.text == text)
        #expect(try fixture.connection.disconnect() == .notConnected)
        #expect(fixture.bytes == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.connection.location.directory.path))
    }

    // Refs: US-33, AC-33.08.
    @Test func anExistingCommandIsBackedUpChainedAndRestoredExactly() throws {
        let settings = """
        {
            "statusLine" : {"type":"command", "command":"~/.claude/my line.sh", "padding": 2, "refreshInterval": 5},
            "theme": "dark"
        }
        """
        let fixture = try Fixture(settings: settings); defer { fixture.box.remove() }
        #expect(try fixture.connection.connect() == .connected)
        // Four-space style and the " : " separator are kept; padding and the timer carry over to Lunlet's line.
        #expect(fixture.text?.contains("\"statusLine\" : {\n        \"type\" : \"command\",") == true)
        #expect(fixture.statusLine?["padding"] as? Int == 2 && fixture.statusLine?["refreshInterval"] as? Int == 5)
        #expect(fixture.text?.hasSuffix(",\n    \"theme\": \"dark\"\n}") == true)
        let backup = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.connection.location.backup)) as? [String: Any]
        #expect(backup?["previousCommand"] as? String == "~/.claude/my line.sh")
        #expect(backup?["previous"] as? String
            == #"{"type":"command", "command":"~/.claude/my line.sh", "padding": 2, "refreshInterval": 5}"#)
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.connection.location.backup.path)[.posixPermissions]
        #expect(mode as? Int == 0o600)
        #expect(try fixture.connection.disconnect() == .notConnected && fixture.text == settings)
    }

    // Refs: US-33, AC-33.08.
    @Test func theInstalledLineChainsTheReplacedCommandEndToEnd() throws {
        let fixture = try Fixture(settings: #"{"statusLine":{"type":"command","command":"cat > /dev/null; echo mine"}}"#)
        defer { fixture.box.remove() }
        #expect(try fixture.connection.connect() == .connected)
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", try #require(fixture.statusLine?["command"] as? String)]
        process.standardInput = input; process.standardOutput = output
        try process.run()
        let reset = Int(Date().timeIntervalSince1970) + 630  // 30 s of slack so a slow run still prints "10m"
        input.fileHandleForWriting.write(Data(StatusLineSandbox.input(fiveHour: (7, reset)).utf8))
        try input.fileHandleForWriting.close()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0 && printed == "mine\n5h 7% · resets 10m\n")
        // A single-line file stays on one line.
        #expect(fixture.text?.contains("\n") == false)
        #expect(fixture.text?.hasPrefix(#"{"statusLine":{"type":"command", "command":"/bin/sh '"#) == true)
    }

    // Refs: US-33, AC-33.08.
    @Test func unreadableOrInvalidSettingsAreRefusedAndLeftUntouched() throws {
        let cases = [
            "{\n  \"model\": \"opus\",\n}\n",                       // trailing comma
            "{\n  // comment\n  \"model\": \"opus\"\n}\n",          // comments
            "[\"not\", \"an\", \"object\"]",
            "{\"statusLine\": {\"type\": \"command\", \"command\": \"a\"}, \"statusLine\": {\"type\": \"command\", \"command\": \"b\"}}",
            "",
        ]
        for text in cases {
            let fixture = try Fixture(settings: text); defer { fixture.box.remove() }
            #expect(throws: ClaudeStatusLineFailure.settingsInvalid) { try fixture.connection.connect() }
            #expect(fixture.text == text && !fixture.backupExists)
        }
        // A status line Lunlet cannot chain is not replaced.
        let other = #"{"statusLine": {"type": "static", "text": "hello"}}"#
        let fixture = try Fixture(settings: other); defer { fixture.box.remove() }
        #expect(throws: ClaudeStatusLineFailure.unsupportedStatusLine) { try fixture.connection.connect() }
        #expect(fixture.text == other && !fixture.backupExists)
        #expect(!FileManager.default.fileExists(atPath: fixture.connection.location.directory.path))
        // Without Claude Code's directory nothing is created.
        let missing = ClaudeStatusLineConnection(home: .init(root: fixture.box.root.appendingPathComponent("absent")),
                                                 location: fixture.connection.location)
        #expect(throws: ClaudeStatusLineFailure.claudeDirectoryMissing) { try missing.connect() }
        #expect(!FileManager.default.fileExists(atPath: fixture.box.root.appendingPathComponent("absent").path))
    }

    // Refs: US-33, AC-33.08.
    @Test func aStatusLineChangedAfterConnectingIsNeverOverwritten() throws {
        let fixture = try Fixture(settings: Self.twoSpace); defer { fixture.box.remove() }
        _ = try fixture.connection.connect()
        let changed = try #require(fixture.text).replacingOccurrences(of: fixture.connection.location.command, with: "my-own-line")
        try Data(changed.utf8).write(to: fixture.settings)
        #expect(try fixture.connection.state() == .changedOutsideLunlet)
        #expect(try fixture.connection.disconnect() == .changedOutsideLunlet && fixture.text == changed)
        #expect(try fixture.connection.forget() == .notConnected && fixture.text == changed && !fixture.backupExists)
        // Restoring the previous configuration by hand reads as not connected; replacing it is an outside change.
        let again = try Fixture(settings: Self.twoSpace); defer { again.box.remove() }
        _ = try again.connection.connect()
        try Data(Self.twoSpace.utf8).write(to: again.settings)
        #expect(try again.connection.state() == .notConnected)
        let prior = try Fixture(settings: #"{"statusLine":{"type":"command","command":"echo old"}}"#)
        defer { prior.box.remove() }
        _ = try prior.connection.connect()
        try Data(#"{"theme":"dark"}"#.utf8).write(to: prior.settings)
        #expect(try prior.connection.disconnect() == .changedOutsideLunlet && prior.text == #"{"theme":"dark"}"#)
    }

    // Refs: US-33, AC-33.08.
    @Test func aCreatedFileIsRemovedAndALinkedFileIsEditedAtItsTarget() throws {
        let fixture = try Fixture(settings: nil); defer { fixture.box.remove() }
        #expect(try fixture.connection.connect() == .connected)
        #expect(fixture.text?.hasPrefix("{\n  \"statusLine\": {\n    \"type\": \"command\",") == true)
        #expect(try fixture.connection.disconnect() == .notConnected && fixture.bytes == nil)

        let linked = try Fixture(settings: nil); defer { linked.box.remove() }
        let target = linked.box.scratch.appendingPathComponent("dotfiles-settings.json")
        try Data(Self.twoSpace.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: linked.settings, withDestinationURL: target)
        #expect(try linked.connection.connect() == .connected)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linked.settings.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8).contains("\"statusLine\""))
        #expect(try linked.connection.disconnect() == .notConnected)
        #expect(try String(contentsOf: target, encoding: .utf8) == Self.twoSpace)
    }

    // Refs: US-33, AC-33.08.
    @Test func documentEditsTouchOnlyTheStatusLineMember() throws {
        let compact = try ClaudeSettingsDocument(Data(#"{"a":1,"statusLine":{"type":"command","command":"x"},"b":[1,{"c":"}"}]}"#.utf8))
        #expect(try compact.valueText("statusLine") == #"{"type":"command","command":"x"}"#)
        #expect(String(decoding: try compact.removing("statusLine"), as: UTF8.self) == #"{"a":1,"b":[1,{"c":"}"}]}"#)
        let first = try ClaudeSettingsDocument(Data(#"{ "statusLine": 1, "z": "\"q\"" }"#.utf8))
        #expect(String(decoding: try first.removing("statusLine"), as: UTF8.self) == #"{ "z": "\"q\"" }"#)
        let empty = try ClaudeSettingsDocument(Data("{}".utf8))
        #expect(String(decoding: try empty.setting("statusLine", to: "2"), as: UTF8.self) == "{\n  \"statusLine\": 2\n}")
        #expect(ClaudeStatusLineLocation.quoted("/a b/it's") == #"'/a b/it'\''s'"#)
    }
}
