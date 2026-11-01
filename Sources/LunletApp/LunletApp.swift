// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-14, AC-14.01, AC-14.02, AC-14.03, AC-14.06, AC-14.07.
// Refs: US-02, AC-02.03; US-03, AC-03.04, AC-03.05, AC-03.06, AC-03.07, AC-03.10.
// Refs: US-12, AC-12.04, AC-12.05; US-05, AC-05.05.
import AppKit
import LunletCore
import LunletDesktop

@main struct LunletApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let lifecycle = LunletLifecycle()
        application.delegate = lifecycle
        withExtendedLifetime(lifecycle) { application.run() }
    }
}

@MainActor private final class LunletLifecycle: NSObject, NSApplicationDelegate {
    let runtime = CompanionRuntime()
    private let operation = DiagnosticOperation()
    private var terminating: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var cleanedUp = false
    /// How long an orderly cleanup may take before the app quits regardless.
    private static let terminationLimit: Duration = .seconds(8)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only the app keeps the local error file; tests and tools leave it off (AC-14.07).
        DiagnosticLog.file = DiagnosticFile()
        runtime.start()
        NSApplication.shared.mainMenu = ApplicationMenu.make()
        DiagnosticLog.record(.startup, component: .app, outcome: .completed, operation: operation)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if terminating == nil { runtime.showPanel() }
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if cleanedUp { return .terminateNow }
        if terminating == nil {
            DiagnosticLog.record(.shutdown, component: .app, outcome: .started, operation: operation)
            terminating = Task {
                await runtime.shutdown()
                finishTermination(sender)
            }
            // A cleanup that stalls on a provider or a socket never keeps the app alive: after the limit the
            // app quits anyway and the log says so, with the runtime's last finished stage before it.
            watchdog = Task {
                try? await Task.sleep(for: Self.terminationLimit)
                guard !cleanedUp else { return }
                DiagnosticLog.record(.shutdown, component: .app, outcome: .uncertain, operation: operation, reason: .timeout)
                finishTermination(sender)
            }
        }
        return .terminateLater
    }
    private func finishTermination(_ sender: NSApplication) {
        guard !cleanedUp else { return }
        cleanedUp = true
        watchdog?.cancel(); watchdog = nil
        sender.reply(toApplicationShouldTerminate: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticLog.record(.shutdown, component: .app, outcome: .completed, operation: operation)
    }
}
