// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-03, AC-03.02, AC-03.03.
import AppKit
import LunletCodex

@MainActor enum SessionDestinationOpener {
    static func open(_ destination: CodexTerminalDestination) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: destination.applicationPID), !app.isTerminated,
              app.bundleIdentifier == destination.applicationID,
              app.bundleURL?.resolvingSymlinksInPath() == destination.applicationURL.resolvingSymlinksInPath() else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        // Open with the verified host explicitly, never the default URL handler.
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([destination.revealURL], withApplicationAt: destination.applicationURL,
                                    configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}
