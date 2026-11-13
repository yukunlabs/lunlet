// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-24, AC-24.01, AC-24.02; US-23, AC-23.03; US-02, AC-02.05.
// Refs: US-03, AC-03.09, AC-03.10, AC-03.11; US-04, AC-04.03.
// Refs: US-22, AC-22.03; US-01, AC-01.08; US-20, AC-20.02; US-19, AC-19.05.
import AppKit
import LunletCore
import SwiftUI

/// Shared panel tokens from the approved macOS-style design: a 4-point spacing scale and grid, nested radii,
/// four text roles no smaller than 11 points, one meter, system fills and one status vocabulary.
/// Presentation only: none of these values changes session, account or connection state.
enum PanelStyle {
    /// The 4-point scale: 2 · 4 · 6 · 8 · 10 · 12 · 16 · 20.
    enum Space {
        static let hairline: CGFloat = 2, tight: CGFloat = 4, small: CGFloat = 6, medium: CGFloat = 8
        static let module: CGFloat = 10, margin: CGFloat = 12, large: CGFloat = 16, extra: CGFloat = 20
    }
    /// Concentric radii: surface 20, modules 12, rows 8 inside a 4-point module inset.
    enum Radius { static let surface: CGFloat = 20, module: CGFloat = 12, row: CGFloat = 8 }
    /// One grid for every page: cards and sections 12 apart with 12 of padding, so card text, segmented labels and
    /// session rows share one leading edge 24 points from the panel body; rows inside a card 6 apart, groups 8.
    enum Grid {
        /// Panel margin, card padding and the gap between cards or sections.
        static let margin: CGFloat = Space.margin
        static let row: CGFloat = Space.small
        static let group: CGFloat = Space.medium
        /// A card's or a segmented label's text inset from its own edge, equal to the card padding.
        static let textInset: CGFloat = Space.margin
    }
    /// Vertical budget shared by the panel and its fit checks.
    enum Layout {
        /// One session card: a title line and a metadata line inside the card's padding.
        static let rowHeight: CGFloat = 48
        /// The gap between session cards.
        static let rowGap: CGFloat = 6
        /// A title, primary or figure line in a card; it also holds the 20-point inline chart button.
        static let line: CGFloat = 20
        /// A secondary line: subtitles, reset times and footnotes.
        static let secondaryLine: CGFloat = 14
        /// The list's side inset; row highlights sit inside it with the row radius. With the row's own 8-point
        /// padding it equals the card padding, so a row's symbol starts on the cards' text edge.
        static let listInset: CGFloat = 4
        static let rowPadding: CGFloat = Space.medium
        /// The list's top and bottom inset plus the highlight's own vertical inset equal the side inset, so a
        /// viewport ending at the third row reveals only blank margin of a fourth, never text or a highlight.
        static let listVerticalInset: CGFloat = 2
        static let rowHighlightInset: CGFloat = 2
        /// A header row without a notch, or the tab row below the notch band; also the regular segment height.
        static let headerHeight: CGFloat = 28
        /// The Active/History row: the small segmented control's height.
        static let listHeaderHeight: CGFloat = 22
        static let headerGap: CGFloat = 4
        static let footerHeight: CGFloat = 36
        /// Header buttons; macOS guidance prefers 28 x 28 and requires at least 20 x 20.
        static let iconButton: CGFloat = 28
        /// Inline chart and copy buttons keep the 20 x 20 minimum within dense rows.
        static let inlineButton: CGFloat = 20
        /// Three whole session cards with the gaps between them.
        static let threeRows: CGFloat = 3 * rowHeight + 2 * rowGap
        /// A session card grows no taller than this when its page has room to spare.
        static let tallestSessionCard: CGFloat = 60
        /// One session card's height in a list `available` points tall: three whole cards fill the list, sharing what
        /// a shorter card at the top of the page leaves spare, in whole points and no taller than the limit.
        static func sessionCard(available: CGFloat) -> CGFloat {
            min(tallestSessionCard, max(rowHeight, ((available - 2 * rowGap) / 3).rounded(.down)))
        }
        /// The list's viewport: exactly three whole cards, so no part of a fourth ever shows and further cards scroll;
        /// on a display too short for three standard cards, what there is.
        static func sessionViewport(available: CGFloat) -> CGFloat {
            available < threeRows ? max(0, available) : 3 * sessionCard(available: available) + 2 * rowGap
        }
        /// The card at the top of an agent's page: the padding above its account line and below its figures, and the
        /// gap on each side of its hairline and between two lines of figures (AC-04.17).
        static let summaryEdge: CGFloat = 7
        static let summaryGap: CGFloat = 5
        static func summaryCard(lines: Int) -> CGFloat {
            summaryEdge + secondaryLine + 2 * summaryGap + CGFloat(lines) * secondaryLine + CGFloat(lines - 1) * summaryGap + summaryEdge
        }
        /// The page between the header and the footer: the summary card at its tallest, with two lines of figures, the
        /// list header and exactly three whole session cards (AC-03.10). The Overview fills the same height with its chart.
        static let pageHeight: CGFloat = summaryCard(lines: 2) + Grid.margin + listHeaderHeight + Grid.group + threeRows
        /// The header's sky below its top inset: a body, its label of up to four lines and a margin.
        static let skyHeight: CGFloat = 140
        /// The gap between the header and the page; the sky is still there, on its way out.
        static let skyTail: CGFloat = Grid.margin
        /// The sky runs on this far behind the page, fainter and fainter, so that no line marks where it ends.
        static let skyBleed: CGFloat = 118
        /// The stretch over which the sky dissolves, ending where its bleed ends. It begins among the labels, slowly
        /// enough that their last line stays on a sky dark enough to read it; it is about half gone where the page
        /// begins and goes on, in a long tail, behind the page's first card.
        static let skyFade: CGFloat = 162
        /// The header's top inset on a display without a notch.
        static let skyTop: CGFloat = 14
        /// The strip of sky Settings keeps under the band, with Back.
        static let settingsStrip: CGFloat = 10
        /// Settings keeps only a strip of the sky, so its page is taller than an agent's by the rest of it.
        static let settingsPageHeight: CGFloat = pageHeight + skyHeight - settingsStrip
        /// Everything above the page: the header's sky under the notch band, or under a small top margin on a display
        /// without a notch, and its dissolving tail. The header is the same for one agent or several (AC-19.09).
        static func headerBlock(notchHeight: CGFloat?) -> CGFloat { (notchHeight ?? skyTop) + skyHeight + skyTail }
        /// The panel height that keeps the page budget on every display.
        static func panelHeight(notchHeight: CGFloat?) -> CGFloat { headerBlock(notchHeight: notchHeight) + pageHeight + footerHeight }
    }
    /// The four text roles of the panel pages. One line uses one size; weight and color, never size, set items
    /// apart. Every role uses monospaced digits so figures do not shift as they change.
    enum Text {
        enum Role: CaseIterable {
            /// Card titles, 13 points semibold.
            case title
            /// Row titles, limit labels, values, amounts and regular segmented labels, 13 points.
            case primary
            /// Subtitles, reset times, row metadata, token breakdowns, footnotes and small segmented labels,
            /// 11 points in the secondary color.
            case secondary
            /// Only the Overview totals and the Codex remaining percentage, 15 points semibold.
            case figure
            var style: Font.TextStyle {
                switch self {
                case .title, .primary: .body
                case .secondary: .subheadline
                case .figure: .title3
                }
            }
            var systemStyle: NSFont.TextStyle {
                switch self {
                case .title, .primary: .body
                case .secondary: .subheadline
                case .figure: .title3
                }
            }
            var weight: Font.Weight { self == .title || self == .figure ? .semibold : .regular }
            var font: Font { Font.system(style, weight: weight).monospacedDigit() }
        }
        static let title = Role.title.font
        static let primary = Role.primary.font
        static let secondary = Role.secondary.font
        static let figure = Role.figure.font
        /// The header's own roles on its sky: a body's figure, 20 points semibold (22 once it is chosen and its label
        /// grows), and its name, 12 points semibold.
        static let headerFigure = Font.system(size: 20, weight: .semibold).monospacedDigit()
        static let headerName = Font.system(size: 12, weight: .semibold).monospacedDigit()
    }
    /// The panel's surface color: the deep blue-black the header's sky ends in, so the sky has nothing to end against.
    static let surface = Color(.sRGB, red: 11 / 255, green: 10 / 255, blue: 24 / 255, opacity: 1)
    /// How much of the surface is its own color; the rest is the system's glass under it. About half of each: the
    /// window behind still colors the surface softly, as frosted glass does, and over a white window the secondary
    /// text keeps a contrast of four to one. Much more of the color and the glass is gone.
    static let surfaceDepth = 0.5
    /// The panel is dark in both appearances, as the notch it hangs from is.
    @MainActor static var appearance: NSAppearance? { NSAppearance(named: .darkAqua) }
    /// A hairline around a module, brighter along its top edge as if lit from above, which lifts it off the surface
    /// without a lighter fill.
    static let moduleStroke = LinearGradient(colors: [Color.white.opacity(0.17), Color.white.opacity(0.045)],
                                             startPoint: .top, endPoint: .bottom)
    /// Modules are lighter translucent layers on the surface rather than gray fills; over the opaque surface of
    /// Reduce Transparency the same fill composites to an opaque tone.
    static var moduleFill: Color { Color(nsColor: moduleFillColor) }
    static let moduleFillColor = NSColor(name: "LunletModuleFill") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.065) : NSColor.white.withAlphaComponent(0.5)
    }
    static var separator: Color { Color(nsColor: .separatorColor) }

    /// About 0.36 s, as approved; Reduce Motion keeps the final geometry without a transition.
    static func motion(reduce: Bool) -> Animation? { reduce ? nil : .spring(duration: 0.36, bounce: 0.12) }
    /// A selection pill sliding between segments; Reduce Motion moves it without a slide.
    static func selection(reduce: Bool) -> Animation? { reduce ? nil : .spring(duration: 0.3, bounce: 0.15) }
    static func hover(reduce: Bool) -> Animation? { reduce ? nil : .easeOut(duration: 0.12) }

    /// A compact age from a source-reported activity time; an unavailable or implausible time shows none.
    static func relativeAge(since date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let elapsed = now.timeIntervalSince(date)
        // Small clock differences read as now; a time far in the future is not trusted.
        guard elapsed.isFinite, elapsed > -300, elapsed < 400 * 86_400 else { return nil }
        if elapsed < 60 { return "now" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60))m" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3_600))h" }
        return "\(Int(elapsed / 86_400))d"
    }
    /// The same age in words for VoiceOver, which would otherwise read "2m" as a distance.
    static func spokenAge(since date: Date?, now: Date) -> String? {
        guard let compact = relativeAge(since: date, now: now) else { return nil }
        guard compact != "now", let value = Int(compact.dropLast()), let unit = compact.last else { return "active now" }
        let word = unit == "m" ? "minute" : unit == "h" ? "hour" : "day"
        return "active \(value) \(word)\(value == 1 ? "" : "s") ago"
    }
}

