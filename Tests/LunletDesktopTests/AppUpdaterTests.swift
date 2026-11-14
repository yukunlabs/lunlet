// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-35, AC-35.01, AC-35.02, AC-35.03, AC-35.04.
import AppKit
import Combine
import SwiftUI
import Testing
@testable import LunletDesktop

/// Records what Lunlet asks of Sparkle; no feed, network, window or defaults write.
@MainActor final class SyntheticUpdateDriver: UpdateDriving {
    var automaticallyChecksForUpdates = true
    private(set) var checks = 0
    func checkForUpdates() { checks += 1 }
}

/// Stands in for a window the application has open, and counts how often it is put in front.
@MainActor private final class SyntheticWindow: FrontableWindow {
    var isOrdinaryAndVisible: Bool
    private(set) var fronted = 0
    init(shown: Bool) { isOrdinaryAndVisible = shown }
    func orderFrontRegardless() { fronted += 1 }
}

@MainActor struct AppUpdaterTests {
    /// A synthetic EdDSA public key: 32 bytes, base64, as Sparkle's generate_keys prints one. It signs nothing.
    private static let key = Data(repeating: 7, count: 32).base64EncodedString()
    private static let release: [String: Any] = [
        "LunletDevelopmentPreview": false, "SUFeedURL": "https://example.invalid/lunlet/appcast.xml", "SUPublicEDKey": key,
    ]
    private static func info(_ changes: [String: Any?]) -> [String: Any] {
        var info = release
        for (key, value) in changes { info[key] = value }
        return info
    }

