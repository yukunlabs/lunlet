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

/// Encodes the Feishu registration record on top of the shared secure item store.
public struct EnrollmentStore: EnrollmentStoring {
    private struct Record: Codable, Sendable {
        let applicationID: String
        let ownerID: String
        let secret: String
        let isLark: Bool
    }

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
        let record = Record(applicationID: enrollment.applicationID, ownerID: enrollment.scannedOwnerID,
                            secret: enrollment.secret, isLark: enrollment.isLark)
        try await items.perform(.storageSave) { access in
            let data = try JSONEncoder().encode(record)
            guard data.count <= 65_536 else { throw SecureStorageFailure(status: errSecParam) }
            try access.save(data)
        }
    }

    public func load() async throws -> FeishuEnrollment? {
        try await items.perform(.storageLoad) { try Self.decode($0.load()) }
    }

    /// Called only by the owner's explicit authorization action. Background
    /// reads, saves, and removal remain non-interactive. An enrollment the owner
    /// just authorized is re-created under this build's own signing identity, so
    /// the next build with the same identity needs no further authorization.
    public func authorizeSavedEnrollment() async throws -> FeishuEnrollment? {
        try await items.perform(.storageLoad, interactionAllowed: true) { access in
            let data = try access.load()
            let enrollment = try Self.decode(data)
            if let data, enrollment != nil { try access.reown(data) }
            return enrollment
        }
    }

    public func remove() async throws {
        try await items.perform(.storageRemove) { try $0.remove() }
    }

    private static func decode(_ data: Data?) throws -> FeishuEnrollment? {
        guard let data else { return nil }
        guard data.count <= 65_536, let record = try? JSONDecoder().decode(Record.self, from: data),
              !record.applicationID.isEmpty, !record.ownerID.isEmpty, !record.secret.isEmpty else {
            throw SecureStorageFailure(status: errSecDecode)
        }
        return FeishuEnrollment(applicationID: record.applicationID, scannedOwnerID: record.ownerID,
                                secret: record.secret, isLark: record.isLark)
    }
}
