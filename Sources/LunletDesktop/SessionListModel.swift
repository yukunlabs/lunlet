// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-15, AC-15.06; US-13, AC-13.09.
// Refs: US-13, AC-13.07.
// Refs: US-02, AC-02.02, AC-02.03, AC-02.05; US-03, AC-03.01, AC-03.02, AC-03.03, AC-03.04.
// Refs: US-13, AC-13.01, AC-13.02, AC-13.03, AC-13.04, AC-13.05, AC-13.06; US-12, AC-12.04.
// Refs: US-11, AC-11.03.
// Refs: US-15, AC-15.01, AC-15.02, AC-15.03, AC-15.04, AC-15.05.
// Refs: US-33, AC-33.01, AC-33.02, AC-33.06; US-19, AC-19.03, AC-19.04.
import Foundation
import Combine
import CryptoKit
import LunletCore

@MainActor protocol TaskCuePresenting: AnyObject {
    func show(_ cues: [TaskCue])
    func hide()
}

@MainActor final class SessionListModel: ObservableObject {
    @Published private(set) var sessions: [SessionSnapshot] = [] { didSet { updateCompactStatus() } }
    @Published private(set) var history: [SessionSnapshot] = []
    @Published private(set) var monitoringAvailable = false { didSet { updateCompactStatus() } }
    @Published private(set) var selectedID: UUID?
    /// The conversation a recent cue named, published when the panel opens soon after so the panel shows it (AC-13.09).
    struct CueFocus: Equatable { let sessionID: UUID; let provider: SessionProvider; let sequence: Int }
    @Published private(set) var cueFocus: CueFocus?
    /// A cue keeps its conversation for opening while visible and this long after it hides.
    nonisolated static let cueFocusGrace: TimeInterval = 15
    private var pendingFocus: (sessionID: UUID, provider: SessionProvider, until: TimeInterval)?
    private var focusSequence = 0
    @Published private(set) var navigationUnavailableFor: UUID?
    var navigationAction: (@MainActor (UUID, UUID) async -> Bool)?
    private var returning = false
    @Published var isRefreshing = false
    @Published private(set) var monitoringPartial = false { didSet { updateCompactStatus() } }
    /// The single compact status for both entries; it is reassigned only when it changes.
    @Published private(set) var compactStatus = CompactSessionStatus.unavailable
    /// Providers whose sources are running; each reports its own availability.
    @Published private(set) var monitoredProviders: Set<SessionProvider> = [.codex] { didSet { updateCompactStatus() } }
    @Published private(set) var connectedProviders: Set<SessionProvider> = []
    private var partialProviders: Set<SessionProvider> = []
    /// Rows and cues name their agent whenever any provider other than Codex alone is shown.
    var labelsAgents: Bool { monitoredProviders != [.codex] }
    private struct Binding: Hashable { let session: UUID; let connection: UUID }
    private let displayAvailable: @MainActor () -> Bool
    private let elapsed: @MainActor () -> TimeInterval
    private let presenter: any TaskCuePresenting
    private let presentation = CuePresentation()
    private var ended: Set<Binding> = []
    // Retain previously useful rows through temporary observation outages.
    private var presentedSessions: Set<UUID> = []
    private struct Activity: Equatable {
        let connection: UUID
        let phase: SessionPhase
        let turn: String?
        let input: String?
    }
    // Retain verified activity through observation outages; recovery alone is not new work.
    private var lastActivity: [UUID: Activity] = [:]
    private struct CueActivity {
        let turn: String
        let input: String?
        let pending: Bool
        let key: String?
        let token: String
    }
    private var cueActivity: [Binding: CueActivity] = [:]
    private var shown: [TaskCue] = []
    private var expiry: Task<Void, Never>?
    private var displayMonitor: DisplayStateMonitor?
    private var closed = false

    var displayedSessions: [SessionSnapshot] { displayedSessions(for: nil) }

    /// Active rows for one provider page, or for every provider when nil.
    func displayedSessions(for provider: SessionProvider?) -> [SessionSnapshot] {
        let hidden = Set(history.map { $0.observation.sessionID })
        return sessions.filter {
            $0.parentSessionID == nil && !hidden.contains($0.observation.sessionID)
                && (provider == nil || $0.provider == provider)
                && (presentedSessions.contains($0.observation.sessionID) || Self.isUseful($0))
        }
    }
    func history(for provider: SessionProvider?) -> [SessionSnapshot] {
        provider.map { provider in history.filter { $0.provider == provider } } ?? history
    }

