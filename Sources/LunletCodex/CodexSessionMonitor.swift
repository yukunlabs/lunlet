// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-15, AC-15.06; US-33, AC-33.02.
// Refs: US-02, AC-02.08; US-04, AC-04.11; US-25, AC-25.01.
// Refs: US-02, AC-02.01, AC-02.02, AC-02.04, AC-02.05, AC-02.06; US-11, AC-11.03, AC-11.04, AC-11.05, AC-11.06.
// Refs: US-03, AC-03.01, AC-03.02, AC-03.03; US-15, AC-15.02, AC-15.05; US-13, AC-13.01, AC-13.04; US-12, AC-12.04; US-14, AC-14.01, AC-14.03.
// Refs: US-08, AC-08.01, AC-08.03; US-09, AC-09.03; US-10, AC-10.04.
import Darwin
import Foundation
import LunletCore

/// Codex adds original-destination navigation to the provider-neutral observation stream.
public protocol CodexSessionObserving: SessionObserving {
    func destination(sessionID: UUID, connectionID: UUID) async -> CodexTerminalDestination?
    /// A freshly rechecked binding of the exact live CLI for a reply to `completedTurnID`.
    func continuationBinding(sessionID: UUID, connectionID: UUID, completedTurnID: String) async -> CodexBindingResult
}
public extension CodexSessionObserving {
    /// Sources without a verified original-CLI input path never continue a session.
    func continuationBinding(sessionID: UUID, connectionID: UUID, completedTurnID: String) async -> CodexBindingResult {
        .refused(.unverified)
    }
}

