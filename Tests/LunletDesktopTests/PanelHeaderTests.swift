// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.09, AC-19.10; US-25, AC-25.01; US-24, AC-24.02.
import AppKit
import SwiftUI
import Testing
import LunletCore
@testable import LunletDesktop

/// The header in a real window, where an animation would run. Opt-in with the other native checks.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_PANEL"] == "1"))
@MainActor struct PanelHeaderOnScreenTests {
    private func picture(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private final class Model: ObservableObject {
        @Published var unknown: HeaderPresentation.Unknown
        init(_ unknown: HeaderPresentation.Unknown) { self.unknown = unknown }
    }
    private struct Host: View {
        @ObservedObject var model: Model
        var body: some View {
            let labels: [SessionProvider: HeaderAgentLabel] = [
                .codex: HeaderAgentLabel(provider: .codex, remaining: nil, plan: "Free", resetsAt: nil, unknown: model.unknown, today: nil, waiting: 0),
                .claude: HeaderAgentLabel(provider: .claude, remaining: 86, plan: nil, resetsAt: nil, unknown: nil, today: nil, waiting: 0)]
            PanelHeader(agents: [.claude, .codex], chosen: .codex, labels: labels, totals: HeaderTotals(tokens: "≥437M", cost: nil),
                        top: 32, keyboard: false, now: Date(timeIntervalSince1970: 1_800_000_000), choose: { _ in })
        }
    }
    /// How many different pictures the view gives over about a second.
    private func pictures(of view: NSView) async throws -> Int {
        var seen: Set<Data> = []
        for _ in 0..<4 {
            seen.insert(try picture(view))
            try await Task.sleep(for: .milliseconds(330))
        }
        return seen.count
    }

    // Nothing in the header moves by itself: not while an agent's first read is under way, not once that read has
    // ended without a limit, and not when the limit was unknown from the start. Only choosing a body moves anything
    // (AC-19.09), so an open panel costs nothing at rest (US-25).
    @Test func aHeaderAtRestIsStillWhateverAnAgentsLimitIs() async throws {
        _ = NSApplication.shared
        for first in [HeaderPresentation.Unknown.reading, .unknown] {
            let model = Model(first)
            let panel = NSPanel(contentRect: .init(x: 600, y: 400, width: 454, height: 172),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: Host(model: model))
            panel.contentView = hosting
            panel.orderFrontRegardless()
            defer { panel.close() }
            try await Task.sleep(for: .milliseconds(400))
            #expect(try await pictures(of: hosting) == 1, "\(first): a header at rest moved")
            model.unknown = .unknown
            try await Task.sleep(for: .milliseconds(400))
            #expect(try await pictures(of: hosting) == 1, "\(first), then unknown: a header at rest moved")
        }
    }
}

/// The header as drawn.
@MainActor struct PanelHeaderRenderTests {
    // Design notes, Panel header and pages: the sky has no edge. It runs from one side of the panel to the other and
    // dissolves over a long, eased stretch that goes on behind the top of the page, in both appearances.
    @Test(arguments: [ColorScheme.light, .dark])
    func theSkyDissolvesIntoThePageWithoutAnEdge(scheme: ColorScheme) throws {
        let top: CGFloat = 32, layout = PanelStyle.Layout.self
        let frame = top + layout.skyHeight + layout.skyTail, total = frame + layout.skyBleed
        let header = PanelHeader(agents: [.codex, .claude], chosen: nil, labels: [:], totals: HeaderTotals(tokens: "0", cost: nil),
                                 top: top, keyboard: false, now: Date(timeIntervalSince1970: 1_800_000_000), choose: { _ in })
        let image = try HeaderArtBitmap(header.frame(height: total, alignment: .top).environment(\.colorScheme, scheme),
                                        size: CGSize(width: 470, height: total))
        // A column between the bodies' labels, near the middle.
        let middle: CGFloat = 172
        func alpha(_ x: CGFloat, _ y: CGFloat) -> Int { Int(image.at(point: CGPoint(x: x, y: y)).a) }
        // Whole from side to side where the bodies are, and still dark under the labels' last line.
        for x: CGFloat in [1, middle, 468] { #expect(alpha(x, 4) == 255 && alpha(x, top + 90) >= 250, "x \(x)") }
        // At least four fifths of the sky is left under the labels' last line, which is white.
        #expect(alpha(middle, top + 132) >= 205, "under the last label line: \(alpha(middle, top + 132))")
        // No line marks its end: it is about half gone where the page begins, still there well behind the page's
        // first card, and gone only where its long tail ends.
        let pageTop = alpha(middle, frame + 1), behindCard = alpha(middle, frame + 30)
        #expect(pageTop > 95 && pageTop < 150, "where the page begins: \(pageTop)")
        // Behind the first card there is the sky's tail and the chosen body's light, both faint.
        #expect(behindCard > 25 && behindCard < 120, "behind the first card: \(behindCard)")
        #expect(alpha(middle, total - 0.5) <= 3)
        // Never a step, and never steep: at most about 2% of the way in one point.
        var above = 255
        for y in stride(from: top + 90, to: total, by: 1) {
            let here = alpha(middle, y)
            // One level of rounding either way is not a step.
            #expect(here <= above + 1 && above - here <= 6, "y \(y): \(above) to \(here)")
            above = min(above, here)
        }
        // No straight line across the panel: the sides dissolve a little sooner than the middle.
        #expect(alpha(4, frame - 8) < alpha(middle, frame - 8) - 6)
    }
}
