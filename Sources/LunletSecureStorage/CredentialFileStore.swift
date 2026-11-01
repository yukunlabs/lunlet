// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.02; US-20, AC-20.04, AC-20.06; US-12, AC-12.02; US-26, AC-26.02; US-14, AC-14.01.
import Foundation
import LunletCore
import Security

/// Credentials in a file only the current user can read, under Lunlet's Application Support directory.
///
/// Chosen over the Keychain on 2026-11-01 for the unsigned preview release: the Keychain pins an item to the code
/// hash of the build that saved it, so every update of an unsigned build would ask the owner to authorize access
/// again, while a user-only file follows the user. Any process running as that user can read the file, as it can
/// read Codex's own credential file; the Keychain store stays available for a release with a stable signing identity.
public struct CredentialFileStore: Sendable {
    public static let maximumBytes = 65_536
    /// `~/Library/Application Support/com.lunlet/credentials`, created with user-only permissions on first save.
    public static var standardDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.lunlet/credentials", isDirectory: true)
    }
    let directory: URL
    let service: String

    public init(service: String, directory: URL = CredentialFileStore.standardDirectory) {
        precondition(!service.isEmpty && !service.contains("/"), "A credential file needs a plain service name")
        self.service = service; self.directory = directory.standardizedFileURL
    }
    /// One file per service, named like the Keychain service it replaces.
    public var file: URL { directory.appendingPathComponent(service + ".json", isDirectory: false) }

    /// Runs `body` on the shared credential queue with the same diagnostics as the Keychain store (AC-14.01).
    public func perform<T: Sendable>(_ event: DiagnosticEvent,
                                     _ body: @escaping @Sendable (CredentialFileAccess) throws -> T) async throws -> T {
        let access = CredentialFileAccess(file: file, directory: directory)
        return try await CredentialFileQueue.run {
            let operation = DiagnosticOperation()
            DiagnosticLog.record(event, component: .credentials, outcome: .started, operation: operation)
            do {
                let result = try body(access)
                DiagnosticLog.record(event, component: .credentials, outcome: .completed, operation: operation)
                return result
            } catch {
                DiagnosticLog.record(event, component: .credentials, outcome: .failed, operation: operation,
                                     reason: .storage, code: (error as? SecureStorageFailure).map { Int($0.status) })
                throw error
            }
        }
    }
}

/// File operations, valid only inside `CredentialFileStore.perform`. Failures carry Security status codes so the
/// setup models treat both stores alike.
public struct CredentialFileAccess: Sendable {
    let file: URL
    let directory: URL

    /// The saved bytes, or nil when nothing is saved. A file that grew wider than user-only is narrowed before
    /// reading; an oversize file is rejected for its owner to replace.
    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try Self.restrict(file, to: 0o600)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? 0
        guard size <= CredentialFileStore.maximumBytes else { throw SecureStorageFailure(status: errSecDecode) }
        do { return try Data(contentsOf: file) } catch { throw SecureStorageFailure(status: errSecIO) }
    }

    /// Writes the bytes beside the file with user-only permissions from the first byte, then moves them into place
    /// atomically, so no reader ever sees a partial file or a wider-readable one.
    public func save(_ data: Data) throws {
        guard !data.isEmpty, data.count <= CredentialFileStore.maximumBytes else { throw SecureStorageFailure(status: errSecParam) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Self.restrict(directory, to: 0o700)
        } catch let failure as SecureStorageFailure { throw failure } catch { throw SecureStorageFailure(status: errSecIO) }
        let temporary = directory.appendingPathComponent("." + file.lastPathComponent + "." + UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SecureStorageFailure(status: errSecIO)
        }
        guard rename(temporary.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw SecureStorageFailure(status: errSecIO)
        }
        // Credentials belong to this Mac; a backup of them is not wanted. Best effort: a file system that cannot
        // record the flag changes nothing above.
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var url = file; try? url.setResourceValues(values)
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { try FileManager.default.removeItem(at: file) } catch { throw SecureStorageFailure(status: errSecIO) }
    }

    private static func restrict(_ url: URL, to permissions: Int) throws {
        let current = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        guard current != permissions else { return }
        do { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        catch { throw SecureStorageFailure(status: errSecIO) }
    }
}

/// One serial queue for every credential file, off Swift's cooperative pool, so writes to one service never
/// interleave and a slow disk never blocks shared threads.
enum CredentialFileQueue {
    private static let queue = DispatchQueue(label: "com.lunlet.credentials", qos: .userInitiated)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}
