// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.04, AC-20.06.
// Refs: US-12, AC-12.02.
import Foundation
import Security
import Testing
import LunletSecureStorage
@testable import LunletMessaging

// Every Security operation is injected; these fixtures never access a keychain.
private final class SyntheticChannelKeychain: KeychainAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: Bool
    private var recorded: [String] = []
    private var records: [String: Data] = [:]
    private var policyStatuses: [OSStatus]
    let itemFailure: OSStatus?
    let policyReadStatus: OSStatus
    let copyDelay: TimeInterval

    init(allowed: Bool = true, itemFailure: OSStatus? = nil,
         policyReadStatus: OSStatus = errSecSuccess, policyStatuses: [OSStatus] = [],
         copyDelay: TimeInterval = 0) {
        self.allowed = allowed; self.itemFailure = itemFailure
        self.policyReadStatus = policyReadStatus; self.policyStatuses = policyStatuses
        self.copyDelay = copyDelay
    }
    var events: [String] { lock.withLock { recorded } }
    var interactionEnabled: Bool { lock.withLock { allowed } }
    func seed(_ data: Data, service: String) { lock.withLock { records[service] = data } }
    func interactionAllowed() -> (OSStatus, Bool) {
        lock.withLock { recorded.append("get"); return (policyReadStatus, allowed) }
    }
    func setInteractionAllowed(_ value: Bool) -> OSStatus {
        lock.withLock {
            recorded.append(value ? "allow" : "deny")
            let status = policyStatuses.isEmpty ? errSecSuccess : policyStatuses.removeFirst()
            if status == errSecSuccess { allowed = value }
            return status
        }
    }
    private func service(_ query: [String: Any]) -> String {
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrAccount as String] as? String == "enrollment")
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        return query[kSecAttrService as String] as? String ?? "invalid"
    }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        let name = service(query)
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        if copyDelay > 0 { Thread.sleep(forTimeInterval: copyDelay) }
        return lock.withLock {
            recorded.append("copy")
            if let itemFailure { return (itemFailure, nil) }
            guard let data = records[name] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        let name = service(query)
        return lock.withLock {
            recorded.append("update")
            if let itemFailure { return itemFailure }
            guard records[name] != nil else { return errSecItemNotFound }
            records[name] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }
    func add(_ item: [String: Any]) -> OSStatus {
        let name = service(item)
        return lock.withLock {
            recorded.append("add")
            if let itemFailure { return itemFailure }
            records[name] = item[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        let name = service(query)
        return lock.withLock {
            recorded.append("delete")
            if let itemFailure { return itemFailure }
            return records.removeValue(forKey: name) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}

@Test func channelCredentialNamespaceIsolationReplacementAndRemoval() async throws {
    let api = SyntheticChannelKeychain()
    let slack = ChannelCredentialStore(channel: .slack, keychain: api)
    let telegram = ChannelCredentialStore(channel: .telegram, keychain: api)
    let first = Data(#"{"token":"synthetic-first"}"#.utf8)
    let second = Data(#"{"token":"synthetic-second"}"#.utf8)
    #expect(try await slack.load() == nil)
    try await slack.save(first)
    try await telegram.save(second)
    #expect(try await slack.load() == first)
    #expect(try await telegram.load() == second)
    try await slack.save(second)
    #expect(try await slack.load() == second)
    try await slack.remove()
    try await slack.remove()
    #expect(try await slack.load() == nil)
    #expect(try await telegram.load() == second)
    let directSlack = ChannelCredentialStore(channel: .slack, keychain: api)
    #expect(try await directSlack.load() == nil)
    try await telegram.remove()
    #expect(try await telegram.load() == nil)
}

@Test func channelCredentialsUseExactServicesAndPreserveOpaqueJSONBytes() async throws {
    let api = SyntheticChannelKeychain()
    let first = Data(#"{ "provider": "slack", "opaque": true }"#.utf8)
    let second = Data(#"{"provider":"telegram"}"#.utf8)
    api.seed(first, service: "com.lunlet.slack")
    api.seed(second, service: "com.lunlet.telegram")
    #expect(try await ChannelCredentialStore(channel: .slack, keychain: api).load() == first)
    #expect(try await ChannelCredentialStore(channel: .telegram, keychain: api).load() == second)
}

@Test func channelCredentialBackgroundOperationsRemainNoninteractiveAndRestorePolicy() async throws {
    for previous in [true, false] {
        let api = SyntheticChannelKeychain(allowed: previous)
        let store = ChannelCredentialStore(channel: .slack, keychain: api)
        #expect(try await store.load() == nil)
        try await store.save(Data(#"{"token":"synthetic"}"#.utf8))
        try await store.remove()
        let restore = previous ? "allow" : "deny"
        #expect(api.events == ["get", "deny", "copy", restore,
                               "get", "deny", "update", "add", restore,
                               "get", "deny", "delete", restore])
        #expect(api.interactionEnabled == previous)
    }
}

@Test func channelCredentialDeliberateAuthorizeRestoresPriorPolicyEvenAfterFailure() async throws {
    for previous in [true, false] {
        for failure: OSStatus? in [nil, errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed] {
            let api = SyntheticChannelKeychain(allowed: previous, itemFailure: failure)
            let store = ChannelCredentialStore(channel: .telegram, keychain: api)
            if let failure {
                await #expect(throws: SecureStorageFailure(status: failure)) { try await store.authorize() }
            } else {
                #expect(try await store.authorize() == nil)
            }
            #expect(api.events == ["get", "allow", "copy", previous ? "allow" : "deny"])
            #expect(api.interactionEnabled == previous)
        }
    }
}

@Test func unsignedChannelCredentialOperationsStopBeforeEverySecurityCall() async throws {
    let api = SyntheticChannelKeychain()
    let store = ChannelCredentialStore(channel: .slack, keychain: api, signingIdentity: { false })
    await #expect(throws: EnrollmentIdentityFailure.certificateRequired) { try await store.load() }
    await #expect(throws: EnrollmentIdentityFailure.certificateRequired) { try await store.authorize() }
    await #expect(throws: EnrollmentIdentityFailure.certificateRequired) {
        try await store.save(Data(#"{"token":"synthetic"}"#.utf8))
    }
    await #expect(throws: EnrollmentIdentityFailure.certificateRequired) { try await store.remove() }
    #expect(api.events.isEmpty)
}

// Saved credentials depend on these exact services; channels outside BotChannel are unrepresentable.
@Test func channelCredentialServicesStayFixedForSavedCredentialCompatibility() {
    #expect(ChannelCredentialStore.service(for: .slack) == "com.lunlet.slack")
    #expect(ChannelCredentialStore.service(for: .telegram) == "com.lunlet.telegram")
}

@Test func channelCredentialRejectsMalformedAndOversizeRecordsWithoutWriting() async throws {
    let api = SyntheticChannelKeychain()
    let store = ChannelCredentialStore(channel: .slack, keychain: api)
    let maximum = Data((#"{"value":""# + String(repeating: "x", count: 65_524) + #""}"#).utf8)
    #expect(maximum.count == 65_536)
    try await store.save(maximum)
    #expect(try await store.load() == maximum)
    for data in [Data(), Data("{".utf8), Data("null".utf8), Data("[]".utf8), maximum + Data(" ".utf8)] {
        await #expect(throws: SecureStorageFailure(status: errSecParam)) { try await store.save(data) }
        #expect(try await store.load() == maximum)
    }
    #expect(api.events.filter { $0 == "update" }.count == 1)
    for data in [Data(), Data("not-json".utf8), Data("[]".utf8), maximum + Data(" ".utf8)] {
        api.seed(data, service: "com.lunlet.slack")
        await #expect(throws: SecureStorageFailure(status: errSecDecode)) { try await store.load() }
        #expect(api.interactionEnabled)
    }
}

@Test func channelCredentialPolicyFailuresStopItemAccessAndPreserveOriginalErrors() async throws {
    for api in [SyntheticChannelKeychain(policyReadStatus: errSecParam),
                SyntheticChannelKeychain(policyStatuses: [errSecParam, errSecSuccess])] {
        let store = ChannelCredentialStore(channel: .telegram, keychain: api)
        await #expect(throws: SecureStorageFailure(status: errSecParam)) { try await store.load() }
        #expect(!api.events.contains("copy"))
        #expect(api.interactionEnabled)
    }
    let restorationFailure = SyntheticChannelKeychain(policyStatuses: [errSecSuccess, errSecParam])
    let failedLoad = ChannelCredentialStore(channel: .telegram, keychain: restorationFailure)
    await #expect(throws: SecureStorageFailure(status: errSecParam)) { try await failedLoad.load() }
    let originalFailure = SyntheticChannelKeychain(itemFailure: errSecAuthFailed,
                                                  policyStatuses: [errSecSuccess, errSecParam])
    let denied = ChannelCredentialStore(channel: .telegram, keychain: originalFailure)
    await #expect(throws: SecureStorageFailure(status: errSecAuthFailed)) { try await denied.load() }
}

@Test func failedChannelCredentialWritesAndRemovalRestoreSilentPolicyWithoutRetry() async throws {
    let api = SyntheticChannelKeychain(itemFailure: errSecAuthFailed)
    let store = ChannelCredentialStore(channel: .slack, keychain: api)
    await #expect(throws: SecureStorageFailure(status: errSecAuthFailed)) {
        try await store.save(Data(#"{"token":"synthetic"}"#.utf8))
    }
    await #expect(throws: SecureStorageFailure(status: errSecAuthFailed)) { try await store.remove() }
    #expect(api.events == ["get", "deny", "update", "allow", "get", "deny", "delete", "allow"])
    #expect(api.interactionEnabled)
}
