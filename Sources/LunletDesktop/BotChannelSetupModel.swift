// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.01, AC-20.02, AC-20.04, AC-20.05, AC-20.06; US-12, AC-12.02, AC-12.04.
// Refs: US-22, AC-22.01, AC-22.02, AC-22.03.
import Foundation
import Combine
import LunletCore
import LunletMessaging
import LunletSecureStorage

@MainActor final class BotChannelSetupModel: ObservableObject {
    enum State: Equatable { case disconnected, loading, connecting, pairing, saving, disconnecting, enrolled, failed, accessRequired, signingRequired }
    @Published private(set) var state = State.disconnected
    @Published private(set) var channel: BotChannel?
    @Published private(set) var identity: BotIdentity?
    @Published private(set) var challenge: PairingChallenge?
    @Published private(set) var binding: BotBinding?
    @Published private(set) var issue: String?
    /// Tokens typed into the setup card but not yet connected. They live here rather than in the card, so leaving the
    /// panel to copy the second token from the browser does not clear the first; they are dropped on connect, cancel,
    /// disconnect, a channel change and shutdown, and are never saved (AC-20.04).
    @Published var draftBotToken = ""
    @Published var draftAppToken = ""
    /// True after the saved connection could not be read or written, when reloading it makes sense.
    @Published private(set) var reloadAvailable = false
    /// Delivery owns the check; it ignores requests while one is already running.
    var checkAuthorizationAction: (@MainActor () -> Void)?
    var enrollmentChanged: (@MainActor (BotEnrollment?) -> Void)?
    private let storeFactory: @Sendable (BotChannel) throws -> any ChannelCredentialStoring
    private let clientFactory: @Sendable (BotCredentials) -> any ChannelBotClient
    private var operation: Task<Void, Never>?
    private var pairingClient: (any ChannelBotClient)?
    private var pendingSave: BotEnrollment?
    private var cleanup: [Task<Void, Never>] = []
    private var revision = UUID()
    private var closed = false

