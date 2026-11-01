// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-07, AC-07.02, AC-07.03, AC-07.04; US-08, AC-08.03;
// US-09, AC-09.02; US-10, AC-10.01, AC-10.02, AC-10.03, AC-10.04;
// US-11, AC-11.02, AC-11.03, AC-11.04, AC-11.05, AC-11.06;
// US-12, AC-12.01, AC-12.02, AC-12.03.
// Refs: US-05, AC-05.08, AC-05.09; US-08, AC-08.01, AC-08.02, AC-08.04; US-09, AC-09.01, AC-09.03.
import Foundation

public struct FeishuOwner: Equatable, Sendable {
    public let applicationID: String
    public let tenantID: String
    public let userID: String

    public init(applicationID: String, tenantID: String, userID: String) {
        self.applicationID = applicationID
        self.tenantID = tenantID
        self.userID = userID
    }

    /// Every identity component is required before an owner can authorize anything.
    public var isComplete: Bool { !applicationID.isEmpty && !tenantID.isEmpty && !userID.isEmpty }
}

public enum CLILiveness: Equatable, Sendable {
    case unverified, alive, ended
}

public enum QuestionPurpose: Equatable, Sendable {
    case ordinary, authorization, unknown
}

public enum SessionPhase: Equatable, Sendable {
    case unknown, running, approval, ended
    case idle(completedTurnID: String)
    case question(turnID: String, requestID: String, itemID: String,
                  questionIDs: [String], purpose: QuestionPurpose)

    /// A question or an execution approval is waiting for the developer.
    public var awaitsUser: Bool {
        switch self { case .question, .approval: true; default: false }
    }
}

public struct ObservedSession: Equatable, Sendable {
    public let sessionID: UUID
    public let connectionID: UUID
    public let liveness: CLILiveness
    public let phase: SessionPhase

    public init(sessionID: UUID, connectionID: UUID,
                liveness: CLILiveness, phase: SessionPhase) {
        self.sessionID = sessionID
        self.connectionID = connectionID
        self.liveness = liveness
        self.phase = phase
    }

    public var isEnded: Bool { liveness == .ended || phase == .ended }

    /// The same binding with new lifecycle facts.
    public func replacing(liveness: CLILiveness, phase: SessionPhase) -> Self {
        .init(sessionID: sessionID, connectionID: connectionID, liveness: liveness, phase: phase)
    }
}

public struct MobileAccess: Equatable, Sendable {
    public var owner: FeishuOwner?
    public var connected: Bool
    public var awayMode: Bool
    public var inputEnabled: Bool

    public init(owner: FeishuOwner?, connected: Bool, awayMode: Bool, inputEnabled: Bool) {
        self.owner = owner
        self.connected = connected
        self.awayMode = awayMode
        self.inputEnabled = inputEnabled
    }

    /// The single remote-input readiness rule: a complete owner, a verified
    /// connection, enabled full continuation access and enabled input.
    public var allowsRemoteInput: Bool {
        owner?.isComplete == true && connected && awayMode && inputEnabled
    }
}

public struct ContinuationControl: Equatable, Sendable {
    public let id: UUID
    public let expiresAt: TimeInterval
}

public enum ContinuationInput: Equatable, Sendable {
    case followup(String)
    case answer([String: [String]])
}

public enum ActionStatus: Equatable, Sendable {
    case received, submitted, processing, failed, uncertain

    /// Receipts only move forward; a confirmed or failed outcome is never replaced by an earlier stage.
    public func canTransition(to next: ActionStatus) -> Bool {
        switch (self, next) {
        case (.received, .submitted), (.received, .processing), (.received, .failed), (.received, .uncertain),
             (.submitted, .processing), (.submitted, .failed), (.submitted, .uncertain),
             (.uncertain, .submitted), (.uncertain, .processing), (.uncertain, .failed),
             (.processing, .failed):
            return true
        default:
            return false
        }
    }
}

public struct ActionReceipt: Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public var status: ActionStatus
}

public struct AuthorizedContinuation: Equatable, Sendable {
    public let receipt: ActionReceipt
    public let session: ObservedSession
    public let input: ContinuationInput
}

public enum ContinuationDecision: Equatable, Sendable {
    case accepted(AuthorizedContinuation)
    case duplicate(ActionReceipt)
    case rejected
}

