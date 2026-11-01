// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-08, AC-08.01, AC-08.02; US-10, AC-10.03; US-11, AC-11.03.
import Darwin
import Foundation

/// One fixed program invocation: an absolute executable, exact arguments and an explicit
/// environment. No shell, PATH search or inherited wrapper is involved.
public struct CodexProcessRequest: Equatable, Sendable, CustomStringConvertible {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public var description: String { "Codex process request (redacted)" }
}

public enum CodexProcessExit: Equatable, Sendable {
    case exited(Int32)
    /// Ended by a signal Lunlet did not send.
    case signaled
    /// Stopped by Lunlet (timeout or cancellation) before it exited; its effect is unknown.
    case timedOut
    case launchFailed
}

public protocol CodexProcessRunning: Sendable {
    /// Runs once with no standard input and discarded output; only the exit status is reported.
    func run(_ request: CodexProcessRequest, timeout: Duration) async -> CodexProcessExit
}

/// Foundation's posix_spawn-based `Process`. Timeouts and cancellation terminate the child,
/// escalating to SIGKILL; nothing it prints is read or retained.
public struct SystemCodexProcessRunner: CodexProcessRunning {
    public init() {}

    public func run(_ request: CodexProcessRequest, timeout: Duration) async -> CodexProcessExit {
        let child = ChildProcess(request)
        do { try child.start() } catch { return .launchFailed }
        let watchdog = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            child.stop()
        }
        let (reason, status) = await withTaskCancellationHandler {
            await child.wait()
        } onCancel: {
            child.stop()
        }
        watchdog.cancel()
        if reason == .exit { return .exited(status) }
        return child.wasStopped ? .timedOut : .signaled
    }
}

/// Lock-protected ownership of one child process and its single termination result.
private final class ChildProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var result: (Process.TerminationReason, Int32)?
    private var waiter: CheckedContinuation<(Process.TerminationReason, Int32), Never>?
    private var stopped = false

    init(_ request: CodexProcessRequest) {
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] value in
            self?.finish(value.terminationReason, value.terminationStatus)
        }
    }

    var wasStopped: Bool { lock.withLock { stopped } }

    func start() throws { try process.run() }

    func wait() async -> (Process.TerminationReason, Int32) {
        await withCheckedContinuation { continuation in
            let current: (Process.TerminationReason, Int32)? = lock.withLock {
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let current { continuation.resume(returning: current) }
        }
    }

    func stop() {
        let running: Bool = lock.withLock {
            guard result == nil, !stopped else { return false }
            stopped = true
            return true
        }
        guard running else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.lock.withLock({ self.result == nil }) else { return }
            kill(pid, SIGKILL)
        }
    }

    private func finish(_ reason: Process.TerminationReason, _ status: Int32) {
        let pending: CheckedContinuation<(Process.TerminationReason, Int32), Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = (reason, status)
            let current = waiter
            waiter = nil
            return current
        }
        pending?.resume(returning: (reason, status))
    }
}