    init(storeFactory: @escaping @Sendable (BotChannel) throws -> any ChannelCredentialStoring = { MigratingChannelCredentialStore.standard(channel: $0) },
         clientFactory: @escaping @Sendable (BotCredentials) -> any ChannelBotClient = BotClientFactory.client) {
        self.storeFactory = storeFactory; self.clientFactory = clientFactory
    }
    func select(_ channel: BotChannel?) {
        guard !closed, self.channel != channel else { return }
        invalidate()
        self.channel = channel; reset()
        guard let channel else { state = .disconnected; return }
        load(channel, authorized: false)
    }
    func reload() {
        guard !closed, operation == nil, let channel else { return }
        load(channel, authorized: false)
    }
    func authorize() {
        guard !closed, state == .accessRequired, operation == nil, let channel else { return }
        load(channel, authorized: true)
    }
    private func load(_ channel: BotChannel, authorized: Bool) {
        let current = revision, preceding = cleanup
        state = .loading; issue = nil
        operation = Task {
            defer { if revision == current { operation = nil } }
            do {
                try await settle(preceding, revision: current)
                let store = try storeFactory(channel)
                let data = try await (authorized ? store.authorize() : store.load())
                try Task.checkCancellation()
                guard valid(current) else { return }
                if authorized, let pendingSave {
                    try await store.save(JSONEncoder().encode(pendingSave))
                    try Task.checkCancellation()
                    guard valid(current) else { return }
                    activate(pendingSave)
                } else if let data { activate(try BotEnrollment.decode(data, channel: channel)) }
                else { state = .disconnected }
            } catch { if valid(current), !Task.isCancelled { storageFailed(error) } }
        }
    }
    func connect(_ credentials: BotCredentials) {
        guard !closed, operation == nil, channel == credentials.channel,
              state == .disconnected || state == .failed else { return }
        let current = revision, client = clientFactory(credentials), preceding = cleanup
        pairingClient = client; state = .connecting; issue = nil; pendingSave = nil
        draftBotToken = ""; draftAppToken = ""
        // The bot check and the pairing are logged as two stages of one operation (AC-14.01, AC-14.02).
        let component: DiagnosticComponent = credentials.channel == .slack ? .slack : .telegram
        let diagnostic = DiagnosticOperation()
        DiagnosticLog.record(.authentication, component: component, outcome: .started, operation: diagnostic)
        operation = Task {
            defer { if revision == current { operation = nil; pairingClient = nil } }
            do {
                try await settle(preceding, revision: current)
                let identity = try await client.prepare()
                try Task.checkCancellation()
                guard valid(current), identity.channel == credentials.channel else { throw BotChannelFailure.identityMismatch }
                DiagnosticLog.record(.authentication, component: component, outcome: .completed, operation: diagnostic)
                self.identity = identity
                let challenge = PairingChallenge()
                self.challenge = challenge; state = .pairing
                DiagnosticLog.record(.registration, component: component, outcome: .started, operation: diagnostic)
                let binding = try await client.pair(challenge)
                try Task.checkCancellation()
                guard valid(current) else { return }
                guard binding.channel == identity.channel, binding.botID == identity.id,
                      binding.workspaceID == identity.workspaceID, binding.applicationID == identity.applicationID else {
                    throw BotChannelFailure.identityMismatch
                }
                DiagnosticLog.record(.registration, component: component, outcome: .completed, operation: diagnostic)
                let enrollment = try BotEnrollment(credentials: credentials, binding: binding)
                await client.close()
                try Task.checkCancellation()
                guard valid(current) else { return }
                pendingSave = enrollment; state = .saving; self.challenge = nil
                do {
                    let store = try storeFactory(credentials.channel)
                    try await store.save(JSONEncoder().encode(enrollment))
                    try Task.checkCancellation()
                    guard valid(current) else { return }
                    activate(enrollment)
                } catch { if valid(current), !Task.isCancelled { storageFailed(error) } }
            } catch {
                await client.close()
                guard valid(current), !Task.isCancelled else { return }
                DiagnosticLog.record(state == .pairing ? .registration : .authentication, component: component, outcome: .failed,
                                     operation: diagnostic, reason: (error as? BotChannelFailure).map(DiagnosticReason.init) ?? .unknown)
                challenge = nil; state = .failed; reloadAvailable = false; issue = Self.message(error)
            }
        }
    }
    func cancel() {
        guard !closed, [.connecting, .pairing, .saving].contains(state) else { return }
        invalidate(); reset(); state = .disconnected
    }
    func disconnect() {
        guard !closed, let channel else { return }
        invalidate(); reset(); state = .disconnecting
        let current = revision, preceding = cleanup
        operation = Task {
            defer { if revision == current { operation = nil } }
            do {
                try await settle(preceding, revision: current)
                let store = try storeFactory(channel)
                try await store.remove()
                try Task.checkCancellation()
                guard valid(current) else { return }
                state = .disconnected
            } catch { if valid(current), !Task.isCancelled { storageFailed(error) } }
        }
    }
    func checkAuthorization() {
        guard state == .enrolled else { return }
        checkAuthorizationAction?()
    }
    private func activate(_ enrollment: BotEnrollment) {
        binding = enrollment.binding; pendingSave = nil; challenge = nil
        identity = .init(channel: enrollment.binding.channel, id: enrollment.binding.botID, name: enrollment.binding.botName,
            workspaceID: enrollment.binding.workspaceID, applicationID: enrollment.binding.applicationID)
        state = .enrolled; issue = nil; enrollmentChanged?(enrollment)
    }
    private func settle(_ preceding: [Task<Void, Never>], revision current: UUID) async throws {
        // Security writes can finish after cancellation. A new load/save/remove
        // must wait for that write before it may observe or replace the record.
        for task in preceding { await task.value }
        try Task.checkCancellation()
        guard valid(current) else { throw BotChannelFailure.canceled }
        cleanup.removeAll()
    }
    private func valid(_ current: UUID) -> Bool { !closed && revision == current }
    private func reset() {
        binding = nil; identity = nil; challenge = nil; pendingSave = nil; issue = nil
        draftBotToken = ""; draftAppToken = ""
        enrollmentChanged?(nil)
    }
    private func invalidate() {
        revision = UUID()
        let previous = operation, client = pairingClient
        previous?.cancel(); operation = nil; pairingClient = nil
        if previous != nil || client != nil {
            cleanup.append(Task { await client?.close(); await previous?.value })
        }
    }
    private func storageFailed(_ error: any Error) {
        if error is EnrollmentIdentityFailure { state = .signingRequired; issue = "A signed Lunlet build is required." }
        else if (error as? SecureStorageFailure)?.requiresOwnerAuthorization == true {
            state = .accessRequired
            issue = "This build needs your permission to read the saved connection. Authorize it, or clear it and paste the token again."
        } else {
            state = .failed; reloadAvailable = true
            issue = "The connection could not be saved or restored. Your existing credentials were kept."
        }
    }
    static func message(_ error: any Error) -> String {
        switch error as? BotChannelFailure {
        case .invalidCredentials: "Check the bot tokens and try again."
        case .unauthorized, .permissionDenied: "Check the bot authorization and required permissions."
        case .rateLimited: "The service is limiting requests. Wait a moment and try again."
        case .webhookInUse: "This bot already uses a webhook. Connect a dedicated bot; its existing setup was kept."
        case .expired: "Pairing expired. Connect again for a new code."
        case .identityMismatch: "The bot or private recipient did not match. Connect again."
        case .invalidResponse: "The service answered in an unexpected way. Check that the token belongs to an installed bot, then try again."
        default: "Could not connect. Check your network and bot settings, then try again."
        }
    }
    func shutdown() async {
        guard !closed else { return }
        invalidate(); closed = true
        for task in cleanup { await task.value }
        cleanup.removeAll(); pendingSave = nil; challenge = nil; binding = nil
        draftBotToken = ""; draftAppToken = ""
        enrollmentChanged = nil; checkAuthorizationAction = nil
    }
}

