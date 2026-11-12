// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-41, AC-41.01, AC-41.02, AC-41.03, AC-41.04, AC-41.05; US-04, AC-04.01, AC-04.05, AC-04.15; US-25, AC-25.01.
import AppKit
import Combine
import Foundation
import LunletClaude
import LunletCore
import SwiftUI

/// One officially reported allowance window at one reading (AC-41.03): never a forecast, never a window past its reset.
struct AllowanceReading: Equatable, Sendable {
    enum Span: String, Codable, Sendable {
        case weekly, fiveHour
        var title: String { self == .weekly ? "weekly allowance" : "5-hour window" }
    }
    let provider: SessionProvider
    let span: Span
    let remainingPercent: Double
    let resetsAt: Date
    let observedAt: Date
    /// One window of one agent; the rule and the notification identifiers key on it.
    var key: String { provider.rawValue + "." + span.rawValue }

    /// Codex's windows by their reported duration (AC-04.07, AC-04.15), from the account's own bucket as the card shows them.
    static func codex(_ snapshot: AccountLimitsSnapshot, now: Date) -> [AllowanceReading] {
        var readings: [AllowanceReading] = []
        if let weekly = AccountUsagePresentation.weekly(in: snapshot), let remaining = weekly.remainingPercent,
           let reset = weekly.resetsAt, reset > now {
            readings.append(.init(provider: .codex, span: .weekly, remainingPercent: remaining, resetsAt: reset, observedAt: snapshot.observedAt))
        }
        if let window = AccountUsagePresentation.fiveHour(in: snapshot), let remaining = window.remainingPercent,
           let reset = window.resetsAt, reset > now {
            readings.append(.init(provider: .codex, span: .fiveHour, remainingPercent: remaining, resetsAt: reset, observedAt: snapshot.observedAt))
        }
        return readings
    }
    /// Claude's weekly window while the status line is connected and the window applies now (AC-33.09).
    static func claude(_ limits: ClaudePlanLimits?, connected: Bool, now: Date) -> [AllowanceReading] {
        guard connected, let week = ClaudeLimitsText.current(limits?.sevenDay, now: now) else { return [] }
        return [.init(provider: .claude, span: .weekly, remainingPercent: min(100, max(0, 100 - week.usedPercent)),
                      resetsAt: week.resetsAt, observedAt: week.at)]
    }
}

/// What a notification says: the agent and window, the percent left and the reset in the cards' wording (AC-04.01),
/// nothing about the account (AC-41.05).
enum AllowanceNotice: Equatable, Sendable {
    case low(AllowanceReading)
    case reset(AllowanceReading)

    static let identifierPrefix = "com.lunlet.allowance."
    var reading: AllowanceReading {
        switch self { case .low(let reading), .reset(let reading): reading }
    }
    private var kind: String { if case .low = self { "low" } else { "reset" } }
    var title: String {
        let window = reading.provider.displayName + " " + reading.span.title
        switch self {
        case .low: return window + ": " + Self.left(reading.remainingPercent)
        case .reset: return window + " has reset"
        }
    }
    func body(now: Date) -> String {
        let moment = ClaudeLimitsText.moment(reading.resetsAt, now: now)
        switch self {
        case .low: return "Resets in " + (AccountUsagePresentation.countdown(until: reading.resetsAt, now: now) ?? "<1h") + " · " + moment
        case .reset: return Self.left(reading.remainingPercent) + " · resets " + moment
        }
    }
    /// Stable per window and kind, so a repeated notice replaces its predecessor in Notification Center.
    var identifier: String { Self.identifierPrefix + reading.key + "." + kind }
    static func provider(of identifier: String) -> SessionProvider? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return identifier.dropFirst(identifierPrefix.count).split(separator: ".").first.flatMap { SessionProvider(rawValue: String($0)) }
    }
    /// "18% left", or "<1% left" for a nearly exhausted window, as the cards read.
    private static func left(_ value: Double) -> String { (value > 0 && value < 1 ? "<1" : String(Int(value))) + "% left" }
}

