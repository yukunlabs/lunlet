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

    @Test func aScheduledUpdateBecomesTheFooterNoticeUntilSparklesSessionEnds() {
        let driver = SyntheticUpdateDriver(), updater = AppUpdater(driver: driver)
        #expect(updater.availableVersion == nil)
        // Sparkle shows user-initiated results in its own window; they never add a second notice.
        updater.updateFound(version: "0.2.0", shownBySparkle: true)
        #expect(updater.availableVersion == nil)
        // A scheduled result opens no window; it waits in the footer (AC-35.01).
        updater.updateFound(version: "0.2.0", shownBySparkle: false)
        #expect(updater.availableVersion == "0.2.0" && driver.checks == 0)
        // Installing, skipping, postponing or a failure ends the session and the notice.
        updater.updateSessionFinished()
        #expect(updater.availableVersion == nil)
    }

    @Test func choosingTheNoticeOrCheckForUpdatesMovesThePanelAsideAndOpensSparkle() {
        let driver = SyntheticUpdateDriver(), updater = AppUpdater(driver: driver)
        var events: [String] = []
        updater.willPresent = { events.append("panel hidden at check \(driver.checks)") }
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
        updater.updateSessionFinished()
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