extension BotChannelSetupModel {
    /// Saved credentials, the private recipient and delivery are separate facts; replies and input are not listed.
    func readinessStages(delivery status: CompletionDeliveryStatus,
                         authorization check: CompletionAuthorizationCheck) -> [ReadinessStage] {
        var tone = PanelTone.neutral
        let authorization: String
        switch state {
        case .enrolled: (authorization, tone) = ReadinessWording.savedAuthorization(check)
        case .disconnected: authorization = "Not connected"
        case .loading: (authorization, tone) = ("Reading saved connection", .running)
        case .connecting: (authorization, tone) = ("Checking bot", .running)
        case .pairing, .saving: (authorization, tone) = ("Bot token checked", .running)
        case .disconnecting: (authorization, tone) = ("Disconnecting", .running)
        case .failed: (authorization, tone) = ("Unavailable", .failure)
        case .accessRequired: (authorization, tone) = ("Access required", .attention)
        case .signingRequired: (authorization, tone) = ("Signed build required", .attention)
        }
        let recipient: (String, PanelTone) = state == .enrolled && binding != nil ? ("Paired", .success)
            : state == .pairing ? ("Awaiting pairing code", .attention)
            : state == .enrolled ? ("Not paired", .attention) : ("Not paired", .neutral)
        // Only stages this build supports are listed; replies and session input are not offered.
        return [
            .init(id: "Authorization", value: authorization, symbol: "checkmark.shield", tone: tone),
            .init(id: "Private chat", value: recipient.0, symbol: "person.crop.circle", tone: recipient.1),
            ReadinessWording.delivery(status)
        ]
    }
}
