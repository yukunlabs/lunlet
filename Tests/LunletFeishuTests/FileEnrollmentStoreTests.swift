// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.02, AC-01.04; US-12, AC-12.02; US-26, AC-26.02.
import Foundation
import Security
import Testing
import LunletSecureStorage
@testable import LunletFeishu

/// A Keychain store of an earlier build, scripted: what a silent read and an authorized read return, and how often
/// the item was removed.
private final class ScriptedLegacyStore: EnrollmentStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var silent: Result<FeishuEnrollment?, any Error>
    private var authorized: Result<FeishuEnrollment?, any Error>
    private(set) var removals = 0
    private(set) var silentReads = 0
    private(set) var authorizedReads = 0
    init(silent: Result<FeishuEnrollment?, any Error>, authorized: Result<FeishuEnrollment?, any Error>) {
        self.silent = silent; self.authorized = authorized
    }
    func save(_ enrollment: FeishuEnrollment) async throws { Issue.record("the legacy store is never written") }
    func load() async throws -> FeishuEnrollment? { try lock.withLock { silentReads += 1; return try silent.get() } }
    func authorizeSavedEnrollment() async throws -> FeishuEnrollment? {
        try lock.withLock { authorizedReads += 1; return try authorized.get() }
    }
    func remove() async throws { lock.withLock { removals += 1; silent = .success(nil); authorized = .success(nil) } }
}

struct FileEnrollmentStoreTests {
    private let enrollment = FeishuEnrollment(applicationID: "cli_synthetic", scannedOwnerID: "ou_synthetic",
                                              secret: "synthetic-secret", isLark: true)
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-feishu-" + UUID().uuidString, isDirectory: true)
    }

    @Test func fileStoreRoundTripsReplacesAndRemovesTheEnrollment() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileEnrollmentStore(directory: directory)
        #expect(try await store.load() == nil)
        try await store.save(enrollment)
        #expect(try await store.load() == enrollment)
        #expect(try await store.authorizeSavedEnrollment() == enrollment)
        let replacement = FeishuEnrollment(applicationID: "cli_next", scannedOwnerID: "ou_next", secret: "next", isLark: false)
        try await store.save(replacement)
        #expect(try await store.load() == replacement)
        try await store.remove()
        #expect(try await store.load() == nil)
        // The file holds the record, nothing else, under the Keychain service's name.
        try await store.save(enrollment)
        let saved = try Data(contentsOf: directory.appendingPathComponent(FileEnrollmentStore.service + ".json"))
        #expect(String(decoding: saved, as: UTF8.self).contains("\"secret\":\"synthetic-secret\""))
    }

    @Test func aReadableKeychainEnrollmentMovesIntoTheFileSilentlyAndOnce() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = ScriptedLegacyStore(silent: .success(enrollment), authorized: .success(enrollment))
        let store = MigratingEnrollmentStore(file: FileEnrollmentStore(directory: directory), legacy: legacy)
        #expect(try await store.load() == enrollment)
        #expect(legacy.silentReads == 1 && legacy.authorizedReads == 0 && legacy.removals == 1)
        // The file now answers; the Keychain is not consulted again.
        #expect(try await store.load() == enrollment)
        #expect(try await FileEnrollmentStore(directory: directory).load() == enrollment)
        #expect(legacy.silentReads == 1)
    }

    @Test func anEnrollmentThisBuildMayNotReadWaitsForTheOwnersAuthorizationThenMoves() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let refused = SecureStorageFailure(status: errSecAuthFailed)
        let legacy = ScriptedLegacyStore(silent: .failure(refused), authorized: .success(enrollment))
        let store = MigratingEnrollmentStore(file: FileEnrollmentStore(directory: directory), legacy: legacy)
        // A background read surfaces the need for authorization, as the Keychain store did (AC-01.04).
        await #expect(throws: refused) { try await store.load() }
        #expect(legacy.removals == 0)
        #expect(try await store.authorizeSavedEnrollment() == enrollment)
        #expect(legacy.authorizedReads == 1 && legacy.removals == 1)
        #expect(try await store.load() == enrollment)
    }

    @Test func noKeychainItemOrNoCertificateMeansNothingToMoveAndNoPrompt() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = ScriptedLegacyStore(silent: .success(nil), authorized: .success(nil))
        #expect(try await MigratingEnrollmentStore(file: FileEnrollmentStore(directory: directory), legacy: empty).load() == nil)
        #expect(empty.removals == 0)
        // An ad hoc-signed build cannot use the Keychain at all; the file store works without a certificate.
        let unsigned = ScriptedLegacyStore(silent: .failure(EnrollmentIdentityFailure.certificateRequired),
                                           authorized: .failure(EnrollmentIdentityFailure.certificateRequired))
        let store = MigratingEnrollmentStore(file: FileEnrollmentStore(directory: directory), legacy: unsigned)
        #expect(try await store.load() == nil)
        #expect(try await store.authorizeSavedEnrollment() == nil)
        try await store.save(enrollment)
        #expect(try await store.load() == enrollment)
        #expect(unsigned.silentReads == 1)
    }

    @Test func savingOrRemovingAlsoForgetsTheKeychainItem() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = ScriptedLegacyStore(silent: .failure(SecureStorageFailure(status: errSecAuthFailed)),
                                         authorized: .success(enrollment))
        let store = MigratingEnrollmentStore(file: FileEnrollmentStore(directory: directory), legacy: legacy)
        try await store.save(enrollment)
        #expect(legacy.removals == 1)
        try await store.remove()
        #expect(legacy.removals == 2)
        #expect(try await store.load() == nil)
    }
}
