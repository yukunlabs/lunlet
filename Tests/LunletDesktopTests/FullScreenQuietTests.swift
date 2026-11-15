// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-42, AC-42.01, AC-42.02, AC-42.03, AC-42.04.
import AppKit
import Testing
@testable import LunletDesktop

@MainActor struct FullScreenQuietTests {
    /// A notched display, in the top-left coordinates the window server reports.
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private func window(_ pid: pid_t, _ frame: CGRect, layer: Int = 0) -> ScreenWindow { .init(pid: pid, layer: layer, frame: frame) }

    @Test func aWindowThatCoversTheMenuBarMakesItsApplicationTheFullScreenOne() {
        // In full screen a window covers the whole display, the menu bar's strip included; no ordinary window can.
        #expect(FullScreenScene.owner(of: display, windows: [window(7, display)]) == 7)
        // Lunlet's own entry and the menu bar sit above it on other layers and do not count.
        let above = [window(1, CGRect(x: 611, y: 0, width: 289, height: 49), layer: 26), window(2, CGRect(x: 0, y: 0, width: 1512, height: 33), layer: 24)]
        #expect(FullScreenScene.owner(of: display, windows: above + [window(7, display)]) == 7)
        // The application's own sheet or controls in front of its full-screen window change nothing.
        #expect(FullScreenScene.owner(of: display, windows: [window(7, CGRect(x: 500, y: 300, width: 400, height: 200)), window(7, display)]) == 7)
    }

    @Test func ordinaryWindowsLeaveTheDisplayToTheDesktop() {
        // A zoomed window starts below the menu bar.
        #expect(FullScreenScene.owner(of: display, windows: [window(7, CGRect(x: 0, y: 33, width: 1512, height: 949))]) == nil)
        #expect(FullScreenScene.owner(of: display, windows: []) == nil)
        // Another application's window in front means the filling window is not what is being looked at.
        let behind = [window(9, CGRect(x: 100, y: 100, width: 800, height: 600)), window(7, display)]
        #expect(FullScreenScene.owner(of: display, windows: behind) == nil)
        // A window that fills another display says nothing about this one.
        let other = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        #expect(FullScreenScene.owner(of: display, windows: [window(7, other)]) == nil)
        #expect(FullScreenScene.owner(of: other, windows: [window(7, other), window(9, CGRect(x: 0, y: 33, width: 1512, height: 949))]) == 7)
    }

