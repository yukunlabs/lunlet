// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-02, AC-02.05; US-24, AC-24.02; US-23, AC-23.03.
// Refs: US-01, AC-01.08; US-20, AC-20.02; US-03, AC-03.05, AC-03.09; US-04, AC-04.03; US-33, AC-33.09.
import AppKit
import Foundation
import SwiftUI
import Testing
import LunletCore
@testable import LunletDesktop

struct PanelStyleTests {
    private func snapshot(_ phase: SessionPhase, confirmed: Bool = true, liveness: CLILiveness = .unverified,
                          outcome: TaskCue.Outcome = .unknown, inputPending: Bool = false) -> SessionSnapshot {
        .init(observation: .init(sessionID: UUID(), connectionID: UUID(), liveness: liveness, phase: phase),
              project: "Synthetic", outcome: outcome, turnID: "turn", inputActivityID: inputPending ? "input" : nil,
              inputPending: inputPending, activityConfirmed: confirmed)
    }
    private var question: SessionPhase {
        .question(turnID: "turn", requestID: "request", itemID: "item", questionIDs: ["q"], purpose: .ordinary)
    }
    private var everyPhase: [SessionPhase] { [.unknown, .running, .approval, .ended, .idle(completedTurnID: "turn"), question] }

    // AC-02.05: unconfirmed state never looks like running work or a confirmed success.
    @Test func unknownStateNeverMapsToRunningOrSuccess() {
        for phase in everyPhase {
            for outcome in [TaskCue.Outcome.succeeded, .failed, .stopped, .unknown] {
                for pending in [false, true] {
                    let style = SessionStatusStyle(snapshot(phase, confirmed: false, outcome: outcome, inputPending: pending))
                    #expect(style.tone != .running && style.tone != .success && style.tone != .attention)
                    #expect(style.kind == (phase == .ended ? .ended : .unknown))
                }
            }
        }
        let confirmedUnknown = SessionStatusStyle(snapshot(.unknown))
        #expect(confirmedUnknown.kind == .unknown && confirmedUnknown.tone == .neutral && confirmedUnknown.label == "Status unavailable")
        // Success needs a confirmed succeeded outcome; an unconfirmed finish stays neutral, never green.
        #expect(SessionStatusStyle(snapshot(.idle(completedTurnID: "turn"), outcome: .succeeded)).tone == .success)
        #expect(SessionStatusStyle(snapshot(.idle(completedTurnID: "turn"))).tone == .neutral)
        #expect(SessionStatusStyle(snapshot(.idle(completedTurnID: "turn"), outcome: .failed)).tone == .failure)
    }

    // AC-24.02: only a question or an approval waiting on the developer gets the attention color.
    @Test func onlyQuestionsAndApprovalsGetTheAttentionColor() {
        for phase in everyPhase {
            for outcome in [TaskCue.Outcome.succeeded, .failed, .stopped, .unknown] {
                for pending in [false, true] {
                    let item = snapshot(phase, outcome: outcome, inputPending: pending)
                    let style = SessionStatusStyle(item)
                    let waiting = !pending && (phase == .approval || phase == question)
                    #expect((style.tone == .attention) == waiting)
                    #expect(style.awaitsDeveloper == waiting && style.awaitsDeveloper == (pending ? false : item.awaitsUser))
                    // Every state carries a symbol and words, never color alone.
                    #expect(!style.symbol.isEmpty && !style.label.isEmpty)
                }
            }
        }
        let labels = Set([SessionStatusStyle(snapshot(question)).label, SessionStatusStyle(snapshot(.approval)).label])
        #expect(labels == ["Waiting for an answer", "Approval on Mac"])
    }

    // AC-01.08, AC-20.02: the footer names the state in words and only a verified delivery looks successful.
    @Test func connectionWordsNeverClaimAnUnverifiedConnection() {
        let all: [CompletionDeliveryStatus] = [.unavailable, .ready, .sending, .delivered, .failed]
        let successes = all.filter { $0.tone == .success }
        #expect(successes == [.delivered])
        let sayingConnected = all.filter { $0.word.localizedCaseInsensitiveContains("connected") }
        #expect(sayingConnected.allSatisfy { $0 == .unavailable })
        #expect(CompletionDeliveryStatus.ready.symbol != "circle.dotted")
        #expect(CompletionDeliveryStatus.failed.tone == .failure)
    }

