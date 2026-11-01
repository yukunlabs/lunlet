// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.01, AC-33.02, AC-33.03, AC-33.05, AC-33.06, AC-33.07.
// Refs: US-02, AC-02.05, AC-02.06; US-13, AC-13.01, AC-13.04; US-15, AC-15.05, AC-15.06; US-12, AC-12.04; US-25, AC-25.01.
import Darwin
import Foundation
import LunletCore

/// Read-only Claude Code observation through Claude's own per-process records and transcripts.
/// It installs no hooks, changes no settings, contacts no sockets and never issues remote controls.
public actor ClaudeSessionMonitor: SessionObserving {
    private struct Owner { let process: ClaudeProcessIdentity; let record: ClaudeRegistryRecord }
    private struct Tracked {
        let owners: Set<ClaudeProcessIdentity>
        let transcript: ClaudeTranscriptFile
        let registryFiles: Set<URL>
        let connection: UUID
        let record: ClaudeRegistryRecord
        var snapshot: SessionSnapshot
        var sole: ClaudeProcessIdentity? { owners.count == 1 ? owners.first : nil }
    }
    private struct Availability: Equatable { let connected: Bool; let partial: Bool }
    private enum Budget {
        static let poll: Duration = .seconds(5)
        static let reads: Duration = .seconds(3)
        static let sessions = 256
        static let freshDiscovery: TimeInterval = 10
        static let changeCoalescing: Duration = .milliseconds(100)
        static let eventScanInterval: Duration = .seconds(1)
    }
    /// Blocking process and file inspection stays off the shared cooperative pool.
    private nonisolated let executor = DispatchSerialQueue(label: "com.lunlet.claude.sessions", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let home: ClaudeHome
    private let registry: any ClaudeRegistryReading
    private let processes: any ClaudeProcessInspecting
    private let watchingFiles: Bool
    private let eventQueue: DispatchQueue
    private let wallNow: @Sendable () -> Date
    private var previousScanAt: Date?
    private var lastScanStarted: ContinuousClock.Instant?
    private var continuation: AsyncStream<SessionUpdate>.Continuation?
    private var running: Task<Void, Never>?
    private var coalescing: Task<Void, Never>?
    private var readingChanges: Task<Void, Never>?
    private var changedFiles: Set<ClaudeTranscriptFile> = []
    private var readers: [ClaudeTranscriptFile: ClaudeTranscriptReader] = [:]
    private var tracked: [UUID: Tracked] = [:]
    private var fileWatches: [WatchTarget: DispatchSourceFileSystemObject] = [:]
    private var exitWatches: [ClaudeProcessIdentity: DispatchSourceProcess] = [:]
    private let cleanup = DispatchGroup()
    private var lastAvailability: Availability?
    private var closed = false
    private var closing: Task<Void, Never>?

    public init(home: ClaudeHome = .current()) {
        self.init(home: home, registry: ClaudeSessionRegistry(directory: home.sessions), processes: ClaudeProcessReader(),
                  watchingFiles: true)
    }
    init(home: ClaudeHome, registry: any ClaudeRegistryReading, processes: any ClaudeProcessInspecting,
         watchingFiles: Bool = false, eventQueue: DispatchQueue = .global(qos: .utility),
         wallNow: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home; self.registry = registry; self.processes = processes
        self.watchingFiles = watchingFiles; self.eventQueue = eventQueue; self.wallNow = wallNow
    }

    public func updates() -> AsyncStream<SessionUpdate> {
        guard !closed, continuation == nil else { return AsyncStream { $0.finish() } }
        let pair = AsyncStream<SessionUpdate>.makeStream(bufferingPolicy: .unbounded)
        continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.shutdown() } }
        DiagnosticLog.record(.sessionObservation, component: .claude, outcome: .started, operation: .init())
        running = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                if let monitor = self { await monitor.refresh() } else { return }
                do { try await Task.sleep(for: Budget.poll) } catch { return }
            }
        }
        return pair.stream
    }
    public func refresh() {
        guard !closed, continuation != nil else { return }
        lastScanStarted = .now
        do { try scan() }
        catch is CancellationError { return }
        catch {
            previousScanAt = nil
            for id in Array(tracked.keys) { unconfirm(id) }
            availability(false, partial: true)
        }
    }
    public func reconcile() async {
        refresh()
        continuation?.yield(.reconciled(currentConnections()))
    }
    private func currentConnections() -> [UUID: UUID] {
        guard !closed, lastAvailability?.connected == true else { return [:] }
        return Dictionary(uniqueKeysWithValues: tracked.compactMap { id, value in
            guard value.snapshot.hasConfirmedActivity, let owner = value.sole, processes.presence(of: owner) == .same else { return nil }
            return (id, value.connection)
        })
    }

    private func scan() throws {
        let scanAt = wallNow()
        let found = try registry.scan()
        var uncertain = !found.complete
        var owners: [UUID: [Owner]] = [:]
        for record in found.records {
            try Task.checkCancellation()
            // An unrecognized start-time format cannot prove the owner; the record is not accepted.
            guard let start = record.processStart else { uncertain = true; continue }
            switch processes.verify(pid: record.pid, startedAt: start) {
            case .verified(let process): owners[record.sessionID, default: []].append(.init(process: process, record: record))
            case .stale: continue
            case .unknown: uncertain = true
            }
        }
        retire(owners, certain: !uncertain)
        var partial = uncertain
        try apply(owners, scanComplete: !uncertain, partial: &partial)
        reconcileWatches()
        previousScanAt = uncertain ? nil : scanAt
        availability(true, partial: partial || tracked.values.contains { !$0.snapshot.hasConfirmedActivity })
    }

    /// Retires bindings whose owners exited or no longer name the session, such as after `/clear`.
    private func retire(_ owners: [UUID: [Owner]], certain: Bool) {
        for id in Array(tracked.keys) {
            guard let old = tracked[id] else { continue }
            let current = Set((owners[id] ?? []).map(\.process))
            if current == old.owners { continue }
            let exited = old.owners.allSatisfy { processes.presence(of: $0) == .ended }
            if exited || (certain && current.isEmpty) {
                continuation?.yield(.snapshot(old.snapshot.degraded(liveness: .ended, phase: .ended), baseline: true))
                tracked.removeValue(forKey: id)
            } else if !current.isEmpty {
                // Another live process now shares or holds the session: rebind it with a new connection.
                unconfirm(id); tracked.removeValue(forKey: id)
            } else { unconfirm(id) }
        }
    }

    private func apply(_ owners: [UUID: [Owner]], scanComplete: Bool, partial: inout Bool) throws {
        let deadline = ContinuousClock.now + Budget.reads
        var nextReaders: [ClaudeTranscriptFile: ClaudeTranscriptReader] = [:]
        let ordered = owners.sorted { $0.key.uuidString < $1.key.uuidString }
        if ordered.count > Budget.sessions { partial = true }
        for (id, list) in ordered.prefix(Budget.sessions) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { partial = true; break }
            let ownerSet = Set(list.map(\.process))
            guard let record = list.map(\.record).min(by: { $0.pid < $1.pid }) else { continue }
            let old = tracked[id]
            // An unwritten transcript holds no activity yet; the session appears once it exists.
            guard let transcript = old.flatMap({ ClaudeProjects.regularFile($0.transcript.url) == $0.transcript ? $0.transcript : nil })
                    ?? ClaudeProjects.transcript(sessionName: record.sessionName, cwd: record.cwd, projects: home.projects)
            else { continue }
            var reader = readers[transcript].flatMap { $0.file.url == transcript.url && $0.sessionName == record.sessionName ? $0 : nil }
                ?? ClaudeTranscriptReader(file: transcript, sessionName: record.sessionName)
            let read: ClaudeTranscriptRead
            do { read = try reader.read() }
            catch is CancellationError { throw CancellationError() }
            catch { partial = true; continue }
            nextReaders[transcript] = reader
            if read.needsCatchup { fileChanged(transcript) }
            let value = observed(id, connection: old?.connection ?? UUID(), record: record, read: read, sole: ownerSet.count == 1)
            let fresh: Bool
            if old == nil, scanComplete, !read.needsCatchup, let previousScanAt, let activity = read.lastActivityAt {
                let age = wallNow().timeIntervalSince(activity)
                fresh = activity > previousScanAt && age >= 0 && age <= Budget.freshDiscovery
            } else { fresh = false }
            let baseline = !fresh && (old == nil || read.baseline || old?.snapshot.hasConfirmedActivity != true)
            if old?.snapshot != value { continuation?.yield(.snapshot(value, baseline: baseline)) }
            tracked[id] = .init(owners: ownerSet, transcript: transcript, registryFiles: Set(list.map(\.record.file)),
                                connection: value.observation.connectionID, record: record, snapshot: value)
        }
        // Keep readers of bindings that this scan could not confirm, so recovery is incremental.
        for value in tracked.values where nextReaders[value.transcript] == nil {
            nextReaders[value.transcript] = readers[value.transcript]
        }
        readers = nextReaders
    }

    private func observed(_ id: UUID, connection: UUID, record: ClaudeRegistryRecord, read: ClaudeTranscriptRead,
                          sole: Bool) -> SessionSnapshot {
        let content = read.content
        var phase = content.phase
        var activity = read.lastActivityAt
        // Claude records a permission or input wait only in its process record until it resolves.
        if !read.needsCatchup, record.status == "waiting" {
            phase = record.waitingFor?.lowercased().contains("permission") == true ? .approval
                : .question(turnID: content.turn ?? "", requestID: "", itemID: "", questionIDs: [], purpose: .unknown)
            if let at = record.statusUpdatedAt { activity = max(activity ?? at, at) }
        }
        let folder = record.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        // The registry proves a live owner, not an original-client connection, so liveness stays unverified.
        let value = SessionSnapshot(
            observation: .init(sessionID: id, connectionID: connection, liveness: .unverified, phase: phase),
            project: folder.isEmpty ? "Project" : folder, publicConclusion: content.conclusion,
            outcome: content.outcome, turnID: content.turn,
            inputActivityID: content.inputActivityID, activityConfirmed: true, lastActivityAt: activity,
            localPreview: content.localPreview, provider: .claude)
        // Several live owners, or an uninspected major version, stay observation-only with unknown state.
        let supported = record.version.map(ClaudeTranscriptReader.supportsVersion) ?? true
        return sole && supported ? value : value.degraded(liveness: .unverified, phase: .unknown)
    }

    /// Appends to a confirmed binding need only its transcript; anything else waits for a registry scan.
    private func readChangedFiles() {
        readingChanges = nil
        let files = changedFiles; changedFiles.removeAll()
        guard !closed, continuation != nil else { return }
        var unmatched = files
        for (id, old) in tracked where files.contains(old.transcript) {
            unmatched.remove(old.transcript)
            guard old.snapshot.hasConfirmedActivity, let owner = old.sole, processes.presence(of: owner) == .same,
                  var reader = readers[old.transcript], let read = try? reader.read() else { refreshSoon(); continue }
            readers[old.transcript] = reader
            if read.needsCatchup { fileChanged(old.transcript) }
            let value = observed(id, connection: old.connection, record: old.record, read: read, sole: true)
            guard value != old.snapshot else { continue }
            continuation?.yield(.snapshot(value, baseline: read.baseline))
            tracked[id]?.snapshot = value
        }
        if !unmatched.isEmpty { refreshSoon() }
    }
    private func fileChanged(_ file: ClaudeTranscriptFile) {
        guard !closed else { return }
        changedFiles.insert(file)
        guard readingChanges == nil else { return }
        readingChanges = Task { [weak self] in
            do { try await Task.sleep(for: Budget.changeCoalescing) } catch { return }
            await self?.readChangedFiles()
        }
    }
    private func unconfirm(_ id: UUID) {
        guard var old = tracked[id], old.snapshot.activityConfirmed || old.snapshot.observation.phase != .unknown else { return }
        old.snapshot = old.snapshot.degraded(liveness: .unverified, phase: .unknown)
        tracked[id] = old; continuation?.yield(.snapshot(old.snapshot, baseline: true))
    }
    private func availability(_ connected: Bool, partial: Bool) {
        let value = Availability(connected: connected, partial: partial)
        guard lastAvailability != value else { return }
        lastAvailability = value
        continuation?.yield(.availability(connected: connected, partial: partial))
        if !connected {
            DiagnosticLog.record(.sessionObservation, component: .claude, outcome: .unavailable, operation: .init(), reason: .unknown)
        }
    }
    private func refreshSoon() {
        guard !closed, coalescing == nil else { return }
        // Event-driven registry scans are bounded to about one per second.
        let delay = max(Budget.changeCoalescing, lastScanStarted.map { $0 + Budget.eventScanInterval - .now } ?? .zero)
        coalescing = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.flushRefresh()
        }
    }
    private func flushRefresh() { coalescing = nil; refresh() }

    /// A transcript watch is keyed by file identity, so a replaced file at the same path is watched anew.
    private enum WatchTarget: Hashable {
        case transcript(ClaudeTranscriptFile, path: URL)
        case registry(URL)
        var url: URL { switch self { case .transcript(_, let path): path; case .registry(let url): url } }
        var transcript: ClaudeTranscriptFile? { if case .transcript(let file, _) = self { return file }; return nil }
    }

    /// Transcripts are appended and closed between writes, so path-level vnode events are watched;
    /// the session directory, process records and owning processes trigger registry scans.
    private func reconcileWatches() {
        guard watchingFiles else { return }
        var targets: Set<WatchTarget> = [.registry(home.sessions)]
        for value in tracked.values {
            targets.insert(.transcript(value.transcript, path: value.transcript.url))
            for file in value.registryFiles { targets.insert(.registry(file)) }
        }
        let owners = Set(tracked.values.flatMap(\.owners))
        for key in Array(fileWatches.keys) where !targets.contains(key) { fileWatches.removeValue(forKey: key)?.cancel() }
        for key in Array(exitWatches.keys) where !owners.contains(key) { exitWatches.removeValue(forKey: key)?.cancel() }
        for target in targets where fileWatches[target] == nil {
            let fd = open(target.url.path, O_EVTONLY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename, .revoke], queue: eventQueue)
            cleanup.enter()
            source.setEventHandler { [weak self, weak source] in
                let structural = source.map { !$0.data.isDisjoint(with: [.delete, .rename, .revoke]) } ?? true
                Task { await self?.watched(target, structural: structural) }
            }
            source.setCancelHandler { [cleanup] in close(fd); cleanup.leave() }
            fileWatches[target] = source; source.resume()
        }
        for process in owners where exitWatches[process] == nil {
            let source = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: .exit, queue: eventQueue)
            cleanup.enter()
            source.setEventHandler { [weak self] in Task { await self?.refreshSoon() } }
            source.setCancelHandler { [cleanup] in cleanup.leave() }
            exitWatches[process] = source; source.resume()
        }
    }
    /// A replaced or removed file is unwatched so the next scan watches its successor.
    private func watched(_ target: WatchTarget, structural: Bool) {
        guard !closed else { return }
        if structural { fileWatches.removeValue(forKey: target)?.cancel(); refreshSoon() }
        else if let transcript = target.transcript { fileChanged(transcript) } else { refreshSoon() }
    }

    public func shutdown() async {
        if let closing { await closing.value; return }
        closed = true
        running?.cancel(); coalescing?.cancel(); readingChanges?.cancel()
        for watch in fileWatches.values { watch.cancel() }
        for watch in exitWatches.values { watch.cancel() }
        fileWatches.removeAll(); exitWatches.removeAll(); readers.removeAll(); tracked.removeAll()
        let pending = running, stream = continuation, cleanup = cleanup
        let task = Task {
            await withCheckedContinuation { done in cleanup.notify(queue: .global()) { done.resume() } }
            stream?.finish()
            await pending?.value
            DiagnosticLog.record(.sessionObservation, component: .claude, outcome: .stopped, operation: .init())
        }
        closing = task
        await task.value
        continuation = nil; running = nil; coalescing = nil; readingChanges = nil; changedFiles.removeAll()
    }
}
