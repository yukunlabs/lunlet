// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.01, AC-01.02, AC-01.04, AC-01.05, AC-01.08; US-12, AC-12.02, AC-12.04.
// Refs: US-22, AC-22.01, AC-22.02, AC-22.03; US-04, AC-04.12.
import Foundation
import Combine
import SwiftUI
import LunletFeishu
import LunletSecureStorage

@MainActor final class FeishuSetupModel: ObservableObject {
    enum State: Equatable {
        case loading, disconnected, requestingCode, saving, stopping, signingRequired
        case awaitingScan(RegistrationCode)
        case enrolled(applicationID: String)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    /// The removal confirmation is showing; removal forgets the connection and a new scan creates another bot.
    @Published var confirmingRemoval = false
    @Published private(set) var platformName = "Feishu"
    var enrollmentChanged: (@MainActor (FeishuEnrollment?) -> Void)?
    /// Delivery owns the check; it ignores requests while one is already running.
    var checkAuthorizationAction: (@MainActor () -> Void)?
    func checkAuthorization() {
        guard case .enrolled = state else { return }
        checkAuthorizationAction?()
    }
    private let registration: RegistrationClient
    private let store: any EnrollmentStoring
    private let ownerMemory: FeishuOwnerMemory
    private var operation: Task<Void, Never>?
    private var loadingSavedAuthorization = false
    private enum Recovery { case load, authorize, register, save(FeishuEnrollment), remove }
    private var recovery: Recovery = .register

    init(registration: RegistrationClient = RegistrationClient(), store: any EnrollmentStoring = MigratingEnrollmentStore.standard(),
         ownerMemory: FeishuOwnerMemory = FeishuOwnerMemory()) {
        self.ownerMemory = ownerMemory
        self.registration = registration
        self.store = store
    }

    func load() async {
        guard state == .loading, !loadingSavedAuthorization else { return }
        loadingSavedAuthorization = true
        defer { loadingSavedAuthorization = false }
        do {
            let saved = try await store.load()
            guard state == .loading else { return }
            platformName = saved?.isLark == true ? "Lark" : "Feishu"
            state = saved.map { .enrolled(applicationID: $0.applicationID) } ?? .disconnected
            enrollmentChanged?(saved)
        } catch EnrollmentIdentityFailure.certificateRequired {
            state = .signingRequired
        } catch {
            recovery = Self.needsAuthorization(error) ? .authorize : .load
            state = .failed(Self.storageMessage(for: error, operation: "read saved authorization"))
        }
    }