    private static func isUseful(_ snapshot: SessionSnapshot) -> Bool {
        if let preview = snapshot.localPreview, !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if let title = snapshot.sourceTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if snapshot.navigationAvailable { return true }
        return snapshot.hasConfirmedActivity && (snapshot.observation.phase != .unknown || snapshot.inputPending)
    }

    /// Clearing a provider page moves only that provider's rows into History.
    func clearDisplayedSessions(provider: SessionProvider? = nil) {
        guard !closed else { return }
        for snapshot in displayedSessions(for: provider) { retainInHistory(snapshot) }
        selectedID = nil
    }

    func restoreAfterExplicitRefresh(_ connections: [UUID: UUID]) {
        guard !closed else { return }
        history.removeAll {
            Self.hasOngoingWork($0) && $0.hasConfirmedActivity
                && connections[$0.observation.sessionID] == $0.observation.connectionID
        }
    }

    func canRestore(sessionID: UUID) -> Bool {
        sessions.contains { $0.observation.sessionID == sessionID && $0.hasConfirmedActivity && Self.hasOngoingWork($0) }
    }
    private static func hasOngoingWork(_ snapshot: SessionSnapshot) -> Bool {
        snapshot.inputPending || snapshot.observation.phase == .running || snapshot.awaitsUser
    }
    func restore(sessionID: UUID) {
        guard !closed, canRestore(sessionID: sessionID) else { return }
        history.removeAll { $0.observation.sessionID == sessionID }
    }

    private func retainInHistory(_ snapshot: SessionSnapshot) {
        if let index = history.firstIndex(where: { $0.observation.sessionID == snapshot.observation.sessionID }) {
            history[index] = snapshot
        } else { history.append(snapshot) }
    }

    var selected: SessionSnapshot? {
        sessions.first { $0.observation.sessionID == selectedID }
            ?? history.first { $0.observation.sessionID == selectedID }
    }

    convenience init() { self.init(presenter: TransientCuePanel()) }

    convenience init(presenter: any TaskCuePresenting) {
        let clock = ContinuousClock(), start = ContinuousClock.now
        self.init(displayAvailable: { SystemDisplayState.isAvailable }, elapsed: {
            let duration = start.duration(to: clock.now).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }, presenter: presenter)
        displayMonitor = DisplayStateMonitor { [weak self] in self?.refreshDisplayState() }
    }

    init(displayAvailable: @escaping @MainActor () -> Bool, elapsed: @escaping @MainActor () -> TimeInterval,
         presenter: any TaskCuePresenting) {
        self.displayAvailable = displayAvailable; self.elapsed = elapsed; self.presenter = presenter
    }

    func receive(_ snapshot: SessionSnapshot, origin: CuePresentation.Origin) {
        guard !closed else { return }
        let observation = snapshot.observation
        let binding = Binding(session: observation.sessionID, connection: observation.connectionID)
        guard !ended.contains(binding) else { return }
        if Self.isUseful(snapshot) { presentedSessions.insert(observation.sessionID) }
        if snapshot.isEnded { retainEnded(snapshot, binding: binding); return }
        recordActivity(snapshot, origin: origin)
        store(snapshot)
        refreshDisplayState()
        guard let cue = cue(for: snapshot, binding: binding) else { return }
        presentation.receive(cue, origin: origin, now: elapsed())
        refreshPresentation()
    }

    /// An ended binding is final; it keeps the previous same-connection summary.
    private func retainEnded(_ snapshot: SessionSnapshot, binding: Binding) {
        let observation = snapshot.observation
        let previous = (sessions + history).first {
            $0.observation.sessionID == observation.sessionID && $0.observation.connectionID == observation.connectionID
        }
        ended.insert(binding)
        // A delayed exit for an older connection cannot replace a newer live connection.
        let newerConnection = sessions.contains {
            $0.observation.sessionID == observation.sessionID && $0.observation.connectionID != observation.connectionID
        }
        if !newerConnection {
            let retained = snapshot.retainingSummary(of: previous)
            if let index = sessions.firstIndex(where: { $0.observation.sessionID == observation.sessionID }) {
                sessions[index] = retained
            } else { sessions.append(retained) }
            if history.contains(where: { $0.observation.sessionID == observation.sessionID }) { retainInHistory(retained) }
        }
        updateMonitoringAvailability()
        if selected == nil { selectedID = nil }
    }

