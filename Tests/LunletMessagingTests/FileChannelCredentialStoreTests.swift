// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.04, AC-20.06; US-12, AC-12.02.
import Foundation
import Security
import Testing
import LunletSecureStorage
@testable import LunletMessaging

private final class ScriptedLegacyChannelStore: ChannelCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var silent: Result<Data?, any Error>
    private var authorized: Result<Data?, any Error>
    private(set) var removals = 0
    init(silent: Result<Data?, any Error>, authorized: Result<Data?, any Error>) { self.silent = silent; self.authorized = authorized }
    func load() async throws -> Data? { try lock.withLock { try silent.get() } }
    func authorize() async throws -> Data? { try lock.withLock { try authorized.get() } }
    func save(_ data: Data) async throws { Issue.record("the legacy store is never written") }
    func remove() async throws { lock.withLock { removals += 1; silent = .success(nil); authorized = .success(nil) } }
}

struct FileChannelCredentialStoreTests {
    private let record = Data(#"{"botToken":"synthetic","chatID":"1"}"#.utf8)
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-channel-" + UUID().uuidString, isDirectory: true)
    }

    @Test func channelsKeepSeparateFilesWithValidatedOpaqueJSON() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let slack = FileChannelCredentialStore(channel: .slack, directory: directory)
        let telegram = FileChannelCredentialStore(channel: .telegram, directory: directory)
        try await slack.save(record)
        #expect(try await slack.load() == record)
        #expect(try await slack.authorize() == record)
        #expect(try await telegram.load() == nil)
        await #expect(throws: SecureStorageFailure(status: errSecParam)) { try await telegram.save(Data("[]".utf8)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["com.lunlet.slack.json"])
        try await slack.remove()
        #expect(try await slack.load() == nil)
    }

    @Test func keychainCredentialsMoveIntoTheFileSilentlyOrAfterAuthorization() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let readable = ScriptedLegacyChannelStore(silent: .success(record), authorized: .success(record))
        let moved = MigratingChannelCredentialStore(file: FileChannelCredentialStore(channel: .slack, directory: directory), legacy: readable)
        #expect(try await moved.load() == record)
        #expect(readable.removals == 1)
        #expect(try await FileChannelCredentialStore(channel: .slack, directory: directory).load() == record)

        let refused = SecureStorageFailure(status: errSecAuthFailed)
        let guarded = ScriptedLegacyChannelStore(silent: .failure(refused), authorized: .success(record))
        let waiting = MigratingChannelCredentialStore(file: FileChannelCredentialStore(channel: .telegram, directory: directory), legacy: guarded)
        await #expect(throws: refused) { try await waiting.load() }
        #expect(try await waiting.authorize() == record)
        #expect(guarded.removals == 1)
        #expect(try await waiting.load() == record)

        let unsigned = ScriptedLegacyChannelStore(silent: .failure(EnrollmentIdentityFailure.certificateRequired),
                                                  authorized: .failure(EnrollmentIdentityFailure.certificateRequired))
        let fresh = MigratingChannelCredentialStore(file: FileChannelCredentialStore(channel: .slack, directory: directory.appendingPathComponent("fresh")), legacy: unsigned)
        #expect(try await fresh.load() == nil)
        try await fresh.save(record)
        #expect(try await fresh.load() == record)
    }
}