/// One color vocabulary. Attention is reserved for a question or an approval waiting on the developer;
/// success only for a confirmed outcome. Color always comes with a symbol and a text label.
enum PanelTone: Equatable {
    case attention, running, success, failure, neutral, muted
    var color: Color {
        switch self {
        case .attention: .orange
        case .running: .blue
        case .success: .green
        case .failure: .red
        case .neutral: .secondary
        case .muted: Color(nsColor: .tertiaryLabelColor)
        }
    }
}

/// The state a session row shows, derived only from observed evidence.
struct SessionStatusStyle: Equatable {
    enum Kind: Equatable { case waiting, approval, input, running, completed, failed, stopped, finished, unknown, ended }
    let kind: Kind

    init(kind: Kind) { self.kind = kind }
    init(_ snapshot: SessionSnapshot) {
        if snapshot.inputPending && snapshot.hasConfirmedActivity { kind = .input; return }
        if snapshot.isEnded { kind = .ended; return }
        guard snapshot.hasConfirmedActivity else { kind = .unknown; return }
        switch snapshot.observation.phase {
        case .running: kind = .running
        case .question: kind = .waiting
        case .approval: kind = .approval
        case .unknown: kind = .unknown
        case .ended: kind = .ended
        case .idle:
            switch snapshot.outcome {
            case .succeeded: kind = .completed
            case .failed: kind = .failed
            case .stopped: kind = .stopped
            case .unknown: kind = .finished
            }
        }
    }

