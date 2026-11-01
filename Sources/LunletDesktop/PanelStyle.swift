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
        static let rowHeight: CGFloat = 44
        /// A title, primary or figure line in a card; it also holds the 20-point inline chart button.
        static let line: CGFloat = 20
        /// A secondary line: subtitles, reset times and footnotes.
        static let secondaryLine: CGFloat = 14
        /// Every allowance and plan-limit meter, Codex and Claude alike.
        static let meterHeight: CGFloat = 6
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
        /// Both provider cards: a title line, a secondary line, the limits group and a footnote, inside the card
        /// padding. Codex fills the group with a figure line, the meter and a reset line; Claude with two compact
        /// windows, each a secondary line over its meter, so the cards match and switching tabs never shifts.
        static let limitsGroup: CGFloat = line + Grid.row + meterHeight + Grid.row + secondaryLine
        static let cardHeight: CGFloat = 2 * Grid.margin + line + Grid.row + secondaryLine + Grid.group + limitsGroup
            + Grid.group + secondaryLine
        /// One compact Claude window: its line, a tight gap and the meter; two with a tight gap fill a limits group.
        static let compactWindow: CGFloat = secondaryLine + Space.tight + meterHeight
        /// Three whole rows in their list module, with hairlines between them.
        static let threeRows: CGFloat = 3 * rowHeight + 2 * listVerticalInset + 2 * 0.5
        /// The page between the header and the footer: a provider card and exactly three whole rows (AC-03.10).
        static let pageHeight: CGFloat = cardHeight + Grid.margin + listHeaderHeight + Grid.group + threeRows
        /// Everything above the page. Below a notch the header shares the menu-bar band, with a tab row under it
        /// when several agents are selected; without a notch one header row holds the title or tabs and actions.
        static func headerBlock(notchHeight: CGFloat?, tabRow: Bool) -> CGFloat {
            guard let notchHeight else { return headerHeight + headerGap }
            return notchHeight + (tabRow ? headerHeight : 0) + headerGap
        }
        /// The panel height that keeps the page budget on every display.
        static func panelHeight(notchHeight: CGFloat?, tabRow: Bool) -> CGFloat {
            headerBlock(notchHeight: notchHeight, tabRow: tabRow) + pageHeight + footerHeight
        }
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
    }
    /// Modules are lighter translucent layers on the glass rather than gray fills; over the opaque surface of
    /// Reduce Transparency the same fill composites to an opaque tone.
    static var moduleFill: Color { Color(nsColor: moduleFillColor) }
    static let moduleFillColor = NSColor(name: "LunletModuleFill") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.5)
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
            .overlay { if contrast == .increased { shape.strokeBorder(PanelStyle.separator, lineWidth: 1) } }
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
        content.tint(agent.map { AgentPalette.color($0, accentHex: skins.accentHex(for: preferences.value)).color }
            ?? skins.controlTint(for: preferences.value).color)
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