/// Decides, per window, when a reading warrants a notice (AC-41.03, AC-41.04): once when it drops below the level,
/// again only after a reading above the level or a refreshed window; a reset only from a reading taken after the
/// reset moment that shows the window refreshed. Saved between launches so a window is never reported twice.
struct AllowanceAlertRule: Codable, Equatable {
    private struct Window: Codable, Equatable {
        var remaining: Double
        var resetsAt: Date
        var observedAt: Date
        var warned: Bool
    }
    private var windows: [String: Window] = [:]
    init() {}

    mutating func notices(for readings: [AllowanceReading], warnBelow: Int, resetNotices: Bool, now: Date) -> [AllowanceNotice] {
        var notices: [AllowanceNotice] = []
        let level = Double(warnBelow)
        for reading in readings where reading.resetsAt > now {
            var warned = false
            if let previous = windows[reading.key] {
                // The same reading published again, or an older one, is not a new reading.
                guard reading.observedAt > previous.observedAt else { continue }
                warned = previous.warned
                let refreshed = reading.observedAt > previous.resetsAt
                    && (reading.resetsAt > previous.resetsAt || reading.remainingPercent > previous.remaining)
                if refreshed {
                    if resetNotices { notices.append(.reset(reading)) }
                    warned = false
                } else if reading.resetsAt != previous.resetsAt { warned = false }
            }
            if reading.remainingPercent < level {
                if !warned { notices.append(.low(reading)); warned = true }
            } else { warned = false }
            windows[reading.key] = .init(remaining: reading.remainingPercent, resetsAt: reading.resetsAt,
                                         observedAt: reading.observedAt, warned: warned)
        }
        return notices
    }
}

enum AllowanceNotificationAuthorization: Equatable, Sendable {
    /// Not asked yet in this process.
    case unknown
    /// This process cannot post notifications (an unbundled build).
    case unavailable
    case notDetermined, granted, denied
}

/// The seam to Notification Center; the system implementation exists only in the bundled app.
@MainActor protocol AllowanceNotificationDelivering: AnyObject {
    /// Called with the agent named by an activated notification (AC-41.05).
    var activated: ((SessionProvider) -> Void)? { get set }
    func authorizationState() async -> AllowanceNotificationAuthorization
    func requestAuthorization() async -> AllowanceNotificationAuthorization
    func deliver(_ notice: AllowanceNotice) async
}

/// Follows the readings the limits models already take (AC-41.05, AC-04.05) and the Settings choices, asks for
/// permission once when the switch turns on (AC-41.01) and hands the rule's notices to the deliverer.
@MainActor final class AllowanceNotifier: ObservableObject {
    @Published private(set) var authorization = AllowanceNotificationAuthorization.unknown
    /// Opens the panel on an agent's page when its notification is activated.
    var openProvider: ((SessionProvider) -> Void)?

    static let memoryKey = "allowanceNotifications.windows"
    private let deliverer: any AllowanceNotificationDelivering
    private let defaults: UserDefaults?
    private let now: @MainActor () -> Date
    private var rule: AllowanceAlertRule
    private var readings: [SessionProvider: [AllowanceReading]] = [:]
    private var preferences: LunletPreferences?
    private var subscriptions: Set<AnyCancellable> = []
    private var work: Task<Void, Never>?
    private var closed = false

    init(deliverer: any AllowanceNotificationDelivering, defaults: UserDefaults? = .standard,
         now: @escaping @MainActor () -> Date = Date.init) {
        self.deliverer = deliverer; self.defaults = defaults; self.now = now
        rule = defaults?.data(forKey: Self.memoryKey).flatMap { try? JSONDecoder().decode(AllowanceAlertRule.self, from: $0) } ?? .init()
        deliverer.activated = { [weak self] provider in self?.openProvider?(provider) }
    }