    /// New verified input or turn identity restores cleared ongoing work; recovery alone does not.
    private func recordActivity(_ snapshot: SessionSnapshot, origin: CuePresentation.Origin) {
        let observation = snapshot.observation
        guard snapshot.hasConfirmedActivity, observation.phase != .unknown || snapshot.inputPending else { return }
        let turn = snapshot.turnID ?? { if case .idle(let completed) = observation.phase { return completed }; return nil }()
        let activity = Activity(connection: observation.connectionID, phase: observation.phase, turn: turn, input: snapshot.inputActivityID)
        let previous = lastActivity[observation.sessionID]
        let newIdentity = previous.map {
            (turn != nil && $0.turn != nil && turn != $0.turn)
                || (activity.input != nil && $0.input != nil && activity.input != $0.input)
        } ?? false
        let live: Bool
        if case .liveTransition = origin { live = true } else { live = false }
        let wasHidden = history.contains { $0.observation.sessionID == observation.sessionID }
        if wasHidden, Self.hasOngoingWork(snapshot), previous != activity, live || newIdentity {
            history.removeAll { $0.observation.sessionID == observation.sessionID }
        }
        lastActivity[observation.sessionID] = activity
    }

    private func store(_ snapshot: SessionSnapshot) {
        let id = snapshot.observation.sessionID
        if history.contains(where: { $0.observation.sessionID == id }) { retainInHistory(snapshot) }
        if let index = sessions.firstIndex(where: { $0.observation.sessionID == id }) {
            sessions[index] = snapshot
        } else { sessions.append(snapshot) }
        updateMonitoringAvailability()
    }

    /// Builds the cue for a verified start or completion and records the binding's cue identity.
    private func cue(for snapshot: SessionSnapshot, binding: Binding) -> TaskCue? {
        guard snapshot.parentSessionID == nil, snapshot.hasConfirmedActivity else { return nil }
        let observation = snapshot.observation
        let phase: TaskCue.Phase
        let turn: String
        if snapshot.inputPending, let input = snapshot.inputActivityID {
            turn = snapshot.turnID ?? input; phase = .started
        } else {
            switch observation.phase {
            case .running:
                guard let current = snapshot.turnID, !current.isEmpty else { return nil }
                turn = current; phase = .started
            case .idle(let completed): turn = completed; phase = .finished(snapshot.outcome)
            default: return nil
            }
        }
        let notice = SessionNotice.prepare(snapshot)
        let previousCue = cueActivity[binding]
        let inputKey: String?
        if let previousCue, previousCue.input == snapshot.inputActivityID, !snapshot.inputPending {
            // Preserve pending-input/assigned-turn coalescing, but a later turn
            // retaining that input record must have its own start identity.
            inputKey = previousCue.turn == turn || previousCue.pending ? previousCue.key : nil
        } else { inputKey = snapshot.inputActivityID }
        let token: String
        if let previousCue, previousCue.input == snapshot.inputActivityID,
           previousCue.turn == turn || previousCue.pending {
            token = previousCue.token
        } else { token = Self.cueToken(session: observation.sessionID, turn: turn, input: snapshot.inputActivityID) }
        cueActivity[binding] = .init(turn: turn, input: snapshot.inputActivityID,
            pending: snapshot.inputPending, key: inputKey, token: token)
        let title = labelsAgents ? snapshot.provider.shortName + " · " + notice.project : notice.project
        return .init(sessionID: observation.sessionID.uuidString, connectionID: observation.connectionID.uuidString,
                     turnID: turn, title: title, phase: phase, inputActivityID: inputKey,
                     context: snapshot.localPreview ?? "Task " + token)
    }

    private static func cueToken(session: UUID, turn: String, input: String?) -> String {
        let identity = [session.uuidString, turn, input ?? ""]
        return SHA256.hash(data: Data(identity.map { "\($0.utf8.count):\($0)" }.joined().utf8))
            .prefix(4).map { String(format: "%02X", $0) }.joined()
    }

    func canRequestReturn(_ id: UUID) -> Bool {
        guard !closed, navigationAction != nil,
              let session = sessions.first(where: { $0.observation.sessionID == id }) else { return false }
        return session.navigationAvailable && session.hasConfirmedActivity
    }

    func returnToSession(_ id: UUID) async {
        guard !closed, !returning else { return }
        guard canRequestReturn(id), let session = sessions.first(where: { $0.observation.sessionID == id }),
              let navigationAction else { navigationUnavailableFor = id; return }
        returning = true
        navigationUnavailableFor = nil
        let opened = await navigationAction(id, session.observation.connectionID)
        returning = false
        guard !closed else { return }
        if !opened { navigationUnavailableFor = id }
    }

    /// Called as the panel opens by hover, click or keyboard: within the grace period the recent cue's conversation
    /// is selected and its provider published once; later openings keep the page last shown.
    func applyCueFocus() {
        defer { pendingFocus = nil }
        guard !closed, let pending = pendingFocus, elapsed() <= pending.until,
              (sessions + history).contains(where: { $0.observation.sessionID == pending.sessionID }) else { return }
        select(pending.sessionID)
        focusSequence += 1
        cueFocus = CueFocus(sessionID: pending.sessionID, provider: pending.provider, sequence: focusSequence)
    }

