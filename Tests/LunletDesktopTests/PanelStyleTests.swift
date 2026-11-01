// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-02, AC-02.05; US-24, AC-24.02; US-23, AC-23.03.
// Refs: US-01, AC-01.08; US-20, AC-20.02; US-03, AC-03.09; US-04, AC-04.03; US-33, AC-33.09.
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
        #expect(all.filter { $0.tone == .success } == [.delivered])
        #expect(all.allSatisfy { !$0.word.localizedCaseInsensitiveContains("connected") || $0 == .unavailable })
        #expect(CompletionDeliveryStatus.ready.symbol != "circle.dotted" && CompletionDeliveryStatus.failed.tone == .failure)
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
    // AC-03.09: the panel pages use exactly four text roles, none below 11 points, and the page budget holds a card
    // and three whole rows on the 4-point grid.
    @Test @MainActor func panelTextHasFourRolesAndThePageBudgetHoldsThreeRows() {
        typealias Role = PanelStyle.Text.Role
        #expect(Role.allCases == [.title, .primary, .secondary, .figure])
        let sizes = Role.allCases.map { NSFont.preferredFont(forTextStyle: $0.systemStyle).pointSize }
        #expect(sizes == [13, 13, 11, 15], "role sizes \(sizes)")
        #expect(Role.allCases.filter { $0.weight == .semibold } == [.title, .figure])
        let page = PanelStyle.Layout.pageHeight
        #expect(page >= 3 * PanelStyle.Layout.rowHeight + 2 * PanelStyle.Layout.listVerticalInset)
        #expect(PanelStyle.Layout.iconButton >= 28 && PanelStyle.Layout.inlineButton >= 20)
        // The row inset plus row padding, and the segmented label inset, equal the card padding: one text edge.
        #expect(PanelStyle.Layout.listInset + PanelStyle.Layout.rowPadding == PanelStyle.Grid.margin)
        for size in [PanelSegmentedStyle.Size.regular, .small] {
            let style = PanelSegmentedStyle(size: size, scheme: .light, contrast: .standard)
            #expect(style.inset + style.padding == PanelStyle.Grid.textInset)
        }
        #expect(PanelSegmentedStyle(size: .small, scheme: .light, contrast: .standard).height == PanelStyle.Layout.listHeaderHeight)
        for value in [PanelStyle.Grid.margin, PanelStyle.Grid.row, PanelStyle.Grid.group, PanelStyle.Layout.line,
                      PanelStyle.Layout.secondaryLine, PanelStyle.Layout.meterHeight, PanelStyle.Layout.cardHeight] {
            #expect(value.truncatingRemainder(dividingBy: 2) == 0, "\(value) is off the grid")
        }
    }

    // AC-03.09: panel page sources set text only through the four roles, never a system text style directly.
    @Test func panelPagesUseOnlyTheFourTextRoles() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LunletDesktop")
        let pages = ["CompanionPanel", "ProviderSummaries", "AccountUsageSummary", "SessionPanel", "SessionListHeader",
                     "PanelSegmentedControl", "WeeklyAllowanceBar"]
        let styles = "caption2?|subheadline|headline|body|footnote|callout|title[23]?|largeTitle"
        let direct = try NSRegularExpression(pattern: #"\.font\(\.("# + styles + #")\b"#)
        for page in pages {
            let text = try String(contentsOf: sources.appendingPathComponent(page + ".swift"), encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            #expect(direct.numberOfMatches(in: text, range: range) == 0, "\(page) sets a system text style directly")
        }
    }

    // AC-04.03, AC-33.09: every meter, Codex allowance and both Claude windows, has one height, with the fill exactly
    // as tall as the track; the even-pace tick and the ruler marks never change it, and a small share stays a dot.
    @Test @MainActor func everyMeterHasOneHeightAndAFullHeightMinimumFill() throws {
        _ = NSApplication.shared
        let width: CGFloat = 200, height = PanelStyle.Layout.meterHeight
        let meters: [(String, AnyView)] = [
            ("codex", AnyView(AllowanceBar(remaining: 62))),
            ("session", AnyView(AllowanceBar(remaining: 95, agent: .claude))),
            ("week", AnyView(AllowanceBar(remaining: 85, agent: .claude, evenPace: 60))),
            ("unknown", AnyView(AllowanceBar(remaining: nil, agent: .claude))),
        ]
        for (name, meter) in meters {
            let hosting = NSHostingView(rootView: meter.frame(width: width).padding(.vertical, 8))
            hosting.frame = .init(x: 0, y: 0, width: width, height: height + 16)
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.height == height + 16, "\(name) layout height \(hosting.fittingSize.height - 16)")
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsHigh) / hosting.bounds.height
            // Painted rows in a column clear of every mark: the track, and inside the fill the fill, are as tall
            // as the meter. A column at 2 points sits inside the 5% fill's minimum width.
            // The unknown meter is a dashed outline, so only its layout height is compared.
            for x in name == "unknown" ? [] : [CGFloat(4), 150] {
                let column = Int(x * scale)
                let painted = (0..<bitmap.pixelsHigh).filter { (bitmap.colorAt(x: column, y: $0)?.alphaComponent ?? 0) > 0.05 }
                let extent = CGFloat((painted.last ?? 0) - (painted.first ?? 0) + 1) / scale
                #expect(abs(extent - height) <= 1, "\(name) at \(x): \(extent)")
            }
        }
        #expect(PanelMeter.fillWidth(0, width: width) == 0)
        #expect(PanelMeter.fillWidth(1, width: width) == height)
        #expect(PanelMeter.fillWidth(50, width: width) == 100 && PanelMeter.fillWidth(140, width: width) == width)
    }
}
