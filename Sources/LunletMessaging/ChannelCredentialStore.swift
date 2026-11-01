// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.04, AC-20.06.
// Refs: US-12, AC-12.02.
import Foundation
import LunletSecureStorage
import Security

public protocol ChannelCredentialStoring: Sendable {
    func load() async throws -> Data?
    func authorize() async throws -> Data?
    func save(_ data: Data) async throws
    func remove() async throws
}

/// Bounded, opaque JSON objects in Lunlet's user-only credential file: the store every build uses since
/// 2026-11-01, so an update of an unsigned build never asks the owner to authorize access again (AC-20.04).
public struct FileChannelCredentialStore: ChannelCredentialStoring {
    private let items: CredentialFileStore

    public init(channel: BotChannel, directory: URL = CredentialFileStore.standardDirectory) {
        items = CredentialFileStore(service: ChannelCredentialStore.service(for: channel), directory: directory)
    }
    public func load() async throws -> Data? {
        try await items.perform(.storageLoad) { try ChannelCredentialStore.validated($0.load()) }
    }
    public func authorize() async throws -> Data? { try await load() }
    public func save(_ data: Data) async throws {
        try await items.perform(.storageSave) { access in
            guard ChannelCredentialStore.isValid(data) else { throw SecureStorageFailure(status: errSecParam) }
            try access.save(data)
        }
    }
    public func remove() async throws {
        try await items.perform(.storageRemove) { try $0.remove() }
    }
}

/// The file store, with credentials an earlier build saved in the Keychain moved into it on first use: silently when
/// this build may still read them, otherwise through the owner's Authorize access action, once; the Keychain item is
/// removed after the move. A build without a certificate has no Keychain access and simply has nothing to move.
public struct MigratingChannelCredentialStore: ChannelCredentialStoring {
    private let file: any ChannelCredentialStoring
    private let legacy: any ChannelCredentialStoring

    public static func standard(channel: BotChannel) -> MigratingChannelCredentialStore {
        MigratingChannelCredentialStore(file: FileChannelCredentialStore(channel: channel), legacy: ChannelCredentialStore(channel: channel))
    }
    public init(file: any ChannelCredentialStoring, legacy: any ChannelCredentialStoring) { self.file = file; self.legacy = legacy }

    public func load() async throws -> Data? {
        if let current = try await file.load() { return current }
        return try await move { try await legacy.load() }
    }
    public func authorize() async throws -> Data? {
        if let current = try await file.load() { return current }
        return try await move { try await legacy.authorize() }
    }
    public func save(_ data: Data) async throws {
        try await file.save(data)
        await forgetLegacy()
    }
    public func remove() async throws {
        try await file.remove()
        await forgetLegacy()
    }
    private func move(_ read: () async throws -> Data?) async throws -> Data? {
        let saved: Data?
        do { saved = try await read() } catch EnrollmentIdentityFailure.certificateRequired { return nil }
        guard let saved else { return nil }
        try await file.save(saved)
        await forgetLegacy()
        return saved
    }
    private func forgetLegacy() async { try? await legacy.remove() }
}

/// Stores bounded, opaque JSON objects in the Keychain. Kept for a release with a stable signing identity and as
/// the source of credentials saved before the credential file. Provider-specific enrollment decoding and recipient
/// validation remain the responsibility of the channel owner.
public struct ChannelCredentialStore: ChannelCredentialStoring {
    private let items: SecureItemStore

    public init(channel: BotChannel) {
        items = SecureItemStore(services: [Self.service(for: channel)],
                                signingIdentity: CodeSigningIdentity.allowsCredentialAccess)
    }

    // Tests inject all Security calls and identity, never owner credentials.
    init(channel: BotChannel, keychain: any KeychainAPI, signingIdentity: @escaping @Sendable () -> Bool = { true }) {
        items = SecureItemStore(services: [Self.service(for: channel)], keychain: keychain,
                                signingIdentity: signingIdentity)
    }

    /// Existing saved credentials depend on these exact service names.
    static func service(for channel: BotChannel) -> String {
        switch channel {
        case .slack: "com.lunlet.slack"
        case .telegram: "com.lunlet.telegram"
        }
    }

    public func load() async throws -> Data? {
        try await items.perform(.storageLoad) { try Self.validated($0.load()) }
    }

    /// Only the owner's explicit authorization action may permit a system prompt.
    public func authorize() async throws -> Data? {
        try await items.perform(.storageLoad, interactionAllowed: true) { try Self.validated($0.load()) }
    }

    public func save(_ data: Data) async throws {
        try await items.perform(.storageSave) { access in
            guard Self.isValid(data) else { throw SecureStorageFailure(status: errSecParam) }
            try access.save(data)
        }
    }

    public func remove() async throws {
        try await items.perform(.storageRemove) { try $0.remove() }
    }

    static func validated(_ data: Data?) throws -> Data? {
        guard let data else { return nil }
        guard isValid(data) else { throw SecureStorageFailure(status: errSecDecode) }
        return data
    }

    static func isValid(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] else { return false }
        return true
    }
}