    var label: String {
        switch kind {
        case .waiting: "Waiting for an answer"
        case .approval: "Approval on Mac"
        case .input: "Input received"
        case .running: "Turn in progress"
        case .completed: "Turn completed"
        case .failed: "Turn failed"
        case .stopped: "Turn stopped"
        case .finished: "Turn finished"
        case .unknown: "Status unavailable"
        case .ended: "Ended"
        }
    }
    var symbol: String {
        switch kind {
        case .waiting: "text.bubble.fill"
        case .approval: "hand.raised.fill"
        case .input: "arrow.up.circle.fill"
        case .running: "play.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        case .finished: "flag.circle"
        case .unknown: "circle.dashed"
        case .ended: "xmark.circle"
        }
    }
    /// The glyph inside a session card's round badge: one size and one shape of badge for every state, told apart by
    /// the glyph, so none brings a circle of its own.
    var glyph: String {
        switch kind {
        case .waiting: "questionmark"
        case .approval: "hand.raised.fill"
        case .input: "arrow.up"
        case .running: "play.fill"
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        case .stopped: "stop.fill"
        case .finished: "flag.fill"
        case .unknown: "ellipsis"
        case .ended: "xmark"
        }
    }
    var tone: PanelTone {
        switch kind {
        case .waiting, .approval: .attention
        case .input, .running: .running
        case .completed: .success
        case .failed: .failure
        case .stopped, .finished, .unknown: .neutral
        case .ended: .muted
        }
    }
    var awaitsDeveloper: Bool { tone == .attention }
    var isRunning: Bool { tone == .running }
}

