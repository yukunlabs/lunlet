// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-13, AC-13.01, AC-13.02, AC-13.03, AC-13.04, AC-13.05, AC-13.08.
import Foundation

public struct TaskCue: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case succeeded, failed, stopped, unknown }
    public enum Phase: Equatable, Sendable { case started, finished(Outcome) }
    public let sessionID: String
    public let connectionID: String
    public let turnID: String
    public let title: String
    public let phase: Phase
    public let inputActivityID: String?
    public let context: String?

    public init(sessionID: String, connectionID: String, turnID: String, title: String, phase: Phase, inputActivityID: String? = nil, context: String? = nil) {
        self.sessionID = sessionID
        self.connectionID = connectionID
        self.turnID = turnID
        self.title = title
        self.phase = phase; self.inputActivityID = inputActivityID; self.context = context
    }
}

/// Presentation state only; confine to its owning executor. The adapter must
/// establish live-transition provenance and the display's unlocked/awake state.
public final class CuePresentation {
    public enum Origin: Sendable { case snapshot, liveTransition }
    /// A start is identified by its input record when one exists, otherwise by its turn.
    private enum Transition: Hashable {
        case turnStart(session: String, connection: String, turn: String)
        case inputStart(session: String, connection: String, input: String)
        case completion(session: String, connection: String, turn: String)

        static func start(_ cue: TaskCue) -> Self {
            guard let input = cue.inputActivityID else {
                return .turnStart(session: cue.sessionID, connection: cue.connectionID, turn: cue.turnID)
            }
            return .inputStart(session: cue.sessionID, connection: cue.connectionID, input: input)
        }
    }
    /// Rollout reading is incremental and bindings are never reused, so only recent
    /// transitions can recur; older keys are evicted oldest first to bound memory.
    static let retainedTransitions = 4_096

    /// How long a live cue stays presented (about five seconds, AC-13.08); owners schedule their expiry checks with it.
    public static let displayDuration: TimeInterval = 5
    public private(set) var cues: [TaskCue] = []
    private var displayAvailable = false
    private var deadline: TimeInterval?
    private var consumed: Set<Transition> = []
    private var consumedOrder: [Transition] = []
    var consumedCount: Int { consumed.count }

    public init() {}

    public func setDisplayAvailable(_ available: Bool) {
        displayAvailable = available
        if !available { cues.removeAll(); deadline = nil }
    }

    public func receive(_ cue: TaskCue, origin: Origin, now: TimeInterval) {
        guard now.isFinite, now >= 0, !cue.sessionID.isEmpty,
              !cue.connectionID.isEmpty, !cue.turnID.isEmpty else { return }
        expire(now: now)
        let completion = Transition.completion(session: cue.sessionID, connection: cue.connectionID, turn: cue.turnID)
        if case .finished = cue.phase {
            guard consume(completion) else { return }
            // A delayed start for the input that already completed is not new work.
            consume(.start(cue))
        } else {
            guard consume(.start(cue)) else { return }
            guard cue.inputActivityID != nil || !consumed.contains(completion) else { return }
        }
        guard case .liveTransition = origin, displayAvailable else { return }
        cues = [cue]
        deadline = now + Self.displayDuration
    }

    @discardableResult private func consume(_ transition: Transition) -> Bool {
        guard consumed.insert(transition).inserted else { return false }
        consumedOrder.append(transition)
        if consumedOrder.count > Self.retainedTransitions {
            let evicted = consumedOrder.count - Self.retainedTransitions
            for old in consumedOrder.prefix(evicted) { consumed.remove(old) }
            consumedOrder.removeFirst(evicted)
        }
        return true
    }

    public func expire(now: TimeInterval) {
        guard now.isFinite, let deadline, now >= deadline else { return }
        cues.removeAll()
        self.deadline = nil
    }
}
