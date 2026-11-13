// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.08, AC-33.09, AC-33.11; US-32, AC-32.05, AC-32.06, AC-32.07, AC-32.08.
// Refs: US-04, AC-04.03, AC-04.05, AC-04.12; US-12, AC-12.04; US-25, AC-25.02.
import Combine
import Darwin
import Foundation
import LunletClaude
import LunletCore
import SwiftUI

/// Claude plan limits from Lunlet's status line, and its explicit connect and disconnect actions. Reads only Lunlet's
/// own files: on panel opening, on Refresh, and on file events while the panel is visible. No timer polls.
@MainActor final class ClaudePlanLimitsModel: ObservableObject {
    enum Connection: Equatable, Sendable {
        case checking, notConnected, connected, changedOutsideLunlet
        case unavailable(ClaudeStatusLineFailure)
    }
    @Published private(set) var connection = Connection.checking
    @Published private(set) var limits: ClaudePlanLimits?
    /// The latest read of Lunlet's reading file failed; earlier readings stay and are labeled stale (AC-32.07).
    @Published private(set) var readFailed = false
    /// The outcome of the last connect, disconnect or forget action that did not succeed.
    @Published private(set) var actionIssue: ClaudeStatusLineFailure?
    @Published private(set) var isChanging = false
    /// The account Claude Code caches, read with the limits: email and plan only, never logged (AC-33.11).
    @Published private(set) var account: ClaudeAccountProfile?
    /// Set when Lunlet connected the status line on its own, until the panel has been shown and hidden once, so the
    /// card can say so and offer Undo (AC-33.08).
    @Published private(set) var addedAutomatically = false

    private let service: ClaudeStatusLineConnection
    private let reader: ClaudePlanLimitsReader
    private let now: @MainActor () -> Date
    private var active = false, closed = false, watching = false
    private var operation: Task<Void, Never>?
    private var rerun = false
    /// Counts status-line changes; a read that started before a change is stale and never overwrites its result.
    private var generation = 0
    /// True from the end of a change until the read that follows it lands, so `isChanging` never clears while the
    /// published connection, limits and account still mix the states before and after the change.
    private var settlingChange = false
    private var watch: DispatchSourceFileSystemObject?
    private var debounce: Task<Void, Never>?
    /// Connects automatically while Claude Code is selected, unless the owner disconnected it (AC-33.08).
    private let connectsAutomatically: Bool
    /// Remembers an explicit disconnect across launches; only a later explicit connect clears it.
    private let choices: UserDefaults?
    static let declinedKey = "claudeStatusLineDeclined"
    private var automaticAttempted = false, automaticPending = false, shownSinceAdded = false
    /// True once the status line Lunlet added was taken out after Claude Code was turned off; set when that removal
    /// succeeded, never before, so a removal that failed or had to wait is still owed.
    private var released = false
    /// The changes this owner makes to Claude Code's settings. `release` is the removal after Claude Code was
    /// turned off: a line Lunlet connected goes back to what it replaced, any other state is left alone.
    private enum Change: Sendable { case connect, disconnect, forget, release }
    /// A change asked for while another was in flight; it runs when that one has settled.
    private var queuedChange: Change?
    /// The change `actionIssue` reports, so Try again repeats it.
    private var failedChange: Change?

    init(service: ClaudeStatusLineConnection = .init(), reader: ClaudePlanLimitsReader? = nil,
         now: @escaping @MainActor () -> Date = Date.init, connectsAutomatically: Bool = false, choices: UserDefaults? = nil) {
        self.service = service; self.reader = reader ?? .init(location: service.location); self.now = now
        self.connectsAutomatically = connectsAutomatically; self.choices = choices
    }
    /// An inert owner for views shown without the runtime's model: it reads and writes nothing, not even Claude
    /// Code's settings, and reports not connected.
    static let placeholder: ClaudePlanLimitsModel = {
        let model = ClaudePlanLimitsModel()
        model.closed = true; model.connection = .notConnected
        return model
    }()

