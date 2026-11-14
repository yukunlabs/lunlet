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

/// What the reader answered in the update window; closing it counts as later.
enum UpdateChoice { case install, skip, later }

/// A window the updater may have to put in front; tests substitute their own.
@MainActor protocol FrontableWindow: AnyObject {
    /// On screen, and an ordinary window rather than one of Lunlet's own at the notch.
    var isOrdinaryAndVisible: Bool { get }
    func orderFrontRegardless()
}
extension NSWindow: FrontableWindow {
    /// Lunlet's panel, entry and cue sit above the menu bar and place themselves; everything below is ordinary.
    static func isOrdinary(level: NSWindow.Level) -> Bool { level.rawValue < NSWindow.Level.mainMenu.rawValue }
    var isOrdinaryAndVisible: Bool { isVisible && Self.isOrdinary(level: level) }
}

/// Owns Sparkle in a configured release build and publishes what the panel footer and Settings › About show.
@MainActor final class AppUpdater: ObservableObject {
    /// A newer version Sparkle found. The footer shows it until it is installed or skipped, or a check finds nothing
    /// newer; closing the update window leaves it there (AC-35.01).
    @Published private(set) var availableVersion: String?
    /// On by default from the bundle; Sparkle keeps the owner's choice (AC-35.03).
    @Published private(set) var automaticallyChecks: Bool
    /// False while Sparkle is busy in the background, such as fetching the feed.
    @Published private(set) var canCheck = true
    /// Runs before Sparkle's window opens, so the panel at the notch does not cover it.
    var willPresent: (() -> Void)?
    /// The application's windows, among them the ones Sparkle opens.
    var windows: () -> [any FrontableWindow] = { NSApplication.shared.windows }
    /// Runs work a moment later, once Sparkle has put its window up.
    var later: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
    }
    private var fronted: [any FrontableWindow] = []
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
        let reminders = FooterUpdateReminders(), answers = UpdateAnswers()
        let userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: reminders)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: answers)
        let owner = AppUpdater(driver: updater, canCheck: updater.publisher(for: \.canCheckForUpdates).eraseToAnyPublisher())
        owner.sparkle = [updater, userDriver, reminders, answers]
        reminders.owner = owner; answers.owner = owner
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
        bringWindowsForward()
    }
    /// Lunlet has no Dock icon, so macOS opens its windows behind the frontmost application and declines its request
    /// to become active: the update window would be there, unseen. Each window of an update session is therefore put
    /// in front once, as it appears; after that it behaves like any other window (AC-35.02).
    private func bringWindowsForward() {
        // Sparkle shows a window just after it says so, and a check's progress a moment after it starts.
        for delay in [0.05, 0.4, 1.2] {
            later(delay) { [weak self] in
                guard let self else { return }
                for window in windows() where window.isOrdinaryAndVisible && !fronted.contains(where: { $0 === window }) {
                    fronted.append(window)
                    window.orderFrontRegardless()
                }
            }
        }
    }
    /// Sparkle is about to show an alert, such as the one saying Lunlet is up to date.
    func alertWillShow() { bringWindowsForward() }
    /// Off stops background checks; a manual check still works (AC-35.03).
    func setAutomaticallyChecks(_ enabled: Bool) {
        driver.automaticallyChecksForUpdates = enabled
        automaticallyChecks = driver.automaticallyChecksForUpdates
    }
    /// Sparkle found `version`. It shows the result of a check the reader asked for in its own window; a scheduled
    /// result opens none. Either way the footer names the update.
    func updateFound(version: String, shownBySparkle: Bool) {
        availableVersion = version
        if shownBySparkle { bringWindowsForward() }
    }
    /// The reader's answer in the update window. Only skipping declines the update; later, or a closed window, leaves
    /// it on offer, and an installation that fails does too.
    func readerChose(_ choice: UpdateChoice) {
        if choice == .skip { availableVersion = nil }
    }
    /// A check found nothing newer than this version.
    func noUpdateFound() { availableVersion = nil }
    /// Sparkle's session ended and its windows are gone.
    func updateSessionFinished() { fronted.removeAll() }
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
    func standardUserDriverWillShowModalAlert() { owner?.alertWillShow() }
    func standardUserDriverWillFinishUpdateSession() { owner?.updateSessionFinished() }
}

/// What the reader chose and what a check found, which decide how long the footer notice stays (AC-35.01).
@MainActor private final class UpdateAnswers: NSObject, SPUUpdaterDelegate {
    weak var owner: AppUpdater?
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        switch choice {
        case .skip: owner?.readerChose(.skip)
        case .install: owner?.readerChose(.install)
        case .dismiss: owner?.readerChose(.later)
        @unknown default: break
        }
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) { owner?.noUpdateFound() }
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
            // One module of two rows, in the settings groups' style.
            SettingsGroup {
                SettingsRow("Automatically check for updates", controlNamed: true) {
                    Toggle("Automatically check for updates", isOn: Binding(get: { updater.automaticallyChecks },
                                                                            set: { updater.setAutomaticallyChecks($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .help("Checks about once a day. Nothing is downloaded or installed until you choose Install.")
                HStack(spacing: PanelStyle.Space.medium) {
                    Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                        .buttonStyle(SettingsLinkButtonStyle())
                    Spacer(minLength: 0)
                    if let version = updater.availableVersion {
                        Text("Version \(version) is available").font(PanelStyle.Text.secondary).foregroundStyle(.secondary)
                    }
                }
                .settingsCell()
            }
        }
    }
}