    @Test func theChoiceIsSavedAndStartsAsWithTheMenuBar() throws {
        // AC-42.03.
        #expect(LunletPreferences().fullScreen == .menuBar)
        let saved = try JSONDecoder().decode(LunletPreferences.self, from: Data(#"{"schemaVersion":1}"#.utf8))
        #expect(saved.fullScreen == .menuBar)
        // A value this version does not know starts as the default.
        let unknown = try JSONDecoder().decode(LunletPreferences.self, from: Data(#"{"schemaVersion":1,"fullScreen":"video"}"#.utf8))
        #expect(unknown.fullScreen == .menuBar)
        var changed = LunletPreferences(); changed.fullScreen = .never
        let again = try JSONDecoder().decode(LunletPreferences.self, from: JSONEncoder().encode(changed))
        #expect(again.fullScreen == .never)
        #expect(FullScreenPolicy.allCases.map(\.title) == ["With the menu bar", "Never"])
    }

    private let away = CGPoint(x: 700, y: 500)

    @Test func theWatcherReportsADisplayWhileItIsInFullScreen() {
        // AC-42.01: one reading of the system serves every part of Lunlet.
        var windows: [ScreenWindow] = [], spaces: Set<CGDirectDisplayID> = [], changes = 0
        let quiet = FullScreenQuiet(windows: { windows }, spaces: { spaces }, pointer: { self.away }, displays: { [1: self.display] })
        quiet.changed = { changes += 1 }
        quiet.refresh()
        #expect(!quiet.isQuiet(display: 1) && changes == 0)
        // A browser's full-screen window stays below the strip beside the notch, as a zoomed window does; it is the
        // system that says the Space in front is a full-screen one.
        windows = [window(7, CGRect(x: 0, y: 33, width: 1512, height: 949))]
        quiet.refresh()
        #expect(!quiet.isQuiet(display: 1) && changes == 0)
        spaces = [1]
        quiet.refresh()
        #expect(quiet.isQuiet(display: 1) && !quiet.isQuiet(display: 2) && changes == 1)
        quiet.refresh()
        #expect(changes == 1)
        // A window that covers the whole display counts by itself: the Space is announced only when the move into
        // it has ended, and a window can cover the display without a Space of its own.
        spaces = []; windows = [window(7, display)]
        quiet.refresh()
        #expect(quiet.isQuiet(display: 1) && changes == 1)
        // AC-42.03: Never keeps the entry.
        quiet.leave = .never
        #expect(!quiet.isQuiet(display: 1) && changes == 2)
        quiet.leave = .withMenuBar
        #expect(quiet.isQuiet(display: 1) && changes == 3)
        windows = []
        quiet.refresh()
        #expect(!quiet.isQuiet(display: 1) && changes == 4)
    }

    @Test func theEntryReturnsWhileThePointerIsWhereTheMenuBarComesDown() {
        // AC-42.02: the menu bar comes down when the pointer reaches the top edge and stays while the pointer is in it.
        var point = away
        let quiet = FullScreenQuiet(windows: { [] }, spaces: { [1] }, pointer: { point }, displays: { [1: self.display] })
        quiet.refresh()
        #expect(quiet.isQuiet(display: 1))
        point = CGPoint(x: 300, y: 0)
        quiet.refresh()
        #expect(!quiet.isQuiet(display: 1))
        // The pointer moves along the strip to the entry, which reaches a little below the bar.
        point = CGPoint(x: 800, y: 45)
        quiet.refresh()
        #expect(!quiet.isQuiet(display: 1))
        point = CGPoint(x: 800, y: 200)
        quiet.refresh()
        #expect(quiet.isQuiet(display: 1))
        // Passing near the top without reaching the edge calls nothing down.
        point = CGPoint(x: 800, y: 20)
        quiet.refresh()
        #expect(quiet.isQuiet(display: 1))
        // The top edge of another display says nothing about this one.
        point = CGPoint(x: 2_000, y: 0)
        quiet.refresh()
        #expect(quiet.isQuiet(display: 1))
    }

    @Test func thePetLeavesEveryFullScreenAndDoesNotReturnWithThePointer() {
        // AC-39.02: the pet is not part of the menu bar; a full-screen application in front takes the display,
        // wherever the pointer is and whatever the menu bar does.
        var point = away, spaces: Set<CGDirectDisplayID> = [1]
        let quiet = FullScreenQuiet(windows: { [] }, spaces: { spaces }, pointer: { point }, barStays: { true }, displays: { [1: self.display] })
        quiet.leave = .always
        #expect(quiet.isQuiet(display: 1))
        point = CGPoint(x: 300, y: 0)
        quiet.refresh()
        #expect(quiet.isQuiet(display: 1))
        spaces = []
        quiet.refresh()
        #expect(!quiet.isQuiet(display: 1))
    }

    @Test func theEntryInUseDecidesHowFullScreenIsTreated() {
        // AC-42.03: the choice belongs to the notch entry; the menu-bar entry follows the bar and the pet always leaves.
        #expect(FullScreenQuiet.leave(for: .notch, choice: .menuBar) == .withMenuBar)
        #expect(FullScreenQuiet.leave(for: .notch, choice: .never) == .never)
        #expect(FullScreenQuiet.leave(for: .menuBar, choice: .never) == .withMenuBar)
        #expect(FullScreenQuiet.leave(for: .pet, choice: .never) == .always)
        #expect(FullScreenQuiet.leave(for: .pet, choice: .menuBar) == .always)
    }

    @Test func aMenuBarThatStaysInFullScreenKeepsTheEntry() {
        // The system can keep the menu bar in full screen; the entry stays with it and nothing more is read.
        var reads = 0
        let quiet = FullScreenQuiet(windows: { reads += 1; return [] }, spaces: { [1] }, pointer: { self.away }, barStays: { true },
                                    displays: { [1: self.display] })
        quiet.refresh()
        #expect(!quiet.isQuiet(display: 1) && reads == 0)
    }

    @Test func theMacLeftAloneIsReadOnlyNowAndThen() {
        // AC-42.04: full screen begins and ends, and the pointer calls the menu bar, by the keyboard or the pointer.
        // While neither has been touched for a few seconds, a reading now and then is enough for what an
        // application does by itself, such as leaving full screen when a film ends.
        var reads = 0, idle: TimeInterval = 0.2, uptime: TimeInterval = 100
        let quiet = FullScreenQuiet(windows: { reads += 1; return [] }, spaces: { [] }, pointer: { self.away }, displays: { [1: self.display] },
                                    idle: { idle }, uptime: { uptime })
        // In use: every step of the pace reads.
        for _ in 0..<4 { uptime += FullScreenQuiet.pace; quiet.tick() }
        #expect(reads == 4)
        // Left alone: the steps go by without a reading until the slower interval has passed.
        idle = FullScreenQuiet.rest + 1
        for _ in 0..<4 { uptime += FullScreenQuiet.pace; quiet.tick() }
        #expect(reads == 4)
        uptime += FullScreenQuiet.leftAlonePace
        quiet.tick()
        #expect(reads == 5)
        quiet.tick()
        #expect(reads == 5)
        // Touched again: the next step reads at once.
        idle = 0
        uptime += FullScreenQuiet.pace
        quiet.tick()
        #expect(reads == 6)
        // A move out of full screen can end a moment after the key that began it.
        #expect(FullScreenQuiet.rest >= 2 && FullScreenQuiet.leftAlonePace >= 2 && FullScreenQuiet.leftAlonePace <= 5)
    }

    @Test func aDisplayKnownToBeInFullScreenNeedsNoWindowList() {
        // AC-42.04: the windows are listed only to learn of full screen early; the kind of Space settles it.
        var lists = 0, spaces: Set<CGDirectDisplayID> = [1]
        let quiet = FullScreenQuiet(windows: { lists += 1; return [] }, spaces: { spaces }, pointer: { self.away }, displays: { [1: self.display] })
        quiet.refresh()
        #expect(quiet.isQuiet(display: 1) && lists == 0)
        spaces = []
        quiet.refresh()
        #expect(!quiet.isQuiet(display: 1) && lists == 1)
    }

    @Test func theSystemIsReadOnlyWhileTheEntryCanLeave() {
        // AC-42.04: the system announces neither an application entering full screen nor its menu bar coming down,
        // so it is read on a pace, and not at all when the entry never leaves.
        var reads = 0
        let quiet = FullScreenQuiet(windows: { reads += 1; return [] }, spaces: { [] }, pointer: { self.away }, displays: { [1: self.display] })
        quiet.refresh()
        #expect(reads == 1)
        quiet.leave = .never
        quiet.refresh()
        #expect(reads == 1)
        // A reading must fall inside the half second an application takes to move into full screen.
        #expect(FullScreenQuiet.pace <= 0.25)
    }
}
