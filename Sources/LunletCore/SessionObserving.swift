// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.01, AC-33.02, AC-33.05; US-19, AC-19.03, AC-19.04.
// Refs: US-02, AC-02.01, AC-02.02, AC-02.05; US-13, AC-13.04; US-15, AC-15.05.
import Foundation

/// The coding agent whose local records produced an observation. Identity never grants input authority.
public enum SessionProvider: String, CaseIterable, Hashable, Sendable {
    case codex, claude
    /// Product name for page titles and notifications.
    public var displayName: String { self == .codex ? "Codex" : "Claude Code" }
    /// Compact label for session rows and cues.
    public var shortName: String { self == .codex ? "Codex" : "Claude" }
}

/// One provider's ordered observation stream.
public enum SessionUpdate: Sendable {
    /// A baseline snapshot is current state, never a new start or completion.
    case snapshot(SessionSnapshot, baseline: Bool)
    case availability(connected: Bool, partial: Bool)
    /// Sessions whose activity is confirmed now, yielded after every snapshot of the same refresh.
    case reconciled([UUID: UUID])
}

/// A read-only local session source. Observation never issues remote controls.
public protocol SessionObserving: Sendable {
    func updates() async -> AsyncStream<SessionUpdate>
    func refresh() async
    func reconcile() async
    func shutdown() async
}