    // AC-23.03: a compact age only from a source-reported time.
    @Test func relativeAgeComesOnlyFromAKnownActivityTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PanelStyle.relativeAge(since: nil, now: now) == nil)
        #expect(PanelStyle.relativeAge(since: now.addingTimeInterval(-20), now: now) == "now")
        #expect(PanelStyle.relativeAge(since: now.addingTimeInterval(-125), now: now) == "2m")
        #expect(PanelStyle.relativeAge(since: now.addingTimeInterval(-3 * 3_600 - 5), now: now) == "3h")
        #expect(PanelStyle.relativeAge(since: now.addingTimeInterval(-2 * 86_400), now: now) == "2d")
        // Small clock differences read as now; a time far in the future is not trusted.
        #expect(PanelStyle.relativeAge(since: now.addingTimeInterval(30), now: now) == "now")
        #expect(PanelStyle.relativeAge(since: now.addingTimeInterval(3_600), now: now) == nil)
        #expect(PanelStyle.spokenAge(since: now.addingTimeInterval(-60), now: now) == "active 1 minute ago")
        #expect(PanelStyle.spokenAge(since: now.addingTimeInterval(-7_200), now: now) == "active 2 hours ago")
        #expect(PanelStyle.spokenAge(since: nil, now: now) == nil)
    }
    // Design notes, Panel header and pages: every session card carries one round badge of one size, a glyph on its
    // tone; the glyph alone tells the states apart, so no state depends on color (AC-24.02).
    @Test func everySessionStateHasItsOwnBadgeGlyph() {
        let kinds: [SessionStatusStyle.Kind] = [.waiting, .approval, .input, .running, .completed, .failed, .stopped, .finished, .unknown, .ended]
        let glyphs = kinds.map { SessionStatusStyle(kind: $0).glyph }
        #expect(Set(glyphs).count == kinds.count, "glyphs \(glyphs)")
        // A glyph sits inside the badge's circle, so none brings a circle of its own.
        #expect(glyphs.allSatisfy { !$0.contains("circle") })
    }

    // Design notes, Panel presentation: three complete session cards, ending cleanly after the third; further cards
    // scroll, and what is above them stays. An agent with a shorter card at the top of its page has room to spare,
    // which its three cards share rather than showing part of a fourth.
    @Test func theSessionListShowsExactlyThreeWholeCardsOnEveryAgentsPage() {
        let layout = PanelStyle.Layout.self
        for lines in 1...2 {
            let available = layout.pageHeight - layout.summaryCard(lines: lines) - PanelStyle.Grid.margin
                - layout.listHeaderHeight - PanelStyle.Grid.group
            let card = layout.sessionCard(available: available), viewport = layout.sessionViewport(available: available)
            #expect(card >= layout.rowHeight && card == card.rounded(), "\(lines) lines: card \(card)")
            // The third card ends where the viewport ends; the gap after it and the fourth card are outside.
            #expect(viewport == 3 * card + 2 * layout.rowGap && viewport <= available, "\(lines) lines: \(viewport) of \(available)")
            #expect(available - viewport < 3, "\(lines) lines: \(available - viewport) left blank")
        }
        #expect(layout.sessionCard(available: layout.threeRows) == layout.rowHeight)
        // Room far beyond three cards is not stretched into: a card stays a card, and the list ends after three.
        let roomy = layout.sessionCard(available: 400)
        #expect(roomy == layout.tallestSessionCard && layout.sessionViewport(available: 400) == 3 * roomy + 2 * layout.rowGap)
        // A display too short for three standard cards keeps them standard and scrolls within what there is.
        #expect(layout.sessionCard(available: 100) == layout.rowHeight && layout.sessionViewport(available: 100) == 100)
    }

    // AC-03.09: the panel pages use exactly four text roles, none below 11 points, and the page budget holds a card
    // and three whole rows on the 4-point grid.
    // Design notes, Surfaces: the panel is the system's glass under its own deep color, about half of each. With less
    // glass the frosted surface turns into a slab; with less color a white window behind leaves the secondary text
    // too little contrast (AC-03.05, AC-24.02).
    @Test func theSurfaceLetsTheGlassThroughAndKeepsItsTextLegible() throws {
        let depth = PanelStyle.surfaceDepth
        #expect(depth <= 0.55, "the system's glass reads through the surface")
        // The brightest the system's dark glass was measured on a device, over a white window: sRGB 133 of 255.
        let glass = 133.0 / 255
        let surface = try #require(NSColor(PanelStyle.surface).usingColorSpace(.sRGB))
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) }
        let page = [surface.redComponent, surface.greenComponent, surface.blueComponent].map { Double($0) * depth + glass * (1 - depth) }
        // Secondary text is white at 55% in the dark appearance.
        let text = page.map { 0.55 + 0.45 * $0 }
        let contrast = (luminance(text[0], text[1], text[2]) + 0.05) / (luminance(page[0], page[1], page[2]) + 0.05)
        #expect(contrast >= 4, "secondary text over a white window: \(contrast)")
    }

    @Test @MainActor func panelTextHasFourRolesAndThePageBudgetHoldsThreeRows() {
        typealias Role = PanelStyle.Text.Role
        #expect(Role.allCases == [.title, .primary, .secondary, .figure])
        let sizes = Role.allCases.map { NSFont.preferredFont(forTextStyle: $0.systemStyle).pointSize }
        #expect(sizes == [13, 13, 11, 15], "role sizes \(sizes)")
        #expect(Role.allCases.filter { $0.weight == .semibold } == [.title, .figure])
        let page = PanelStyle.Layout.pageHeight
        let rows = PanelStyle.Layout.rowHeight * 3
        let gaps = PanelStyle.Layout.rowGap * 2
        #expect(page >= rows + gaps && PanelStyle.Layout.threeRows == rows + gaps)
        #expect(PanelStyle.Layout.iconButton >= 28 && PanelStyle.Layout.inlineButton >= 20)
        // The row inset plus row padding, and the segmented label inset, equal the card padding: one text edge.
        #expect(PanelStyle.Layout.listInset + PanelStyle.Layout.rowPadding == PanelStyle.Grid.margin)
        for size in [PanelSegmentedStyle.Size.regular, .small] {
            let style = PanelSegmentedStyle(size: size, scheme: .light, contrast: .standard)
            #expect(style.inset + style.padding == PanelStyle.Grid.textInset)
        }
        #expect(PanelSegmentedStyle(size: .small, scheme: .light, contrast: .standard).height == PanelStyle.Layout.listHeaderHeight)
        for value in [PanelStyle.Grid.margin, PanelStyle.Grid.row, PanelStyle.Grid.group, PanelStyle.Layout.line,
                      PanelStyle.Layout.secondaryLine, PanelStyle.Layout.rowHeight, PanelStyle.Layout.rowGap, PanelStyle.Layout.skyHeight] {
            #expect(value.truncatingRemainder(dividingBy: 2) == 0, "\(value) is off the grid")
        }
    }

    // AC-03.09: panel page sources set text only through the four roles, never a system text style directly.
    @Test func panelPagesUseOnlyTheFourTextRoles() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LunletDesktop")
        let pages = ["CompanionPanel", "ProviderSummaries", "AccountUsageSummary", "SessionPanel", "SessionListHeader",
                     "PanelSegmentedControl", "PanelHeader", "AgentFigures"]
        let styles = "caption2?|subheadline|headline|body|footnote|callout|title[23]?|largeTitle"
        let direct = try NSRegularExpression(pattern: #"\.font\(\.("# + styles + #")\b"#)
        for page in pages {
            let text = try String(contentsOf: sources.appendingPathComponent(page + ".swift"), encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            #expect(direct.numberOfMatches(in: text, range: range) == 0, "\(page) sets a system text style directly")
        }
    }
}