    func connect() {
        guard state == .disconnected else { return }
        recovery = .register
        state = .requestingCode
        operation = Task {
            do {
                let code = try await registration.requestCode()
                try Task.checkCancellation()
                state = .awaitingScan(code)
                while let delay = await registration.pollingDelay() {
                    try await Task.sleep(for: .seconds(delay))
                    let result = try await registration.pollAuthorization()
                    try Task.checkCancellation()
                    switch result {
                    case .authorized(let enrollment):
                        await persist(enrollment)
                        return
                    case .failed(let error): throw error
                    default: break
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(Self.message(for: error))
            }
        }
    }

    func removeSetup() {
        guard state != .stopping, state != .loading, state != .signingRequired else { return }
        enrollmentChanged?(nil)
        let previous = operation
        previous?.cancel()
        recovery = .remove
        state = .stopping
        operation = Task {
            // Finish any in-flight credential write before removing local setup.
            await previous?.value
            await registration.cancel()
            do {
                try await store.remove()
                ownerMemory.forget()
                recovery = .register
                platformName = "Feishu"
                state = .disconnected
            } catch EnrollmentIdentityFailure.certificateRequired {
                state = .signingRequired
            } catch {
                state = .failed(Self.storageMessage(for: error, operation: "remove saved authorization"))
            }
        }
    }

    func shutdown() async {
        enrollmentChanged?(nil)
        operation?.cancel()
        await operation?.value
        await registration.cancel()
    }

    /// Only this build's access to a connection an earlier build saved in the Keychain is missing; the connection
    /// itself is intact and one authorization moves it into Lunlet's credential file for good, so authorizing is the
    /// primary action and removal, which would create another Feishu bot on reconnecting, asks first.
    var accessRequired: Bool { if case .authorize = recovery { true } else { false } }
    var retryTitle: String { accessRequired ? "Authorize access" : "Try again" }

    func retry() {
        guard case .failed = state else { return }
        switch recovery {
        case .load:
            state = .loading
            operation = Task { await load() }
        case .authorize:
            state = .loading
            loadingSavedAuthorization = true
            operation = Task {
                defer { loadingSavedAuthorization = false }
                do {
                    let saved = try await store.authorizeSavedEnrollment()
                    try Task.checkCancellation()
                    platformName = saved?.isLark == true ? "Lark" : "Feishu"
                    state = saved.map { .enrolled(applicationID: $0.applicationID) } ?? .disconnected
                    enrollmentChanged?(saved)
                } catch EnrollmentIdentityFailure.certificateRequired {
                    state = .signingRequired
                } catch {
                    guard !Task.isCancelled else { return }
                    recovery = .authorize
                    state = .failed(Self.storageMessage(for: error, operation: "read saved authorization"))
                }
            }
        case .register:
            state = .disconnected
            connect()
        case .save(let enrollment):
            state = .saving
            operation = Task { await persist(enrollment) }
        case .remove:
            removeSetup()
        }
    }

    private func persist(_ enrollment: FeishuEnrollment) async {
        state = .saving
        do {
            try await store.save(enrollment)
            try Task.checkCancellation()
            recovery = .register
            platformName = enrollment.isLark ? "Lark" : "Feishu"
            state = .enrolled(applicationID: enrollment.applicationID)
            enrollmentChanged?(enrollment)
        } catch EnrollmentIdentityFailure.certificateRequired {
            state = .signingRequired
        } catch {
            guard !Task.isCancelled else { return }
            recovery = .save(enrollment)
            state = .failed(Self.storageMessage(for: error, operation: "save authorization"))
        }
    }

    private static func needsAuthorization(_ error: Error) -> Bool {
        (error as? SecureStorageFailure)?.requiresOwnerAuthorization == true
    }

    private static func storageMessage(for error: Error, operation: String) -> String {
        if needsAuthorization(error) {
            return "This build needs your permission to read the saved Feishu connection. The connection itself is intact."
        }
        if (error as? SecureStorageFailure)?.unreadableOnThisMac == true {
            return "The saved Feishu connection cannot be opened on this Mac; it may have been copied from another Mac "
                + "or user account. Remove it and connect again."
        }
        return "Lunlet could not \(operation) on this Mac. Feishu is unavailable. Try again after the storage issue is resolved."
    }

    private static func message(for error: Error) -> String {
        switch error as? RegistrationFailure {
        case .denied: return "Authorization was denied or blocked by your organization. Check access and try again."
        case .expired: return "This authorization code expired. Connect again to get a fresh code."
        case .unverifiedOwner: return "Feishu did not verify an owner. Connect again with your own account."
        case .invalidResponse: return "Feishu returned an unsupported response. Try connecting again."
        default: return "Feishu could not be reached. Check your network and try again."
        }
    }
}

/// One factual connection stage, colored by state: success only for verified facts, running while
/// in progress or armed, attention when the owner must act, failure when a step failed.
struct ReadinessStage: Identifiable, Equatable {
    let id: String
    let value: String
    let symbol: String
    var tone: PanelTone = .neutral
    /// Verified, actionable and failed values take their color; progress and neutral text stays secondary.
    static func valueStyle(_ tone: PanelTone) -> Color {
        switch tone {
        case .success, .attention, .failure: tone.color
        case .muted: Color(nsColor: .tertiaryLabelColor)
        case .running, .neutral: .secondary
        }
    }
}

enum ReadinessWording {
    static func delivery(_ status: CompletionDeliveryStatus) -> ReadinessStage {
        let value: String
        switch status {
        case .unavailable: value = "Unavailable"
        case .ready: value = "Ready when Mac locks"
        case .sending: value = "Sending"
        case .delivered: value = "Last notification delivered"
        case .failed: value = "Failed or unconfirmed"
        }
        return .init(id: "Completion delivery", value: value, symbol: status.symbol, tone: status.tone)
    }
    /// A failed check leaves saved credentials unconfirmed; the global Refresh checks again, nothing retries.
    static func savedAuthorization(_ check: CompletionAuthorizationCheck) -> (String, PanelTone) {
        switch check {
        case .accepted: ("Credentials accepted", .success)
        case .failed: ("Check failed · Refresh to try again", .failure)
        case .checking: ("Checking authorization", .running)
        default: ("Saved on this Mac", .running)
        }
    }
}

/// The channel's overall state from its worst supported stage, shown as a colored icon.
enum ChannelHealth: Equatable {
    case notConnected, pending, connected, needsAction, failed
    init(stages: [ReadinessStage]) {
        let tones = stages.map(\.tone)
        if tones.contains(.failure) { self = .failed }
        else if tones.contains(.attention) { self = .needsAction }
        else if stages.first?.tone == .success { self = .connected }
        else if tones.contains(.running) { self = .pending }
        else { self = .notConnected }
    }
    var word: String {
        switch self {
        case .notConnected: "Not connected"
        case .pending: "Checking"
        case .connected: "Connected"
        case .needsAction: "Action needed"
        case .failed: "Failed"
        }
    }
    var symbol: String {
        switch self {
        case .notConnected: "link.badge.plus"
        case .pending: "clock.fill"
        case .connected: "checkmark.circle.fill"
        case .needsAction: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
    var tone: PanelTone {
        switch self {
        case .notConnected: .neutral
        case .pending: .running
        case .connected: .success
        case .needsAction: .attention
        case .failed: .failure
        }
    }
}

extension FeishuSetupModel {
    /// Delivery success does not authorize callbacks or establish a live CLI adapter.
    func readinessStages(delivery status: CompletionDeliveryStatus,
                         authorization check: CompletionAuthorizationCheck) -> [ReadinessStage] {
        var tone = PanelTone.neutral
        let authorization: String
        switch state {
        case .enrolled: (authorization, tone) = ReadinessWording.savedAuthorization(check)
        case .loading: (authorization, tone) = ("Reading saved authorization", .running)
        case .disconnected: authorization = "Not authorized"
        case .requestingCode, .awaitingScan: (authorization, tone) = ("Awaiting authorization", .attention)
        case .saving: (authorization, tone) = ("Saving authorization", .running)
        case .stopping: (authorization, tone) = ("Disconnecting", .running)
        case .signingRequired: (authorization, tone) = ("Signed build required", .attention)
        case .failed: (authorization, tone) = accessRequired ? ("Access required", .attention) : ("Unavailable", .failure)
        }
        // Only stages this build supports are listed; replies and session input are not offered.
        return [
            .init(id: "Authorization", value: authorization, symbol: "checkmark.shield", tone: tone),
            ReadinessWording.delivery(status)
        ]
    }
}
