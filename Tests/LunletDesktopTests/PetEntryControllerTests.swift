// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-39, AC-39.01, AC-39.02, AC-39.05, AC-39.06; US-21, AC-21.03; US-26, AC-26.01.
import AppKit
import Foundation
import SwiftUI
import Testing
import LunletCore
@testable import LunletDesktop

@MainActor struct PetEntryControllerTests {
    private func store() throws -> PreferencesStore {
        let defaults = try #require(UserDefaults(suiteName: "lunlet-pet-" + UUID().uuidString))
        return PreferencesStore(defaults: defaults)
    }
    private func controller(_ preferences: PreferencesStore, screen: NSScreen?, available: Bool = true)
        -> (PetEntryController, SessionListModel) {
        let companion = CompanionPanelController(motionAllowed: { false }, observesSystemEvents: false)
        let sessions = SessionListModel(displayAvailable: { true }, elapsed: { 0 }, presenter: NoCues())
        let entry = PetEntryController(companion: companion, sessions: sessions, preferences: preferences,
                                       display: { screen }, available: { available }, motionAllowed: { false })
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
        let saved = preferences.value.petPositions[PetEntryController.key(for: screen)]
        #expect(saved?.x == origin.x - 24 && saved?.y == origin.y)
        // The display it was left on is remembered, so a relaunch brings it back there (AC-39.02).
        #expect(preferences.value.petDisplay == PetEntryController.key(for: screen))
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
        let above = PanelPlacement.panel(near: pet, tabRow: false, screen: screen)
        #expect(above.minY == pet.maxY + PanelPlacement.bubbleGap && above.width == PanelPlacement.panelWidth)
        #expect(above.maxX <= screen.visibleFrame.maxX && above.minX >= screen.visibleFrame.minX)
        #expect(above.height == PanelStyle.Layout.panelHeight(notchHeight: nil, tabRow: false) + BubbleTail.height)
        let tail = PanelPlacement.tail(panel: above, anchor: pet)
        #expect(tail.edge == .bottom && tail.x == pet.midX - above.minX)
        let high = CGRect(x: 100, y: 700, width: 64, height: 140)
        let below = PanelPlacement.panel(near: high, tabRow: true, screen: screen)
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
        #expect(window.frame == PanelPlacement.panel(near: first, tabRow: false, screen: geometry))
        let second = first.offsetBy(dx: 180, dy: 40)
        controller.move(near: second)
        #expect(window.frame == PanelPlacement.panel(near: second, tabRow: false, screen: geometry))
        controller.hide(animated: false)
        controller.move(near: first)
        #expect(window.frame == PanelPlacement.panel(near: second, tabRow: false, screen: geometry))
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
