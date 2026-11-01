// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-03, AC-03.01, AC-03.04, AC-03.05, AC-03.06, AC-03.08, AC-03.10, AC-03.11.
// Refs: US-12, AC-12.04; US-13, AC-13.01, AC-13.02, AC-13.04, AC-13.05, AC-13.08; US-24, AC-24.03.
// Refs: US-19, AC-19.05; US-03, AC-03.09.
import AppKit
import SwiftUI
import Testing
import LunletCodex
import LunletCore
import LunletFeishu
import LunletMessaging
@testable import LunletDesktop

@MainActor private final class PanelTestClock { var now: TimeInterval = 0 }

// Synthetic models for the real panel content: no account read, Keychain, network or session source.
private actor KeyboardEnrollmentStore: EnrollmentStoring {
    func save(_ enrollment: FeishuEnrollment) {}
    func load() -> FeishuEnrollment? { nil }
    func remove() {}
}
private actor KeyboardCredentialStore: ChannelCredentialStoring {
    func load() -> Data? { nil }
    func authorize() -> Data? { nil }
    func save(_ data: Data) {}
    func remove() {}
}
private struct KeyboardAccount: CodexAccountReading {
    func readLimits() async throws -> AccountLimitsSnapshot { throw CancellationError() }
}
private struct KeyboardUsage: LocalUsageReading {
    func readHistory(now: Date, calendar: Calendar, days: Int) async throws -> LocalUsageHistory { throw CancellationError() }
}
private final class KeyboardPower: IdleSleepControlling { func setEnabled(_ enabled: Bool) {} }
@MainActor private final class KeyboardCues: TaskCuePresenting { func show(_ cues: [TaskCue]) {}; func hide() {} }

