// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.08; US-38, AC-38.01, AC-38.06.
// The status line and the Stop hook are two members of one settings file; these cases have both editors, or
// another writer, at work on it. Synthetic settings in per-test temporary directories only.
import Foundation
import Testing
import LunletHook
@testable import LunletClaude

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult func increment() -> Int { lock.withLock { count += 1; return count } }
}

@Suite struct ClaudeSettingsEditsTests {
    struct Fixture {
        let root: URL
        var claude: URL { root.appendingPathComponent("claude", isDirectory: true) }
        var settings: URL { claude.appendingPathComponent("settings.json") }
        var statusLine: ClaudeStatusLineConnection {
            .init(home: .init(root: claude), location: .init(directory: root.appendingPathComponent("support/status-line")))
        }
        var hook: ClaudeHookConnection {
            .init(home: .init(root: claude), spool: .init(root: root.appendingPathComponent("support/hook")))
        }
        init(settings text: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-settings-edits-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("claude"), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: root.appendingPathComponent("claude/settings.json"))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        var bytes: Data? { try? Data(contentsOf: settings) }
        var object: [String: Any]? { bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] }
        var namesTheHook: Bool { (try? hook.state()) == .connected }
        var namesTheStatusLine: Bool { (try? statusLine.state()) == .connected }
    }

    static let original = """
    {
      "model": "opus",
      "statusLine": {"type": "command", "command": "status.sh"},
      "hooks": {
        "Stop": [{"hooks": [{"type": "command", "command": "notify.sh"}]}]
      }
    }

    """

    // Refs: US-33, AC-33.08; US-38, AC-38.01. Turning Claude Code on or off starts both edits at once; each must see
    // the file the other left, so neither is lost and neither gives up.
    @Test func theTwoEditorsTakeTurnsOnTheFile() throws {
        let fixture = try Fixture(settings: Self.original); defer { fixture.remove() }
        for connecting in [true, false] {
            let statusLine = fixture.statusLine, starts = Counter(), finishedMeanwhile = Counter(), done = DispatchSemaphore(value: 0)
            let other = Counter()
            var hook = fixture.hook
            hook.afterRead = {
                starts.increment()
                // The status line's edit begins while the hook's is between its read and its write.
                Thread {
                    if (try? (connecting ? statusLine.connect() : statusLine.disconnect())) != nil { other.increment() }
                    done.signal()
                }.start()
                Thread.sleep(forTimeInterval: 0.2)
                if other.value > 0 { finishedMeanwhile.increment() }
            }
            #expect(try (connecting ? hook.connect() : hook.disconnect()) == (connecting ? .connected : .notConnected))
            #expect(done.wait(timeout: .now() + 10) == .success)
            // The other edit waited for this one, so this one never had to start over, and both took effect.
            #expect(finishedMeanwhile.value == 0 && starts.value == 1 && other.value == 1)
            #expect(fixture.namesTheHook == connecting && fixture.namesTheStatusLine == connecting)
        }
        // After both removals the owner's own entries are what they were.
        let restored = try #require(fixture.object), expected = try #require(try JSONSerialization.jsonObject(with: Data(Self.original.utf8)) as? [String: Any])
        #expect(NSDictionary(dictionary: restored).isEqual(to: expected))
    }

    // Refs: US-33, AC-33.08; US-38, AC-38.01, AC-38.06. Claude Code and the owner write this file too. A change
    // between Lunlet's read and its write is taken in and the edit applied to it; a file that keeps changing is left
    // alone after a few tries, with nothing half-done.
    @Test func anEditStartsOverOnAChangedFileAndStopsAfterAFewTries() throws {
        let fixture = try Fixture(settings: Self.original); defer { fixture.remove() }
        let reads = Counter()
        var hook = fixture.hook
        hook.afterRead = { [settings = fixture.settings] in
            guard reads.increment() == 1 else { return }
            let text = String(decoding: (try? Data(contentsOf: settings)) ?? Data(), as: UTF8.self)
            try? Data(text.replacingOccurrences(of: "\"opus\"", with: "\"fable\"").utf8).write(to: settings)
        }
        #expect(try hook.connect() == .connected)
        #expect(reads.value == 2 && fixture.namesTheHook && fixture.object?["model"] as? String == "fable")
        // Every try meets a newer file.
        let tries = Counter()
        var statusLine = fixture.statusLine
        statusLine.afterRead = { [settings = fixture.settings] in
            let text = String(decoding: (try? Data(contentsOf: settings)) ?? Data(), as: UTF8.self)
            try? Data(text.replacingOccurrences(of: "\"model\": \"", with: "\"model\": \"x").utf8).write(to: settings)
            tries.increment()
        }
        #expect(throws: ClaudeStatusLineFailure.settingsChanged) { try statusLine.connect() }
        #expect(tries.value == 3)
        #expect((fixture.object?["statusLine"] as? [String: Any])?["command"] as? String == "status.sh")
        #expect(!FileManager.default.fileExists(atPath: fixture.statusLine.location.backup.path))
        #expect(fixture.namesTheHook)
    }

    // Refs: US-33, AC-33.08. Lunlet's script and its record of the owner's previous line are removed only once the
    // file is seen without Lunlet's line; another writer may put an earlier copy back right after the removal.
    @Test func lunletsScriptAndBackupStayWhileTheSettingsStillNameThem() throws {
        let fixture = try Fixture(settings: Self.original); defer { fixture.remove() }
        let original = try #require(fixture.bytes)
        #expect(try fixture.statusLine.connect() == .connected)
        let connected = try #require(fixture.bytes), once = Counter()
        var statusLine = fixture.statusLine
        statusLine.afterWrite = { [settings = fixture.settings] in
            if once.increment() == 1 { try? connected.write(to: settings) }
        }
        #expect(try statusLine.disconnect() == .connected)
        let location = fixture.statusLine.location
        #expect(FileManager.default.fileExists(atPath: location.script.path) && FileManager.default.fileExists(atPath: location.backup.path))
        // With the file left alone, the same removal restores the owner's line exactly and takes Lunlet's files away.
        #expect(try fixture.statusLine.disconnect() == .notConnected)
        #expect(fixture.bytes == original)
        #expect(!FileManager.default.fileExists(atPath: location.directory.path))
    }
}
