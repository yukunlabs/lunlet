// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-12, AC-12.02.
// Refs: US-01, AC-01.02, AC-01.04, AC-01.05.
import Foundation
import Testing
import LunletSecureStorage
@testable import LunletFeishu

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_KEYCHAIN"] == "1"))
func realKeychainRoundTripAndRemovalAffectOnlyTheOwnedNamespace() async throws {
    let service = "com.lunlet.tests.\(UUID().uuidString)"
    let store = EnrollmentStore(service: service)
    let other = EnrollmentStore(service: service + ".other")
    let first = FeishuEnrollment(applicationID: "cli_synthetic", scannedOwnerID: "ou_synthetic",
                                  secret: "synthetic-secret", isLark: false)
    let replacement = FeishuEnrollment(applicationID: "cli_synthetic_next", scannedOwnerID: "ou_synthetic_next",
                                        secret: "synthetic-replacement", isLark: true)
    do {
        #expect(try await store.load() == nil)
        try await other.save(first)
        try await store.save(first)
        #expect(try await store.load() == first)
        try await store.save(replacement)
        #expect(try await store.load() == replacement)
        try await store.remove()
        #expect(try await store.load() == nil)
        #expect(try await other.load() == first)
        try await other.remove()
    } catch {
        try? await store.remove()
        try? await other.remove()
        throw error
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_KEYCHAIN"] == "1"))
func renamedServiceReadsOldEnrollmentPrefersNewAndDisconnectClearsBoth() async throws {
    let service = "com.lunlet.tests.\(UUID().uuidString)"
    let legacy = EnrollmentStore(service: service + ".legacy")
    let primary = EnrollmentStore(service: service)
    let store = EnrollmentStore(service: service, legacyService: service + ".legacy")
    let old = FeishuEnrollment(applicationID: "cli_old", scannedOwnerID: "ou_synthetic", secret: "synthetic-old", isLark: false)
    let new = FeishuEnrollment(applicationID: "cli_new", scannedOwnerID: "ou_synthetic", secret: "synthetic-new", isLark: false)
    do {
        try await legacy.save(old)
        #expect(try await store.load() == old)
        try await store.save(new)
        #expect(try await primary.load() == new)
        #expect(try await store.load() == new)
        try await store.remove()
        #expect(try await legacy.load() == nil)
        #expect(try await primary.load() == nil)
        #expect(try await store.load() == nil)
    } catch {
        try? await primary.remove()
        try? await legacy.remove()
        throw error
    }
}

// These tests inject every Security call; they never access a system keychain.
private final class SyntheticEnrollmentKeychain: KeychainAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: Bool
    private var recorded: [String] = []
    let expectedInteraction: Bool?
    let itemStatus: Int32
    let policyReadStatus: Int32
    let policyWriteStatus: Int32
    init(allowed: Bool = true, itemStatus: Int32 = -25300,
         policyReadStatus: Int32 = 0, policyWriteStatus: Int32 = 0, expectedInteraction: Bool? = false) {
        self.expectedInteraction = expectedInteraction
        self.allowed = allowed; self.itemStatus = itemStatus
        self.policyReadStatus = policyReadStatus; self.policyWriteStatus = policyWriteStatus
    }
    var events: [String] { lock.withLock { recorded } }
    var interactionEnabled: Bool { lock.withLock { allowed } }
    func interactionAllowed() -> (Int32, Bool) {
        lock.withLock { recorded.append("get"); return (policyReadStatus, allowed) }
    }
    func setInteractionAllowed(_ value: Bool) -> Int32 {
        lock.withLock {
            recorded.append(value ? "allow" : "deny")
            if policyWriteStatus == 0 { allowed = value }
            return policyWriteStatus
        }
    }
    private func item(_ name: String) -> Int32 {
        lock.withLock {
            recorded.append(name)
            if let expectedInteraction { #expect(allowed == expectedInteraction) }
            return itemStatus
        }
    }
    func copyMatching(_ query: [String: Any]) -> (Int32, Data?) { (item("copy"), nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> Int32 { item("update") }
    func add(_ item: [String: Any]) -> Int32 {
        let status = self.item("add"); return status == -25300 ? 0 : status
    }
    func delete(_ query: [String: Any]) -> Int32 { item("delete") }
}

@Test func enrollmentOperationsDisableLegacyInteractionAndRestoreThePriorPolicy() async throws {
    for previouslyAllowed in [true, false] {
        let api = SyntheticEnrollmentKeychain(allowed: previouslyAllowed)
        let store = EnrollmentStore(service: "synthetic", keychain: api)
        #expect(try await store.load() == nil)
        try await store.save(.init(applicationID: "cli_synthetic", scannedOwnerID: "ou_synthetic",
                                   secret: "synthetic-secret", isLark: false))
        try await store.remove()
        let restore = previouslyAllowed ? "allow" : "deny"
        #expect(api.events == ["get", "deny", "copy", restore,
                               "get", "deny", "update", "add", restore,
                               "get", "deny", "delete", restore])
        #expect(api.interactionEnabled == previouslyAllowed)
    }
}

@Test func deniedEnrollmentAccessRestoresPolicyAndDoesNotFallBackToAnotherService() async {
    for status: Int32 in [-128, -25293, -25308, -26275] {
        let api = SyntheticEnrollmentKeychain(itemStatus: status)
        let store = EnrollmentStore(service: "synthetic", legacyService: "synthetic.legacy", keychain: api)
        await #expect(throws: SecureStorageFailure(status: status)) { try await store.load() }
        #expect(api.events == ["get", "deny", "copy", "allow"])
        #expect(api.interactionEnabled)
    }
}

@Test func enrollmentDoesNotTouchItemsIfSilentAccessCannotBeEstablished() async {
    for (readStatus, writeStatus): (Int32, Int32) in [(-50, 0), (0, -50)] {
        let api = SyntheticEnrollmentKeychain(policyReadStatus: readStatus, policyWriteStatus: writeStatus)
        let store = EnrollmentStore(service: "synthetic", keychain: api)
        await #expect(throws: SecureStorageFailure(status: -50)) { try await store.load() }
        #expect(!api.events.contains("copy"))
        #expect(api.interactionEnabled)
    }
}

@Test func failedEnrollmentWritesAndRemovalAlsoRestoreSilentInteraction() async {
    let enrollment = FeishuEnrollment(applicationID: "cli_synthetic", scannedOwnerID: "ou_synthetic",
                                       secret: "synthetic-secret", isLark: false)
    let api = SyntheticEnrollmentKeychain(itemStatus: -25293)
    let store = EnrollmentStore(service: "synthetic", keychain: api)
    await #expect(throws: SecureStorageFailure(status: -25293)) { try await store.save(enrollment) }
    await #expect(throws: SecureStorageFailure(status: -25293)) { try await store.remove() }
    #expect(api.events == ["get", "deny", "update", "allow", "get", "deny", "delete", "allow"])
    #expect(api.interactionEnabled)
}

@Test func silentPolicyIsSerializedAcrossIndependentEnrollmentStores() async throws {
    let api = SyntheticEnrollmentKeychain()
    let stores = (0..<20).map { EnrollmentStore(service: "synthetic.\($0)", keychain: api) }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for store in stores { group.addTask { let loaded = try await store.load(); #expect(loaded == nil) } }
        try await group.waitForAll()
    }
    #expect(api.events == Array(repeating: ["get", "deny", "copy", "allow"], count: 20).flatMap { $0 })
    #expect(api.interactionEnabled)
}

@Test func anUnstableApplicationIdentityCannotReadWriteOrRemoveAnyCredential() async {
    let api = SyntheticEnrollmentKeychain()
    let store = EnrollmentStore(service: "synthetic", keychain: api, signingIdentity: { false })
    let value = FeishuEnrollment(applicationID: "cli_synthetic", scannedOwnerID: "ou_synthetic",
                                  secret: "synthetic-secret", isLark: false)
    await #expect(throws: EnrollmentIdentityFailure.certificateRequired) { try await store.load() }
    await #expect(throws: EnrollmentIdentityFailure.certificateRequired) { try await store.save(value) }
    await #expect(throws: EnrollmentIdentityFailure.certificateRequired) { try await store.remove() }
    #expect(api.events.isEmpty)
}


/// A keychain holding one item, so authorization can show what happens to it; the status of every item call is recorded.
private final class SyntheticOwnedKeychain: KeychainAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var allowed = true
    private var recorded: [String] = []
    init(stored: Data?) { self.stored = stored }
    var events: [String] { lock.withLock { recorded } }
    var data: Data? { lock.withLock { stored } }
    func interactionAllowed() -> (Int32, Bool) { lock.withLock { (0, allowed) } }
    func setInteractionAllowed(_ value: Bool) -> Int32 { lock.withLock { allowed = value; return 0 } }
    func copyMatching(_ query: [String: Any]) -> (Int32, Data?) {
        lock.withLock { recorded.append("copy"); return stored == nil ? (-25300, nil) : (0, stored) }
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> Int32 {
        lock.withLock {
            recorded.append("update")
            guard stored != nil else { return -25300 }
            stored = attributes[kSecValueData as String] as? Data; return 0
        }
    }
    func add(_ item: [String: Any]) -> Int32 {
        lock.withLock { recorded.append("add"); stored = item[kSecValueData as String] as? Data; return 0 }
    }
    func delete(_ query: [String: Any]) -> Int32 { lock.withLock { recorded.append("delete"); stored = nil; return 0 } }
}

// Refs: US-01, AC-01.05: an authorized enrollment is re-created by the running build, so the next build with the same
// signing identity reads it without another prompt; a missing item is left alone.
@Test func authorizingASavedEnrollmentReownsItForTheRunningBuild() async throws {
    let enrollment = FeishuEnrollment(applicationID: "cli_synthetic", scannedOwnerID: "ou_synthetic",
                                      secret: "synthetic-secret", isLark: true)
    let seed = SyntheticOwnedKeychain(stored: nil)
    try await EnrollmentStore(service: "synthetic", keychain: seed).save(enrollment)
    let api = SyntheticOwnedKeychain(stored: seed.data)
    let store = EnrollmentStore(service: "synthetic", legacyService: "synthetic.legacy", keychain: api)
    #expect(try await store.authorizeSavedEnrollment() == enrollment)
    #expect(api.events == ["copy", "delete", "delete", "update", "add"] && api.data == seed.data)
    #expect(try await store.load() == enrollment)
    let empty = SyntheticOwnedKeychain(stored: nil)
    #expect(try await EnrollmentStore(service: "synthetic", keychain: empty).authorizeSavedEnrollment() == nil)
    #expect(empty.events == ["copy"])
}

@Test func onlyAnExplicitOwnerActionAllowsAKeychainPromptAndRestoresThePriorPolicy() async throws {
    let api = SyntheticEnrollmentKeychain(expectedInteraction: nil)
    let store = EnrollmentStore(service: "synthetic", keychain: api)
    #expect(try await store.load() == nil)
    #expect(try await store.authorizeSavedEnrollment() == nil)
    #expect(try await store.load() == nil)
    #expect(api.events == ["get", "deny", "copy", "allow", "get", "allow", "copy", "allow",
                           "get", "deny", "copy", "allow"])
}
