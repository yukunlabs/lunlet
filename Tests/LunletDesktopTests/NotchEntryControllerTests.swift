// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-02, AC-02.03, AC-02.05; US-21, AC-21.02; US-04, AC-04.13; US-16, AC-16.03.
// Refs: US-03, AC-03.07, AC-03.08, AC-03.10; US-12, AC-12.04.
import AppKit
import QuartzCore
import SwiftUI
import Testing
import LunletCore
@testable import LunletDesktop

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_PANEL"] == "1"))
@MainActor struct NotchEntryControllerTests {
    @Test func notchExposesTheSameVerifiedWaitingStatusAndUnknownState() throws {
        _ = NSApplication.shared
        let screen = try #require(PanelScreen.notchDisplay)
        let companion = CompanionPanelController(), sessions = SessionListModel()
        let entry = NotchEntryController(companion: companion, display: { screen }, available: { true }, sessions: sessions)
        defer { entry.shutdown(); sessions.shutdown(); companion.shutdown() }
        entry.start()
        let mark = try #require(entry.window?.contentView as? LettermarkView)
        #expect((mark.accessibilityValue() as? String)?.contains("Session status unavailable") == true)
        sessions.monitoringConnected(partial: false)
        sessions.receive(.init(observation: .init(sessionID: UUID(), connectionID: UUID(),
            liveness: .unverified, phase: .approval), project: "Synthetic", title: "Waiting",
            activityConfirmed: true), origin: .snapshot)
        #expect((mark.accessibilityValue() as? String)?.contains("1 waiting") == true)
        mark.layoutSubtreeIfNeeded()
        let badge = try #require(mark.layer?.sublayers?.first { $0.name == "session-status" } as? CATextLayer)
        #expect(badge.string as? String == "1")
        #expect(mark.bounds.contains(badge.frame))
        #expect(badge.frame.minX >= 52 + mark.notchSize.width)
        sessions.monitoringConnected(partial: true)
        #expect((mark.accessibilityValue() as? String)?.contains("waiting count unknown") == true)
        #expect(badge.string as? String == "")
        #expect(badge.isHidden)
    }

    // Refs: US-04, AC-04.13; US-16, AC-16.03.
    @Test func entryFollowsClaudeLimitsAndTheSelectedAgentsAsTheyChange() async throws {
        _ = NSApplication.shared
        let screen = try #require(PanelScreen.notchDisplay)
        let suite = "com.lunlet.test.entry.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.update { $0.providers = [.codex, .claude] }
        let fixture = try ClaudeLimitsFixture(); defer { fixture.remove() }
        _ = try fixture.connection.connect()
        let t = Int(Date().timeIntervalSince1970)
        try fixture.write(state: "lunlet-claude-limits 1\nseven_day 30 \(t + 86_400) \(t - 5)\n")
        let limits = ClaudePlanLimitsModel(service: fixture.connection), companion = CompanionPanelController()
        let entry = NotchEntryController(companion: companion, display: { screen }, available: { true }, claudeLimits: limits,
                                         preferences: preferences)
        defer { entry.shutdown(); companion.shutdown() }
        entry.start()
        let mark = try #require(entry.window?.contentView as? LettermarkView)
        func value() -> String { mark.accessibilityValue() as? String ?? "" }
        #expect(value().contains("Codex weekly allowance unavailable") && value().contains("Claude Code weekly allowance unavailable"))
        // Each published reading reaches the entry; the entry itself never reads or polls.
        limits.setActive(true)
        try await ClaudeLimitsFixture.settle(limits) { value().contains("Claude Code 70%") }
        #expect(value().contains("Claude Code 70% weekly allowance left") && value().contains("Codex weekly allowance unavailable"))
        try fixture.write(state: "lunlet-claude-limits 1\nseven_day 45 \(t + 86_400) \(t - 1)\n")
        limits.refresh()
        try await ClaudeLimitsFixture.settle(limits) { value().contains("Claude Code 55%") }
        #expect(value().contains("Claude Code 55% weekly allowance left"))
        mark.layoutSubtreeIfNeeded()
        #expect(mark.layer?.sublayers?.contains { $0.sublayers?.contains { $0.name == "rope" && !$0.isHidden } == true } == true)
        // Deselecting Claude Code returns to the single Codex vine.
        preferences.update { $0.providers = [.codex] }
        #expect(!value().contains("Claude"))
        await limits.shutdown()
    }

