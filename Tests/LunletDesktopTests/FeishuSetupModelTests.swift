// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.02, AC-01.04, AC-01.08; US-12, AC-12.02.
// Refs: US-22, AC-22.01, AC-22.02, AC-22.03; US-04, AC-04.12.
import Foundation
import Testing
import LunletSecureStorage
@testable import LunletDesktop
@testable import LunletFeishu

private actor RecoverableStorage: EnrollmentStoring {
    enum Failure: Error { case unavailable }
    private var failLoad: Bool
    private var failRemoval: Bool
    private var failSave: Bool
    private var accessDenied: Bool
    private var saved: FeishuEnrollment?

    init(failLoad: Bool = false, failRemoval: Bool = false, failSave: Bool = false, accessDenied: Bool = false, isLark: Bool = false) {
        self.failLoad = failLoad
        self.failRemoval = failRemoval
        self.failSave = failSave
        self.accessDenied = accessDenied
        saved = FeishuEnrollment(applicationID: "cli_synthetic", scannedOwnerID: "ou_synthetic",
                                 secret: "synthetic-secret", isLark: isLark)
    }

    func load() throws -> FeishuEnrollment? {
        if failLoad { failLoad = false; throw Failure.unavailable }
        if accessDenied { accessDenied = false; throw SecureStorageFailure(status: -25293) }
        return saved
    }
    func save(_ enrollment: FeishuEnrollment) throws {
        if failSave { failSave = false; throw Failure.unavailable }
        saved = enrollment
    }
    func remove() throws {
        if failRemoval { failRemoval = false; throw Failure.unavailable }
        saved = nil
    }
}

private final class SetupResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    func reset() { lock.withLock { index = 0 } }
    func next() -> String? {
        lock.withLock {
            defer { index += 1 }
            switch index {
            case 0: return #"{"device_code":"synthetic-device-code","verification_uri_complete":"https://open.feishu.cn/page/launcher?user_code=synthetic","interval":1,"expires_in":3600}"#
            case 1: return #"{"client_id":"cli_created","client_secret":"synthetic-secret","user_info":{"open_id":"ou_synthetic","tenant_brand":"feishu"}}"#
            default: return nil
            }
        }
    }
}

private final class SetupHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let replies = SetupResponses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let json = Self.replies.next() else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private func eventually(_ expected: FeishuSetupModel.State, in model: FeishuSetupModel) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while model.state != expected, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.state == expected)
}

@Test @MainActor func retryAfterKeychainUnlockRestoresTheExistingEnrollment() async throws {
    let model = FeishuSetupModel(store: RecoverableStorage(failLoad: true))
    await model.load()
    guard case .failed = model.state else { Issue.record("Storage failure should be recoverable"); return }
    model.retry()
    try await eventually(.enrolled(applicationID: "cli_synthetic"), in: model)
}

// Refs: US-01, AC-01.05: when only Keychain access is missing, the connection is intact, so authorizing is
// the primary action, the message says what the prompt is for, and the retry restores the saved connection.
@Test @MainActor func aBuildWithoutKeychainAccessOffersOnlyAuthorization() async throws {
    let model = FeishuSetupModel(store: RecoverableStorage(accessDenied: true))
    await model.load()
    guard case .failed(let message) = model.state else { Issue.record("Denied access should be recoverable"); return }
    #expect(model.accessRequired && model.retryTitle == "Authorize access" && message.contains("permission"))
    let generic = FeishuSetupModel(store: RecoverableStorage(failLoad: true))
    await generic.load()
    #expect(!generic.accessRequired && generic.retryTitle == "Try again")
    model.retry()
    try await eventually(.enrolled(applicationID: "cli_synthetic"), in: model)
}

@Test @MainActor func retryOfFailedRemovalRemovesSetupInsteadOfRegisteringAnotherApp() async throws {
    let model = FeishuSetupModel(store: RecoverableStorage(failRemoval: true))
    await model.load()
    model.removeSetup()
    let deadline = ContinuousClock.now + .seconds(10)
    while model.state == .stopping, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    guard case .failed = model.state else { Issue.record("Removal failure should be recoverable"); return }
    model.retry()
    try await eventually(.disconnected, in: model)
}

@Test @MainActor func retryOfFailedSavePersistsTheAlreadyAuthorizedEnrollment() async throws {
    SetupHTTPProtocol.replies.reset()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SetupHTTPProtocol.self]
    let registration = RegistrationClient(configuration: config, uptime: { ProcessInfo.processInfo.systemUptime })
    let storage = RecoverableStorage(failSave: true)
    let model = FeishuSetupModel(registration: registration, store: storage)
    await model.load()
    model.removeSetup()
    try await eventually(.disconnected, in: model)
    model.connect()
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if case .failed = model.state { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    guard case .failed = model.state else { Issue.record("Credential write failure should be recoverable"); return }
    await registration.cancel()
    model.retry()
    try await eventually(.enrolled(applicationID: "cli_created"), in: model)
    #expect(try await storage.load()?.applicationID == "cli_created")
}

@Test @MainActor func footerIdentifiesSavedPlatformWithoutClaimingAConnection() async throws {
    for (isLark, name) in [(false, "Feishu"), (true, "Lark")] {
        let model = FeishuSetupModel(store: RecoverableStorage(isLark: isLark))
        var enrollmentChanges: [FeishuEnrollment?] = []
        model.enrollmentChanged = { enrollmentChanges.append($0) }
        await model.load()
        #expect(enrollmentChanges.count == 1 && enrollmentChanges[0]?.isLark == isLark)
        #expect(model.platformName == name)
        model.removeSetup()
        try await eventually(.disconnected, in: model)
        #expect(model.platformName == "Feishu")
        #expect(enrollmentChanges.count == 2 && enrollmentChanges[1] == nil)
        await model.shutdown()
    }
}

