// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-08, AC-08.01, AC-08.02, AC-08.03, AC-08.04; US-09, AC-09.02, AC-09.03.
// Refs: US-10, AC-10.01, AC-10.02, AC-10.03, AC-10.04; US-11, AC-11.03, AC-11.06.
import Foundation
import LunletCore

/// The exact live CLI a reply may reach, freshly rechecked by the session monitor.
public struct CodexContinuationBinding: Equatable, Sendable, CustomStringConvertible {
    public let sessionID: UUID
    public let connectionID: UUID
    public let completedTurnID: String
    let process: CodexProcessIdentity
    let rollout: CodexRolloutFile
    /// The observed process image, never a PATH lookup or the launching wrapper.
    let executable: URL
    /// The Codex home that holds this session's record.
    let codexHome: URL
    public var description: String { "Codex continuation binding (redacted)" }
}

public enum CodexBindingResult: Equatable, Sendable {
    case bound(CodexContinuationBinding)
    case refused(ContinuationRefusal)
}

/// One authorized follow-up for the completed turn its card was issued for.
public struct CodexContinuationRequest: Equatable, Sendable, CustomStringConvertible {
    public let sessionID: UUID
    public let connectionID: UUID
    public let completedTurnID: String
    public let text: String
    public var description: String { "Codex continuation request (redacted)" }

    public init(sessionID: UUID, connectionID: UUID, completedTurnID: String, text: String) {
        self.sessionID = sessionID
        self.connectionID = connectionID
        self.completedTurnID = completedTurnID
        self.text = text
    }
}

/// Hands one authorized follow-up to the same running Codex CLI with `codex queue`, which reaches
/// the open session under its existing sandbox and approval policy. Queue acceptance is not delivery evidence and the command also accepts ended sessions,
/// so the live binding is rechecked first and arrival is confirmed from that session's record.
/// It runs at most once per call and never retries.
public struct CodexQueueAdapter: Sendable {
    private let runner: any CodexProcessRunning
    private let queueTimeout: Duration
    private let confirmationTimeout: Duration
    private let pollInterval: Duration
    private let baseEnvironment: [String: String]

    public init() { self.init(runner: SystemCodexProcessRunner()) }

    init(runner: any CodexProcessRunning, queueTimeout: Duration = .seconds(15),
         confirmationTimeout: Duration = .seconds(20), pollInterval: Duration = .milliseconds(250),
         baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.runner = runner
        self.queueTimeout = queueTimeout
        self.confirmationTimeout = confirmationTimeout
        self.pollInterval = pollInterval
        self.baseEnvironment = baseEnvironment
    }

    /// Exactly `queue --thread <uuid> --message <text>` for the observed executable. The
    /// environment is explicit: a fixed system PATH, so no wrapper directory is inherited, and
    /// the session's own Codex home, so the request reaches the installation that owns it.
    static func processRequest(for binding: CodexContinuationBinding, text: String,
                               baseEnvironment: [String: String]) -> CodexProcessRequest? {
        guard ContinuationText.isForwardable(text), binding.executable.path.hasPrefix("/"),
              binding.codexHome.path.hasPrefix("/") else { return nil }
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CODEX_HOME": binding.codexHome.path]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] {
            if let value = baseEnvironment[key], !value.isEmpty { environment[key] = value }
        }
        return CodexProcessRequest(executable: binding.executable,
                                   arguments: ["queue", "--thread", binding.sessionID.uuidString.lowercased(),
                                               "--message", text],
                                   environment: environment)
    }

    public func continueSession(_ request: CodexContinuationRequest, in source: any CodexSessionObserving,
                                progress: ContinuationProgress) async -> ContinuationOutcome {
        let operation = DiagnosticOperation()
        guard ContinuationText.isForwardable(request.text) else {
            DiagnosticLog.record(.sessionInput, component: .codex, outcome: .rejected, operation: operation, reason: .invalidInput)
            return .failed
        }
        // A rejection logs the refusing stage by number: 1 the live binding, 2 the request and record, 3 the recheck.
        let binding: CodexContinuationBinding
        switch await source.continuationBinding(sessionID: request.sessionID, connectionID: request.connectionID,
                                                completedTurnID: request.completedTurnID) {
        case .refused(let reason):
            DiagnosticLog.record(.sessionInput, component: .codex, outcome: .rejected, operation: operation,
                                 reason: .init(reason), code: 1)
            return .refused(reason)
        case .bound(let value):
            binding = value
        }
        guard binding.sessionID == request.sessionID, binding.connectionID == request.connectionID,
              binding.completedTurnID == request.completedTurnID,
              let process = Self.processRequest(for: binding, text: request.text, baseEnvironment: baseEnvironment),
              var watch = CodexDeliveryWatch(file: binding.rollout, text: request.text) else {
            DiagnosticLog.record(.sessionInput, component: .codex, outcome: .rejected, operation: operation, reason: .record, code: 2)
            return .refused(.unverified)
        }
        // Access, connection or observation may have changed while the binding was rechecked.
        if let reason = await progress.recheck() {
            DiagnosticLog.record(.sessionInput, component: .codex, outcome: .rejected, operation: operation,
                                 reason: .init(reason), code: 3)
            return .refused(reason)
        }
        DiagnosticLog.record(.sessionInput, component: .codex, outcome: .started, operation: operation)
        switch await runner.run(process, timeout: queueTimeout) {
        case .exited(0):
            await progress.submitted()
            DiagnosticLog.record(.sessionInput, component: .codex, outcome: .submitted, operation: operation)
        case .timedOut:
            // The request may still have been queued: confirm from the record, never resubmit.
            DiagnosticLog.record(.sessionInput, component: .codex, outcome: .uncertain, operation: operation, reason: .timeout)
        case .exited(let status):
            DiagnosticLog.record(.sessionInput, component: .codex, outcome: .failed, operation: operation, code: Int(status))
            return .failed
        case .signaled, .launchFailed:
            DiagnosticLog.record(.sessionInput, component: .codex, outcome: .failed, operation: operation)
            return .failed
        }
        let confirmed = await confirm(&watch)
        DiagnosticLog.record(.sessionInput, component: .codex, outcome: confirmed ? .processing : .uncertain,
                             operation: operation, reason: confirmed ? nil : .timeout)
        return confirmed ? .delivered : .notConfirmed
    }

    /// Bounded polling for one reply only; no observation outlives the confirmation window.
    private func confirm(_ watch: inout CodexDeliveryWatch) async -> Bool {
        let deadline = ContinuousClock.now + confirmationTimeout
        while true {
            switch watch.poll() {
            case .delivered: return true
            case .mismatched, .unavailable: return false
            case .pending: break
            }
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: pollInterval) } catch { return false }
        }
    }
}