    @Test func menuCountsConfirmedRuntimeWaitingAndKeepsUnknownCountsDistinct() throws {
        _ = NSApplication.shared
        let companion = CompanionPanelController(), sessions = SessionListModel()
        let menu = MenuBarController(panel: companion, sessions: sessions)
        defer { menu.shutdown(); sessions.shutdown(); companion.shutdown() }
        sessions.monitoringConnected(partial: false)
        sessions.receive(.init(observation: .init(sessionID: UUID(), connectionID: UUID(),
            liveness: .unverified, phase: .approval), project: "Synthetic", title: "Waiting",
            activityConfirmed: true), origin: .snapshot)
        #expect(menu.item?.button?.title == " 1")
        #expect(menu.item?.button?.toolTip?.contains("1 waiting") == true)
        sessions.monitoringUnavailable()
        #expect(menu.item?.button?.title == "")
        #expect(menu.item?.button?.toolTip?.contains("0 waiting") == false)
    }

    @Test func displayLossHidesTheEntryCancelsHoverAndShutdownCannotReopenIt() async throws {
        _ = NSApplication.shared
        let screen = try #require(PanelScreen.notchDisplay, "This physical-entry check requires a notched display")
        let companion = CompanionPanelController()
        companion.setContent { AnyView(Text("Synthetic preview")) }
        var available = true
        let entry = NotchEntryController(companion: companion, display: { screen }, available: { available })
        defer { entry.shutdown(); companion.shutdown() }
        entry.start()
        let window = try #require(entry.window)
        #expect(window.isVisible && !window.isKeyWindow)
        entry.panelVisibilityChanged(true)
        entry.panelVisibilityChanged(false)
        let notch = try #require(PanelScreen(screen).notch)
        // AppKit rounds window origins to whole points on this display.
        #expect(abs(window.frame.midX - notch.midX) < 1)
        #expect(window.frame.width == notch.width + 104)
        let mark = try #require(window.contentView as? LettermarkView)
        #expect(mark.layer?.sublayers?.filter { $0.name == "lun" || $0.name == "let" }.count == 2)
        companion.entryHoverChanged(true, on: screen)
        available = false; entry.refresh()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!window.isVisible && !companion.isVisible)
        #expect(mark.layer?.sublayers?.allSatisfy { ($0.animationKeys() ?? []).isEmpty } == true)
        available = true; entry.refresh()
        #expect(entry.window === window && window.isVisible)
        entry.shutdown(); entry.start(); entry.refresh()
        #expect(entry.window == nil && !window.isVisible)
    }
    @Test func expandedPanelTakesPointerOwnershipAndLeavingItCanDismiss() async throws {
        _ = NSApplication.shared
        let screen = try #require(PanelScreen.notchDisplay)
        let companion = CompanionPanelController(motionAllowed: { false }, observesSystemEvents: false)
        companion.setContent { AnyView(Text("Synthetic preview")) }
        let entry = NotchEntryController(companion: companion, display: { screen }, available: { true })
        companion.visibilityChanged = { [weak entry] in entry?.panelVisibilityChanged($0) }
        defer { entry.shutdown(); companion.shutdown() }
        entry.start()
        let window = try #require(entry.window), mark = try #require(window.contentView as? LettermarkView)
        mark.hover?(true)
        let deadline = ContinuousClock.now + .seconds(2)
        while !companion.isVisible, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(companion.isVisible && window.ignoresMouseEvents)
        // An ignored entry window need not emit mouseExited. The controller
        // must release its old hover ownership without relying on that event.
        companion.pointerChanged(true)
        try await Task.sleep(for: .milliseconds(420))
        #expect(companion.isVisible)
        companion.pointerChanged(false)
        while companion.isVisible, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!companion.isVisible && !window.ignoresMouseEvents)
    }

    @Test func temporaryDisplayUnavailabilityDoesNotSwitchToTheMenuFallback() throws {
        _ = NSApplication.shared
        let screen = try #require(PanelScreen.notchDisplay)
        let companion = CompanionPanelController(), sessions = SessionListModel()
        let menu = MenuBarController(panel: companion, sessions: sessions)
        var available = true
        let entry = NotchEntryController(companion: companion, display: { screen }, available: { available })
        entry.notchAvailabilityChanged = { menu.setNotchEntryAvailable($0) }
        defer { entry.shutdown(); menu.shutdown(); sessions.shutdown(); companion.shutdown() }
        entry.start()
        #expect(menu.item?.isVisible == false)
        available = false; entry.refresh()
        #expect(entry.window?.isVisible == false)
        #expect(menu.item?.isVisible == false)
        available = true; entry.refresh()
        #expect(entry.window?.isVisible == true && menu.item?.isVisible == false)
    }

    @Test func displaySignalBeforeTheOSStateSettlesStillRestoresTheEntry() async throws {
        _ = NSApplication.shared
        let screen = try #require(PanelScreen.notchDisplay)
        let companion = CompanionPanelController()
        var available = true
        let entry = NotchEntryController(companion: companion, display: { screen }, available: { available })
        defer { entry.shutdown(); companion.shutdown() }
        entry.start()
        available = false
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let hiddenDeadline = ContinuousClock.now + .seconds(1)
        while entry.window?.isVisible == true, ContinuousClock.now < hiddenDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(entry.window?.isVisible == false)
        available = true
        let recoveryDeadline = ContinuousClock.now + .seconds(2)
        while entry.window?.isVisible != true, ContinuousClock.now < recoveryDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(entry.window?.isVisible == true)
        entry.shutdown()
        try await Task.sleep(for: .milliseconds(150))
        #expect(entry.window == nil)
    }

    // AC-21.02: the live menu-bar entry shows the system-tinted lun·let wordmark,
    // not the full-color application icon.
    @Test func fallbackUsesTheTemplateWordmarkRatherThanTheColorApplicationIcon() throws {
        _ = NSApplication.shared
        let companion = CompanionPanelController(), sessions = SessionListModel()
        let menu = MenuBarController(panel: companion, sessions: sessions)
        defer { menu.shutdown(); sessions.shutdown(); companion.shutdown() }
        let image = try #require(menu.item?.button?.image)
        #expect(image.isTemplate)
        #expect(image.size.height == LunletWordmark.menuBarHeight)
        #expect(image.accessibilityDescription == "Lunlet")
    }

    @Test func savedMenuModeSurvivesDisplayRefreshAndCanSwitchBackToTheNotch() throws {
        _ = NSApplication.shared
        let screen = try #require(PanelScreen.notchDisplay)
        let suite = "com.lunlet.test.entry.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        var value = preferences.value; value.presentation = .menuBar
        try preferences.apply(value)
        let companion = CompanionPanelController(), sessions = SessionListModel()
        let menu = MenuBarController(panel: companion, sessions: sessions)
        var available = true
        let entry = NotchEntryController(companion: companion, display: { screen }, available: { available }, preferences: preferences)
        entry.notchAvailabilityChanged = { menu.setNotchEntryAvailable($0) }
        defer { entry.shutdown(); menu.shutdown(); sessions.shutdown(); companion.shutdown() }
        entry.start(); entry.cueChanged(.working); entry.refresh()
        #expect(entry.window?.isVisible != true && menu.item?.isVisible == true)
        preferences.update { $0.presentation = .notch }
        #expect(entry.window?.isVisible == true && menu.item?.isVisible == false)
        available = false; entry.refresh()
        preferences.update { $0.presentation = .menuBar }
        available = true; entry.refresh()
        #expect(entry.window?.isVisible != true && menu.item?.isVisible == true)
        entry.shutdown(); preferences.update { $0.presentation = .notch }
        #expect(entry.window == nil)
    }

    @Test func noNotchedDisplayCreatesNoOverlay() {
        _ = NSApplication.shared
        let companion = CompanionPanelController()
        let entry = NotchEntryController(companion: companion, display: { nil }, available: { true })
        defer { entry.shutdown(); companion.shutdown() }
        entry.start()
        #expect(entry.window == nil)
    }
    @Test func aDisplayWithoutANotchKeepsAManuallyOpenedPanel() {
        _ = NSApplication.shared
        let companion = CompanionPanelController()
        companion.setContent { AnyView(Text("Synthetic preview")) }
        let entry = NotchEntryController(companion: companion, display: { nil }, available: { true })
        defer { entry.shutdown(); companion.shutdown() }
        companion.show()
        entry.start(); entry.refresh()
        #expect(companion.isVisible && companion.isPinned)
    }

    @Test func theMenuFallbackIsExclusiveWithTheActualNotchEntry() throws {
        _ = NSApplication.shared
        let companion = CompanionPanelController()
        let sessions = SessionListModel()
        let menu = MenuBarController(panel: companion, sessions: sessions)
        let display = try #require(PanelScreen.notchDisplay)
        var notchedDisplay: NSScreen? = display
        let entry = NotchEntryController(companion: companion, display: { notchedDisplay }, available: { true })
        entry.notchAvailabilityChanged = { menu.setNotchEntryAvailable($0) }
        defer { entry.shutdown(); menu.shutdown(); sessions.shutdown(); companion.shutdown() }
        #expect(menu.item?.isVisible == true)
        entry.start()
        #expect(entry.window?.isVisible == true && menu.item?.isVisible == false)
        notchedDisplay = nil; entry.refresh()
        #expect(entry.window?.isVisible == false && menu.item?.isVisible == true)
        notchedDisplay = display; entry.refresh()
        #expect(entry.window?.isVisible == true && menu.item?.isVisible == false)
        entry.shutdown(); menu.shutdown()
        #expect(entry.window == nil && menu.item == nil)
    }

}