private actor DeniedEnrollmentStorage: EnrollmentStoring {
    let status: Int32
    private(set) var loads = 0
    private(set) var saves = 0
    private(set) var removals = 0
    init(status: Int32) { self.status = status }
    func load() throws -> FeishuEnrollment? { loads += 1; throw SecureStorageFailure(status: status) }
    func save(_ enrollment: FeishuEnrollment) throws { saves += 1; throw SecureStorageFailure(status: status) }
    func remove() throws { removals += 1; throw SecureStorageFailure(status: status) }
}

@Test @MainActor func deniedEnrollmentDoesNotRetryDeleteOrClaimTheKeychainIsLocked() async {
    // Access denial and a silent authentication requirement do not establish a locked keychain.
    for status: Int32 in [-128, -25293, -25308] {
        let storage = DeniedEnrollmentStorage(status: status)
        let model = FeishuSetupModel(store: storage)
        await model.load()
        guard case .failed(let message) = model.state else { Issue.record("Access failure must remain unavailable"); continue }
        #expect(!message.localizedCaseInsensitiveContains("unlock"))
        await model.load()
        model.connect()
        #expect(await storage.loads == 1)
        #expect(await storage.saves == 0)
        #expect(await storage.removals == 0)
        #expect(model.readinessStages(delivery: .unavailable, authorization: .unavailable)[0].value == "Access required")
        model.retry()
        for _ in 0..<100 where await storage.loads < 2 { await Task.yield() }
        #expect(await storage.loads == 2)
        await model.shutdown()
    }
}


private actor DelayedDeniedStorage: EnrollmentStoring {
    private(set) var loads = 0
    func load() async throws -> FeishuEnrollment? {
        loads += 1
        try await Task.sleep(for: .milliseconds(30))
        throw SecureStorageFailure(status: -128)
    }
    func save(_ enrollment: FeishuEnrollment) {}
    func remove() {}
}

@Test @MainActor func overlappingPanelLoadsShareOneCredentialAttempt() async {
    let storage = DelayedDeniedStorage(), model = FeishuSetupModel(store: storage)
    async let first: Void = model.load()
    async let second: Void = model.load()
    _ = await (first, second)
    #expect(await storage.loads == 1)
    guard case .failed = model.state else { Issue.record("Denied storage stays unavailable"); return }
    await model.shutdown()
}

private actor UnsignedEnrollmentStorage: EnrollmentStoring {
    private(set) var loads = 0
    private(set) var removals = 0
    func load() throws -> FeishuEnrollment? { loads += 1; throw EnrollmentIdentityFailure.certificateRequired }
    func save(_ enrollment: FeishuEnrollment) throws { throw EnrollmentIdentityFailure.certificateRequired }
    func remove() { removals += 1 }
}

@Test @MainActor func unsignedNormalBuildDoesNotOfferFutileRetryOrNewBotAuthorization() async {
    let storage = UnsignedEnrollmentStorage(), model = FeishuSetupModel(store: storage)
    await model.load()
    #expect(model.state == .signingRequired)
    model.retry(); model.connect(); model.removeSetup(); await model.load()
    #expect(model.state == .signingRequired)
    #expect(await storage.loads == 1)
    #expect(await storage.removals == 0)
    await model.shutdown()
}

@Test @MainActor func successfulDeliveryDoesNotClaimReplyOrOriginalSessionReadiness() async {
    let model = FeishuSetupModel(store: RecoverableStorage())
    await model.load()
    let stages = model.readinessStages(delivery: .delivered, authorization: .notChecked)
    #expect(stages.map(\.id) == ["Authorization", "Completion delivery"])
    #expect(stages[0].value == "Saved on this Mac")
    #expect(stages[1].value == "Last notification delivered")
    let failed = model.readinessStages(delivery: .failed, authorization: .accepted)
    #expect(failed[1].value == "Failed or unconfirmed")
    #expect(failed[0].value == "Credentials accepted")
    // AC-22.03 (revised): only supported stages are listed, colored by state — verified facts green,
    // armed or in-progress blue, failures red — and the overall health follows the worst stage.
    #expect(stages[1].tone == .success && failed[1].tone == .failure && failed[0].tone == .success)
    for status in [CompletionDeliveryStatus.unavailable, .ready, .sending] {
        #expect(model.readinessStages(delivery: status, authorization: .accepted)[1].tone != .success)
    }
    let armed = model.readinessStages(delivery: .ready, authorization: .accepted)
    #expect(armed[1].tone == .running && ChannelHealth(stages: armed) == .connected)
    #expect(ChannelHealth(stages: failed) == .failed)
    #expect(ChannelHealth(stages: model.readinessStages(delivery: .ready, authorization: .notChecked)) == .pending)
    // AC-04.12: a failed check stays unconfirmed and names Refresh, which checks again without automatic retries.
    let unchecked = model.readinessStages(delivery: .ready, authorization: .failed)[0]
    #expect(unchecked.value == "Check failed · Refresh to try again" && unchecked.tone == .failure)
    await model.shutdown()
}