    func select(_ id: UUID) {
        if !closed, (sessions + history).contains(where: { $0.observation.sessionID == id }) {
            selectedID = id; navigationUnavailableFor = nil
        }
    }

    func monitoringConnected(partial: Bool, provider: SessionProvider = .codex) {
        guard !closed else { return }
        connectedProviders.insert(provider)
        if partial { partialProviders.insert(provider) } else { partialProviders.remove(provider) }
        updateMonitoringAvailability()
    }

    /// One provider's outage degrades only that provider's rows and cues.
    func monitoringUnavailable(provider: SessionProvider = .codex) {
        guard !closed else { return }
        connectedProviders.remove(provider); partialProviders.insert(provider)
        let degrade = { (snapshot: SessionSnapshot) in
            snapshot.provider != provider || snapshot.isEnded ? snapshot : snapshot.degraded(liveness: .unverified, phase: .unknown)
        }
        sessions = sessions.map(degrade); history = history.map(degrade)
        updateMonitoringAvailability()
        let owned = Set(sessions.filter { $0.provider == provider }.map(\.observation.sessionID.uuidString))
        guard shown.contains(where: { owned.contains($0.sessionID) }) else { return }
        presentation.setDisplayAvailable(false)
        refreshPresentation()
    }

    /// Stops presenting deselected providers; their rows, history and cue state are local and are dropped.
    func setMonitoredProviders(_ providers: Set<SessionProvider>) {
        guard !closed, providers != monitoredProviders else { return }
        let removed = Set((sessions + history).filter { !providers.contains($0.provider) }.map(\.observation.sessionID))
        if !removed.isEmpty {
            sessions.removeAll { removed.contains($0.observation.sessionID) }
            history.removeAll { removed.contains($0.observation.sessionID) }
            presentedSessions.subtract(removed)
            for id in removed { lastActivity.removeValue(forKey: id) }
            ended = ended.filter { !removed.contains($0.session) }
            cueActivity = cueActivity.filter { !removed.contains($0.key.session) }
            if let selectedID, removed.contains(selectedID) { self.selectedID = nil }
        }
        connectedProviders.formIntersection(providers); partialProviders.formIntersection(providers)
        monitoredProviders = providers
        updateMonitoringAvailability()
    }

    func isMonitoringAvailable(for provider: SessionProvider) -> Bool {
        connectedProviders.contains(provider) || sessions.contains { $0.provider == provider && $0.hasConfirmedActivity }
    }

    /// Published flags change only when their value does, so subscribers are not woken per snapshot.
    private func updateMonitoringAvailability() {
        let available = !monitoredProviders.isEmpty && monitoredProviders.allSatisfy(isMonitoringAvailable(for:))
        let partial = !partialProviders.isDisjoint(with: monitoredProviders)
        if monitoringPartial != partial { monitoringPartial = partial }
        if monitoringAvailable != available { monitoringAvailable = available }
    }

    private func updateCompactStatus() {
        let label = monitoredProviders.count == 1 ? monitoredProviders.first?.displayName ?? "Agents" : "Agents"
        let next = CompactSessionStatus(snapshots: sessions, available: monitoringAvailable, partial: monitoringPartial,
                                        label: label)
        if next != compactStatus { compactStatus = next }
    }

    func refreshDisplayState() {
        guard !closed else { return }
        presentation.setDisplayAvailable(displayAvailable())
        refreshPresentation()
    }

    func refreshPresentation() {
        guard !closed else { return }
        presentation.expire(now: elapsed())
        let cues = presentation.cues
        guard cues != shown else { return }
        shown = cues; expiry?.cancel(); expiry = nil
        if cues.isEmpty { presenter.hide() }
        else {
            // The newest cue's conversation is the one to show if the panel opens soon (AC-13.09).
            if let cue = cues.last, let id = UUID(uuidString: cue.sessionID),
               let snapshot = (sessions + history).first(where: { $0.observation.sessionID == id }) {
                pendingFocus = (id, snapshot.provider, elapsed() + CuePresentation.displayDuration + Self.cueFocusGrace)
            }
            presenter.show(cues)
            expiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(CuePresentation.displayDuration)) } catch { return }
                self?.refreshPresentation()
            }
        }
    }

    func shutdown() {
        guard !closed else { return }
        closed = true; expiry?.cancel(); expiry = nil; displayMonitor = nil; navigationAction = nil
        presentation.setDisplayAvailable(false); shown = []; presenter.hide()
    }
}
