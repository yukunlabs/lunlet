// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.01, AC-33.02, AC-33.03, AC-33.05, AC-33.06, AC-33.07; US-38, AC-38.02, AC-38.03.
// Refs: US-02, AC-02.05, AC-02.06; US-13, AC-13.01, AC-13.04; US-15, AC-15.05, AC-15.06; US-12, AC-12.04; US-25, AC-25.01.
// Refs: US-14, AC-14.01.
import Darwin
import Foundation
import LunletCore
import LunletHook

/// Read-only Claude Code observation through Claude's own per-process records and transcripts.
/// It installs no hooks, changes no settings, contacts no sockets and never issues remote controls.
public actor ClaudeSessionMonitor: ClaudeSessionObserving {
    private struct Owner { let process: ClaudeProcessIdentity; let record: ClaudeRegistryRecord }
    private struct Tracked {
        let owners: Set<ClaudeProcessIdentity>
        let transcript: ClaudeTranscriptFile
        let registryFiles: Set<URL>
        let connection: UUID
        let record: ClaudeRegistryRecord
        /// The latest transcript content, for the continuation count a hook completion is keyed by.
        var content: ClaudeTranscriptContent?
        var snapshot: SessionSnapshot
        var sole: ClaudeProcessIdentity? { owners.count == 1 ? owners.first : nil }
    }
    /// A finished turn the hook helper keeps open for one phone reply (AC-38.02).
    private struct Hold { let stopID: UUID; let hookPID: Int32; let turn: String; let since: Date }
    /// The latest completion the hook reported for a session, until the transcript records it too.
    private struct HookCompletion { let turn: String; let base: String?; let continuations: Int; let conclusion: String? }
    private struct Availability: Equatable { let connected: Bool; let partial: Bool }
    private enum Budget {
        static let poll: Duration = .seconds(5)
        static let reads: Duration = .seconds(3)
        static let sessions = 256
        static let freshDiscovery: TimeInterval = 10
        static let changeCoalescing: Duration = .milliseconds(100)
        static let eventScanInterval: Duration = .seconds(1)
        static let handledStops = 4_096
        static let sweepInterval: TimeInterval = 30
    }
    /// Blocking process and file inspection stays off the shared cooperative pool.
    private nonisolated let executor = DispatchSerialQueue(label: "com.lunlet.claude.sessions", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let home: ClaudeHome
    private let registry: any ClaudeRegistryReading
    private let processes: any ClaudeProcessInspecting
    private let hooks: HookSpool
    private let hookConnected: @Sendable () -> Bool
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
    private var holds: [UUID: Hold] = [:]
    private var stopsRecheck: Task<Void, Never>?
    private var handledStops: Set<UUID> = []
    /// The same stops, oldest first, so the bound forgets the oldest.
    private var handledOrder: [UUID] = []
    private var lastSweepAt: Date?
    private var hookSeen: Set<UUID> = []
    private var hookCompletions: [UUID: HookCompletion] = [:]
    /// The latest turn of each session that was published as completed or held; a later stop of the same turn
    /// completes nothing new and is not held again.
    private var settledTurns: [UUID: String] = [:]
    private var replyWindow = false
    private var hookConnectedNow = false
    private var closed = false
    private var closing: Task<Void, Never>?

    public init(home: ClaudeHome = .current()) {
        let spool = HookSpool.standard()
        // Asked on every scan; the settings are read again only when the file changed.
        let hookState = ClaudeHookStateCache(ClaudeHookConnection(home: home, spool: spool))
        self.init(home: home, registry: ClaudeSessionRegistry(directory: home.sessions), processes: ClaudeProcessReader(),
                  watchingFiles: true, hooks: spool, hookConnected: { hookState.isConnected() })
    }
    init(home: ClaudeHome, registry: any ClaudeRegistryReading, processes: any ClaudeProcessInspecting,
         watchingFiles: Bool = false, eventQueue: DispatchQueue = .global(qos: .utility),
         wallNow: @escaping @Sendable () -> Date = { Date() }, hooks: HookSpool? = nil,
         hookConnected: @escaping @Sendable () -> Bool = { false }) {
        self.home = home; self.registry = registry; self.processes = processes
        self.hooks = hooks ?? HookSpool(root: home.root.appendingPathComponent("lunlet-hook-unused", isDirectory: true))
        self.hookConnected = hookConnected
        self.watchingFiles = watchingFiles; self.eventQueue = eventQueue; self.wallNow = wallNow
    }

    /// Opening the window lets the hook hold each finished turn for one reply; closing it releases every hold.
    public func setReplyWindow(_ open: Bool) async {
        guard !closed, replyWindow != open else { return }
        replyWindow = open
        if open { scanStops() } else { releaseAllHolds() }
    }

    /// The exact live session for a reply to `completedTurnID`: its sole owner still runs, its transcript is the
    /// same file, the completed turn is still the latest, and the hook helper holding it is that owner's running child.
    public func continuationBinding(sessionID: UUID, connectionID: UUID, completedTurnID: String) async -> ClaudeBindingResult {
        guard !closed, let value = tracked[sessionID], value.snapshot.hasConfirmedActivity else { return .refused(.sessionEnded) }
        guard value.connection == connectionID else { return .refused(.sessionEnded) }
        guard let owner = value.sole, processes.presence(of: owner) == .same else { return .refused(.sessionEnded) }
        switch value.snapshot.observation.phase {
        case .idle(let completed) where completed == completedTurnID: break
        case .idle, .question: return .refused(.superseded)
        case .running: return .refused(.sessionRunning)
        case .approval: return .refused(.awaitingApproval)
        case .ended: return .refused(.sessionEnded)
        case .unknown: return .refused(.unverified)
        }
        guard ClaudeProjects.regularFile(value.transcript.url) == value.transcript,
              let hold = holds[sessionID], hold.turn == completedTurnID, processes.parent(of: hold.hookPID) == owner.pid
        else { return .refused(.unverified) }
        return .bound(.init(sessionID: sessionID, connectionID: connectionID, completedTurnID: completedTurnID,
                            process: owner, transcript: value.transcript, stopID: hold.stopID))
    }


    public func updates() -> AsyncStream<SessionUpdate> {
        guard !closed, continuation == nil else { return AsyncStream { $0.finish() } }
        let pair = AsyncStream<SessionUpdate>.makeStream(bufferingPolicy: .unbounded)
        continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.shutdown() } }
        DiagnosticLog.record(.sessionObservation, component: .claude, outcome: .started, operation: .init())
        announceToHooks()
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
            // A scan was attempted, so no helper waits out its verdict timeout on this failure.
            scanStops(afterScan: true)
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
        hookConnectedNow = hookConnected()
        try apply(owners, scanComplete: !uncertain, partial: &partial)
        scanStops(afterScan: true)
        sweepStops(now: scanAt)
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
                // An ended session's hook history goes with it.
                hookSeen.remove(id); hookCompletions[id] = nil; settledTurns[id] = nil
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
                                connection: value.observation.connectionID, record: record, content: read.content, snapshot: value)
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
        var conclusion = content.conclusion
        var activity = read.lastActivityAt
        // A completion the hook reported stands until the transcript records that turn end itself.
        if let completion = hookCompletions[id] {
            let same = completion.base == content.turn && completion.continuations == content.continuations
            if same, case .idle = content.phase { hookCompletions[id] = nil }
            else if same { phase = .idle(completedTurnID: completion.turn); conclusion = completion.conclusion }
            else { hookCompletions[id] = nil }
        }
        // Claude records a permission or input wait only in its process record until it resolves.
        if !read.needsCatchup, record.status == "waiting" {
            phase = record.waitingFor?.lowercased().contains("permission") == true ? .approval
                : .question(turnID: content.turn ?? "", requestID: "", itemID: "", questionIDs: [], purpose: .unknown)
            if let at = record.statusUpdatedAt { activity = max(activity ?? at, at) }
        }
        let folder = record.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        // The registry proves a live owner, not an original-client connection, so liveness stays unverified
        // unless Lunlet's hook holds the finished turn open from inside that owner, which proves the live CLI (AC-38.02).
        let holding = sole && holds[id] != nil
        let note: String? = holding ? nil
            : !sole ? "Several processes own this session"
            : hookSeen.contains(id) ? "Takes phone replies while the Mac is locked"
            : hookConnectedNow ? "Takes phone replies after its next turn ends" : "Lunlet's Claude Code hook is not connected"
        let value = SessionSnapshot(
            observation: .init(sessionID: id, connectionID: connection, liveness: holding ? .alive : .unverified, phase: phase),
            project: folder.isEmpty ? "Project" : folder, publicConclusion: conclusion,
            outcome: content.outcome, turnID: content.turn,
            inputActivityID: content.inputActivityID, activityConfirmed: true, lastActivityAt: activity,
            localPreview: content.localPreview, provider: .claude,
            inputPath: holding ? .claudeHook : nil, inputPathNote: note)
        // Several live owners, or an uninspected major version, stay observation-only with unknown state.
        let supported = record.version.map(ClaudeTranscriptReader.supportsVersion) ?? true
        let result = sole && supported ? value : value.degraded(liveness: .unverified, phase: .unknown)
        if case .idle(let completed) = result.observation.phase { settledTurns[id] = completed }
        return result
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
            tracked[id]?.content = read.content
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
        /// Lunlet's own stop folder, where the hook helper announces each finished turn.
        case stops(URL)
        var url: URL { switch self { case .transcript(_, let path): path; case .registry(let url): url; case .stops(let url): url } }
        var transcript: ClaudeTranscriptFile? { if case .transcript(let file, _) = self { return file }; return nil }
        var isStops: Bool { if case .stops = self { return true }; return false }
    }

    /// Transcripts are appended and closed between writes, so path-level vnode events are watched;
    /// the session directory, process records and owning processes trigger registry scans.
    private func reconcileWatches() {
        guard watchingFiles else { return }
        var targets: Set<WatchTarget> = [.registry(home.sessions), .stops(hooks.stopsDirectory)]
        for (id, value) in tracked {
            targets.insert(.transcript(value.transcript, path: value.transcript.url))
            for file in value.registryFiles { targets.insert(.registry(file)) }
            if ClaudeProjects.isDirectory(hooks.stopDirectory(id)) { targets.insert(.stops(hooks.stopDirectory(id))) }
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
        if target.isStops {
            if structural { fileWatches.removeValue(forKey: target)?.cancel() }
            stopsChanged(); return
        }
        if structural { fileWatches.removeValue(forKey: target)?.cancel(); refreshSoon() }
        else if let transcript = target.transcript { fileChanged(transcript) } else { refreshSoon() }
    }

    // MARK: Stop hook

    /// A stop folder event: the helper makes the session's folder and then writes its signal, so the signal may
    /// land after the folder's own event; a short recheck and a watch on the new folder catch it within milliseconds.
    private func stopsChanged() {
        guard !closed else { return }
        scanStops()
        reconcileWatches()
        stopsRecheck?.cancel()
        stopsRecheck = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            await self?.scanStops()
        }
    }

    /// The app record the hook helper checks before it writes anything, with this process's start time so a later
    /// process with the same pid is not taken for it; removed at shutdown. Only this monitor writes it.
    private func announceToHooks() {
        try? HookSpool.createPrivateDirectory(hooks.stopsDirectory)
        let started = HookProcess.startTime(of: getpid()) ?? wallNow()
        if let encoded = try? HookSpool.encoder.encode(HookSpool.AppRecord(pid: getpid(), startedAt: started)) {
            try? HookSpool.writeAtomically(encoded, to: hooks.appRecordURL)
        }
    }

    /// Reads every new stop signal of a tracked session: a signal from that session's own child process is a
    /// completion, held for one phone reply while the window is open and released otherwise; anything else is
    /// released at once. Holds end when the window closes, the helper exits or the window's length passes.
    /// `afterScan` is true when a registry scan has just run, so a session still untracked will not appear by waiting.
    private func scanStops(afterScan: Bool = false) {
        guard !closed else { return }
        defer { answerUntrackedStops(afterScan: afterScan) }
        let now = wallNow()
        for (id, hold) in holds {
            if processes.parent(of: hold.hookPID) == nil {
                // The helper is gone without removing its files, which hold the reply text: the app removes them
                // instead of answering a process that no longer reads.
                holds[id] = nil
                for suffix in [HookSpool.signalSuffix, HookSpool.holdSuffix, HookSpool.releaseSuffix] {
                    try? FileManager.default.removeItem(at: hooks.file(id, stop: hold.stopID, suffix: suffix))
                }
                republish(id)
            } else if now.timeIntervalSince(hold.since) > 600 { release(id, hold) }
        }
        for (id, value) in tracked {
            let directory = hooks.stopDirectory(id)
            for url in HookSpool.files(in: directory, suffix: HookSpool.signalSuffix) {
                guard let stopID = HookSpool.stopID(of: url, suffix: HookSpool.signalSuffix), !handledStops.contains(stopID) else { continue }
                markHandled(stopID)
                guard let data = try? HookSpool.readSmall(url),
                      let signal = try? HookSpool.decoder.decode(HookSpool.StopSignal.self, from: data),
                      signal.version == HookSpool.formatVersion, signal.stopID == stopID, signal.sessionID == id,
                      let owner = value.sole, processes.presence(of: owner) == .same, processes.parent(of: signal.pid) == owner.pid
                else { writeVerdict(id, stopID, HookSpool.releaseSuffix); logVerdict(held: false, code: 1); continue }
                // Only an interactive session is ever held, so only it is said to take phone replies.
                if value.record.isInteractive { hookSeen.insert(id) }
                if let previous = holds[id] { release(id, previous) }
                let base = signal.promptID ?? value.content?.turn
                let continuations = value.content?.continuations ?? 0
                let turn = ClaudeTurnID.compose(base ?? stopID.uuidString.lowercased(), continuations: continuations)
                let text = signal.lastAssistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                // A stop for another turn than the transcript's, such as one an injected prompt started, completes
                // nothing; the completion already reported for the transcript's turn stands.
                let namesTranscriptTurn = base == value.content?.turn
                if namesTranscriptTurn {
                    hookCompletions[id] = .init(turn: turn, base: base, continuations: continuations, conclusion: text.isEmpty ? nil : text)
                }
                // A hold waits for a reply to this stop's completion notice. A stop that completes nothing new (another
                // turn than the transcript's, or a turn already completed or held) gets no notice, and a run that is
                // not interactive has nobody to reply, so both are released at once (AC-38.02, AC-38.07).
                if replyWindow, value.record.isInteractive, namesTranscriptTurn, settledTurns[id] != turn {
                    holds[id] = .init(stopID: stopID, hookPID: signal.pid, turn: turn, since: now)
                    settledTurns[id] = turn
                    writeVerdict(id, stopID, HookSpool.holdSuffix)
                    logVerdict(held: true, code: nil)
                } else {
                    writeVerdict(id, stopID, HookSpool.releaseSuffix)
                    logVerdict(held: false, code: !replyWindow ? 2 : !value.record.isInteractive ? 3 : !namesTranscriptTurn ? 4 : 5)
                }
                republish(id)
            }
        }
    }
    /// Logs the verdict on one stop: held, or released with the number of the check that released it and nothing
    /// of the session (AC-14.01): 1 the signal does not come from the session's own verified process, 2 the reply
    /// window is closed, 3 the session is not interactive, 4 the stop names another turn than the transcript's,
    /// 5 the turn was already completed or held, 6 the session is not tracked.
    private func logVerdict(held: Bool, code: Int?) {
        DiagnosticLog.record(.stopVerdict, component: .claude, outcome: held ? .completed : .rejected,
                             operation: DiagnosticOperation(), code: code)
    }

    /// Remembers an answered stop so it is never answered twice. Past the bound the oldest are forgotten first, and
    /// never a stop that is still held: forgetting that one would read its signal again and end its hold.
    private func markHandled(_ stopID: UUID) {
        guard handledStops.insert(stopID).inserted else { return }
        handledOrder.append(stopID)
        guard handledOrder.count > Budget.handledStops else { return }
        let held = Set(holds.values.map(\.stopID))
        var excess = handledOrder.count - Budget.handledStops / 2
        handledOrder.removeAll { id in
            guard excess > 0, !held.contains(id) else { return false }
            excess -= 1; handledStops.remove(id)
            return true
        }
    }
    /// The helper waits up to three seconds for a verdict, so the stops of sessions this monitor does not track (an
    /// unverified owner, no transcript, over a budget, no registry record) are released too. One scan may still
    /// discover the session, so a signal is released only once a scan has looked: the one that just ran, one that
    /// started within the last second, or one requested here.
    private func answerUntrackedStops(afterScan: Bool) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: hooks.stopsDirectory.path)) ?? []
        let looked = afterScan || lastScanStarted.map { ContinuousClock.now - $0 < Budget.eventScanInterval } ?? false
        var waiting = false
        for name in names {
            guard let id = UUID(uuidString: name), tracked[id] == nil else { continue }
            for url in HookSpool.files(in: hooks.stopDirectory(id), suffix: HookSpool.signalSuffix) {
                guard let stopID = HookSpool.stopID(of: url, suffix: HookSpool.signalSuffix), !handledStops.contains(stopID) else { continue }
                guard looked else { waiting = true; continue }
                markHandled(stopID)
                writeVerdict(id, stopID, HookSpool.releaseSuffix)
                logVerdict(held: false, code: 6)
            }
        }
        // The scan ends by answering whatever is still untracked.
        if waiting { refresh() }
    }
    private func releaseAllHolds() {
        for (id, hold) in holds { release(id, hold) }
    }
    private func release(_ id: UUID, _ hold: Hold) {
        holds[id] = nil
        writeVerdict(id, hold.stopID, HookSpool.releaseSuffix)
        republish(id)
    }
    private func writeVerdict(_ id: UUID, _ stopID: UUID, _ suffix: String) {
        // A helper removes its signal as it exits; a verdict written after that would never be read or removed.
        guard FileManager.default.fileExists(atPath: hooks.file(id, stop: stopID, suffix: HookSpool.signalSuffix).path) else { return }
        try? HookSpool.writeAtomically(Data("{}\n".utf8), to: hooks.file(id, stop: stopID, suffix: suffix))
    }
    /// What gone helpers left is swept while the monitor runs, about twice a minute; the folders of observed
    /// sessions stay, since they are watched for the next stop.
    private func sweepStops(now: Date) {
        guard lastSweepAt.map({ now.timeIntervalSince($0) >= Budget.sweepInterval }) ?? true else { return }
        lastSweepAt = now
        ClaudeHookInstallation.sweepStale(spool: hooks, isProcessAlive: { processes.parent(of: $0) != nil },
                                          keeping: Set(tracked.keys), now: now)
    }
    /// Re-derives a tracked session's snapshot after a hook event; only a changed snapshot is yielded.
    private func republish(_ id: UUID) {
        guard let old = tracked[id] else { return }
        let read = ClaudeTranscriptRead(content: old.content ?? ClaudeTranscriptContent(), baseline: false, needsCatchup: false,
                                        lastActivityAt: old.snapshot.lastActivityAt)
        let value = observed(id, connection: old.connection, record: old.record, read: read, sole: old.sole != nil)
        guard value != old.snapshot else { return }
        tracked[id]?.snapshot = value
        continuation?.yield(.snapshot(value, baseline: false))
    }

    public func shutdown() async {
        if let closing { await closing.value; return }
        for (id, hold) in holds { holds[id] = nil; writeVerdict(id, hold.stopID, HookSpool.releaseSuffix) }
        try? FileManager.default.removeItem(at: hooks.appRecordURL)
        closed = true
        running?.cancel(); coalescing?.cancel(); readingChanges?.cancel(); stopsRecheck?.cancel()
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