/// Owns local observation only; remote controls are never issued from this stream.
public actor CodexSessionMonitor: CodexSessionObserving {
    /// How an original destination can be proven before navigation is offered.
    private enum NavigationProof {
        /// One terminal-attached record: the terminal itself identifies the destination.
        case direct
        /// A terminal process holding several records also needs the host's session binding.
        case sessionBinding
        case none
    }
    private struct Discovery {
        let process: CodexProcessIdentity
        let file: CodexRolloutFile
        let read: CodexSessionRead
        /// Readable, uniquely owned evidence; only eligible discoveries become bindings.
        let eligible: Bool
        let role: CodexProcessRole
        let proof: NavigationProof
    }
    /// Navigation resolved for an unchanged process and record; it is revalidated on reveal.
    private struct ResolvedNavigation { let value: SessionNavigation? }
    private struct Tracked {
        let process: CodexProcessIdentity
        let role: CodexProcessRole
        let file: CodexRolloutFile
        let connection: UUID
        let proof: NavigationProof
        var snapshot: SessionSnapshot
        /// Nil until final; an unmatched session binding is retried because hosts write it late.
        var navigation: ResolvedNavigation?
    }
    private struct Availability: Equatable {
        let connected: Bool
        let partial: Bool
    }
    private enum Budget {
        static let poll: Duration = .seconds(5)
        static let reads: Duration = .seconds(3)
        static let inspectedFiles = 256
        static let bindingRecords = 64
        static let navigation: Duration = .seconds(1)
        static let freshDiscovery: TimeInterval = 10
        static let changeCoalescing: Duration = .milliseconds(100)
        static let eventScanInterval: Duration = .seconds(1)
    }
    /// Blocking process and file inspection stays off the shared cooperative pool.
    private nonisolated let executor = DispatchSerialQueue(label: "com.lunlet.codex.sessions", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let accounting: CodexAccountingCatalog?
    private let processes: any CodexProcessInspecting
    private let resolveDestination: @Sendable (CodexProcessIdentity) -> CodexTerminalDestination?
    private let matchesSessionDestination: @Sendable (UUID, CodexTerminalDestination) -> Bool
    private let wallNow: @Sendable () -> Date
    private var previousScanAt: Date?
    private var lastScanStarted: ContinuousClock.Instant?
    private let watchingFiles: Bool
    private let eventQueue: DispatchQueue
    private var continuation: AsyncStream<SessionUpdate>.Continuation?
    private var running: Task<Void, Never>?
    private var coalescing: Task<Void, Never>?
    private var changedFiles: Set<CodexRolloutFile> = []
    private var readingChanges: Task<Void, Never>?
    private var readers: [CodexRolloutFile: CodexSessionReader] = [:]
    private var tracked: [UUID: Tracked] = [:]
    private var fileWatches: [CodexRolloutFile: DispatchSourceFileSystemObject] = [:]
    private var exitWatches: [CodexProcessIdentity: DispatchSourceProcess] = [:]
    private let cleanup = DispatchGroup()
    private var lastAvailability: Availability?
    private var closed = false
    private var closing: Task<Void, Never>?

    public init(accounting: CodexAccountingCatalog? = nil) {
        self.init(processes: CodexProcessReader(), accounting: accounting, watchingFiles: true,
                  resolveDestination: { CodexDestinationReader().read(process: $0) },
                  matchesSessionDestination: { SupersetSessionBindingReader().matches(sessionID: $0, destination: $1) })
    }
    init(processes: any CodexProcessInspecting, accounting: CodexAccountingCatalog? = nil, watchingFiles: Bool = false,
         eventQueue: DispatchQueue = .global(qos: .utility),
         resolveDestination: @escaping @Sendable (CodexProcessIdentity) -> CodexTerminalDestination? = { _ in nil },
         matchesSessionDestination: @escaping @Sendable (UUID, CodexTerminalDestination) -> Bool = { _, _ in false },
         wallNow: @escaping @Sendable () -> Date = { Date() }) {
        self.accounting = accounting
        self.resolveDestination = resolveDestination
        self.matchesSessionDestination = matchesSessionDestination
        self.wallNow = wallNow
        self.processes = processes; self.watchingFiles = watchingFiles; self.eventQueue = eventQueue
    }
    public func updates() -> AsyncStream<SessionUpdate> {
        guard !closed, continuation == nil else { return AsyncStream { $0.finish() } }
        let pair = AsyncStream<SessionUpdate>.makeStream(bufferingPolicy: .unbounded)
        continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.shutdown() } }
        DiagnosticLog.record(.sessionObservation, component: .codex, outcome: .started, operation: .init())
        // Background polling never inherits the caller's interactive priority, and it
        // stops once the monitor is released even without an explicit shutdown.
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
        // A cancelled caller is not an observation outage; the next scan resumes as before.
        catch is CancellationError { return }
        catch {
            previousScanAt = nil
            for id in Array(tracked.keys) { unconfirm(id) }
            availability(false, partial: true)
        }
    }
    public func reconcile() async {
        refresh()
        // The stream delivers every refreshed snapshot before this boundary.
        continuation?.yield(.reconciled(currentConnections(activityOnly: true)))
    }
    func activeConnections() -> [UUID: UUID] { currentConnections() }
    private func currentConnections(activityOnly: Bool = false) -> [UUID: UUID] {
        guard !closed, lastAvailability?.connected == true else { return [:] }
        return Dictionary(uniqueKeysWithValues: tracked.compactMap { id, value in
            guard (activityOnly ? value.snapshot.hasConfirmedActivity : value.snapshot.observation.liveness == .alive),
                  processes.presence(of: value.process) == .same else { return nil }
            return (id, value.connection)
        })
    }

    public func destination(sessionID: UUID, connectionID: UUID) async -> CodexTerminalDestination? {
        guard !closed else { return nil }
        refresh()
        guard let current = tracked[sessionID], current.connection == connectionID,
              current.snapshot.navigationAvailable, current.snapshot.hasConfirmedActivity,
              processes.presence(of: current.process) == .same else { return nil }
        guard let destination = resolveDestination(current.process),
              current.proof != .sessionBinding || matchesSessionDestination(sessionID, destination),
              processes.presence(of: current.process) == .same else { return nil }
        return destination
    }

    /// Rescans first, then requires the same binding (connection, PID and start time, record), a
    /// terminal-attached interactive CLI that owns only this record, and an idle phase whose latest
    /// completed turn is the card's turn. Running, approval, ended and unverified states refuse.
    public func continuationBinding(sessionID: UUID, connectionID: UUID, completedTurnID: String) async -> CodexBindingResult {
        let operation = DiagnosticOperation()
        // A refusal logs the failed check by number: 1 observation, 2 process, 3 liveness, 4 phase, 5 image.
        func refuse(_ reason: ContinuationRefusal, _ detail: DiagnosticReason, check: Int) -> CodexBindingResult {
            DiagnosticLog.record(.sessionBinding, component: .codex, outcome: .rejected, operation: operation,
                                 reason: detail, code: check)
            return .refused(reason)
        }
        guard !closed, !completedTurnID.isEmpty else { return refuse(.unverified, .invalidInput, check: 1) }
        refresh()
        guard lastAvailability?.connected == true else { return refuse(.unverified, .unverified, check: 1) }
        // An exited process is retired by the scan; a restored session receives a new connection.
        guard let current = tracked[sessionID], current.connection == connectionID,
              processes.presence(of: current.process) == .same else { return refuse(.sessionEnded, .ended, check: 2) }
        let snapshot = current.snapshot
        guard current.role == .terminalCLI, snapshot.observation.liveness == .alive,
              snapshot.hasConfirmedActivity else { return refuse(.unverified, .unverified, check: 3) }
        switch snapshot.observation.phase {
        case .idle(let turn) where turn == completedTurnID && !snapshot.inputPending: break
        case .idle, .question: return refuse(.superseded, .state, check: 4)
        case .running: return refuse(.sessionRunning, .state, check: 4)
        case .approval: return refuse(.awaitingApproval, .state, check: 4)
        case .ended: return refuse(.sessionEnded, .ended, check: 4)
        // Input recorded without a started turn is new work, not an idle session.
        case .unknown where snapshot.inputPending: return refuse(.sessionRunning, .state, check: 4)
        case .unknown: return refuse(.unverified, .unverified, check: 4)
        }
        guard let executable = processes.executable(of: current.process),
              let home = CodexProcessReader.accountingRoot(for: current.file.url),
              processes.presence(of: current.process) == .same else { return refuse(.unverified, .image, check: 5) }
        DiagnosticLog.record(.sessionBinding, component: .codex, outcome: .completed, operation: operation)
        return .bound(CodexContinuationBinding(sessionID: sessionID, connectionID: connectionID,
                                               completedTurnID: completedTurnID, process: current.process,
                                               rollout: current.file, executable: executable, codexHome: home))
    }

    private func scan() throws {
        let scanAt = wallNow()
        let scan = try processes.scan()
        accounting?.record(scan.candidates.flatMap(\.files))
        var partial = !scan.complete
        let discoveries = try collectDiscoveries(scan, partial: &partial)
        retireStaleBindings(discoveries, scan: scan)
        apply(discoveries, scanComplete: scan.complete, partial: &partial)
        reconcileWatches()
        previousScanAt = scan.complete ? scanAt : nil
        availability(true, partial: partial || tracked.values.contains { !$0.snapshot.hasConfirmedActivity })
    }

    /// Reads each candidate's writable records within a bounded budget.
    private func collectDiscoveries(_ scan: CodexProcessScan, partial: inout Bool) throws -> [UUID: [Discovery]] {
        var owners: [CodexRolloutFile: Set<CodexProcessIdentity>] = [:]
        for candidate in scan.candidates {
            for file in candidate.files { owners[file, default: []].insert(candidate.process) }
        }
        var discoveries: [UUID: [Discovery]] = [:]
        var nextReaders: [CodexRolloutFile: CodexSessionReader] = [:]
        let deadline = ContinuousClock.now + Budget.reads
        var inspectedFiles = 0
        for candidate in scan.candidates {
            var primary: [(file: CodexRolloutFile, read: CodexSessionRead, isCLI: Bool)] = []
            var uncertain = false
            for file in candidate.files {
                guard inspectedFiles < Budget.inspectedFiles, ContinuousClock.now < deadline else {
                    uncertain = true; partial = true; break
                }
                inspectedFiles += 1
                var reader = readers[file].flatMap { $0.file.isSamePath(as: file) ? $0 : nil } ?? CodexSessionReader(file: file)
                do {
                    let read = try reader.read()
                    nextReaders[file] = reader
                    primary.append((file, read, reader.isCLISource))
                    if read.needsCatchup { fileChanged(file, structural: false) }
                } catch is CancellationError { throw CancellationError() }
                catch { partial = true; uncertain = true }
            }
            // Preserve ambiguous/unreadable ownership evidence through final attribution.
            let unique = !primary.isEmpty && !uncertain
            if !unique { partial = true }
            let terminal = candidate.role == .terminalCLI
            // Current single-record terminal ownership can prove navigation
            // independently of inherited creation labels and input authority.
            let proof: NavigationProof = !terminal ? .none : primary.count == 1 ? .direct
                : primary.count <= Budget.bindingRecords ? .sessionBinding : .none
            for entry in primary {
                let role: CodexProcessRole = terminal && primary.count == 1 && entry.isCLI ? .terminalCLI : .sharedRuntime
                discoveries[entry.read.content.id, default: []].append(.init(
                    process: candidate.process, file: entry.file, read: entry.read,
                    eligible: unique && owners[entry.file]?.count == 1, role: role, proof: proof))
            }
        }
        readers = nextReaders
        return discoveries
    }

    /// Retires exact old process identities before accepting a restored or reused PID.
    private func retireStaleBindings(_ discoveries: [UUID: [Discovery]], scan: CodexProcessScan) {
        for (id, old) in tracked where processes.presence(of: old.process) == .ended {
            let ended = old.snapshot.degraded(liveness: .ended, phase: .ended)
            continuation?.yield(.snapshot(ended, baseline: true)); tracked.removeValue(forKey: id)
        }
        var held: [CodexProcessIdentity: Set<CodexRolloutFile>] = [:]
        for candidate in scan.candidates { held[candidate.process, default: []].formUnion(candidate.files) }
        for id in Array(tracked.keys) {
            guard let old = tracked[id] else { continue }
            if let found = discoveries[id], found.count == 1, found[0].eligible,
               found[0].process == old.process, found[0].file == old.file { continue }
            // A complete scan shows the same live owner without this writable record,
            // such as after a new chat or an unloaded thread: that binding has ended.
            if scan.complete, let files = held[old.process], !files.contains(old.file) {
                let ended = old.snapshot.degraded(liveness: .ended, phase: .ended)
                continuation?.yield(.snapshot(ended, baseline: true)); tracked.removeValue(forKey: id)
                continue
            }
            unconfirm(id)
        }
    }

    /// Accepts unique discoveries as bindings and publishes changed snapshots.
    private func apply(_ discoveries: [UUID: [Discovery]], scanComplete: Bool, partial: inout Bool) {
        let navigationDeadline = ContinuousClock.now + Budget.navigation
        for (id, matches) in discoveries {
            guard matches.count == 1, matches[0].eligible else { partial = true; continue }
            let found = matches[0], read = found.read
            // A still-present old owner cannot be replaced just because another file claims its UUID.
            if let old = tracked[id], old.process != found.process || old.file != found.file { partial = true; continue }
            let old = tracked[id]
            guard processes.presence(of: found.process) == .same else { partial = true; continue }
            // Reuse only while the proof is unchanged, e.g. not after a second record or a shared role.
            let cached = old.flatMap { $0.proof == found.proof ? $0.navigation : nil }
            let navigation = cached ?? resolveNavigation(id, found, before: navigationDeadline)
            let value = observed(id, connection: old?.connection ?? UUID(), role: found.role, read: read,
                                 navigation: navigation.value)
            if let old, old.snapshot.observation.liveness == .alive, value.observation.liveness != .alive { noteUnverified() }
            let freshDiscovery: Bool
            if old == nil, scanComplete, !read.needsCatchup, let previousScanAt, let activity = read.lastActivityAt {
                let age = wallNow().timeIntervalSince(activity)
                freshDiscovery = activity > previousScanAt && age >= 0 && age <= Budget.freshDiscovery
            } else { freshDiscovery = false }
            let baseline = !freshDiscovery && (old == nil || read.baseline || old?.snapshot.hasConfirmedActivity != true)
            if old?.snapshot != value { continuation?.yield(.snapshot(value, baseline: baseline)) }
            let settled = found.proof != .sessionBinding || navigation.value != nil
            tracked[id] = .init(process: found.process, role: found.role, file: found.file,
                                connection: value.observation.connectionID, proof: found.proof, snapshot: value,
                                navigation: settled ? navigation : nil)
        }
    }

    private func resolveNavigation(_ id: UUID, _ found: Discovery,
                                   before deadline: ContinuousClock.Instant) -> ResolvedNavigation {
        guard found.proof != .none, let destination = resolveDestination(found.process) else { return .init(value: nil) }
        guard found.proof == .direct || (ContinuousClock.now < deadline && matchesSessionDestination(id, destination)) else {
            return .init(value: nil)
        }
        return .init(value: .init(applicationName: destination.applicationURL.deletingPathExtension().lastPathComponent))
    }
    private func observed(_ id: UUID, connection: UUID, role: CodexProcessRole, read: CodexSessionRead,
                          navigation: SessionNavigation?) -> SessionSnapshot {
        let content = read.content
        return SessionSnapshot(
            observation: .init(sessionID: id, connectionID: connection,
                               liveness: role == .terminalCLI ? .alive : .unverified, phase: content.phase),
            project: content.project, publicConclusion: content.conclusion, outcome: content.outcome,
            turnID: content.turn, inputActivityID: content.inputActivityID, inputPending: content.inputPending,
            activityConfirmed: role == .sharedRuntime, navigation: navigation, lastActivityAt: read.lastActivityAt,
            localPreview: content.localPreview, parentSessionID: read.parentSessionID)
    }
    /// Appends to a currently confirmed binding need only that record. Ownership
    /// changes, uncertainty and unmatched records still wait for a process scan.
    private func readChangedFiles() {
        readingChanges = nil
        let files = changedFiles; changedFiles.removeAll()
        guard !closed, continuation != nil else { return }
        var unmatched = files
        for (id, old) in tracked where files.contains(old.file) {
            unmatched.remove(old.file)
            guard old.snapshot.hasConfirmedActivity, processes.presence(of: old.process) == .same,
                  var reader = readers[old.file], reader.file.isSamePath(as: old.file),
                  let read = try? reader.read(), read.content.id == id else { refreshSoon(); continue }
            readers[old.file] = reader
            if read.needsCatchup { fileChanged(old.file, structural: false) }
            let value = observed(id, connection: old.connection, role: old.role, read: read, navigation: old.snapshot.navigation)
            guard value != old.snapshot else { continue }
            continuation?.yield(.snapshot(value, baseline: read.baseline))
            tracked[id]?.snapshot = value
        }
        if !unmatched.isEmpty { refreshSoon() }
    }
    private func fileChanged(_ file: CodexRolloutFile, structural: Bool) {
        guard !closed else { return }
        guard !structural else { refreshSoon(); return }
        changedFiles.insert(file)
        guard readingChanges == nil else { return }
        readingChanges = Task { [weak self] in
            do { try await Task.sleep(for: Budget.changeCoalescing) } catch { return }
            await self?.readChangedFiles()
        }
    }
    private func unconfirm(_ id: UUID) {
        guard var old = tracked[id], old.snapshot.observation.liveness != .unverified || old.snapshot.activityConfirmed else { return }
        if old.snapshot.observation.liveness == .alive { noteUnverified() }
        old.snapshot = old.snapshot.degraded(liveness: .unverified, phase: .unknown)
        tracked[id] = old; continuation?.yield(.snapshot(old.snapshot, baseline: true))
    }
    /// A live CLI session could not be re-established from its process, record and sole ownership; the next complete
    /// scan confirms it again. Logged on the transition only, so a flapping process cannot flood the log.
    private func noteUnverified() {
        DiagnosticLog.record(.sessionObservation, component: .codex, outcome: .uncertain, operation: .init(), reason: .unverified)
    }
    private func availability(_ connected: Bool, partial: Bool) {
        let value = Availability(connected: connected, partial: partial)
        guard lastAvailability != value else { return }
        lastAvailability = value
        continuation?.yield(.availability(connected: connected, partial: partial))
        if !connected {
            DiagnosticLog.record(.sessionObservation, component: .codex, outcome: .unavailable,
                                 operation: .init(), reason: .unknown)
        }
    }
    private func refreshSoon() {
        guard !closed, coalescing == nil else { return }
        // Event-driven process scans are bounded to about one per second.
        let delay = max(Budget.changeCoalescing, lastScanStarted.map { $0 + Budget.eventScanInterval - .now } ?? .zero)
        coalescing = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.flushRefresh()
        }
    }
    private func flushRefresh() { coalescing = nil; refresh() }
    private func reconcileWatches() {
        guard watchingFiles else { return }
        let files = Set(tracked.values.map(\.file)), owners = Set(tracked.values.map(\.process))
        for key in Array(fileWatches.keys) where !files.contains(key) { fileWatches.removeValue(forKey: key)?.cancel() }
        for key in Array(exitWatches.keys) where !owners.contains(key) { exitWatches.removeValue(forKey: key)?.cancel() }
        for file in files where fileWatches[file] == nil {
            let fd = open(file.url.path, O_EVTONLY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename, .revoke], queue: eventQueue)
            cleanup.enter()
            source.setEventHandler { [weak self, weak source] in
                let structural = source.map { !$0.data.isDisjoint(with: [.delete, .rename, .revoke]) } ?? true
                Task { await self?.fileChanged(file, structural: structural) }
            }
            source.setCancelHandler { [cleanup] in close(fd); cleanup.leave() }
            fileWatches[file] = source; source.resume()
        }
        for process in owners where exitWatches[process] == nil {
            let source = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: .exit, queue: eventQueue)
            cleanup.enter()
            source.setEventHandler { [weak self] in Task { await self?.refreshSoon() } }
            source.setCancelHandler { [cleanup] in cleanup.leave() }
            exitWatches[process] = source; source.resume()
        }
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
            DiagnosticLog.record(.sessionObservation, component: .codex, outcome: .stopped, operation: .init())
        }
        closing = task
        await task.value
        continuation = nil; running = nil; coalescing = nil; readingChanges = nil; changedFiles.removeAll()
    }
}
