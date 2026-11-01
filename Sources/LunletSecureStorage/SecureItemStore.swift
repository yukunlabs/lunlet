// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-12, AC-12.02.
// Refs: US-14, AC-14.01, AC-14.02, AC-14.03, AC-14.06.
// Refs: US-01, AC-01.02, AC-01.04, AC-01.05.
// Refs: US-20, AC-20.04, AC-20.06 (shared process interaction policy).
import Foundation
import LunletCore
import Security

public enum EnrollmentIdentityFailure: Error, Equatable, Sendable { case certificateRequired }

public struct SecureStorageFailure: Error, Equatable, Sendable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }

    /// Access requires the owner's explicit Authorize access action, not an automatic retry.
    public var requiresOwnerAuthorization: Bool {
        [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecInteractionRequired].contains(status)
    }
    /// The saved file cannot be opened by this Mac and user account (copied from elsewhere, renamed or edited);
    /// only removing it and connecting again helps, never authorization or a retry.
    public var unreadableOnThisMac: Bool { status == errSecDecode }
}

/// One generic-password item per service in the file-based, non-synchronizing Keychain.
/// The first service is written; later services are read-only fallbacks for renamed
/// identifiers and are removed with it. Credential owners validate their own payloads.
package struct SecureItemStore: Sendable {
    private let services: [String]
    private let keychain: any KeychainAPI
    private let signingIdentity: @Sendable () -> Bool

    package init(services: [String], keychain: any KeychainAPI = SystemKeychain(),
                 signingIdentity: @escaping @Sendable () -> Bool) {
        precondition(!services.isEmpty, "A secure item needs a service")
        self.services = services
        self.keychain = keychain
        self.signingIdentity = signingIdentity
    }

    /// Runs `body` on the shared Keychain queue after the signing check, with legacy
    /// interaction disabled unless the owner explicitly authorized a prompt.
    package func perform<T: Sendable>(_ event: DiagnosticEvent, interactionAllowed: Bool = false,
                                      _ body: @escaping @Sendable (SecureItemAccess) throws -> T) async throws -> T {
        let access = SecureItemAccess(services: services, keychain: keychain)
        let keychain = keychain, signingIdentity = signingIdentity
        return try await KeychainExecutor.run {
            let operation = DiagnosticOperation()
            DiagnosticLog.record(event, component: .keychain, outcome: .started, operation: operation)
            do {
                guard signingIdentity() else { throw EnrollmentIdentityFailure.certificateRequired }
                let result = try KeychainExecutor.withInteraction(allowed: interactionAllowed, keychain: keychain) {
                    try body(access)
                }
                DiagnosticLog.record(event, component: .keychain, outcome: .completed, operation: operation)
                return result
            } catch {
                DiagnosticLog.record(event, component: .keychain, outcome: .failed, operation: operation,
                                     reason: .storage, code: (error as? SecureStorageFailure).map { Int($0.status) })
                throw error
            }
        }
    }
}

/// Item operations, valid only inside `SecureItemStore.perform`.
package struct SecureItemAccess: Sendable {
    fileprivate let services: [String]
    fileprivate let keychain: any KeychainAPI

    /// The first stored item in service order; nil when none exists. An item that
    /// exists without data is returned as empty data for the owner to reject.
    package func load() throws -> Data? {
        for service in services {
            var request = Self.query(service: service)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, result) = keychain.copyMatching(request)
            if status == errSecItemNotFound { continue }
            try Self.check(status)
            return result ?? Data()
        }
        return nil
    }

    package func save(_ data: Data) throws {
        let query = Self.query(service: services[0])
        let status = keychain.update(query, attributes: [kSecValueData as String: data])
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            try Self.check(keychain.add(item))
        } else {
            try Self.check(status)
        }
    }

    /// Re-creates the item so that it belongs to the running build: the Keychain trusts an item's creator by its
    /// signing requirement, so later builds with the same identity read it silently, while an item created by
    /// an earlier identity asks again after every rebuild.
    package func reown(_ data: Data) throws {
        try remove()
        try save(data)
    }

    /// Removes every owned service and reports the first failure.
    package func remove() throws {
        var failure: OSStatus?
        for service in services {
            let status = keychain.delete(Self.query(service: service))
            if status != errSecItemNotFound, status != errSecSuccess { failure = failure ?? status }
        }
        if let failure { try Self.check(failure) }
    }

    // Exact service/account matching in the macOS file-based Keychain without cloud
    // synchronization. No access group or signing entitlement is assumed.
    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "enrollment",
         kSecUseDataProtectionKeychain as String: false,
         kSecAttrSynchronizable as String: false]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw SecureStorageFailure(status: status) }
    }
}

/// SecKeychainSetUserInteractionAllowed affects the whole process. All Keychain work runs on
/// one serial queue, off Swift's cooperative pool, so an owner-approved prompt cannot block
/// shared threads and no two operations interleave the interaction policy.
enum KeychainExecutor {
    private static let queue = DispatchQueue(label: "com.lunlet.keychain", qos: .userInitiated)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    static func withInteraction<T>(allowed: Bool, keychain: any KeychainAPI, body: () throws -> T) throws -> T {
        dispatchPrecondition(condition: .onQueue(queue))
        let (status, previous) = keychain.interactionAllowed()
        guard status == errSecSuccess else { throw SecureStorageFailure(status: status) }
        let policyStatus = keychain.setInteractionAllowed(allowed)
        guard policyStatus == errSecSuccess else {
            _ = keychain.setInteractionAllowed(previous)
            throw SecureStorageFailure(status: policyStatus)
        }
        // Preserve the original access/decoding failure even if restoration
        // also fails. A failed restoration after success remains an error.
        let result = Result { try body() }
        let restored = keychain.setInteractionAllowed(previous)
        switch result {
        case .success(let value):
            guard restored == errSecSuccess else { throw SecureStorageFailure(status: restored) }
            return value
        case .failure(let error): throw error
        }
    }
}

// The file-based implementation needs its legacy interaction switch. These calls
// remain isolated so tests can verify all storage paths without accessing secrets.
package protocol KeychainAPI: Sendable {
    func interactionAllowed() -> (OSStatus, Bool)
    func setInteractionAllowed(_ allowed: Bool) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ item: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

package struct SystemKeychain: KeychainAPI {
    package init() {}
    package func interactionAllowed() -> (OSStatus, Bool) {
        var allowed: DarwinBoolean = false
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        return (status, allowed.boolValue)
    }
    package func setInteractionAllowed(_ allowed: Bool) -> OSStatus {
        SecKeychainSetUserInteractionAllowed(allowed)
    }
    package func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    package func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    package func add(_ item: [String: Any]) -> OSStatus { SecItemAdd(item as CFDictionary, nil) }
    package func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

// Read only this process's public signature. This does not query a keychain,
// enumerate signing identities, or retrieve any certificate private key.
package enum CodeSigningIdentity {
    package static func allowsCredentialAccess() -> Bool {
        var running: SecCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, [], nil) == errSecSuccess else { return false }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let information = information as? [String: Any] else { return false }
        let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        return !certificates.isEmpty
            || Bundle.main.object(forInfoDictionaryKey: "LunletDevelopmentPreview") as? Bool == true
    }
}
