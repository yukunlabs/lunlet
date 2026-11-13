// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.01, AC-38.02, AC-38.03, AC-38.04, AC-38.07.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// One run of the hook helper, from Claude Code's Stop input to its exit. Without a running app it exits at
/// once; otherwise it writes the stop signal, waits briefly for the app's verdict, holds while the app holds,
/// and hands one follow-up to Claude Code. It logs nothing and touches nothing outside its stop directory.
public struct HookRuntime: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Not a Stop event, no session, or no running app: nothing was written.
        case ignored
        /// The app released the stop, or gave no verdict in time.
        case released
        /// A follow-up was handed to Claude Code.
        case continued
        /// The hold ran out without a follow-up.
        case expired
    }

    private let spool: HookSpool
    private let isProcessAlive: @Sendable (Int32) -> Bool
    private let processStartedAt: @Sendable (Int32) -> Date?
    private let verdictTimeout: TimeInterval
    private let holdLimit: TimeInterval
    private let pollInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let isInterrupted: @Sendable () -> Bool
    private let holdPollInterval: TimeInterval
    private let appCheckInterval: TimeInterval

    public init(spool: HookSpool = .standard(), isProcessAlive: @escaping @Sendable (Int32) -> Bool = { kill($0, 0) == 0 },
                processStartedAt: @escaping @Sendable (Int32) -> Date? = { HookProcess.startTime(of: $0) },
                verdictTimeout: TimeInterval = 3, holdLimit: TimeInterval = 600, pollInterval: TimeInterval = 0.05,
                now: @escaping @Sendable () -> Date = { Date() }, isInterrupted: @escaping @Sendable () -> Bool = { false },
                holdPollInterval: TimeInterval = 0.25, appCheckInterval: TimeInterval = 1) {
        self.spool = spool; self.isProcessAlive = isProcessAlive; self.processStartedAt = processStartedAt
        self.verdictTimeout = verdictTimeout; self.holdLimit = holdLimit; self.pollInterval = pollInterval; self.now = now
        self.isInterrupted = isInterrupted
        self.holdPollInterval = holdPollInterval; self.appCheckInterval = appCheckInterval
    }

    /// Runs to completion; `output` receives the continuation line when there is one.
    public func run(input: Data, pid: Int32, parentPID: Int32, output: (Data) -> Void) -> Outcome {
        guard let hook = HookInput(input), appIsRunning() else { return .ignored }
        let stopID = UUID()
        let directory = spool.stopDirectory(hook.sessionID)
        let signal = HookSpool.StopSignal(stopID: stopID, sessionID: hook.sessionID, promptID: hook.promptID,
                                          lastAssistantMessage: hook.lastAssistantMessage, stopHookActive: hook.stopHookActive,
                                          pid: pid, parentPID: parentPID, at: now())
        do {
            try HookSpool.createPrivateDirectory(directory)
            try HookSpool.writeAtomically(try HookSpool.encoder.encode(signal), to: spool.file(hook.sessionID, stop: stopID, suffix: HookSpool.signalSuffix))
        } catch { return .ignored }
        defer { cleanUp(hook.sessionID, stop: stopID) }
        let hold = spool.file(hook.sessionID, stop: stopID, suffix: HookSpool.holdSuffix)
        let release = spool.file(hook.sessionID, stop: stopID, suffix: HookSpool.releaseSuffix)
        let push = spool.file(hook.sessionID, stop: stopID, suffix: HookSpool.pushSuffix)
        // The app answers within milliseconds when it runs; a late or missing verdict never delays the turn for long.
        // Being told to end (TERM or HUP) ends either wait at once; the deferred cleanup then removes this stop's files.
        guard wait(until: verdictTimeout, every: pollInterval, for: { exists(hold) || exists(release) || isInterrupted() }),
              !isInterrupted(), exists(hold), !exists(release) else { return .released }
        // A hold lasts up to ten minutes, so it looks for its files a few times a second rather than twenty, and asks
        // whether the app still runs about once a second: the app ends a hold by writing a release, and only an app
        // that died without one is found this way.
        var appGone = false, lastAppCheck = now()
        let held = wait(until: holdLimit, every: holdPollInterval, for: {
            if exists(push) || exists(release) || isInterrupted() { return true }
            let moment = now()
            guard moment.timeIntervalSince(lastAppCheck) >= appCheckInterval else { return false }
            lastAppCheck = moment
            appGone = !appIsRunning()
            return appGone
        })
        guard held, !isInterrupted(), exists(push), let data = try? HookSpool.readSmall(push),
              let request = try? HookSpool.decoder.decode(HookSpool.PushRequest.self, from: data),
              request.stopID == stopID, request.isAcceptable else {
            return exists(release) || isInterrupted() || appGone ? .released : .expired
        }
        output(HookOutput.continuation(text: request.text))
        let receipt = HookSpool.PushReceipt(stopID: stopID, pushedAt: now())
        if let encoded = try? HookSpool.encoder.encode(receipt) {
            try? HookSpool.writeAtomically(encoded, to: spool.file(hook.sessionID, stop: stopID, suffix: HookSpool.receiptSuffix))
        }
        return .continued
    }

    private func appIsRunning() -> Bool {
        guard let data = try? HookSpool.readSmall(spool.appRecordURL),
              let record = try? HookSpool.decoder.decode(HookSpool.AppRecord.self, from: data),
              record.version == HookSpool.formatVersion, record.pid > 0, isProcessAlive(record.pid) else { return false }
        // The pid must still be the process that wrote the record. Where the platform gives no start time, the pid stands.
        guard let started = processStartedAt(record.pid) else { return !HookProcess.canReadStartTimes }
        return abs(started.timeIntervalSince(record.startedAt)) <= HookProcess.startTolerance
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func wait(until seconds: TimeInterval, every interval: TimeInterval, for condition: () -> Bool) -> Bool {
        let deadline = now().addingTimeInterval(seconds)
        while true {
            if condition() { return true }
            guard now() < deadline else { return false }
            Thread.sleep(forTimeInterval: interval)
        }
    }
    /// Everything but the receipt, which the app removes after reading it.
    private func cleanUp(_ session: UUID, stop: UUID) {
        for suffix in [HookSpool.signalSuffix, HookSpool.holdSuffix, HookSpool.releaseSuffix, HookSpool.pushSuffix] {
            try? FileManager.default.removeItem(at: spool.file(session, stop: stop, suffix: suffix))
        }
    }
}