    /// Work happens only while Claude Code is a selected agent.
    func setActive(_ value: Bool) {
        guard !closed else { return }
        // Claude Code not selected: the status line Lunlet added goes back to what it replaced, so the agent switch is
        // the only control; selecting it again connects anew (AC-33.08). A line changed outside Lunlet is left alone.
        if !value, connectsAutomatically, !released {
            automaticAttempted = false; addedAutomatically = false
            change(.release)
        }
        guard value != active else { return }
        active = value
        if value {
            released = false
            refresh(updatingScript: true)
            if watching { startWatching() }
        } else { stopWatching() }
    }

    /// Reads the connection and the latest readings; overlapping requests coalesce into one more read.
    func refresh(updatingScript: Bool = false) {
        guard active else { return }
        read(updatingScript: updatingScript)
    }

    /// Settings shows the connection whether or not Claude Code is a selected agent.
    func check() { read() }

    private func read(updatingScript: Bool = false) {
        guard !closed else { return }
        guard operation == nil else { rerun = true; return }
        let service = service, reader = reader, date = now(), started = generation
        operation = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Read in
                if updatingScript { try? service.updateInstalledScript() }
                return Read(connection: Self.connection { try service.state() }, limits: Result { try reader.read(now: date) },
                            account: ClaudeAccountProfile.read(home: service.home))
            }.value
            self?.finish(result, from: started)
        }
    }

    /// An explicit connect also lifts an earlier decline.
    func connect() { choices?.removeObject(forKey: Self.declinedKey); change(.connect) }
    /// An explicit disconnect is remembered, so Lunlet does not connect again on its own.
    func disconnect() {
        choices?.set(true, forKey: Self.declinedKey); addedAutomatically = false
        change(.disconnect)
    }
    func forget() { change(.forget) }
    /// Repeats the change that failed. A removal owed since Claude Code was turned off is repeated as that removal;
    /// if Claude Code was selected again meanwhile, the connect is what is wanted now.
    func retry() {
        switch failedChange {
        case .disconnect: disconnect()
        case .forget: forget()
        case .release where !active: change(.release)
        case .connect, .release, nil: connect()
        }
    }

    /// Watches Lunlet's own directory while the panel is visible, so a new reading appears without polling.
    func setWatching(_ value: Bool) {
        // The automatic-connection note stays for one panel visit.
        if value, addedAutomatically { shownSinceAdded = true }
        if !value, shownSinceAdded { addedAutomatically = false; shownSinceAdded = false }
        watching = value
        if value, active { startWatching(); refresh() } else { stopWatching() }
    }

    func shutdown() async {
        closed = true
        stopWatching()
        operation?.cancel()
        await operation?.value
        operation = nil
    }

    private struct Read: Sendable {
        let connection: Connection
        let limits: Result<ClaudePlanLimits?, Error>
        let account: ClaudeAccountProfile?
    }

    private func finish(_ result: Read, from started: Int) {
        operation = nil
        guard !closed else { return }
        // A change landed while this read was in flight: its picture of the status line is stale, so read again.
        guard started == generation else { rerun = false; read(); return }
        connection = result.connection
        if account != result.account { account = result.account }
        switch result.limits {
        case .success(let value): limits = value; readFailed = false
        case .failure: readFailed = true
        }
        if watching, active, connection == .connected, watch == nil { startWatching() }
        if automaticPending, connection == .connected { addedAutomatically = true }
        automaticPending = false
        if settlingChange { settlingChange = false; isChanging = false }
        // A change that had to wait runs now. A removal queued when Claude Code was turned off is dropped if it was
        // selected again meanwhile.
        if !isChanging, let next = queuedChange {
            queuedChange = nil
            if !(next == .release && active) { change(next) }
        }
        connectAutomaticallyIfNeeded()
        if rerun { rerun = false; read() }
    }

    /// Once per launch, while Claude Code is selected: a status line that is simply absent or another command is
    /// connected (and chained); a declined, changed-outside or unsupported state is left alone (AC-33.08).
    private func connectAutomaticallyIfNeeded() {
        guard connectsAutomatically, active, !automaticAttempted, connection == .notConnected,
              choices?.bool(forKey: Self.declinedKey) != true else { return }
        // Nothing else is in flight or waiting, so this attempt is the change that runs next.
        guard !isChanging, queuedChange == nil else { return }
        automaticAttempted = true; automaticPending = true
        change(.connect)
    }

    private nonisolated static func apply(_ change: Change, to service: ClaudeStatusLineConnection) throws -> ClaudeStatusLineState {
        switch change {
        case .connect: try service.connect()
        case .disconnect: try service.disconnect()
        case .forget: try service.forget()
        case .release: try service.state() == .connected ? service.disconnect() : service.state()
        }
    }

    /// One change at a time. A change asked for while another is in flight waits for it instead of being dropped;
    /// the latest request is the one that waits.
    private func change(_ change: Change) {
        guard !closed else { return }
        guard !isChanging else { queuedChange = change; return }
        isChanging = true; actionIssue = nil; failedChange = nil; generation += 1
        let service = service
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ClaudeStatusLineState, Error> in
                Result { try Self.apply(change, to: service) }
            }.value
            guard let self, !self.closed else { return }
            // The change reports the state it left behind, so the connection never lags the file it describes; the
            // change counts as in progress until the read that refreshes limits and account has landed too.
            if case .success(let state) = outcome {
                self.connection = Self.connection { state }
                // The removal owed since Claude Code was turned off is done, unless it was selected again meanwhile.
                if change == .release, !self.active { self.released = true; self.addedAutomatically = false }
            }
            if case .failure(let error) = outcome {
                // An automatic attempt that fails stays quiet; the card keeps its own Add status line button.
                if self.automaticPending { self.automaticPending = false } else {
                    self.actionIssue = error as? ClaudeStatusLineFailure ?? .writeFailed
                    self.failedChange = change
                }
            }
            // Settings acts on Claude Code's configuration whether or not Claude Code is a selected agent.
            self.settlingChange = true
            self.read()
        }
    }

    private nonisolated static func connection(_ read: () throws -> ClaudeStatusLineState) -> Connection {
        do {
            switch try read() {
            case .connected: return .connected
            case .notConnected: return .notConnected
            case .changedOutsideLunlet: return .changedOutsideLunlet
            }
        } catch { return .unavailable(error as? ClaudeStatusLineFailure ?? .settingsUnreadable) }
    }

    private func startWatching() {
        guard watch == nil, !closed else { return }
        let fd = open(service.location.directory.path, O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fileChanged() }
        }
        source.setCancelHandler { close(fd) }
        watch = source
        source.resume()
    }
    private func stopWatching() {
        debounce?.cancel(); debounce = nil
        watch?.cancel(); watch = nil
    }
    /// Claude Code updates its status line at most every 300 ms; reads follow with the same coalescing.
    private func fileChanged() {
        guard debounce == nil else { return }
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.debounce = nil
            // Disconnecting removes the directory; a later connect starts a new watch.
            if !FileManager.default.fileExists(atPath: self.service.location.directory.path) { self.stopWatching() }
            self.refresh()
        }
    }
}

private struct ClaudePlanLimitsKey: EnvironmentKey { static let defaultValue: ClaudePlanLimitsModel? = nil }
extension EnvironmentValues {
    /// The runtime's Claude plan-limits owner; nil in previews and tests that do not show Claude limits.
    var claudePlanLimits: ClaudePlanLimitsModel? {
        get { self[ClaudePlanLimitsKey.self] }
        set { self[ClaudePlanLimitsKey.self] = newValue }
    }
}