/// Synthetic content that reports a tab row on demand and records the notch band it receives.
@MainActor private final class TabRowProbe: ObservableObject {
    @Published var tabs = false
    var band: NotchBand?
}
private struct TabRowContent: View {
    @ObservedObject var probe: TabRowProbe
    @Environment(\.notchBand) private var band
    var body: some View {
        Text("Synthetic panel").preference(key: CompanionPanelTabRow.self, value: probe.tabs)
            .onChange(of: band, initial: true) { probe.band = band }
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_PANEL"] == "1"))
@MainActor struct CompanionPanelControllerTests {
    // Drive events explicitly; real pointer/focus changes must not race synthetic gestures.
    private static let notch = CGRect(x: 663.5, y: 950, width: 185, height: 32)
    private func controller(notch: CGRect? = nil) -> CompanionPanelController {
        _ = NSApplication.shared
        let controller = CompanionPanelController(motionAllowed: { false }, observesSystemEvents: false, screen: {
            .init(frame: .init(x: 0, y: 0, width: 1512, height: 982),
                  visibleFrame: .init(x: 0, y: 90, width: 1512, height: 859), safeTop: 32, notch: notch)
        })
        controller.setContent { AnyView(Text("Synthetic panel")) }
        return controller
    }
    @Test func theOwnedPanelOpensAtTheNotchAnchorAndReusesItsContentAfterDismissal() throws {
        let controller = controller()
        defer { controller.shutdown() }
        controller.show()
        let window = try #require(controller.window)
        #expect(controller.isVisible && window.isVisible)
        #expect(window.frame.midX == 756 && window.frame.maxY == 950)
        let content = window.contentView
        controller.toggle()
        #expect(!controller.isVisible && !window.isVisible)
        controller.show()
        #expect(controller.window === window && window.contentView === content)
        #expect(window.isVisible)
    }
    // Design direction: below a notch the panel hangs from the top edge with its shoulders, gives its
    // content the notch band for the header and resizes for a tab row, keeping the page budget.
    @Test func aNotchedPanelHangsFromTheTopEdgeAndFitsItsTabRow() async throws {
        let controller = controller(notch: Self.notch), probe = TabRowProbe()
        controller.setContent { AnyView(TabRowContent(probe: probe)) }
        defer { controller.shutdown() }
        controller.show()
        let window = try #require(controller.window)
        #expect(window.frame.midX == Self.notch.midX && window.frame.maxY == 982)
        #expect(window.frame.width == 490 && window.frame.height == 397)
        #expect(probe.band == NotchBand(height: 32, leading: 142.5, trailing: 142.5))
        probe.tabs = true
        let deadline = ContinuousClock.now + .seconds(10)
        while window.frame.height != 427, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(window.frame.height == 425 && window.frame.maxY == 982 && controller.isVisible)
        controller.hide(animated: false)
        controller.show()
        #expect(window.frame.height == 425 && window.frame.width == 490)
        // Outside clicks are measured against the body: the room beside it for the shoulders is outside.
        controller.outsideClick(at: .init(x: window.frame.minX + 12, y: window.frame.midY))
        #expect(controller.isVisible)
        controller.outsideClick(at: .init(x: window.frame.minX + 4, y: window.frame.midY))
        #expect(!controller.isVisible)
        // Content that already shows tabs opens at its full height, with no resize after the expansion starts.
        let tabbed = self.controller(notch: Self.notch), tabs = TabRowProbe()
        tabs.tabs = true
        tabbed.setContent { AnyView(TabRowContent(probe: tabs)) }
        defer { tabbed.shutdown() }
        tabbed.show()
        #expect(tabbed.window?.frame.height == 425)
    }
    @Test func escapeAndCloseDismissWithoutDestroyingTheRuntimeWindow() throws {
        let controller = controller()
        defer { controller.shutdown() }
        controller.show()
        let window = try #require(controller.window)
        window.cancelOperation(nil)
        #expect(!controller.isVisible)
        controller.show()
        window.performClose(nil)
        #expect(!controller.isVisible)
        controller.show()
        #expect(window.isVisible)
    }
    @Test func outsideClicksAndAnotherApplicationsActivationDismissOnlyThePanel() throws {
        let controller = controller()
        defer { controller.shutdown() }
        controller.show()
        let window = try #require(controller.window)
        controller.outsideClick(at: .init(x: window.frame.midX, y: window.frame.midY))
        #expect(controller.isVisible)
        controller.outsideClick(at: .init(x: window.frame.maxX + 1, y: window.frame.midY))
        #expect(!controller.isVisible)
        controller.show()
        controller.applicationActivated(processID: getpid())
        #expect(controller.isVisible)
        controller.applicationActivated(processID: -1)
        #expect(!controller.isVisible)
        controller.show()
        #expect(controller.window === window && window.isVisible)
    }

    @Test func hidingThePanelNotifiesAttachedCardsToDismiss() {
        let controller = controller()
        defer { controller.shutdown() }
        let clock = PanelTestClock()
        let observer = NotificationCenter.default.addObserver(forName: .companionPanelDidHide, object: controller, queue: .main) { _ in
            MainActor.assumeIsolated { clock.now += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.show()
        controller.hide(animated: false)
        #expect(clock.now == 1)
    }

    @Test func manualPresentationSuppressesCuesAndSurvivesTheirExpiry() {
        let controller = controller(), clock = PanelTestClock()
        let cues = TransientCuePanel(expanded: { [weak controller] in controller?.isVisible == true })
        controller.beforeShow = { cues.hide() }
        defer { cues.shutdown() }
        let model = SessionListModel(displayAvailable: { true }, elapsed: { clock.now }, presenter: cues)
        defer { model.shutdown(); controller.shutdown() }
        func event(_ turn: String) -> SessionSnapshot {
            .init(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .alive, phase: .running),
                  project: "Synthetic project", title: "Synthetic session", turnID: turn)
        }
        model.receive(event("first"), origin: .liveTransition)
        #expect(cues.isVisible)
        controller.show()
        #expect(controller.isVisible && !cues.isVisible)
        model.receive(event("second"), origin: .liveTransition)
        #expect(controller.isVisible && !cues.isVisible)
        clock.now = CuePresentation.displayDuration
        model.refreshPresentation()
        #expect(controller.isVisible && !cues.isVisible)
        controller.hide()
        model.refreshPresentation()
        #expect(!controller.isVisible && !cues.isVisible)
    }

    // AC-13.02, AC-13.05, AC-13.08: the newest cue replaces the island in one window that never takes focus.
    @Test func newestCueReplacesTheIslandInOneNonKeyWindow() throws {
        let cues = TransientCuePanel()
        defer { cues.shutdown() }
        func cue(_ turn: String, _ phase: TaskCue.Phase) -> TaskCue {
            TaskCue(sessionID: turn, connectionID: "connection", turnID: turn, title: "Synthetic project", phase: phase,
                    context: "Synthetic preview")
        }
        func visibleCueWindows() -> [NSWindow] {
            NSApplication.shared.windows.filter { $0.identifier?.rawValue == "Lunlet.cue" && $0.isVisible }
        }
        cues.show([cue("first", .started)])
        let window = try #require(visibleCueWindows().first)
        cues.show([cue("second", .finished(.succeeded))])
        #expect(cues.isVisible && visibleCueWindows().count == 1 && visibleCueWindows().first === window)
        #expect(!window.isKeyWindow && !window.canBecomeKey && !window.canBecomeMain && window.ignoresMouseEvents)
        if let notch = window.screen.map(PanelScreen.init)?.notch {
            // AppKit rounds the physical half-point notch edge when placing windows.
            #expect(window.frame.maxY >= notch.maxY - 1 && window.frame.minY <= notch.minY - 23)
        }
        cues.shutdown()
        #expect(!cues.isVisible && !window.isVisible)
    }

    // AC-24.03: Command-R and Command-comma act only while the pinned panel is key; a hover preview takes no keys.
    @Test(arguments: [false, true]) func refreshAndSettingsShortcutsWorkOnlyInTheKeyPinnedPanel(notched: Bool) async throws {
        let suite = "com.lunlet.test.keyboard.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lunlet-keyboard-\(UUID())")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let usage = AccountUsageModel(client: KeyboardAccount())
        let history = LocalUsageModel(reader: KeyboardUsage()), claudeHistory = LocalUsageModel(reader: KeyboardUsage())
        let hover = UsageHoverPanelController(observesSystemEvents: false)
        let claudeHover = UsageHoverPanelController(observesSystemEvents: false)
        let sessions = SessionListModel(displayAvailable: { false }, elapsed: { 0 }, presenter: KeyboardCues())
        let notifications = LockedCompletionNotifications(isLocked: { false }, power: KeyboardPower())
        let clock = PanelTestClock()
        let panel = CompanionPanel(preferences: PreferencesStore(defaults: defaults), skins: SkinCatalog(directory: directory),
                                   setup: FeishuSetupModel(store: KeyboardEnrollmentStore()),
                                   botSetup: BotChannelSetupModel(storeFactory: { _ in KeyboardCredentialStore() }),
                                   notifications: notifications, usage: usage, sessions: sessions, history: history,
                                   usageHover: hover, claudeHistory: claudeHistory, claudeUsageHover: claudeHover,
                                   refresh: { clock.now += 1 })
        let controller = controller(notch: notched ? Self.notch : nil)
        controller.setContent { AnyView(panel) }
        defer { controller.shutdown(); hover.shutdown(); claudeHover.shutdown(); sessions.shutdown() }
        func press(_ key: String, code: UInt16) throws {
            let window = try #require(controller.window)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, characters: key,
                                                      charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            NSApplication.shared.sendEvent(event)
        }
        // A hover preview is ordered front without becoming key, so shortcuts never reach it.
        controller.entryHoverChanged(true, on: nil)
        try await Task.sleep(for: .milliseconds(320))
        let window = try #require(controller.window)
        #expect(controller.isVisible && !controller.isPinned && !window.isKeyWindow)
        try press("r", code: 15)
        #expect(clock.now == 0)
        // Pinned and key: the same global Refresh and Settings actions as the header buttons.
        controller.pin()
        window.layoutIfNeeded()
        #expect(window.isKeyWindow)
        try press("r", code: 15)
        #expect(clock.now == 1)
        // The Settings action also closes the usage chart, which makes the shortcut observable here.
        hover.setContent { AnyView(Text("Synthetic chart")) }
        hover.showForKeyboard()
        #expect(hover.isVisible)
        controller.pin()
        #expect(window.isKeyWindow && hover.isVisible)
        try press(",", code: 43)
        #expect(!hover.isVisible)
        try press("r", code: 15)
        #expect(clock.now == 2)
        await history.shutdown(); await claudeHistory.shutdown(); await usage.shutdown(); await notifications.shutdown()
    }

    @Test func shutdownRemovesItsWindowAndCannotBeUndoneByALateOpen() {
        let controller = controller()
        controller.show()
        let window = controller.window
        controller.shutdown(); controller.shutdown(); controller.show(); controller.toggle()
        #expect(!controller.isVisible && controller.window == nil)
        #expect(window?.isVisible == false)
    }
    @Test func hoveringDoesNotStealFocusAndPinningSurvivesLeaving() async throws {
        let controller = controller()
        defer { controller.shutdown() }
        controller.entryHoverChanged(true, on: nil)
        #expect(!controller.isVisible)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.isVisible && !controller.isPinned)
        #expect(controller.window?.isKeyWindow == false)
        controller.entryHoverChanged(false, on: nil)
        controller.pointerChanged(false)
        try await Task.sleep(for: .milliseconds(100))
        controller.pointerChanged(true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.isVisible)
        controller.pin()
        controller.pointerChanged(false)
        try await Task.sleep(for: .milliseconds(450))
        #expect(controller.isVisible && controller.isPinned)
        controller.hide()
        #expect(!controller.isPinned)
    }
    @Test func enteringPanelBeforeEntryExitKeepsPreviewOpenUntilBothAreLeft() async throws {
        let controller = controller()
        defer { controller.shutdown() }
        controller.entryHoverChanged(true, on: nil)
        try await Task.sleep(for: .milliseconds(300))
        controller.pointerChanged(true)
        controller.entryHoverChanged(false, on: nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(controller.isVisible && !controller.isPinned)
        controller.pointerChanged(false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.isVisible)
        controller.pointerChanged(true)
        try await Task.sleep(for: .milliseconds(450))
        #expect(controller.isVisible)
        controller.pointerChanged(false)
        try await Task.sleep(for: .milliseconds(450))
        #expect(!controller.isVisible)
    }

    @Test func returningToEntryBeforePanelExitKeepsPreviewOpen() async throws {
        let controller = controller()
        defer { controller.shutdown() }
        controller.entryHoverChanged(true, on: nil)
        try await Task.sleep(for: .milliseconds(300))
        controller.entryHoverChanged(false, on: nil)
        controller.pointerChanged(true)
        controller.entryHoverChanged(true, on: nil)
        controller.pointerChanged(false)
        try await Task.sleep(for: .milliseconds(450))
        #expect(controller.isVisible && !controller.isPinned)
        controller.entryHoverChanged(false, on: nil)
        try await Task.sleep(for: .milliseconds(450))
        #expect(!controller.isVisible)
    }

    @Test func anAttachedChartKeepsThePreviewOpenAcrossItsGap() async throws {
        let controller = controller()
        defer { controller.shutdown() }
        controller.entryHoverChanged(true, on: nil)
        try await Task.sleep(for: .milliseconds(300))
        controller.auxiliaryHoverChanged(true)
        controller.entryHoverChanged(false, on: nil)
        controller.pointerChanged(false)
        try await Task.sleep(for: .milliseconds(450))
        #expect(controller.isVisible && !controller.isPinned)
        controller.auxiliaryHoverChanged(false)
        try await Task.sleep(for: .milliseconds(450))
        #expect(!controller.isVisible)
    }

    @Test func dismissalClosesAttachedContentBeforeRetracting() {
        let controller = controller()
        defer { controller.shutdown() }
        var attachedClosed = false
        controller.beforeHide = { attachedClosed = true }
        controller.show()
        controller.hide()
        #expect(attachedClosed && !controller.isVisible)
    }

    @Test func leavingBeforeHoverDelayAndShutdownCancelPendingOpens() async throws {
        let controller = controller()
        controller.entryHoverChanged(true, on: nil)
        controller.entryHoverChanged(false, on: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!controller.isVisible)
        controller.entryHoverChanged(true, on: nil)
        controller.shutdown()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!controller.isVisible && controller.window == nil)
    }
    @Test func leavingAnUnpinnedPreviewDismissesIt() async throws {
        let controller = controller()
        defer { controller.shutdown() }
        controller.entryHoverChanged(true, on: nil)
        try await Task.sleep(for: .milliseconds(300))
        controller.entryHoverChanged(false, on: nil)
        controller.pointerChanged(false)
        try await Task.sleep(for: .milliseconds(450))
        #expect(!controller.isVisible)
    }

    @Test func scrollingThePreviewPinsItButUnrelatedScrollDoesNot() async throws {
        let controller = controller()
        defer { controller.shutdown() }
        controller.entryHoverChanged(true, on: nil)
        try await Task.sleep(for: .milliseconds(300))
        controller.interactionOccurred(.scrollWheel, in: nil)
        #expect(!controller.isPinned)
        controller.interactionOccurred(.scrollWheel, in: controller.window)
        controller.pointerChanged(false)
        try await Task.sleep(for: .milliseconds(450))
        #expect(controller.isVisible && controller.isPinned)
    }

    @Test func returningToPanelDuringRetractionRestoresThePreview() async throws {
        let controller = CompanionPanelController(motionAllowed: { true }, observesSystemEvents: false)
        controller.setContent { AnyView(Text("Synthetic hover return")) }
        defer { controller.shutdown() }
        controller.entryHoverChanged(true, on: nil)
        try await Task.sleep(for: .milliseconds(450))
        controller.entryHoverChanged(false, on: nil)
        try await Task.sleep(for: .milliseconds(440))
        #expect(controller.isVisible)
        controller.pointerChanged(true)
        try await Task.sleep(for: .milliseconds(450))
        #expect(controller.isVisible && !controller.isPinned)
    }

    @Test func explicitDismissalCannotBeUndoneByLatePanelHover() async throws {
        let controller = CompanionPanelController(motionAllowed: { true }, observesSystemEvents: false)
        controller.setContent { AnyView(Text("Synthetic explicit close")) }
        defer { controller.shutdown() }
        controller.show()
        controller.hide()
        controller.pointerChanged(true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!controller.isVisible)
    }

    @Test func reopeningDuringRetractionCancelsTheOldClose() async throws {
        let controller = CompanionPanelController(motionAllowed: { true }, observesSystemEvents: false, screen: {
            .init(frame: .init(x: 0, y: 0, width: 1512, height: 982),
                  visibleFrame: .init(x: 0, y: 90, width: 1512, height: 859), safeTop: 32,
                  notch: .init(x: 663.5, y: 950, width: 185, height: 32))
        })
        controller.setContent { AnyView(Text("Synthetic connected surface")) }
        defer { controller.shutdown() }
        controller.show()
        try await Task.sleep(for: .milliseconds(420))
        controller.hide()
        #expect(controller.window?.isVisible == true)
        try await Task.sleep(for: .milliseconds(70))
        controller.show()
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.isVisible && controller.isPinned)
        controller.shutdown()
        #expect(controller.window == nil)
    }

}