    @Test func onlyANonPreviewBuildWithAnHTTPSFeedAndAValidKeyCanCheck() {
        // AC-35.04: previews, missing or malformed feeds and keys, and builds that do not declare themselves never check.
        let unavailable: [[String: Any]] = [
            [:], Self.info(["LunletDevelopmentPreview": true]), Self.info(["LunletDevelopmentPreview": nil]),
            Self.info(["SUFeedURL": nil]), Self.info(["SUPublicEDKey": nil]), Self.info(["SUFeedURL": "", "SUPublicEDKey": ""]),
            Self.info(["SUFeedURL": "http://example.invalid/appcast.xml"]), Self.info(["SUFeedURL": "https:///appcast.xml"]),
            Self.info(["SUPublicEDKey": "not-a-key"]), Self.info(["SUPublicEDKey": Data(count: 16).base64EncodedString()]),
        ]
        for info in unavailable { #expect(AppUpdateConfiguration(info: info) == nil) }
        let configured = AppUpdateConfiguration(info: Self.release)
        #expect(configured?.feedURL.absoluteString == "https://example.invalid/lunlet/appcast.xml")
        #expect(configured?.publicKey == Self.key)
    }

    @Test func unconfiguredBundlesStartNoUpdater() throws {
        // A preview, a bundle without a feed and one without a key create no Sparkle updater at all (AC-35.04).
        for info in [Self.info(["LunletDevelopmentPreview": true]), Self.info(["SUFeedURL": nil]), Self.info(["SUPublicEDKey": nil])] {
            let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-update-\(UUID()).app")
            defer { try? FileManager.default.removeItem(at: bundle) }
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            var plist = info; plist["CFBundleIdentifier"] = "com.lunlet.test.update"
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            #expect(AppUpdater.start(bundle: try #require(Bundle(url: bundle))) == nil)
        }
        // The test runner's own bundle carries no feed either.
        #expect(AppUpdater.start() == nil)
    }

    @Test func aFoundUpdateStaysInTheFooterUntilItIsSkippedOrNoLongerOffered() {
        let driver = SyntheticUpdateDriver(), updater = AppUpdater(driver: driver)
        updater.windows = { [] }
        #expect(updater.availableVersion == nil)
        // A scheduled result opens no window; it waits in the footer (AC-35.01).
        updater.updateFound(version: "0.2.0", shownBySparkle: false)
        #expect(updater.availableVersion == "0.2.0" && driver.checks == 0)
        // Closing the update window or choosing Remind Me Later ends Sparkle's session, not the update: the notice
        // stays, so the update can be reached again without waiting for the next check.
        updater.readerChose(.later); updater.updateSessionFinished()
        #expect(updater.availableVersion == "0.2.0")
        // Install keeps it until the new version starts; a failed installation leaves the update on offer.
        updater.readerChose(.install); updater.updateSessionFinished()
        #expect(updater.availableVersion == "0.2.0")
        // Skip This Version is the reader declining it.
        updater.readerChose(.skip)
        #expect(updater.availableVersion == nil)
        // A check the reader asked for leaves the same notice once its window is closed.
        updater.updateFound(version: "0.2.0", shownBySparkle: true)
        updater.readerChose(.later); updater.updateSessionFinished()
        #expect(updater.availableVersion == "0.2.0")
        // A later check that finds nothing newer takes it away.
        updater.noUpdateFound()
        #expect(updater.availableVersion == nil)
    }

    @Test func eachWindowOfAnUpdateSessionIsPutInFrontOnce() {
        // Lunlet has no Dock icon: macOS opens its windows behind the frontmost application, where choosing the notice
        // or Check for Updates… would seem to do nothing (AC-35.02).
        let driver = SyntheticUpdateDriver(), updater = AppUpdater(driver: driver)
        let checking = SyntheticWindow(shown: true), found = SyntheticWindow(shown: false), panel = SyntheticWindow(shown: false)
        updater.windows = { [checking, found, panel] }
        updater.later = { _, work in work() }
        updater.checkForUpdates()
        // The window Sparkle opens for the check comes forward; one not yet shown, and Lunlet's own panel, do not.
        #expect(checking.fronted == 1 && found.fronted == 0 && panel.fronted == 0 && driver.checks == 1)
        // Sparkle then shows the update; that window comes forward, and the first is not pulled forward again.
        found.isOrdinaryAndVisible = true
        updater.updateFound(version: "0.2.0", shownBySparkle: true)
        #expect(checking.fronted == 1 && found.fronted == 1)
        // So does an alert, such as the one saying Lunlet is up to date.
        let alert = SyntheticWindow(shown: true)
        updater.windows = { [checking, found, alert] }
        updater.alertWillShow()
        #expect(alert.fronted == 1 && found.fronted == 1)
        // A scheduled result opens no window, so nothing is moved.
        let other = SyntheticWindow(shown: true)
        updater.windows = { [other] }
        updater.updateFound(version: "0.2.0", shownBySparkle: false)
        #expect(other.fronted == 0)
        // The next session starts afresh.
        updater.updateSessionFinished()
        updater.windows = { [checking] }
        updater.checkForUpdates()
        #expect(checking.fronted == 2)
    }

    @Test func anOrdinaryWindowIsFrontableAndLunletsPanelsAreNot() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 80, height: 40), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // Not on screen: nothing to bring forward.
        #expect(!window.isOrdinaryAndVisible)
        // The panel, the entry and the cue sit above the menu bar and place themselves.
        #expect(NSWindow.isOrdinary(level: .normal) && NSWindow.isOrdinary(level: .floating) && NSWindow.isOrdinary(level: .modalPanel))
        #expect(!NSWindow.isOrdinary(level: .mainMenu) && !NSWindow.isOrdinary(level: .statusBar) && !NSWindow.isOrdinary(level: .popUpMenu))
    }

    @Test func choosingTheNoticeOrCheckForUpdatesMovesThePanelAsideAndOpensSparkle() {
        let driver = SyntheticUpdateDriver(), updater = AppUpdater(driver: driver)
        var events: [String] = []
        updater.willPresent = { events.append("panel hidden at check \(driver.checks)") }
        updater.windows = { [] }
        updater.updateFound(version: "0.2.0", shownBySparkle: false)
        updater.checkForUpdates()
        // The panel hides before Sparkle's window with the version, notes and Install opens (AC-35.02).
        #expect(events == ["panel hidden at check 0"] && driver.checks == 1)
    }

    @Test func automaticChecksStartOnAndTurningThemOffKeepsManualChecks() {
        let driver = SyntheticUpdateDriver(), updater = AppUpdater(driver: driver)
        #expect(updater.automaticallyChecks)
        updater.setAutomaticallyChecks(false)
        #expect(!driver.automaticallyChecksForUpdates && !updater.automaticallyChecks)
        updater.checkForUpdates()
        #expect(driver.checks == 1)
        updater.setAutomaticallyChecks(true)
        #expect(driver.automaticallyChecksForUpdates && updater.automaticallyChecks)
    }

    @Test func checkForUpdatesFollowsSparklesAvailability() {
        let busy = PassthroughSubject<Bool, Never>()
        let updater = AppUpdater(driver: SyntheticUpdateDriver(), canCheck: busy.eraseToAnyPublisher())
        busy.send(false)
        #expect(!updater.canCheck)
        busy.send(true)
        #expect(updater.canCheck)
    }

    private func fittingSize(_ view: some View) -> CGSize {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func theFooterNoticeTakesNoRoomUntilAnUpdateIsFound() {
        // AC-35.01: a small notice only while a found update waits; none otherwise.
        let updater = AppUpdater(driver: SyntheticUpdateDriver())
        #expect(fittingSize(UpdateNoticeButton(updater: updater)) == .zero)
        updater.updateFound(version: "0.2.0", shownBySparkle: false)
        let notice = fittingSize(UpdateNoticeButton(updater: updater))
        #expect(notice.height == 26 && notice.width > 60 && notice.width < 200)
        updater.readerChose(.skip)
        #expect(fittingSize(UpdateNoticeButton(updater: updater)) == .zero)
    }

    @Test func aboutShowsUpdateControlsOnlyWithAnUpdater() {
        // AC-35.04: no updater, no controls; AC-35.03: a configured build shows the switch and Check for Updates….
        #expect(fittingSize(UpdateSettingsSection(updater: nil)) == .zero)
        let controls = fittingSize(VStack { UpdateSettingsSection(updater: AppUpdater(driver: SyntheticUpdateDriver())) }
            .frame(width: 330))
        let empty = fittingSize(VStack { UpdateSettingsSection(updater: nil) }.frame(width: 330))
        #expect(controls.height > empty.height + 40)
    }
}