    func observe(preferences store: PreferencesStore) {
        store.$value.sink { [weak self] in self?.preferencesChanged($0) }.store(in: &subscriptions)
    }
    func observe(usage: AccountUsageModel) {
        // Only a completed read is a reading; loading and failure carry none (AC-04.12).
        usage.$state.sink { [weak self] state in
            if case .available(let snapshot) = state { self?.codexChanged(snapshot) }
        }.store(in: &subscriptions)
    }
    func observe(claudeLimits: ClaudePlanLimitsModel) {
        claudeLimits.$limits.combineLatest(claudeLimits.$connection).sink { [weak self] limits, connection in
            self?.claudeChanged(limits, connected: connection == .connected)
        }.store(in: &subscriptions)
    }

    func preferencesChanged(_ value: LunletPreferences) {
        let wasOn = preferences?.allowanceNotifications ?? false
        preferences = value
        if value.allowanceNotifications, !wasOn { enqueue { [deliverer] in await deliverer.requestAuthorization() } }
        else { evaluate() }
    }
    func codexChanged(_ snapshot: AccountLimitsSnapshot) {
        readings[.codex] = AllowanceReading.codex(snapshot, now: now()); evaluate()
    }
    func claudeChanged(_ limits: ClaudePlanLimits?, connected: Bool) {
        readings[.claude] = AllowanceReading.claude(limits, connected: connected, now: now()); evaluate()
    }
    /// Re-reads the permission, for a grant made in System Settings after a denial (AC-41.01).
    func checkAuthorization() {
        guard preferences?.allowanceNotifications == true else { return }
        enqueue { [deliverer] in await deliverer.authorizationState() }
    }
    /// Waits for the queued permission reads and deliveries.
    func settle() async {
        var waited: Task<Void, Never>?
        while let task = work, task != waited { waited = task; await task.value }
    }
    func shutdown() async {
        closed = true
        subscriptions.removeAll()
        work?.cancel()
        await work?.value
        work = nil
    }

    private func enqueue(_ read: @escaping @MainActor () async -> AllowanceNotificationAuthorization) {
        guard !closed else { return }
        let previous = work
        work = Task { [weak self] in
            await previous?.value
            let state = await read()
            guard let self, !self.closed else { return }
            self.authorization = state
            self.evaluate()
        }
    }
    private func evaluate() {
        guard !closed, let preferences, preferences.allowanceNotifications, authorization == .granted else { return }
        let notices = rule.notices(for: readings.values.flatMap { $0 }, warnBelow: preferences.allowanceWarnBelow,
                                   resetNotices: preferences.allowanceResetNotices, now: now())
        if let data = try? JSONEncoder().encode(rule) { defaults?.set(data, forKey: Self.memoryKey) }
        guard !notices.isEmpty else { return }
        let previous = work, deliverer = deliverer
        work = Task {
            await previous?.value
            for notice in notices { await deliverer.deliver(notice) }
        }
    }
}

/// The permission state only when it stops delivery (AC-41.01): denied, with the way to System Settings, or unavailable.
struct AllowancePermissionNote: View {
    @ObservedObject var notifier: AllowanceNotifier
    var body: some View {
        switch notifier.authorization {
        case .denied:
            LabeledContent("Permission") {
                HStack {
                    Text("Off for Lunlet in System Settings").foregroundStyle(.secondary)
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.lunlet") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        case .unavailable:
            Text("Notifications are unavailable in this build.").font(Font.caption).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }
}

private struct AllowanceNotifierKey: EnvironmentKey { static let defaultValue: AllowanceNotifier? = nil }
extension EnvironmentValues {
    /// The runtime's notifier, for the Settings section's permission state.
    var allowanceNotifier: AllowanceNotifier? {
        get { self[AllowanceNotifierKey.self] }
        set { self[AllowanceNotifierKey.self] = newValue }
    }
}
