// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-39, AC-39.01, AC-39.02, AC-39.03, AC-39.04, AC-39.05, AC-39.06, AC-39.07, AC-39.08; US-21, AC-21.03; US-26, AC-26.01; US-25, AC-25.01.
import AppKit
import Foundation
import SwiftUI
import Testing
import LunletCore
@testable import LunletDesktop

@MainActor struct PetEntryControllerTests {
    private func store() throws -> PreferencesStore {
        let defaults = try ScratchSettings.make("pet").defaults
        return PreferencesStore(defaults: defaults)
    }
    private func controller(_ preferences: PreferencesStore, screen: NSScreen?, available: Bool = true,
                            uptime: @escaping @MainActor () -> TimeInterval = { 0 }) -> (PetEntryController, SessionListModel) {
        let companion = CompanionPanelController(motionAllowed: { false }, observesSystemEvents: false)
        let sessions = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: NoCues())
        let entry = PetEntryController(companion: companion, sessions: sessions, preferences: preferences,
                                       display: { screen }, available: { available }, motionAllowed: { false }, uptime: uptime)
        return (entry, sessions)
    }
    private final class NoCues: TaskCuePresenting {
        func show(_ cues: [TaskCue]) {}
        func hide() {}
    }

    @Test func windowAppearsOnlyInPetModeOnAnAvailableDisplayAndSitsInsideIt() throws {
        let preferences = try store(), screen = try #require(NSScreen.main)
        let (entry, _) = controller(preferences, screen: screen)
        entry.start()
        #expect(entry.window == nil)
        preferences.update { $0.presentation = .pet }
        let window = try #require(entry.window)
        #expect(window.isVisible && screen.visibleFrame.contains(window.frame))
        #expect(window.frame.size == PetEntryController.windowSize)
        #expect(window.level == .floating && !window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        preferences.update { $0.presentation = .notch }
        #expect(entry.window?.isVisible == false)
        entry.shutdown()
    }

    // Refs: US-39, AC-39.05. The right-click menu's Settings asks for the Settings page, then opens the panel.
    @Test func theContextMenuOffersOpenRefreshSettingsAndQuitAndSettingsAsksForItsPage() throws {
        let preferences = try store(), screen = try #require(NSScreen.main)
        let (entry, _) = controller(preferences, screen: screen)
        var asked = 0
        entry.settingsAction = { asked += 1 }
        let menu = entry.menu()
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Open Lunlet", "Refresh", "Settings…", "Quit"])
        let settings = try #require(menu.item(withTitle: "Settings…"))
        #expect(settings.target === entry)
        _ = NSApplication.shared.sendAction(try #require(settings.action), to: settings.target, from: settings)
        #expect(asked == 1)
        entry.shutdown()
    }

    // Refs: US-39, AC-39.03, AC-39.04, AC-39.07. The pose, the tooltip and the accessibility label follow the session
    // list as it changes, not one change behind it.
    @Test func theShownStateFollowsTheSessionListAtOnce() throws {
        let preferences = try store(), screen = try #require(NSScreen.main)
        let (entry, sessions) = controller(preferences, screen: screen)
        defer { entry.shutdown() }
        #expect(entry.shownState.pose == .asleep && entry.shownState.summary == "Monitoring unavailable")
        // Connected first, so availability stays the same below and only the list changes.
        sessions.monitoringConnected(partial: false)
        #expect(entry.shownState.summary == nil)
        let id = UUID(), connection = UUID()
        func snapshot(_ phase: SessionPhase, liveness: CLILiveness = .unverified) -> SessionSnapshot {
            .init(observation: .init(sessionID: id, connectionID: connection, liveness: liveness, phase: phase),
                  project: "Synthetic", title: "Session", turnID: "one", activityConfirmed: true)
        }
        sessions.receive(snapshot(.approval), origin: .snapshot)
        #expect(entry.shownState.pose == .waiting && entry.shownState.sessionID == id && entry.shownState.waitingCount == 1)
        sessions.receive(snapshot(.running), origin: .snapshot)
        #expect(entry.shownState.pose == .working && entry.shownState.runningCount == 1)
        // The session's process ended: nothing is current, so the dog sleeps at once.
        sessions.receive(snapshot(.ended, liveness: .ended), origin: .snapshot)
        #expect(entry.shownState.pose == .asleep && entry.shownState.sessionCount == 0)
        sessions.monitoringUnavailable()
        #expect(entry.shownState.summary == "Monitoring unavailable")
    }

    @Test func savedPositionIsRestoredPerDisplayAndClamped() throws {
        let preferences = try store(), screen = try #require(NSScreen.main)
        let key = PetEntryController.key(for: screen)
        preferences.update { $0.petPositions[key] = .init(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 60) }
        let (entry, _) = controller(preferences, screen: screen)
        #expect(entry.frame(on: screen).origin == CGPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 60))
        preferences.update { $0.petPositions[key] = .init(x: screen.visibleFrame.maxX + 500, y: screen.visibleFrame.maxY + 500) }
        let clamped = entry.frame(on: screen)
        #expect(screen.visibleFrame.contains(clamped))
        preferences.update { $0.petPositions = [:] }
        let fallback = entry.frame(on: screen)
        #expect(fallback.maxX == screen.visibleFrame.maxX - PetEntryController.margin && fallback.minY == screen.visibleFrame.minY + PetEntryController.margin)
        entry.shutdown()
    }

    @Test func lockedDisplayHidesThePet() throws {
        let preferences = try store(), screen = try #require(NSScreen.main)
        preferences.update { $0.presentation = .pet }
        let (entry, _) = controller(preferences, screen: screen, available: false)
        entry.start()
        #expect(entry.window == nil || entry.window?.isVisible == false)
        entry.shutdown()
    }

    private final class Counter { var count = 0 }

    @Test func displayAvailabilityIsReadWhenTheDisplayChangesNotOnEveryUpdate() throws {
        let preferences = try store(), screen = try #require(NSScreen.main)
        preferences.update { $0.presentation = .pet }
        let reads = Counter()
        let companion = CompanionPanelController(motionAllowed: { false }, observesSystemEvents: false)
        let sessions = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: NoCues())
        let entry = PetEntryController(companion: companion, sessions: sessions, preferences: preferences,
                                       display: { screen }, available: { reads.count += 1; return true }, motionAllowed: { false })
        defer { entry.shutdown() }
        entry.refresh()
        let afterRefresh = reads.count
        #expect(afterRefresh >= 1)
        // Cues, the panel and the pointer change the pose or the gaze many times a second; none of them is a display change.
        entry.show([TaskCue(sessionID: "s", connectionID: "c", turnID: "t", title: "Synthetic project", phase: .finished(.succeeded))])
        entry.hide()
        entry.panelVisibilityChanged(true, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        entry.panelVisibilityChanged(false, frame: nil)
        #expect(reads.count == afterRefresh)
    }

    // Refs: US-39, AC-39.06, AC-39.08; US-25, AC-25.01. On another Space, behind a full-screen app or fully covered,
    // the pet is not shown, so nothing frames it and no pointer move is followed until it shows again.
    @Test func framingAndPointerTrackingStopWhileThePetIsNotOnScreen() throws {
        let preferences = try store(), screen = try #require(NSScreen.main)
        preferences.update { $0.presentation = .pet }
        var showing = true
        let companion = CompanionPanelController(motionAllowed: { false }, observesSystemEvents: false)
        let sessions = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: NoCues())
        let entry = PetEntryController(companion: companion, sessions: sessions, preferences: preferences,
                                       display: { screen }, available: { true }, motionAllowed: { true }, onScreen: { _ in showing })
        defer { entry.shutdown() }
        entry.refresh()
        let window = try #require(entry.window)
        #expect(entry.isFraming && entry.tracksPointer)
        showing = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(!entry.isFraming && !entry.tracksPointer)
        // A session change while the pet is not shown updates its state without starting frames again.
        sessions.receive(.init(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: .unverified, phase: .running),
                               project: "Synthetic", title: "Session", turnID: "one", activityConfirmed: true), origin: .snapshot)
        #expect(entry.shownState.pose == .working && !entry.isFraming && !entry.tracksPointer)
        // Another window's occlusion change is not the pet's.
        showing = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: NSWindow())
        #expect(!entry.isFraming && !entry.tracksPointer)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(entry.isFraming && entry.tracksPointer)
        // Left not showing, so no frame clock outlives the test.
        showing = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(!entry.isFraming)
    }

    @Test func aDragSavesThePositionOnceWhenItEnds() throws {
        let preferences = try store(), screen = try #require(NSScreen.main)
        preferences.update { $0.presentation = .pet }
        let (entry, _) = controller(preferences, screen: screen)
        defer { entry.shutdown() }
        entry.refresh()
        let window = try #require(entry.window)
        let saves = Counter()
        let observation = preferences.$value.dropFirst().sink { _ in saves.count += 1 }
        defer { observation.cancel() }
        let origin = window.frame.origin
        entry.dragStarted()
        for step in 1...3 { window.setFrameOrigin(CGPoint(x: origin.x - CGFloat(step) * 8, y: origin.y)) }
        // The window moves with every pointer event; the preference is written when the drag ends.
        #expect(saves.count == 0)
        entry.dragEnded()
        #expect(saves.count == 1)
        // The place is the origin's offset from the display's visible corner, so it stays valid if the display moves.
        let saved = preferences.value.petPositions[PetEntryController.key(for: screen)]
        #expect(saved == .init(x: origin.x - 24 - screen.visibleFrame.minX, y: origin.y - screen.visibleFrame.minY, relative: true))
        #expect(entry.frame(on: screen).origin == CGPoint(x: origin.x - 24, y: origin.y))
        // The display it was left on is remembered, so a relaunch brings it back there (AC-39.02).
        #expect(preferences.value.petDisplay == PetEntryController.key(for: screen))
    }

    // Refs: US-39, AC-39.02. A place is kept relative to its display, so it survives the display's origin changing
    // when another display is unplugged or rearranged; a place an earlier build saved is still read as it was meant.
    @Test func aPlaceKeepsItsSpotOnItsDisplayWhenTheDisplayArrangementChanges() throws {
        // The built-in display sits left of an external main display; later it is the only display and starts at zero.
        let docked = CGRect(x: -1512, y: 0, width: 1512, height: 944), alone = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let origin = CGPoint(x: -300, y: 120)
        let place = PetEntryController.place(origin: origin, visible: docked)
        #expect(place == .init(x: 1212, y: 120, relative: true))
        #expect(PetEntryController.frame(saved: place, visible: docked).origin == origin)
        #expect(PetEntryController.frame(saved: place, visible: alone).origin == CGPoint(x: 1212, y: 120))
        // A Dock that appears at the bottom raises the visible area; the pet keeps its distance from that corner.
        let raised = CGRect(x: 0, y: 80, width: 1512, height: 864)
        #expect(PetEntryController.frame(saved: place, visible: raised).origin == CGPoint(x: 1212, y: 200))
        // A smaller display clamps the place inside its visible area.
        let small = CGRect(x: 0, y: 0, width: 1000, height: 600)
        #expect(small.contains(PetEntryController.frame(saved: place, visible: small)))
        // An earlier build's place has no marker and is a global origin.
        let earlier = LunletPreferences.PetPosition(x: 900, y: 200)
        #expect(earlier.relative == nil && PetEntryController.frame(saved: earlier, visible: alone).origin == CGPoint(x: 900, y: 200))
        // Both forms survive saving: the earlier one stays without a marker.
        var value = LunletPreferences(); value.petPositions = ["1": place, "2": earlier]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(LunletPreferences.self, from: data).petPositions == ["1": place, "2": earlier])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try #require(object["petPositions"] as? [String: [String: Any]])
        #expect(stored["1"]?["relative"] as? Bool == true && stored["2"]?["relative"] == nil)
    }

    // Refs: US-39, AC-39.02; US-26, AC-26.01. At launch an earlier build's place is rewritten for its connected
    // display without moving the pet; a disconnected display's place waits untouched.
    @Test func anEarlierBuildsPlaceIsAdoptedForItsConnectedDisplayWithoutMovingThePet() throws {
        let preferences = try store(), screen = try #require(NSScreen.main)
        let key = PetEntryController.key(for: screen), visible = screen.visibleFrame
        let global = CGPoint(x: visible.minX + 40, y: visible.minY + 60)
        preferences.update {
            $0.petPositions[key] = .init(x: global.x, y: global.y); $0.petPositions["99999"] = .init(x: 5, y: 6); $0.petDisplay = key
        }
        let (entry, _) = controller(preferences, screen: screen)
        defer { entry.shutdown() }
        #expect(entry.frame(on: screen).origin == global)
        entry.start()
        #expect(preferences.value.petPositions[key] == .init(x: 40, y: 60, relative: true))
        #expect(entry.frame(on: screen).origin == global)
        #expect(preferences.value.petPositions["99999"] == .init(x: 5, y: 6) && preferences.value.petDisplay == key)
        // Adopted once: starting again writes nothing.
        let saves = Counter()
        let observation = preferences.$value.dropFirst().sink { _ in saves.count += 1 }
        defer { observation.cancel() }
        let (again, _) = controller(preferences, screen: screen)
        defer { again.shutdown() }
        again.start()
        #expect(saves.count == 0)
    }

    // Refs: US-39, AC-39.02. Only the owner's drag sets the pet's place: a move the system makes when a display
    // changes is not saved as the place, and the pet returns to where it was left.
    @Test func aMoveThatIsNoDragIsNotSavedAndThePetReturnsToItsPlace() throws {
        let preferences = try store(), screen = try #require(NSScreen.main)
        preferences.update { $0.presentation = .pet }
        var now: TimeInterval = 100
        let (entry, _) = controller(preferences, screen: screen, uptime: { now })
        defer { entry.shutdown() }
        entry.refresh()
        let window = try #require(entry.window)
        let saves = Counter()
        let observation = preferences.$value.dropFirst().sink { _ in saves.count += 1 }
        defer { observation.cancel() }
        let home = window.frame.origin
        // As the system does when the display the window was on goes away.
        window.setFrameOrigin(CGPoint(x: home.x - 60, y: home.y + 30))
        #expect(saves.count == 0 && preferences.value.petPositions.isEmpty && preferences.value.petDisplay == nil)
        #expect(window.frame.origin == home)
        // The owner's drag does set it, and the window server's last move of that drag may arrive just after it ends.
        entry.dragStarted()
        window.setFrameOrigin(CGPoint(x: home.x - 40, y: home.y))
        entry.dragEnded()
        #expect(saves.count == 1)
        now += 0.1
        window.setFrameOrigin(CGPoint(x: home.x - 48, y: home.y))
        #expect(saves.count == 2 && entry.frame(on: screen).origin == CGPoint(x: home.x - 48, y: home.y))
        // Long after the drag a move is again not the owner's.
        now += 5
        window.setFrameOrigin(CGPoint(x: home.x - 120, y: home.y + 50))
        #expect(saves.count == 2 && window.frame.origin == CGPoint(x: home.x - 48, y: home.y))
        // If the system insists on the same spot again, the pet stays there rather than fight, still unsaved.
        window.setFrameOrigin(CGPoint(x: home.x - 120, y: home.y + 50))
        #expect(saves.count == 2 && window.frame.origin == CGPoint(x: home.x - 120, y: home.y + 50))
    }

    @Test func thePetReturnsToTheDisplayItWasLastPlacedOn() {
        let connected = ["1", "7"]
        func chosen(last: String?, placed: Set<String>) -> String? {
            PetEntryController.preferredDisplay(last: last, placed: placed, among: connected, key: { $0 }, fallback: "7")
        }
        // The display it was last on wins while it is connected, whatever display has the focused window.
        #expect(chosen(last: "1", placed: ["1", "7"]) == "1")
        // Disconnected, the one connected display that ever held it is next; otherwise the runtime's choice stands.
        #expect(chosen(last: "9", placed: ["9", "1"]) == "1")
        #expect(chosen(last: "9", placed: ["9", "1", "7"]) == "7")
        #expect(chosen(last: nil, placed: ["1"]) == "1")
        #expect(chosen(last: nil, placed: []) == "7")
    }

    @Test func panelOpensAsTheDogsBubbleWithoutNotchShoulders() {
        let screen = PanelScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 870),
                                 safeTop: 32, notch: CGRect(x: 650, y: 950, width: 212, height: 32))
        let pet = CGRect(x: 1300, y: 104, width: 64, height: 140)
        let above = PanelPlacement.panel(near: pet, screen: screen)
        #expect(above.minY == pet.maxY + PanelPlacement.bubbleGap && above.width == PanelPlacement.panelWidth)
        #expect(above.maxX <= screen.visibleFrame.maxX && above.minX >= screen.visibleFrame.minX)
        #expect(above.height == PanelStyle.Layout.panelHeight(notchHeight: nil) + BubbleTail.height)
        let tail = PanelPlacement.tail(panel: above, anchor: pet)
        #expect(tail.edge == .bottom && tail.x == pet.midX - above.minX)
        let high = CGRect(x: 100, y: 700, width: 64, height: 140)
        let below = PanelPlacement.panel(near: high, screen: screen)
        #expect(below.maxY == high.minY - PanelPlacement.bubbleGap && screen.visibleFrame.contains(below))
        #expect(PanelPlacement.tail(panel: below, anchor: high).edge == .top)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_PANEL"] == "1"))
    func anOpenBubbleFollowsItsAnchorWhenTheDogMoves() throws {
        let screen = try #require(NSScreen.main), geometry = PanelScreen(screen)
        let controller = CompanionPanelController(motionAllowed: { false }, observesSystemEvents: false, screen: { geometry })
        controller.setContent { AnyView(Text("Synthetic bubble")) }
        let visible = screen.visibleFrame
        let first = CGRect(x: visible.minX + 300, y: visible.minY + 100, width: 64, height: 140)
        controller.show(on: screen, near: first)
        let window = try #require(controller.window)
        #expect(window.frame == PanelPlacement.panel(near: first, screen: geometry))
        let second = first.offsetBy(dx: 180, dy: 40)
        controller.move(near: second)
        #expect(window.frame == PanelPlacement.panel(near: second, screen: geometry))
        controller.hide(animated: false)
        controller.move(near: first)
        #expect(window.frame == PanelPlacement.panel(near: second, screen: geometry))
        controller.shutdown()
    }

    @Test func bubbleGrowsFromItsTailTipAndKeepsOneOutline() {
        let size = CGSize(width: 470, height: 400)
        for edge in [BubbleTail.Edge.bottom, .top] {
            let tail = BubbleTail(edge: edge, x: 120)
            let open = NotchSurfaceGeometry.bubble(size: size, tail: tail, progress: 1)
            #expect(open.boundingBoxOfPath == CGRect(origin: .zero, size: size))
            let tipY: CGFloat = edge == .bottom ? 0 : size.height
            #expect(open.contains(CGPoint(x: 120, y: tipY + (edge == .bottom ? 1 : -1))))
            #expect(!open.contains(CGPoint(x: 120 + BubbleTail.width, y: tipY + (edge == .bottom ? 2 : -2))))
            let closed = NotchSurfaceGeometry.bubble(size: size, tail: tail, progress: 0)
            let box = closed.boundingBoxOfPath
            #expect(box.width < 1 && box.height < 1 && abs(box.midX - 120) < 1 && abs(box.midY - tipY) < 1)
            var elements = (0, 0)
            open.applyWithBlock { _ in elements.0 += 1 }
            closed.applyWithBlock { _ in elements.1 += 1 }
            #expect(elements.0 == elements.1)
        }
        // A tip near the edge stays inside the rounded corner.
        let edgeTip = NotchSurfaceGeometry.bubble(size: size, tail: BubbleTail(edge: .bottom, x: 2), progress: 1)
        #expect(edgeTip.contains(CGPoint(x: BubbleTail.width / 2 + NotchSurfaceGeometry.cornerRadius, y: 1)))
    }

    @Test func petPreferencesRoundTripAndDefaultToTheGoldenCoat() throws {
        var value = LunletPreferences()
        #expect(value.petCoat == .golden && value.presentation == .notch && EntryPresentation(rawValue: "pet") == .pet)
        value.presentation = .pet; value.petCoat = .slate; value.petPositions["1"] = .init(x: 12, y: 34); value.petDisplay = "1"
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(LunletPreferences.self, from: data)
        #expect(decoded == value)
        var oversized = value
        for index in 0..<17 { oversized.petPositions[String(index)] = .init(x: 0, y: 0) }
        #expect(throws: PreferenceFailure.invalidValue) { try oversized.validate() }
        var blank = value; blank.petDisplay = ""
        #expect(throws: PreferenceFailure.invalidValue) { try blank.validate() }
    }

    @Test func silhouetteCoversTheDogAndNotTheCorners() {
        let waiting = PetDrawing.silhouette(pose: .waiting)
        #expect(waiting.contains(CGPoint(x: 110, y: 80)) && waiting.contains(CGPoint(x: 110, y: 150)) && waiting.contains(CGPoint(x: 150, y: 10)))
        #expect(!waiting.contains(CGPoint(x: 5, y: 5)) && !waiting.contains(CGPoint(x: 215, y: 185)))
        let asleep = PetDrawing.silhouette(pose: .asleep)
        #expect(asleep.contains(CGPoint(x: 104, y: 108)) && !asleep.contains(CGPoint(x: 150, y: 10)))
        let transform = PetDrawing.transform(for: CGSize(width: 176, height: 152))
        #expect(abs(transform.a - 0.8) < 0.001 && abs(transform.d - 0.8) < 0.001)
    }
}
