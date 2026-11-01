// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-12, AC-12.02.
// Refs: US-14, AC-14.01, AC-14.02, AC-14.03, AC-14.06.
// Refs: US-01, AC-01.02, AC-01.04, AC-01.05.
import Foundation
import LunletSecureStorage
import Security

public protocol EnrollmentStoring: Sendable {
    func save(_ enrollment: FeishuEnrollment) async throws
    func load() async throws -> FeishuEnrollment?
    func authorizeSavedEnrollment() async throws -> FeishuEnrollment?
    func remove() async throws
}

public extension EnrollmentStoring {
    func authorizeSavedEnrollment() async throws -> FeishuEnrollment? { try await load() }
}

/// The enrollment record both stores keep: the registration fields, never a tenant binding.
struct EnrollmentRecord: Codable, Sendable {
    let applicationID: String
    let ownerID: String
    let secret: String
    let isLark: Bool

    static func encode(_ enrollment: FeishuEnrollment) throws -> Data {
        let record = EnrollmentRecord(applicationID: enrollment.applicationID, ownerID: enrollment.scannedOwnerID,
                                      secret: enrollment.secret, isLark: enrollment.isLark)
        let data = try JSONEncoder().encode(record)
        guard data.count <= 65_536 else { throw SecureStorageFailure(status: errSecParam) }
        return data
    }
    static func decode(_ data: Data?) throws -> FeishuEnrollment? {
        guard let data else { return nil }
        guard data.count <= 65_536, let record = try? JSONDecoder().decode(EnrollmentRecord.self, from: data),
              !record.applicationID.isEmpty, !record.ownerID.isEmpty, !record.secret.isEmpty else {
            throw SecureStorageFailure(status: errSecDecode)
        }
        return FeishuEnrollment(applicationID: record.applicationID, scannedOwnerID: record.ownerID,
                                secret: record.secret, isLark: record.isLark)
    }
}

/// The Feishu enrollment in Lunlet's user-only credential file: the store every build uses since 2026-11-01, so
/// an update of an unsigned build never asks the owner to authorize access again (AC-01.02).
public struct FileEnrollmentStore: EnrollmentStoring {
    public static let service = "com.lunlet.feishu"
    private let items: CredentialFileStore

    public init(directory: URL = CredentialFileStore.standardDirectory) {
        items = CredentialFileStore(service: Self.service, directory: directory)
    }
    public func save(_ enrollment: FeishuEnrollment) async throws {
        let data = try EnrollmentRecord.encode(enrollment)
        try await items.perform(.storageSave) { try $0.save(data) }
    }
    public func load() async throws -> FeishuEnrollment? {
        try await items.perform(.storageLoad) { try EnrollmentRecord.decode($0.load()) }
    }
    public func remove() async throws {
        try await items.perform(.storageRemove) { try $0.remove() }
    }
}

/// The file store, with an enrollment an earlier build saved in the Keychain moved into it on first use: silently
/// when this build may still read that item, otherwise through the owner's Authorize access action, once; the
/// Keychain item is removed after the move. A build without a certificate has no Keychain access and simply has no
/// earlier enrollment to move.
public struct MigratingEnrollmentStore: EnrollmentStoring {
    private let file: any EnrollmentStoring
    private let legacy: any EnrollmentStoring

    public static func standard() -> MigratingEnrollmentStore {
        MigratingEnrollmentStore(file: FileEnrollmentStore(), legacy: EnrollmentStore())
    }
    public init(file: any EnrollmentStoring, legacy: any EnrollmentStoring) { self.file = file; self.legacy = legacy }

    public func load() async throws -> FeishuEnrollment? {
        if let current = try await file.load() { return current }
        return try await move { try await legacy.load() }
    }
    public func authorizeSavedEnrollment() async throws -> FeishuEnrollment? {
        if let current = try await file.load() { return current }
        return try await move { try await legacy.authorizeSavedEnrollment() }
    }
    public func save(_ enrollment: FeishuEnrollment) async throws {
        try await file.save(enrollment)
        await forgetLegacy()
    }
    public func remove() async throws {
        try await file.remove()
        await forgetLegacy()
    }
    private func move(_ read: () async throws -> FeishuEnrollment?) async throws -> FeishuEnrollment? {
        let saved: FeishuEnrollment?
        do { saved = try await read() } catch EnrollmentIdentityFailure.certificateRequired { return nil }
        guard let saved else { return nil }
        try await file.save(saved)
        await forgetLegacy()
        return saved
    }
    /// A Keychain item that cannot be removed silently is left alone; it is never read again once the file exists.
    private func forgetLegacy() async { try? await legacy.remove() }
}

/// Encodes the Feishu registration record on top of the shared Keychain item store. Kept for a release with a stable
/// signing identity and as the source of enrollments saved before the credential file.
public struct EnrollmentStore: EnrollmentStoring {

    private let items: SecureItemStore

    public init() {
        // The second service name is a pre-release compatibility shim: enrollments saved before the identifier
        // rename are read from it so they need not be recreated. It is read-only and is removed before 1.0.
        items = SecureItemStore(services: ["com.lunlet.feishu", "com.yukunlabs.lunlet.feishu"],
                                signingIdentity: CodeSigningIdentity.allowsCredentialAccess)
    }
    // Synthetic namespace tests inject identity separately; only the public
    // application initializer establishes the production signing requirement.
    init(service: String, legacyService: String? = nil, keychain: any KeychainAPI = SystemKeychain(),
         signingIdentity: @escaping @Sendable () -> Bool = { true }) {
        items = SecureItemStore(services: [service] + (legacyService.map { [$0] } ?? []),
                                keychain: keychain, signingIdentity: signingIdentity)
    }

    /// Registration credentials are pending setup, not a verified tenant binding.
    public func save(_ enrollment: FeishuEnrollment) async throws {
        let data = try EnrollmentRecord.encode(enrollment)
        try await items.perform(.storageSave) { try $0.save(data) }
    }

    public func load() async throws -> FeishuEnrollment? {
        try await items.perform(.storageLoad) { try EnrollmentRecord.decode($0.load()) }
    }

    /// Called only by the owner's explicit authorization action. Background
    /// reads, saves, and removal remain non-interactive. An enrollment the owner
    /// just authorized is re-created under this build's own signing identity, so
    /// the next build with the same identity needs no further authorization.
    public func authorizeSavedEnrollment() async throws -> FeishuEnrollment? {
        try await items.perform(.storageLoad, interactionAllowed: true) { access in
            let data = try access.load()
            let enrollment = try EnrollmentRecord.decode(data)
            if let data, enrollment != nil { try access.reown(data) }
            return enrollment
        }
    }

    public func remove() async throws {
        try await items.perform(.storageRemove) { try $0.remove() }
    }
}
