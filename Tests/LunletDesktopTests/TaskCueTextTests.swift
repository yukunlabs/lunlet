// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-13, AC-13.01, AC-13.06, AC-13.07, AC-13.08; US-03, AC-03.11.
import AppKit
import Testing
import LunletCore
@testable import LunletDesktop

@MainActor struct TaskCueTextTests {
    private static let phases: [TaskCue.Phase] = [.started, .finished(.unknown), .finished(.stopped),
                                                  .finished(.succeeded), .finished(.failed)]
    private func text(_ title: String = "Project", phase: TaskCue.Phase = .started, context: String? = nil) -> TaskCueText {
        TaskCueText(cue: TaskCue(sessionID: "session", connectionID: "connection", turnID: "turn", title: title, phase: phase,
                                 context: context))
    }
    private func screen(notch: CGSize?) -> PanelScreen {
        guard let notch else {
            return PanelScreen(frame: .init(x: 0, y: 0, width: 1920, height: 1080),
                               visibleFrame: .init(x: 0, y: 0, width: 1920, height: 1056), safeTop: 0)
        }
        return PanelScreen(frame: .init(x: 0, y: 0, width: 1512, height: 982), visibleFrame: .init(x: 0, y: 0, width: 1512, height: 950),
                           safeTop: notch.height, notch: .init(x: (1512 - notch.width) / 2, y: 982 - notch.height,
                                                               width: notch.width, height: notch.height))
    }

    @Test func statusesAreShortCompleteAndUnknownNeverClaimsSuccess() {
        let text = Self.phases.map { self.text(phase: $0) }
        #expect(text.map(\.status) == ["Started", "Finished", "Stopped", "Completed", "Failed"])
        #expect(Set(text.map(\.symbol)).count == 5)
    }
    // AC-13.08: 11 pt and 9.5 pt text was too small to read at a glance.
    @Test func cueTextUsesReadableSystemSizes() {
        for font in [TaskCueText.statusFont, TaskCueText.projectFont, TaskCueText.previewFont] {
            #expect(font.pointSize >= 11)
        }
        #expect(TaskCueText.statusFont.pointSize >= 13)
    }
    // AC-13.07, AC-13.08: the identity column was only as wide as its text, beside the lettering.
    @Test func symmetricWingsHoldTheFullStatusAndProjectBeyondTheLettering() {
        #expect(TaskCueText.notchClearance >= EntryMetrics.wing + 12)
        for phase in Self.phases {
            for title in ["A", "lunlet", "atlas-api-gateway"] {
                let text = text(title, phase: phase, context: "Hi")
                let wings = text.notchWings()
                #expect(wings.left == wings.right)
                #expect(wings.left - TaskCueText.wingPadding >= text.statusWidth)
                #expect(wings.right - TaskCueText.wingPadding >= text.projectWidth)
                #expect(wings.left - TaskCueText.wingPadding >= TaskCueText.wingText.lowerBound)
            }
        }
        let long = text(String(repeating: "Project 👩‍💻 with a long name ", count: 4))
        #expect(long.notchWings().left - TaskCueText.wingPadding == TaskCueText.wingText.upperBound)
    }
    // AC-13.08: a 44 pt strip ended only 12 pt below a 32 pt notch, inside the menu-bar band.
    @Test func theIslandContinuesBelowEveryReportedNotch() {
        for notch in [CGSize(width: 160, height: 26), CGSize(width: 185, height: 32), CGSize(width: 230, height: 40)] {
            let screen = screen(notch: notch), text = text("lunlet", context: "Refactor the notch hover controller")
            let size = text.size(screen: screen)
            #expect(size.height - notch.height >= 24)
            #expect(size.width == notch.width + 2 * text.notchWings().left)
            let frame = PanelPlacement.cue(size: size, screen: screen)
            #expect(frame.maxY == screen.frame.maxY && frame.midX == screen.notch!.midX)
            #expect(frame.minY <= screen.notch!.minY - 24)
        }
    }
    @Test func longTextTruncatesWithoutGrowingTheCue() {
        let screen = screen(notch: CGSize(width: 185, height: 32))
        let short = text("A", context: "Hi"), long = text(String(repeating: "Project 👩‍💻 with a long name ", count: 4),
            phase: .finished(.unknown), context: String(repeating: "conversation preview ", count: 20))
        #expect(long.size(screen: screen).height == short.size(screen: screen).height)
        #expect(long.size(screen: screen).width <= 185 + 2 * (TaskCueText.wingPadding + TaskCueText.wingText.upperBound))
        let narrow = PanelScreen(frame: .init(x: 0, y: 0, width: 600, height: 400),
                                 visibleFrame: .init(x: 0, y: 0, width: 600, height: 368), safeTop: 32,
                                 notch: .init(x: 207.5, y: 368, width: 185, height: 32))
        #expect(long.size(screen: narrow).width == 600)
    }
    // AC-13.06: a display without a notch shows the same rows in a pill sized to the content.
    @Test func displaysWithoutANotchUseAPillBelowTheMenuBar() {
        let screen = screen(notch: nil)
        let short = text("A", context: "Hi"), long = text("lunlet", context: String(repeating: "conversation preview ", count: 20))
        let size = short.size(screen: screen)
        #expect(size.height >= 44 && size.width >= 2 * TaskCueText.wingText.lowerBound)
        #expect(long.size(screen: screen).width > size.width)
        #expect(long.size(screen: screen).width <= 2 * (TaskCueText.wingText.upperBound + TaskCueText.pillPadding) + TaskCueText.pillGap)
        #expect(PanelPlacement.cue(size: size, screen: screen).maxY == screen.visibleFrame.maxY)
    }
    @Test func voiceOverReadsOneCombinedLabelAndTheTaskFallback() {
        #expect(text("lunlet", context: "Refactor the panel").accessibilityLabel == "Started, lunlet, Refactor the panel")
        let fallback = TaskCueText(cue: TaskCue(sessionID: "s", connectionID: "c", turnID: "turn-a1b2c3", title: "lunlet",
                                                phase: .finished(.succeeded)))
        #expect(fallback.accessibilityLabel == "Completed, lunlet, Task A1B2C3")
    }
}
