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

/// Stores bounded, opaque JSON objects. Provider-specific enrollment decoding
/// and recipient validation remain the responsibility of the channel owner.
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

    private static func validated(_ data: Data?) throws -> Data? {
        guard let data else { return nil }
        guard isValid(data) else { throw SecureStorageFailure(status: errSecDecode) }
        return data
    }

    private static func isValid(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] else { return false }
        return true
    }
}
