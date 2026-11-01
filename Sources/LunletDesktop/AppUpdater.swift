// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-35, AC-35.01, AC-35.02, AC-35.03, AC-35.04.
import AppKit
import Combine
import LunletCore
import Sparkle
import SwiftUI

/// The update feed and key a release bundle carries. A development preview, or a build without both, has none and
/// therefore never checks for updates or shows update controls (AC-35.04).
struct AppUpdateConfiguration: Equatable {
    let feedURL: URL
    let publicKey: String

    init?(info: [String: Any]) {
        // Only builds that declare themselves non-preview qualify; an unbundled or hand-made build fails closed.
        guard info["LunletDevelopmentPreview"] as? Bool == false,
              let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
              url.scheme == "https", url.host?.isEmpty == false,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return nil }
        feedURL = url; publicKey = key
    }
}

/// The Sparkle calls Lunlet uses; tests substitute a driver with no feed, network or window.
@MainActor protocol UpdateDriving: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    func checkForUpdates()
}
extension SPUUpdater: UpdateDriving {}

/// Owns Sparkle in a configured release build and publishes what the panel footer and Settings › About show.
@MainActor final class AppUpdater: ObservableObject {
    /// A newer version a scheduled check found and the owner has not acted on yet; the footer shows it until Sparkle's
    /// session for that update ends (AC-35.01).
    @Published private(set) var availableVersion: String?
    /// On by default from the bundle; Sparkle keeps the owner's choice (AC-35.03).
    @Published private(set) var automaticallyChecks: Bool
    /// False while Sparkle is busy in the background, such as fetching the feed.
    @Published private(set) var canCheck = true
    /// Runs before Sparkle's window opens, so the panel at the notch does not cover it.
    var willPresent: (() -> Void)?
    private let driver: any UpdateDriving
    private var sparkle: [AnyObject] = []

    init(driver: any UpdateDriving, canCheck: AnyPublisher<Bool, Never>? = nil) {
        self.driver = driver
        automaticallyChecks = driver.automaticallyChecksForUpdates
        canCheck?.assign(to: &$canCheck)
    }

    /// Starts Sparkle for a configured release bundle; previews and unconfigured builds get no updater (AC-35.04).
    static func start(bundle: Bundle = .main) -> AppUpdater? {
        guard AppUpdateConfiguration(info: bundle.infoDictionary ?? [:]) != nil else { return nil }
        let reminders = FooterUpdateReminders()
        let userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: reminders)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: nil)
        let owner = AppUpdater(driver: updater, canCheck: updater.publisher(for: \.canCheckForUpdates).eraseToAnyPublisher())
        owner.sparkle = [updater, userDriver, reminders]
        reminders.owner = owner
        let operation = DiagnosticOperation()
        do { try updater.start() } catch {
            DiagnosticLog.record(.startup, component: .updates, outcome: .failed, operation: operation, reason: .invalidInput)
            return nil
        }
        DiagnosticLog.record(.startup, component: .updates, outcome: .completed, operation: operation)
        // Sparkle then checks about once a day; this covers "when Lunlet starts" and is documented as safe right
        // after starting the updater (AC-35.01).
        if updater.automaticallyChecksForUpdates { updater.checkForUpdatesInBackground() }
        return owner
    }

    /// Opens Sparkle's window: the found update with its version, release notes and Install, or a new check. Sparkle
    /// verifies the archive's update signature and code signature before replacing Lunlet (AC-35.02).
    func checkForUpdates() {
        willPresent?()
        driver.checkForUpdates()
    }
    /// Off stops background checks; a manual check still works (AC-35.03).
    func setAutomaticallyChecks(_ enabled: Bool) {
        driver.automaticallyChecksForUpdates = enabled
        automaticallyChecks = driver.automaticallyChecksForUpdates
    }
    /// Sparkle found `version`. It shows user-initiated results itself; a scheduled result becomes the footer notice.
    func updateFound(version: String, shownBySparkle: Bool) {
        if !shownBySparkle { availableVersion = version }
    }
    /// The owner installed, skipped or postponed the update, or it failed; the notice goes away.
    func updateSessionFinished() { availableVersion = nil }
}

/// Lunlet has no Dock icon and stays beside the notch, so a scheduled update never opens a window by itself: it becomes
/// the footer notice, and choosing it brings up Sparkle's window. Nothing downloads before then (AC-35.01).
@MainActor private final class FooterUpdateReminders: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    weak var owner: AppUpdater?
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        owner?.updateFound(version: update.displayVersionString, shownBySparkle: handleShowingUpdate)
    }
    func standardUserDriverWillFinishUpdateSession() { owner?.updateSessionFinished() }
}

private struct AppUpdaterKey: EnvironmentKey { static let defaultValue: AppUpdater? = nil }
extension EnvironmentValues {
    /// The runtime's updater; nil in previews, unconfigured builds and tests that do not show updates (AC-35.04).
    var appUpdater: AppUpdater? {
        get { self[AppUpdaterKey.self] }
        set { self[AppUpdaterKey.self] = newValue }
    }
}

/// The footer's small update notice beside the channel entry; it takes no room until an update is found (AC-35.01).
struct UpdateNoticeButton: View {
    @ObservedObject var updater: AppUpdater
    @ViewState private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let version = updater.availableVersion {
            Button { updater.checkForUpdates() } label: {
                HStack(spacing: PanelStyle.Space.small) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint).accessibilityHidden(true)
                    Text("Update available").foregroundStyle(.primary)
                }
                .font(PanelStyle.Text.secondary.weight(.medium))
                .padding(.horizontal, PanelStyle.Grid.textInset).frame(height: 26)
                .background(hovered ? AnyShapeStyle(.primary.opacity(0.1)) : AnyShapeStyle(PanelStyle.moduleFill), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .animation(PanelStyle.hover(reduce: reduceMotion), value: hovered)
            .help("Lunlet \(version) is available. Click to see what's new and install it.")
            .accessibilityLabel("Update available, Lunlet \(version)")
            .accessibilityHint("Shows the release notes and Install")
        }
    }
}

/// Settings › About's update controls, two compact lines on the single About page; a build without an updater
/// shows none (AC-35.03, AC-35.04).
struct UpdateSettingsSection: View {
    let updater: AppUpdater?
    var body: some View {
        if let updater { Controls(updater: updater) }
    }

    private struct Controls: View {
        @ObservedObject var updater: AppUpdater
        var body: some View {
            VStack(alignment: .leading, spacing: PanelStyle.Space.tight) {
                Divider().padding(.bottom, PanelStyle.Space.tight)
                HStack {
                    Text("Automatically check for updates")
                    Spacer()
                    Toggle("Automatically check for updates", isOn: Binding(get: { updater.automaticallyChecks },
                                                                            set: { updater.setAutomaticallyChecks($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .help("Checks about once a day. Nothing is downloaded or installed until you choose Install.")
                HStack(spacing: PanelStyle.Space.medium) {
                    Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck).controlSize(.small)
                    if let version = updater.availableVersion {
                        Text("Version \(version) is available").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
