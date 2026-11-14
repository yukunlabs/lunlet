// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.02, AC-38.03, AC-38.04, AC-38.05; US-08, AC-08.01, AC-08.02, AC-08.03, AC-08.04;
// US-09, AC-09.01; US-10, AC-10.01, AC-10.02, AC-10.03, AC-10.04; US-11, AC-11.03, AC-11.06.
import Foundation
import LunletCore
import LunletHook

/// The exact live Claude Code session a reply may reach, freshly rechecked by the session monitor: its sole owning
/// process, its transcript and the held stop whose hook helper, that process's child, waits for the follow-up.
public struct ClaudeContinuationBinding: Equatable, Sendable, CustomStringConvertible {
    public let sessionID: UUID
    public let connectionID: UUID
    public let completedTurnID: String
    let process: ClaudeProcessIdentity
    let transcript: ClaudeTranscriptFile
    let stopID: UUID
    public var description: String { "Claude continuation binding (redacted)" }
}

public enum ClaudeBindingResult: Equatable, Sendable {
    case bound(ClaudeContinuationBinding)
    case refused(ContinuationRefusal)
}

/// One authorized follow-up for the completed turn its notice was issued for.
public struct ClaudeContinuationRequest: Equatable, Sendable, CustomStringConvertible {
    public let sessionID: UUID
    public let connectionID: UUID
    public let completedTurnID: String
    public let text: String
    public var description: String { "Claude continuation request (redacted)" }

    public init(sessionID: UUID, connectionID: UUID, completedTurnID: String, text: String) {
        self.sessionID = sessionID
        self.connectionID = connectionID
        self.completedTurnID = completedTurnID
        self.text = text
    }
}

public protocol ClaudeSessionObserving: SessionObserving {
    /// A freshly rechecked binding of the exact live session for a reply to `completedTurnID`.
    func continuationBinding(sessionID: UUID, connectionID: UUID, completedTurnID: String) async -> ClaudeBindingResult
    /// While the window is open, a finished turn is held for one phone reply; closing it releases every hold.
    func setReplyWindow(_ open: Bool) async
}
public extension ClaudeSessionObserving {
    /// Sources without a verified original-CLI input path never continue a session.
    func continuationBinding(sessionID: UUID, connectionID: UUID, completedTurnID: String) async -> ClaudeBindingResult {
        .refused(.unverified)
    }
    func setReplyWindow(_ open: Bool) async {}
}

/// Hands one authorized follow-up to the hook helper that holds the same running Claude Code session's finished
/// turn, which continues the turn with it under the session's existing permission mode. The helper's receipt is
/// only a submission receipt, so the live binding is rechecked first and arrival is confirmed from the session's
/// own transcript. It writes at most one request per call and never retries.
public struct ClaudeHookAdapter: Sendable {
    private let spool: HookSpool
    private let receiptTimeout: Duration
    private let confirmationTimeout: Duration
    private let pollInterval: Duration
    private let receiptPollInterval: Duration

    public init() { self.init(spool: .standard()) }

    init(spool: HookSpool, receiptTimeout: Duration = .seconds(5), confirmationTimeout: Duration = .seconds(20),
         pollInterval: Duration = .milliseconds(250), receiptPollInterval: Duration = .milliseconds(100)) {
        self.spool = spool
        self.receiptTimeout = receiptTimeout
        self.confirmationTimeout = confirmationTimeout
        self.pollInterval = pollInterval
        self.receiptPollInterval = receiptPollInterval
    }

    public func continueSession(_ request: ClaudeContinuationRequest, in source: any ClaudeSessionObserving,
                                progress: ContinuationProgress) async -> ContinuationOutcome {
        let operation = DiagnosticOperation()
        guard ContinuationText.isForwardable(request.text) else {
            DiagnosticLog.record(.sessionInput, component: .claude, outcome: .rejected, operation: operation, reason: .invalidInput)
            return .failed
        }
        // A rejection logs the refusing stage by number: 1 the live binding, 2 the request and record, 3 the recheck.
        let binding: ClaudeContinuationBinding
        switch await source.continuationBinding(sessionID: request.sessionID, connectionID: request.connectionID,
                                                completedTurnID: request.completedTurnID) {
        case .refused(let reason):
            DiagnosticLog.record(.sessionInput, component: .claude, outcome: .rejected, operation: operation,
                                 reason: .init(reason), code: 1)
            return .refused(reason)
        case .bound(let value):
            binding = value
        }
        guard binding.sessionID == request.sessionID, binding.connectionID == request.connectionID,
              binding.completedTurnID == request.completedTurnID,
              var watch = ClaudeDeliveryWatch(file: binding.transcript, text: request.text) else {
            DiagnosticLog.record(.sessionInput, component: .claude, outcome: .rejected, operation: operation, reason: .record, code: 2)
            return .refused(.unverified)
        }
        // Access, connection or observation may have changed while the binding was rechecked.
        if let reason = await progress.recheck() {
            DiagnosticLog.record(.sessionInput, component: .claude, outcome: .rejected, operation: operation,
                                 reason: .init(reason), code: 3)
            return .refused(reason)
        }
        DiagnosticLog.record(.sessionInput, component: .claude, outcome: .started, operation: operation)
        let push = HookSpool.PushRequest(stopID: binding.stopID, text: request.text)
        let pushURL = spool.file(binding.sessionID, stop: binding.stopID, suffix: HookSpool.pushSuffix)
        do {
            try HookSpool.writeAtomically(try HookSpool.encoder.encode(push), to: pushURL)
        } catch {
            DiagnosticLog.record(.sessionInput, component: .claude, outcome: .failed, operation: operation)
            return .failed
        }
        let receiptURL = spool.file(binding.sessionID, stop: binding.stopID, suffix: HookSpool.receiptSuffix)
        if await waitForReceipt(at: receiptURL) {
            try? FileManager.default.removeItem(at: receiptURL)
            await progress.submitted()
            DiagnosticLog.record(.sessionInput, component: .claude, outcome: .submitted, operation: operation)
        } else if FileManager.default.fileExists(atPath: pushURL.path) {
            // The helper never took the request: withdraw it so a later helper cannot hand it over.
            try? FileManager.default.removeItem(at: pushURL)
            DiagnosticLog.record(.sessionInput, component: .claude, outcome: .failed, operation: operation, reason: .timeout)
            return .failed
        } else {
            // The request was taken without a receipt yet: confirm from the transcript, never resubmit.
            DiagnosticLog.record(.sessionInput, component: .claude, outcome: .uncertain, operation: operation, reason: .timeout)
        }
        let confirmed = await confirm(&watch)
        DiagnosticLog.record(.sessionInput, component: .claude, outcome: confirmed ? .processing : .uncertain,
                             operation: operation, reason: confirmed ? nil : .timeout)
        return confirmed ? .delivered : .notConfirmed
    }

    private func waitForReceipt(at url: URL) async -> Bool {
        let deadline = ContinuousClock.now + receiptTimeout
        while true {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: receiptPollInterval) } catch { return false }
        }
    }

    /// Bounded polling for one reply only; no observation outlives the confirmation window.
    private func confirm(_ watch: inout ClaudeDeliveryWatch) async -> Bool {
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
