// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-14, AC-14.01, AC-14.02, AC-14.03, AC-14.06.
// Refs: US-04, AC-04.01, AC-04.03, AC-04.04, AC-04.05, AC-04.06, AC-04.09.
import Foundation
import CoreFoundation
import Darwin
import LunletCore
import os

public enum CodexAccountFailure: Error, Equatable, Sendable {
    case unavailable, timeout, invalidResponse, requestFailed
}

public protocol CodexAccountReading: Sendable {
    func readLimits() async throws -> AccountLimitsSnapshot
}

public struct CodexAccountClient: CodexAccountReading {
    private let executableURL: URL?
    private let timeout: TimeInterval

    public init(executableURL: URL? = nil) {
        self.executableURL = executableURL
        timeout = 15
    }

    init(executableURL: URL, timeout: TimeInterval) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public func readLimits() async throws -> AccountLimitsSnapshot {
        let operation = DiagnosticOperation()
        DiagnosticLog.record(.accountRead, component: .codex, outcome: .started, operation: operation)
        do {
            let result = try await readLimits(operation: operation)
            DiagnosticLog.record(.accountRead, component: .codex, outcome: .completed, operation: operation)
            return result
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let reason: DiagnosticReason
            switch error as? CodexAccountFailure {
            case .timeout: reason = .timeout
            case .invalidResponse: reason = .invalidResponse
            case .requestFailed: reason = .provider
            case .unavailable: reason = .ended
            case nil: reason = .unknown
            }
            DiagnosticLog.record(.accountRead, component: .codex, outcome: cancelled ? .cancelled : .failed,
                                 operation: operation, reason: reason)
            throw error
        }
    }

    private func readLimits(operation: DiagnosticOperation) async throws -> AccountLimitsSnapshot {
        let cancellation = AccountReadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Pipe polling runs on a utility queue, never the UI executor or
                // a Swift cooperative-executor thread blocked on a child process.
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let snapshot = try readOwnedAccount(cancellation: cancellation, operation: operation)
                        continuation.resume(returning: snapshot)
                    } catch {
                        if error is CancellationError {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: (error as? CodexAccountFailure) ?? .invalidResponse)
                        }
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func readOwnedAccount(cancellation: AccountReadCancellation, operation: DiagnosticOperation) throws -> AccountLimitsSnapshot {
        try cancellation.check()
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let executable = executableURL ?? Self.findExecutable(environment: environment, home: home) else {
            throw CodexAccountFailure.unavailable
        }
        let connection = try AccountRPCConnection(executable: executable, environment: Self.childEnvironment(
            for: executable, environment: environment, home: home), timeout: timeout, cancellation: cancellation)
        defer { connection.close() }
        DiagnosticLog.record(.accountInitialize, component: .codex, outcome: .started, operation: operation)
        _ = try connection.request(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "lunlet", "title": "Lunlet", "version": "0.1.0"],
        ])
        try connection.send(["method": "initialized"])
        DiagnosticLog.record(.accountInitialize, component: .codex, outcome: .completed, operation: operation)
        let data = try connection.request(id: 2, method: "account/rateLimits/read", params: [:])
        let identity = try? connection.request(id: 3, method: "account/read", params: ["refreshToken": false])
        let snapshot = try AccountLimitsDecoder.decode(data, observedAt: Date(), accountData: identity)
        try cancellation.check()
        return snapshot
    }

    /// A GUI launch inherits a minimal PATH. Search it, then a bounded set of
    /// common package-manager locations; no login shell or profile is executed.
    static func searchDirectories(environment: [String: String], home: URL) -> [String] {
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let nodeVersions = ((try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .prefix(8).map { nvm.appendingPathComponent($0).appendingPathComponent("bin").path }
        let user = [".local/bin", ".npm-global/bin", ".volta/bin", ".bun/bin"].map { home.appendingPathComponent($0).path }
        var seen = Set<String>()
        return (inherited + ["/opt/homebrew/bin", "/usr/local/bin"] + user + nodeVersions)
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    static func findExecutable(environment: [String: String], home: URL) -> URL? {
        searchDirectories(environment: environment, home: home)
            .map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Script launchers such as `#!/usr/bin/env node` need their interpreter,
    /// which package managers install beside the launcher.
    static func childEnvironment(for executable: URL, environment: [String: String], home: URL) -> [String: String] {
        var result = environment
        var seen = Set<String>()
        result["PATH"] = ([executable.deletingLastPathComponent().path] + searchDirectories(environment: environment, home: home))
            .filter { seen.insert($0).inserted }.joined(separator: ":")
        return result
    }
}

private final class AccountReadCancellation: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    func cancel() { cancelled.withLock { $0 = true } }
    func check() throws {
        if cancelled.withLock({ $0 }) { throw CancellationError() }
    }
}

/// A single owned, read-only account exchange. Never attaches or resumes a thread.
private final class AccountRPCConnection {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let deadline: UInt64
    private let cancellation: AccountReadCancellation
    private var buffer = Data()
    private var receivedBytes = 0

    init(executable: URL, environment: [String: String], timeout: TimeInterval, cancellation: AccountReadCancellation) throws {
        self.cancellation = cancellation
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        process.executableURL = executable
        process.environment = environment
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        do { try process.run() } catch { throw CodexAccountFailure.unavailable }
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        let writer = input.fileHandleForWriting.fileDescriptor
        let reader = output.fileHandleForReading.fileDescriptor
        guard fcntl(writer, F_SETNOSIGPIPE, 1) == 0,
              fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) | O_NONBLOCK) == 0,
              fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK) == 0 else {
            close()
            throw CodexAccountFailure.unavailable
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let cleanupDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < cleanupDeadline { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }

    func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0a)
        let descriptor = input.fileHandleForWriting.fileDescriptor
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(descriptor, events: Int16(POLLOUT))
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { throw CodexAccountFailure.unavailable }
                offset += count
            }
        }
    }

    func request(id: Int, method: String, params: [String: Any]) throws -> Data {
        try send(["id": id, "method": method, "params": params])
        while true {
            try cancellation.check()
            let data = try readLine()
            guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw CodexAccountFailure.invalidResponse
            }
            guard message["method"] == nil, let received = message["id"] as? NSNumber,
                  CFGetTypeID(received) != CFBooleanGetTypeID(), received.doubleValue == Double(id) else { continue }
            guard message["error"] == nil else { throw CodexAccountFailure.requestFailed }
            guard let result = message["result"] as? [String: Any] else { throw CodexAccountFailure.invalidResponse }
            return try JSONSerialization.data(withJSONObject: result)
        }
    }

    private func readLine() throws -> Data {
        let descriptor = output.fileHandleForReading.fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer.prefix(upTo: newline))
                guard line.count <= 65_536 else { throw CodexAccountFailure.invalidResponse }
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            guard buffer.count <= 65_536 else { throw CodexAccountFailure.invalidResponse }
            try wait(descriptor, events: Int16(POLLIN))
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw CodexAccountFailure.unavailable }
            receivedBytes += count
            guard receivedBytes <= 1_048_576 else { throw CodexAccountFailure.invalidResponse }
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }

    private func wait(_ descriptor: Int32, events: Int16) throws {
        while true {
            try cancellation.check()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw CodexAccountFailure.timeout }
            let milliseconds = Int32(min(50, max(1, (deadline - now) / 1_000_000)))
            var handle = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&handle, 1, milliseconds)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw CodexAccountFailure.unavailable }
            if ready > 0 { return }
        }
    }
}
