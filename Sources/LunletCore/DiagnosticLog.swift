// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.06; US-33, AC-33.01.
// Refs: US-14, AC-14.01, AC-14.02, AC-14.03, AC-14.06, AC-14.07.
// Refs: US-35, AC-35.04.
// Refs: US-10, AC-10.01.
import Foundation
import OSLog

/// Separate from every provider, session, request, and authorization identifier.
public struct DiagnosticOperation: Sendable {
    public let id = UUID()
    public init() {}
}

public enum DiagnosticComponent: String, Sendable {
    case app, feishu, slack, telegram, codex, claude, continuation, keychain, credentials, power, updates
}
public enum DiagnosticEvent: String, Sendable {
    case startup, shutdown, sessionObservation, registration, authentication, endpointDiscovery, connection, reconnect
    case cardDelivery, cardUpdate, cardAction, receipt, accountInitialize, accountRead, storageLoad, storageSave, storageRemove, powerAssertion
    /// One reply handed to an original CLI session; never its text or identifiers.
    case sessionInput
    /// The live-binding check of one reply against the observed session; a refusal names the failed check.
    case sessionBinding
}
public enum DiagnosticOutcome: String, Sendable {
    case started, completed, cancelled, retrying, stopped, failed, unavailable, rejected
    case received, submitted, processing, uncertain, duplicate
}
public enum DiagnosticReason: String, Sendable {
    case network, authentication, permission, rateLimit, invalidResponse, invalidInput
    case protocolViolation, timeout, storage, provider, ended, unknown
    /// Why a reply was refused: the session's binding or liveness is unverified, its phase conflicts with the reply,
    /// the reply window or control is closed, its CLI image or home is unavailable, or its record or request is.
    case unverified, state, window, image, record
}

/// Only allowlisted metadata reaches the system log; no arbitrary strings or errors.
public enum DiagnosticLog {
    public static func record(_ event: DiagnosticEvent, component: DiagnosticComponent,
                              outcome: DiagnosticOutcome, operation: DiagnosticOperation,
                              reason: DiagnosticReason? = nil, code: Int? = nil) {
        let logger = Logger(subsystem: "com.lunlet", category: component.rawValue)
        let message = "event=\(event.rawValue) outcome=\(outcome.rawValue) operation=\(operation.id.uuidString) reason=\(reason?.rawValue ?? "none") code=\(code.map(String.init) ?? "none")"
        // Public fields are safe because this API accepts only closed enums, numbers,
        // and a separately generated diagnostic identifier; it cannot accept content.
        if outcome == .failed || outcome == .uncertain {
            logger.error("\(message, privacy: .public)")
            // Errors also go to Lunlet's small local file when the app enabled it (AC-14.07).
            file?.append(Date().formatted(.iso8601) + " component=" + component.rawValue + " " + message)
        } else {
            logger.notice("\(message, privacy: .public)")
        }
    }

    private static let fileLock = NSLock()
    nonisolated(unsafe) private static var enabledFile: DiagnosticFile?
    /// Lunlet's local error file; nil until the app enables it, so tests and tools never write one.
    public static var file: DiagnosticFile? {
        get { fileLock.lock(); defer { fileLock.unlock() }; return enabledFile }
        set { fileLock.lock(); enabledFile = newValue; fileLock.unlock() }
    }
}

/// A small local error log for later troubleshooting: failed and uncertain events with the same allowlisted metadata
/// as the system log, appended on a background queue and rotated at a fixed size with one previous file kept, so it
/// never exceeds about twice that size. It is never uploaded (AC-14.07).
public final class DiagnosticFile: @unchecked Sendable {
    public static let maximumBytes = 256 * 1024
    /// `~/Library/Logs/Lunlet/lunlet.log`, where Console lists it under Log Reports.
    public static var standard: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lunlet/lunlet.log")
    }
    public let url: URL
    public var previous: URL { url.deletingLastPathComponent().appendingPathComponent("lunlet.1.log") }
    private let queue = DispatchQueue(label: "com.lunlet.diagnostic-file", qos: .utility)
    private let maximumBytes: Int

    public init(url: URL = DiagnosticFile.standard, maximumBytes: Int = DiagnosticFile.maximumBytes) {
        self.url = url; self.maximumBytes = maximumBytes
    }

    /// Best effort: a failure to write never affects the operation being logged.
    public func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        queue.async { [url, previous, maximumBytes] in
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
            let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 0, size + data.count > maximumBytes {
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: url, to: previous)
            }
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Waits for queued writes; for tests and orderly shutdown.
    public func flush() { queue.sync {} }
}
