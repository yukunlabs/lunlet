// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-06, AC-06.01, AC-06.02; US-05, AC-05.06.
// Refs: US-02, AC-02.01, AC-02.02, AC-02.04, AC-02.05, AC-02.06; US-03, AC-03.01, AC-03.02, AC-03.03; US-15, AC-15.05.
// Refs: US-11, AC-11.03, AC-11.04, AC-11.05; US-13, AC-13.01, AC-13.04; US-12, AC-12.04.
// Refs: US-33, AC-33.01, AC-33.02, AC-33.05, AC-33.06; US-19, AC-19.01, AC-19.03.
// Refs: US-08, AC-08.01, AC-08.05.
import Foundation
import LunletCodex
import LunletCore

/// Owns one read-only observation stream per selected provider and merges them into one list.
/// A source speaks only for its own provider, and a session UUID keeps its first provider.
@MainActor final class SessionObservationModel {
    private final class Entry {
        let provider: SessionProvider
        let source: any SessionObserving
        var receiving: Task<Void, Never>?
        init(provider: SessionProvider, source: any SessionObserving) { self.provider = provider; self.source = source }
    }
    private let model: SessionListModel
    var snapshotReceived: (@MainActor (SessionSnapshot, Bool) -> Void)?
    private let makeSource: @MainActor (SessionProvider) -> any SessionObserving
    private var providers: Set<SessionProvider>
    private var entries: [SessionProvider: Entry] = [:]
    private var owners: [UUID: SessionProvider] = [:]
    private var retiring: [UUID: Task<Void, Never>] = [:]
    private var started = false
    private var refreshing: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var closed = false

    init(model: SessionListModel, providers: Set<SessionProvider>,
         makeSource: @escaping @MainActor (SessionProvider) -> any SessionObserving,
         openDestination: @escaping @MainActor (CodexTerminalDestination) async -> Bool = SessionDestinationOpener.open) {
        self.model = model; self.providers = providers; self.makeSource = makeSource
        model.setMonitoredProviders(providers)
        // Only Codex has verified original destinations; other providers never navigate.
        model.navigationAction = { [weak self] session, connection in
            guard let self, !self.closed, self.owners[session] ?? .codex == .codex,
                  let codex = self.entries[.codex]?.source as? any CodexSessionObserving,
                  let destination = await codex.destination(sessionID: session, connectionID: connection),
                  !self.closed, !Task.isCancelled else { return false }
            return await openDestination(destination)
        }
    }
    convenience init(model: SessionListModel, source: any SessionObserving = CodexSessionMonitor(),
                     openDestination: @escaping @MainActor (CodexTerminalDestination) async -> Bool = SessionDestinationOpener.open) {
        self.init(model: model, providers: [.codex], makeSource: { _ in source }, openDestination: openDestination)
    }

    func start() {
        guard !started, !closed else { return }
        started = true
        for provider in SessionProvider.allCases where providers.contains(provider) { begin(provider) }
    }

    /// Display selection starts and stops sources; a deselected provider's rows leave the list.
    func setProviders(_ next: Set<SessionProvider>) {
        guard !closed, next != providers else { return }
        let removed = providers.subtracting(next), added = next.subtracting(providers)
        providers = next
        for provider in removed {
            guard let entry = entries.removeValue(forKey: provider) else { continue }
            entry.receiving?.cancel()
            let id = UUID()
            retiring[id] = Task { [weak self] in
                await entry.source.shutdown(); await entry.receiving?.value
                self?.retiring.removeValue(forKey: id)
            }
            owners = owners.filter { $0.value != provider }
        }
        model.setMonitoredProviders(next)
        if started { for provider in SessionProvider.allCases where added.contains(provider) { begin(provider) } }
    }

    private func begin(_ provider: SessionProvider) {
        guard entries[provider] == nil else { return }
        let entry = Entry(provider: provider, source: makeSource(provider))
        entries[provider] = entry
        entry.receiving = Task { [weak self, weak entry] in
            guard let source = entry?.source else { return }
            let stream = await source.updates()
            for await update in stream {
                guard let self, let entry, !self.closed, !Task.isCancelled, self.entries[provider] === entry else { return }
                self.receive(update, from: provider)
            }
            guard let self, let entry, !self.closed, self.entries[provider] === entry else { return }
            self.model.monitoringUnavailable(provider: provider)
        }
    }

    private func receive(_ update: SessionUpdate, from provider: SessionProvider) {
        switch update {
        case .snapshot(let snapshot, let baseline):
            let id = snapshot.observation.sessionID
            guard snapshot.provider == provider, owners[id].map({ $0 == provider }) ?? true else { return }
            owners[id] = provider
            model.receive(snapshot, origin: baseline ? .snapshot : .liveTransition)
            // The owner's notice carries a request excerpt (AC-06.02); child tasks send none.
            if snapshot.parentSessionID == nil { snapshotReceived?(snapshot, baseline) }
        case .reconciled(let connections):
            model.restoreAfterExplicitRefresh(connections.filter { owners[$0.key] == provider })
        case .availability(let connected, let partial):
            if connected { model.monitoringConnected(partial: partial, provider: provider) }
            else { model.monitoringUnavailable(provider: provider) }
        }
    }

    /// The Codex source that observes this session, for a reply's live-binding recheck.
    func codexSource(for sessionID: UUID) -> (any CodexSessionObserving)? {
        guard !closed, owners[sessionID] == .codex else { return nil }
        return entries[.codex]?.source as? any CodexSessionObserving
    }

    func refresh() {
        guard !closed, started, refreshing == nil, !entries.isEmpty else { return }
        model.isRefreshing = true
        let sources = entries.values.map(\.source)
        refreshing = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for source in sources { group.addTask { await source.reconcile() } }
            }
            guard let self, !self.closed, !Task.isCancelled else { return }
            self.model.isRefreshing = false; self.refreshing = nil
        }
    }

    func shutdown() async {
        if let closing { await closing.value; return }
        closed = true
        snapshotReceived = nil
        model.navigationAction = nil
        let current = Array(entries.values), pending = Array(retiring.values)
        for entry in current { entry.receiving?.cancel() }
        refreshing?.cancel()
        let task = Task {
            for entry in current { await entry.source.shutdown() }
            for task in pending { await task.value }
        }
        closing = task; await task.value
        for entry in current { await entry.receiving?.value }
        await refreshing?.value
        entries.removeAll(); retiring.removeAll(); owners.removeAll()
        refreshing = nil; model.isRefreshing = false
    }
}
