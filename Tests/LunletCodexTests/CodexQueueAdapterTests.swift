// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-08, AC-08.01, AC-08.02, AC-08.03, AC-08.04; US-09, AC-09.02.
// Refs: US-10, AC-10.01, AC-10.02, AC-10.03, AC-10.04; US-11, AC-11.03.
import Foundation
import Testing
import LunletCore
@testable import LunletCodex

/// A binding source that never scans the system.
private actor BindingSource: CodexSessionObserving {
    private let result: CodexBindingResult
    private(set) var requests = 0
    init(_ result: CodexBindingResult) { self.result = result }
    func updates() -> AsyncStream<SessionUpdate> { AsyncStream { $0.finish() } }
    func refresh() {}
    func reconcile() {}
    func shutdown() {}
    func destination(sessionID: UUID, connectionID: UUID) -> CodexTerminalDestination? { nil }
    func continuationBinding(sessionID: UUID, connectionID: UUID, completedTurnID: String) -> CodexBindingResult {
        requests += 1
        return result
    }
}

/// Records each invocation instead of launching anything; `effect` simulates the CLI's record.
private final class SyntheticRunner: CodexProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CodexProcessRequest] = []
    private let exit: CodexProcessExit
    private let effect: @Sendable () -> Void
    init(_ exit: CodexProcessExit, effect: @escaping @Sendable () -> Void = {}) { self.exit = exit; self.effect = effect }
    var requests: [CodexProcessRequest] { lock.withLock { values } }
    func run(_ request: CodexProcessRequest, timeout: Duration) async -> CodexProcessExit {
        lock.withLock { values.append(request) }
        effect()
        return exit
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private let refusal: ContinuationRefusal?
    init(refusal: ContinuationRefusal? = nil) { self.refusal = refusal }
    var events: [String] { lock.withLock { values } }
    var progress: ContinuationProgress {
        ContinuationProgress(recheck: { self.lock.withLock { self.values.append("recheck") }; return self.refusal },
                             submitted: { self.lock.withLock { self.values.append("submitted") } })
    }
}

struct CodexQueueAdapterTests {
    let helper = CodexSessionReaderTests()
    let connection = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    let process = CodexProcessIdentity(pid: 4242, seconds: 1_800_000_000, microseconds: 7)
    let executable = URL(fileURLWithPath: "/synthetic/lib/node_modules/codex/vendor/codex")
    let text = "Add the missing test,\nthen rerun it"

