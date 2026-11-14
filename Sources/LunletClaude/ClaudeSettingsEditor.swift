// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.08; US-38, AC-38.01, AC-38.06.
import Foundation

/// The one owner of edits to Claude Code's `settings.json` in this process. The status line and the Stop hook are
/// separate members of that file, changed by separate connections that each read it, compute their member and
/// replace the file only while it still holds the bytes they read. Started together, as selecting or deselecting
/// Claude Code does, one of them lost that comparison or wrote over the other. Every edit therefore runs here, one
/// at a time, and an edit that finds the file changed underneath by another writer (Claude Code, the owner, a
/// dotfile tool) starts over from a fresh read, a bounded number of times, before it reports the change.
enum ClaudeSettingsEditor {
    static let attempts = 3
    private static let lock = NSLock()

    /// Runs `body`, one whole read-modify-write, alone; `changed` is the failure that means the file moved underneath.
    static func edit<Value, Failure: Error & Equatable>(startingOverOn changed: Failure, _ body: () throws -> Value) throws -> Value {
        lock.lock(); defer { lock.unlock() }
        var attempt = 1
        while true {
            do { return try body() }
            catch let failure as Failure where failure == changed && attempt < attempts { attempt += 1 }
        }
    }
}