/// Why an authenticated owner's reply was not forwarded. Every case is safe to show the owner;
/// none is inferred from the reply text or a request name.
public enum ContinuationRefusal: Equatable, Sendable {
    /// The Mac was unlocked after the card was sent, which ends its reply window (AC-05.09).
    case replyWindowClosed
    /// Phone replies were turned off after the card was sent (AC-05.08).
    case repliesTurnedOff
    /// The card's validity period elapsed.
    case expired
    /// The callback connection changed after the card was sent; old controls never survive it.
    case connectionReplaced
    /// The session is executing another turn; a follow-up never takes over a running turn.
    case sessionRunning
    /// The session waits for an execution approval, which stays on the Mac.
    case awaitingApproval
    /// The original CLI process exited or its binding was replaced; Lunlet never restarts it.
    case sessionEnded
    /// A later turn or question replaced the turn this card was issued for.
    case superseded
    /// A reply for this exact turn was already accepted.
    case alreadySent
    /// The session's live binding or state could not be verified.
    case unverified

    /// The reason a control issued for `issued` cannot be used in the `current` observation.
    public static func classify(issued: ObservedSession, current: ObservedSession?) -> Self {
        guard let current, current.sessionID == issued.sessionID else { return .unverified }
        if current.isEnded { return .sessionEnded }
        // A restored session has a fresh binding; cards for the old one stay invalid (AC-11.04).
        guard current.connectionID == issued.connectionID else { return .sessionEnded }
        guard current.liveness == .alive else { return .unverified }
        switch current.phase {
        case .running: return .sessionRunning
        case .approval: return .awaitingApproval
        case .ended: return .sessionEnded
        case .unknown: return .unverified
        case .idle, .question: return current == issued ? .alreadySent : .superseded
        }
    }
}

/// The owner-visible result of one forwarded reply. Queue acceptance alone is never `delivered`.
public enum ContinuationOutcome: Equatable, Sendable {
    /// The reply appeared as the session's next user message: processing confirmed.
    case delivered
    /// The reply was handed to the CLI but its arrival was not observed in time; it is never resent.
    case notConfirmed
    /// The reply was definitely not handed to the CLI.
    case failed
    /// Eligibility failed before anything was handed to the CLI.
    case refused(ContinuationRefusal)
}

/// Callbacks an input adapter uses at its submission boundary.
public struct ContinuationProgress: Sendable {
    /// Rechecks access, connection and observation immediately before submitting; nil means still current.
    public let recheck: @Sendable () async -> ContinuationRefusal?
    /// Records that the input was handed to the agent (receipt `submitted`).
    public let submitted: @Sendable () async -> Void

    public init(recheck: @escaping @Sendable () async -> ContinuationRefusal?,
                submitted: @escaping @Sendable () async -> Void) {
        self.recheck = recheck
        self.submitted = submitted
    }
}

/// Follow-up text rules shared by card validation and the CLI adapter.
public enum ContinuationText {
    public static let maximumBytes = 8_192

    /// Bounded, printable text that one CLI argument carries unambiguously: no leading option
    /// marker, no NUL or other C0/C1 control characters except line breaks and tabs, and no
    /// bidirectional override or isolate characters that could disguise the text on the Mac.
    /// A reply that is one whole tag block is refused too: agents record such blocks as hidden
    /// runtime context, so it would not count as the developer's message.
    public static func isForwardable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, text.utf8.count <= maximumBytes, !text.hasPrefix("-"),
              !(trimmed.hasPrefix("<") && trimmed.hasSuffix(">")) else { return false }
        return !text.unicodeScalars.contains { scalar in
            if scalar == "\n" || scalar == "\r" || scalar == "\t" { return false }
            return scalar.properties.generalCategory == .control
                || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
        }
    }

    /// Canonical composition with every whitespace run collapsed to one space, for comparing a
    /// reply with the message the agent recorded.
    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }
}

extension ContinuationRefusal {
    /// A short, accurate explanation for the owner, the same on every channel.
    public var explanation: String {
        switch self {
        case .replyWindowClosed: "Replies stopped when your Mac was unlocked. Continue on your Mac."
        case .repliesTurnedOff: "Phone replies are turned off in Lunlet. Continue on your Mac."
        case .expired: "This notice has expired. Continue on your Mac."
        case .connectionReplaced: "Lunlet reconnected after this notice was sent. Continue on your Mac."
        case .sessionRunning: "The session is already working on another turn."
        case .awaitingApproval: "The session is waiting for an approval on your Mac."
        case .sessionEnded: "The session has ended. Lunlet does not restart sessions."
        case .superseded: "A newer turn replaced this notice. Reply from the latest one."
        case .alreadySent: "A reply for this turn was already sent."
        case .unverified: "Lunlet could not confirm the session is still open and idle. Continue on your Mac."
        }
    }
}

public extension DiagnosticReason {
    /// The allowlisted reason for a refusal; never its wording.
    init(_ refusal: ContinuationRefusal) {
        switch refusal {
        case .replyWindowClosed, .repliesTurnedOff, .expired, .connectionReplaced: self = .window
        case .sessionRunning, .awaitingApproval, .superseded, .alreadySent: self = .state
        case .sessionEnded: self = .ended
        case .unverified: self = .unverified
        }
    }
}