    private func binding(_ file: CodexRolloutFile, root: URL) -> CodexContinuationBinding {
        CodexContinuationBinding(sessionID: helper.first, connectionID: connection, completedTurnID: "turn_done",
                                 process: process, rollout: file, executable: executable, codexHome: root)
    }
    private func request(_ value: String? = nil) -> CodexContinuationRequest {
        CodexContinuationRequest(sessionID: helper.first, connectionID: connection, completedTurnID: "turn_done", text: value ?? text)
    }
    private func userMessage(_ value: String) throws -> Data {
        try helper.line("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": value]]])
    }
    private func adapter(_ runner: SyntheticRunner, confirmation: Duration = .seconds(2)) -> CodexQueueAdapter {
        CodexQueueAdapter(runner: runner, queueTimeout: .seconds(1), confirmationTimeout: confirmation,
                          pollInterval: .milliseconds(5),
                          baseEnvironment: ["HOME": "/Users/synthetic", "PATH": "/synthetic/wrapper/bin:/usr/bin",
                                            "TMPDIR": "/synthetic/tmp/", "DYLD_INSERT_LIBRARIES": "/synthetic/inject.dylib",
                                            "CODEX_HOME": "/synthetic/other-home"])
    }
    private func fixture() throws -> (URL, CodexRolloutFile) {
        try helper.fixture(helper.header(helper.first) + helper.event("task_started", "turn_done")
                           + helper.event("task_complete", "turn_done"))
    }

    @Test func theRequestRunsTheObservedExecutableWithExactlyTheQueueArgumentsAndAnExplicitEnvironment() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try #require(CodexQueueAdapter.processRequest(
            for: binding(file, root: root), text: text,
            baseEnvironment: ["HOME": "/Users/synthetic", "PATH": "/synthetic/wrapper/bin", "LANG": "en_US.UTF-8",
                              "DYLD_INSERT_LIBRARIES": "/synthetic/inject.dylib", "CODEX_HOME": "/synthetic/other-home"]))
        // The observed process image, not `codex` from PATH or the wrapper that launched it.
        #expect(request.executable == executable)
        #expect(request.arguments == ["queue", "--thread", "11111111-1111-1111-1111-111111111111", "--message", text])
        #expect(request.environment == ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CODEX_HOME": root.path,
                                        "HOME": "/Users/synthetic", "LANG": "en_US.UTF-8"])
        for unsafe in ["--dangerously-bypass-approvals-and-sandbox", "-h", "Clear\u{1B}[2J", "\u{202E}txt", "", " \n",
                       String(repeating: "a", count: ContinuationText.maximumBytes + 1)] {
            #expect(CodexQueueAdapter.processRequest(for: binding(file, root: root), text: unsafe, baseEnvironment: [:]) == nil)
        }
    }

    @Test func aQueuedReplyIsDeliveredOnlyWhenItIsTheSessionsNextDeveloperMessage() async throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try helper.line("response_item", ["type": "message", "role": "user", "content": [
            ["type": "input_text", "text": "<environment_context>\n  <cwd>/synthetic</cwd>\n</environment_context>"]]])
        let assistant = try helper.line("response_item", ["type": "message", "role": "assistant",
                                                          "content": [["type": "output_text", "text": "Earlier"]]])
        // Codex may reflow whitespace; hidden context and agent output are not developer input.
        let delivered = try context + assistant + userMessage("Add the missing test,  then rerun it ")
        let runner = SyntheticRunner(.exited(0)) { [helper] in try? helper.append(delivered, to: file) }
        let source = BindingSource(.bound(binding(file, root: root))), log = ProgressLog()
        #expect(await adapter(runner).continueSession(request(), in: source, progress: log.progress) == .delivered)
        #expect(runner.requests.count == 1 && log.events == ["recheck", "submitted"])
        #expect(await source.requests == 1)
    }

    @Test func anotherFirstMessageOrSilenceIsNotConfirmedAndNeverResubmitted() async throws {
        for appended in [try userMessage("Something typed on the Mac") + userMessage(text), Data()] {
            let (root, file) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = SyntheticRunner(.exited(0)) { [helper] in try? helper.append(appended, to: file) }
            let outcome = await adapter(runner, confirmation: .milliseconds(60))
                .continueSession(request(), in: BindingSource(.bound(binding(file, root: root))), progress: ProgressLog().progress)
            #expect(outcome == .notConfirmed)
            #expect(runner.requests.count == 1)
        }
    }

    @Test func failedLaunchesAndExitsAreFailuresWhileATimedOutQueueIsConfirmedFromTheRecord() async throws {
        let cases: [(CodexProcessExit, Bool, ContinuationOutcome)] = [
            (.exited(2), true, .failed), (.signaled, true, .failed), (.launchFailed, false, .failed),
            (.timedOut, true, .delivered), (.timedOut, false, .notConfirmed),
        ]
        for (exit, appends, expected) in cases {
            let (root, file) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let message = try userMessage(text)
            let runner = SyntheticRunner(exit) { [helper] in if appends { try? helper.append(message, to: file) } }
            let log = ProgressLog()
            let outcome = await adapter(runner, confirmation: .milliseconds(60))
                .continueSession(request(), in: BindingSource(.bound(binding(file, root: root))), progress: log.progress)
            #expect(outcome == expected)
            // Only a clean exit is a submission receipt; nothing is ever run twice.
            #expect(!log.events.contains("submitted") && runner.requests.count == 1)
        }
    }

    @Test func refusedBindingsStaleAccessAndUnsafeTextNeverRunTheCLI() async throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for reason in [ContinuationRefusal.sessionRunning, .awaitingApproval, .sessionEnded, .superseded, .unverified] {
            let runner = SyntheticRunner(.exited(0))
            let outcome = await adapter(runner).continueSession(request(), in: BindingSource(.refused(reason)),
                                                                progress: ProgressLog().progress)
            #expect(outcome == .refused(reason) && runner.requests.isEmpty)
        }
        let runner = SyntheticRunner(.exited(0)), unlocked = ProgressLog(refusal: .replyWindowClosed)
        let source = BindingSource(.bound(binding(file, root: root)))
        #expect(await adapter(runner).continueSession(request(), in: source, progress: unlocked.progress)
                == .refused(.replyWindowClosed))
        // A binding for another turn or connection is not this request's binding.
        let other = CodexContinuationBinding(sessionID: helper.first, connectionID: UUID(), completedTurnID: "turn_done",
                                             process: process, rollout: file, executable: executable, codexHome: root)
        #expect(await adapter(runner).continueSession(request(), in: BindingSource(.bound(other)),
                                                      progress: ProgressLog().progress) == .refused(.unverified))
        let unsafe = BindingSource(.bound(binding(file, root: root)))
        #expect(await adapter(runner).continueSession(request("--help"), in: unsafe, progress: ProgressLog().progress) == .failed)
        #expect(await unsafe.requests == 0 && runner.requests.isEmpty)
    }

    @Test func theDeliveryWatchReadsOnlyAppendedRecordsOfTheSameFile() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // A matching message already in the record is history, not delivery.
        try helper.append(userMessage(text), to: file)
        var watch = try #require(CodexDeliveryWatch(file: file, text: text))
        #expect(watch.poll() == .pending)
        let line = try helper.line("event_msg", ["type": "user_message", "message": text, "images": []])
        try helper.append(line.prefix(10), to: file)
        #expect(watch.poll() == .pending)
        try helper.append(line.dropFirst(10), to: file)
        #expect(watch.poll() == .delivered)

        var replaced = try #require(CodexDeliveryWatch(file: file, text: text))
        try FileManager.default.removeItem(at: file.url)
        try helper.header(helper.first).write(to: file.url)
        try helper.append(userMessage(text), to: file)
        #expect(replaced.poll() == .unavailable)
    }
}

