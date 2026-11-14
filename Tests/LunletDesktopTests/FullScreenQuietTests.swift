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

    @Test func aWindowThatFillsTheDisplayMakesItsApplicationTheFullScreenOne() {
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

    @Test func videoIsAFullScreenApplicationKeepingTheDisplayAwake() {
        let app = "/Applications/Player.app"
        // The application itself, as a video player or a browser's main process does.
        #expect(FullScreenScene.showsVideo(owner: 7, bundlePath: app, bundleID: "com.example.player", awake: [.init(pid: 7, path: app + "/Contents/MacOS/Player")]))
        // A helper process that lives inside its bundle.
        #expect(FullScreenScene.showsVideo(owner: 7, bundlePath: app, bundleID: "com.example.player",
                                           awake: [.init(pid: 8, path: app + "/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")]))
        // Safari plays through WebKit's own processes, which live in the system.
        let webKit = AwakeProcess(pid: 8, path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU")
        #expect(FullScreenScene.showsVideo(owner: 7, bundlePath: "/Applications/Safari.app", bundleID: "com.apple.Safari", awake: [webKit]))
        // A terminal in full screen is not video because something else keeps the display awake.
        #expect(!FullScreenScene.showsVideo(owner: 7, bundlePath: "/Applications/Terminal.app", bundleID: "com.example.terminal", awake: [webKit]))
        #expect(!FullScreenScene.showsVideo(owner: 7, bundlePath: "/Applications/Terminal.app", bundleID: "com.example.terminal",
                                            awake: [.init(pid: 9, path: "/usr/bin/caffeinate"), .init(pid: 10, path: "/Applications/TerminalHelper.app/Contents/MacOS/x")]))
        #expect(!FullScreenScene.showsVideo(owner: 7, bundlePath: app, bundleID: "com.example.player", awake: []))
    }

    @Test func thePolicyDecidesWhenTheEntryStepsAside() {
        // AC-42.01, AC-42.02: by default only for video; a full-screen editor keeps the entry.
        #expect(FullScreenScene.isQuiet(policy: .video, fullScreen: true, video: true))
        #expect(!FullScreenScene.isQuiet(policy: .video, fullScreen: true, video: false))
        // AC-42.03: or for every full-screen application, or never.
        #expect(FullScreenScene.isQuiet(policy: .always, fullScreen: true, video: false))
        #expect(!FullScreenScene.isQuiet(policy: .never, fullScreen: true, video: true))
        for policy in FullScreenPolicy.allCases { #expect(!FullScreenScene.isQuiet(policy: policy, fullScreen: false, video: true)) }
    }

    @Test func theChoiceIsSavedAndStartsAsDuringVideo() throws {
        #expect(LunletPreferences().fullScreen == .video)
        let saved = try JSONDecoder().decode(LunletPreferences.self, from: Data(#"{"schemaVersion":1}"#.utf8))
        #expect(saved.fullScreen == .video)
        var changed = LunletPreferences(); changed.fullScreen = .always
        let again = try JSONDecoder().decode(LunletPreferences.self, from: JSONEncoder().encode(changed))
        #expect(again.fullScreen == .always)
        #expect(FullScreenPolicy.allCases.map(\.title) == ["During video", "Always", "Never"])
    }

    @Test func theWatcherReportsADisplayOnlyWhileItsSceneIsQuiet() {
        // AC-42.04: one reading of the windows and of what keeps the display awake serves every part of Lunlet.
        var windows: [ScreenWindow] = [], awake: [AwakeProcess] = [], changes = 0
        let quiet = FullScreenQuiet(windows: { windows }, awake: { awake }, application: { _ in ("/Applications/Player.app", "com.example.player") },
                                    displays: { [1: self.display] })
        quiet.changed = { changes += 1 }
        quiet.refresh()
        #expect(!quiet.isQuiet(display: 1) && changes == 0)
        windows = [window(7, display)]
        quiet.refresh()
        #expect(!quiet.isQuiet(display: 1) && quiet.watching && changes == 0)
        awake = [.init(pid: 7, path: "/Applications/Player.app/Contents/MacOS/Player")]
        quiet.refresh()
        #expect(quiet.isQuiet(display: 1) && changes == 1)
        quiet.refresh()
        #expect(changes == 1)
        quiet.policy = .never
        #expect(!quiet.isQuiet(display: 1) && changes == 2 && !quiet.watching)
        quiet.policy = .always
        awake = []
        quiet.refresh()
        #expect(quiet.isQuiet(display: 1) && !quiet.isQuiet(display: 2))
        windows = []
        quiet.refresh()
        #expect(!quiet.isQuiet(display: 1) && !quiet.watching)
    }

    @Test func aPauseDoesNotBringTheEntryBackOverTheVideo() {
        // A paused or buffering video lets the display sleep again for a moment; the entry popping in and out over
        // the picture would be worse than staying away. It returns when the full-screen window is left (AC-42.01).
        var windows = [window(7, display)], awake = [AwakeProcess(pid: 7, path: "/Applications/Player.app/Contents/MacOS/Player")]
        let quiet = FullScreenQuiet(windows: { windows }, awake: { awake }, application: { _ in ("/Applications/Player.app", "com.example.player") },
                                    displays: { [1: self.display] })
        quiet.refresh()
        #expect(quiet.isQuiet(display: 1))
        awake = []
        quiet.refresh()
        #expect(quiet.isQuiet(display: 1))
        // Another application in full screen on that display starts afresh.
        windows = [window(9, display)]
        quiet.refresh()
        #expect(!quiet.isQuiet(display: 1))
        // And so does the first one when it comes back without playing.
        windows = [window(7, display)]
        quiet.refresh()
        #expect(!quiet.isQuiet(display: 1))
        // Leaving full screen ends it.
        awake = [AwakeProcess(pid: 7, path: "/Applications/Player.app/Contents/MacOS/Player")]
        quiet.refresh()
        #expect(quiet.isQuiet(display: 1))
        windows = [window(7, CGRect(x: 0, y: 33, width: 1512, height: 949))]
        awake = []
        quiet.refresh()
        #expect(!quiet.isQuiet(display: 1))
    }

    @Test func aChangeIsReadAgainWhileItSettles() {
        // A Space or application change is announced before the window has grown to fill the display.
        var reads = 0, scheduled: [TimeInterval] = []
        let quiet = FullScreenQuiet(windows: { reads += 1; return [] }, awake: { [] }, application: { _ in (nil, nil) },
                                    displays: { [1: self.display] })
        quiet.later = { delay, work in scheduled.append(delay); work() }
        quiet.systemChanged()
        #expect(scheduled == FullScreenQuiet.settling && reads == 1 + FullScreenQuiet.settling.count)
        #expect(FullScreenQuiet.settling.allSatisfy { $0 > 0 && $0 <= 2 } && FullScreenQuiet.interval <= 1)
    }
}
