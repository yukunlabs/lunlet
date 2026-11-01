// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-12, AC-12.02.
// Refs: US-20, AC-20.04, AC-20.06 (shared process interaction policy).
import Foundation
import Security
import Testing
@testable import LunletSecureStorage

// Every Security operation is injected; these fixtures never access a keychain.
private final class SyntheticKeychain: KeychainAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    private var recorded: [String] = []
    private var records: [String: Data] = [:]
    let copyDelay: TimeInterval
    let onCopy: (@Sendable () -> Void)?

    init(copyDelay: TimeInterval = 0, onCopy: (@Sendable () -> Void)? = nil) {
        self.copyDelay = copyDelay; self.onCopy = onCopy
    }
    var events: [String] { lock.withLock { recorded } }
    var interactionEnabled: Bool { lock.withLock { allowed } }
    func seed(_ data: Data, service: String) { lock.withLock { records[service] = data } }
    func interactionAllowed() -> (OSStatus, Bool) { lock.withLock { recorded.append("get"); return (errSecSuccess, allowed) } }
    func setInteractionAllowed(_ value: Bool) -> OSStatus {
        lock.withLock { recorded.append(value ? "allow" : "deny"); allowed = value; return errSecSuccess }
    }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        onCopy?()
        if copyDelay > 0 { Thread.sleep(forTimeInterval: copyDelay) }
        let service = query[kSecAttrService as String] as? String ?? "invalid"
        return lock.withLock {
            recorded.append("copy")
            guard let data = records[service] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { errSecItemNotFound }
    func add(_ item: [String: Any]) -> OSStatus { errSecSuccess }
    func delete(_ query: [String: Any]) -> OSStatus { errSecItemNotFound }
}

@Test func everyChannelStoreSharesOneProcessInteractionQueue() async throws {
    let api = SyntheticKeychain(copyDelay: 0.001)
    let stores = ["com.lunlet.feishu", "com.lunlet.slack", "com.lunlet.telegram"].map {
        SecureItemStore(services: [$0], keychain: api, signingIdentity: { true })
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<12 {
            for (index, store) in stores.enumerated() {
                group.addTask { _ = try await store.perform(.storageLoad, interactionAllowed: index == 1) { try $0.load() } }
            }
        }
        try await group.waitForAll()
    }
    let events = api.events
    #expect(events.count == 144)
    for offset in stride(from: 0, to: events.count, by: 4) {
        #expect(events[offset] == "get")
        #expect(["allow", "deny"].contains(events[offset + 1]))
        #expect(events[offset + 2] == "copy")
        #expect(events[offset + 3] == "allow")
    }
    #expect(api.interactionEnabled)
}

@Test func keychainWorkRunsOnTheDedicatedQueueAndKeepsFallbackOrder() async throws {
    let labels = LabelRecorder()
    let api = SyntheticKeychain(onCopy: { labels.record(String(cString: __dispatch_queue_get_label(nil))) })
    api.seed(Data("legacy".utf8), service: "legacy")
    let store = SecureItemStore(services: ["current", "legacy"], keychain: api, signingIdentity: { true })
    #expect(try await store.perform(.storageLoad) { try $0.load() } == Data("legacy".utf8))
    api.seed(Data("current".utf8), service: "current")
    #expect(try await store.perform(.storageLoad) { try $0.load() } == Data("current".utf8))
    #expect(labels.values.count == 3 && labels.values.allSatisfy { $0 == "com.lunlet.keychain" })
}

private final class LabelRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.withLock { recorded } }
    func record(_ label: String) { lock.withLock { recorded.append(label) } }
}