/// On the real screen: a window opened while another application is in front, as Sparkle opens its update window
/// from an application without a Dock icon, ends up in front once the updater has brought it forward (AC-35.02).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_PANEL"] == "1"))
@MainActor struct UpdateWindowFrontingTests {
    /// Whether an ordinary window of another application lies over `window`.
    private func covered(_ window: NSWindow) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        func frame(_ entry: [String: Any]) -> CGRect {
            let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
            return CGRect(x: bounds["X"] as? Double ?? 0, y: bounds["Y"] as? Double ?? 0,
                          width: bounds["Width"] as? Double ?? 0, height: bounds["Height"] as? Double ?? 0)
        }
        guard let index = list.firstIndex(where: { $0[kCGWindowNumber as String] as? Int == window.windowNumber }) else { return true }
        return list[..<index].contains {
            $0[kCGWindowLayer as String] as? Int == 0 && !frame($0).intersection(frame(list[index])).isEmpty
        }
    }

    @Test func aWindowOpenedBehindAnotherApplicationComesToTheFront() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 140), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Lunlet update window test"
        window.center()
        defer { window.close() }
        // As Sparkle shows it: put in order while the application is not the active one.
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        let openedBehind = covered(window)
        let updater = AppUpdater(driver: SyntheticUpdateDriver())
        updater.windows = { [window] }
        updater.later = { _, work in work() }
        updater.checkForUpdates()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!covered(window))
        // With no window of another application in the way, the expectation above holds without proving anything.
        if !openedBehind { print("UpdateWindowFrontingTests: no other application's window covered the test window") }
    }
}