/// Delivery-stage wording; delivered is verified, ready and sending are armed or in progress.
extension CompletionDeliveryStatus {
    var word: String {
        switch self {
        case .unavailable: "Not connected"
        case .ready: "Ready"
        case .sending: "Sending"
        case .delivered: "Delivered"
        case .failed: "Failed"
        }
    }
    var tone: PanelTone {
        switch self {
        case .delivered: .success
        case .failed: .failure
        case .ready, .sending: .running
        case .unavailable: .neutral
        }
    }
}

/// A module on the panel: a system fill, the module radius and a hairline under Increase Contrast.
struct PanelModule: ViewModifier {
    var padding: EdgeInsets
    init(padding: CGFloat = PanelStyle.Grid.margin) { self.init(horizontal: padding, vertical: padding) }
    init(horizontal: CGFloat, vertical: CGFloat) {
        padding = EdgeInsets(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
    }
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PanelStyle.Radius.module, style: .continuous)
        content.padding(padding)
            .background(PanelStyle.moduleFill, in: shape)
            .overlay { shape.strokeBorder(contrast == .increased ? AnyShapeStyle(PanelStyle.separator) : AnyShapeStyle(PanelStyle.moduleStroke),
                                          lineWidth: contrast == .increased ? 1 : 0.5) }
    }
}

/// Applies the selected skin's control tint to a separately hosted surface, such as the usage chart window; an
/// agent's chart takes that agent's palette color instead (AC-16.03).
struct PanelTinted<Content: View>: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var skins: SkinCatalog
    var agent: SessionProvider? = nil
    let content: Content
    init(preferences: PreferencesStore, skins: SkinCatalog, agent: SessionProvider? = nil, @ViewBuilder content: () -> Content) {
        self.preferences = preferences; self.skins = skins; self.agent = agent; self.content = content()
    }
    var body: some View {
        let agentColor = agent.map { AgentPalette.color($0, accentHex: skins.accentHex(for: preferences.value)).color }
        content.tint(agentColor ?? skins.controlTint(for: preferences.value).color)
            .environment(\.agentChartColor, agentColor)
    }
}

private struct AgentChartColorKey: EnvironmentKey { static let defaultValue: Color? = nil }
extension EnvironmentValues {
    /// The agent's palette color on a separately hosted chart, for fills that need a concrete color; nil falls back
    /// to the tint.
    var agentChartColor: Color? {
        get { self[AgentChartColorKey.self] }
        set { self[AgentChartColorKey.self] = newValue }
    }
}

/// Icon-only header and chart buttons with a full hit target and quiet hover feedback.
struct PanelIconButtonStyle: ButtonStyle {
    var size: CGFloat = PanelStyle.Layout.iconButton
    func makeBody(configuration: Configuration) -> some View { PanelIconButton(configuration: configuration, size: size) }
}

private struct PanelIconButton: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    @ViewState private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        configuration.label
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.primary.opacity(configuration.isPressed ? 0.12 : hovered && enabled ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: PanelStyle.Radius.row, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(PanelStyle.hover(reduce: reduceMotion), value: hovered)
    }
}