/// Runs only system utilities, never Codex, to verify the process boundary itself.
struct SystemCodexProcessRunnerTests {
    private func request(_ path: String, _ arguments: [String], environment: [String: String] = [:]) -> CodexProcessRequest {
        CodexProcessRequest(executable: URL(fileURLWithPath: path), arguments: arguments, environment: environment)
    }

    @Test func argumentsAndEnvironmentArePassedExactlyWithoutAShell() async {
        let runner = SystemCodexProcessRunner()
        // `test` succeeds only if each value arrives as one unexpanded argument.
        #expect(await runner.run(request("/bin/test", ["a b; $HOME", "=", "a b; $HOME"]), timeout: .seconds(5)) == .exited(0))
        #expect(await runner.run(request("/usr/bin/false", []), timeout: .seconds(5)) == .exited(1))
        #expect(await runner.run(request("/usr/bin/printenv", ["LUNLET_SYNTHETIC"], environment: ["LUNLET_SYNTHETIC": "1"]),
                                 timeout: .seconds(5)) == .exited(0))
        // Nothing is inherited, not even PATH.
        #expect(await runner.run(request("/usr/bin/printenv", ["PATH"], environment: ["LUNLET_SYNTHETIC": "1"]),
                                 timeout: .seconds(5)) == .exited(1))
        #expect(await runner.run(request("/nonexistent/codex", []), timeout: .seconds(5)) == .launchFailed)
    }

    @Test func timeoutsAndCancellationStopTheChild() async {
        let runner = SystemCodexProcessRunner()
        let started = ContinuousClock.now
        #expect(await runner.run(request("/bin/sleep", ["30"]), timeout: .milliseconds(100)) == .timedOut)
        let cancelled = Task { await runner.run(request("/bin/sleep", ["30"]), timeout: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        #expect(await cancelled.value == .timedOut)
        #expect(started.duration(to: .now) < .seconds(10))
    }
}
