// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-39, AC-39.03, AC-39.04, AC-39.06, AC-39.07; US-13, AC-13.02, AC-13.04.
import Foundation

/// What the desktop pet shows, chosen by precedence over every current conversation (AC-39.03).
public enum PetPose: String, Equatable, Sendable, CaseIterable {
    case asleep, idle, working, done, waiting
    /// The glyph in the bubble above the dog; only two poses carry one (AC-39.04).
    public var bubble: String? {
        switch self { case .waiting: "?"; case .done: "✓"; default: nil }
    }
    public var title: String {
        switch self {
        case .asleep: "Asleep"; case .idle: "Idle"; case .working: "Working"; case .done: "Done"; case .waiting: "Waiting for you"
        }
    }
}

/// The built-in coats; the drawing is the same, only its colors change (AC-39.06).
public enum PetCoat: String, Codable, Equatable, Sendable, CaseIterable {
    case golden, cream, slate
    public var title: String {
        switch self { case .golden: "Golden"; case .cream: "Cream"; case .slate: "Slate" }
    }
}

/// The pet's state for one moment: the pose, the conversation behind it and the counts assistive tools read.
public struct PetState: Equatable, Sendable {
    public let pose: PetPose
    /// The conversation the pose speaks for; nil for Idle and Asleep.
    public let sessionID: UUID?
    public let sessionCount: Int
    public let waitingCount: Int
    public let runningCount: Int
    /// The compact status line shown on hover: project, agent and state of the pose's session.
    public let summary: String?

    public init(pose: PetPose, sessionID: UUID?, sessionCount: Int, waitingCount: Int, runningCount: Int, summary: String?) {
        self.pose = pose; self.sessionID = sessionID; self.sessionCount = sessionCount
        self.waitingCount = waitingCount; self.runningCount = runningCount; self.summary = summary
    }

    /// "Lunlet: two sessions, one waiting for you" (AC-39.07).
    public var accessibilityLabel: String {
        var parts: [String] = []
        parts.append(sessionCount == 0 ? "no sessions" : "\(Self.spelled(sessionCount)) \(sessionCount == 1 ? "session" : "sessions")")
        if waitingCount > 0 { parts.append("\(Self.spelled(waitingCount)) waiting for you") }
        else if pose == .done { parts.append("one just finished") }
        else if runningCount > 0 { parts.append("\(Self.spelled(runningCount)) working") }
        return "Lunlet: " + parts.joined(separator: ", ")
    }
    private static func spelled(_ count: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        return count < words.count ? words[count] : String(count)
    }
}

public enum PetPoseRule {
    /// Waiting over Done over Working over Idle over Asleep; only current conversations count (no child tasks,
    /// no ended sessions). `cue` is the finish cue the list model is presenting, which lasts the AC-13.02 duration.
    public static func state(sessions: [SessionSnapshot], cue: TaskCue?, monitoringAvailable: Bool) -> PetState {
        let current = sessions.filter { $0.parentSessionID == nil && !$0.isEnded && $0.hasConfirmedActivity }
        let waiting = current.filter(\.awaitsUser)
        let running = current.filter { $0.observation.phase == .running }
        let counts = (current.count, waiting.count, running.count)
        if let first = waiting.first {
            return .init(pose: .waiting, sessionID: first.observation.sessionID, sessionCount: counts.0,
                         waitingCount: counts.1, runningCount: counts.2, summary: summary(first))
        }
        if let cue, case .finished(let outcome) = cue.phase, outcome == .succeeded || outcome == .unknown,
           let finished = current.first(where: { $0.observation.sessionID.uuidString == cue.sessionID }) {
            return .init(pose: .done, sessionID: finished.observation.sessionID, sessionCount: counts.0,
                         waitingCount: counts.1, runningCount: counts.2, summary: summary(finished))
        }
        if let first = running.first {
            return .init(pose: .working, sessionID: first.observation.sessionID, sessionCount: counts.0,
                         waitingCount: counts.1, runningCount: counts.2, summary: summary(first))
        }
        if !current.isEmpty {
            return .init(pose: .idle, sessionID: nil, sessionCount: counts.0, waitingCount: 0, runningCount: 0, summary: nil)
        }
        return .init(pose: .asleep, sessionID: nil, sessionCount: 0, waitingCount: 0, runningCount: 0,
                     summary: monitoringAvailable ? nil : "Monitoring unavailable")
    }

    /// The same words as a session row: project, agent and state.
    static func summary(_ snapshot: SessionSnapshot) -> String {
        let notice = SessionNotice.prepare(snapshot)
        return [snapshot.project, snapshot.provider.shortName, notice.status].joined(separator: " · ")
    }
}
