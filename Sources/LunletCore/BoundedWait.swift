// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-12, AC-12.04; US-14, AC-14.01.
import Foundation

/// Waiting on cleanup that must not keep the app alive: a quit waits for each cancelled task a few seconds, no more.
public enum BoundedWait {
    /// Waits for `task` at most `limit`; true when it finished in time. The task itself is never cancelled here, so
    /// a cleanup that overruns still completes in the background while the caller moves on.
    ///
    /// Awaiting a task's value cannot be interrupted, so the wait is not a task group (its end would await that child
    /// and inherit the stall); two detached waiters race for one continuation, and the one that loses simply ends
    /// when it can, holding nothing but the task's value.
    public static func settle<Value: Sendable>(_ task: Task<Value, Never>, limit: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let outcome = Outcome(continuation)
            Task { _ = await task.value; outcome.resume(true) }
            Task { try? await Task.sleep(for: limit); outcome.resume(false) }
        }
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ finished: Bool) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: finished)
        }
    }
}
