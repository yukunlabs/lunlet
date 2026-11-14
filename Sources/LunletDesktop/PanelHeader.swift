// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.02, AC-19.09, AC-19.10, AC-19.11; US-04, AC-04.01, AC-04.03, AC-04.16.
// Refs: US-24, AC-24.01, AC-24.02, AC-24.04; US-25, AC-25.01.
import LunletCore
import SwiftUI

/// The panel's header: a night sky with one body per selected agent around the Sun, which stands for all of them.
/// Every body in one row is the Overview; a chosen agent's body moves to the center and its page opens below
/// (AC-19.09). Each body writes what its lit share shows, so nothing depends on the drawing alone (AC-24.02).
struct PanelHeader: View {
    let agents: [SessionProvider]
    /// The agent whose page is open; nil is the Overview.
    let chosen: SessionProvider?
    let labels: [SessionProvider: HeaderAgentLabel]
    let totals: HeaderTotals
    /// The notch band's height, or the top margin on a display without a notch.
    let top: CGFloat
    /// Left and Right were used, so the current body shows a focus ring until the pointer chooses again (AC-24.04).
    let keyboard: Bool
    let now: Date
    let choose: (HeaderBody) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var warp: SkyWarp?
    @ViewState private var warps = 0

    /// Fixed inks: the sky is dark in both appearances.
    enum Ink {
        static let primary = Color.white.opacity(0.94)
        static let secondary = Color.white.opacity(0.68)
        static let tertiary = Color.white.opacity(0.56)
        static let low = Color(red: 0.96, green: 0.71, blue: 0.27)
        static let critical = Color(red: 1, green: 0.45, blue: 0.4)
    }
    var body: some View {
        GeometryReader { geometry in
            let slots = HeaderLayout.slots(agents: agents, chosen: chosen, width: geometry.size.width, top: top)
            ZStack(alignment: .topLeading) {
                // The empty sky leads back to the Overview, as the Sun does. Only the header's own frame takes the
                // click; the sky's bleed behind the page does not.
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { if chosen != nil && agents.count > 1 { choose(.all) } }
                    .accessibilityHidden(true)
                ForEach(slots, id: \.body) { slot in
                    HeaderBodyView(slot: slot, label: label(slot.body), totals: totals, agentCount: agents.count,
                                   current: slot.body == current, keyboard: keyboard, now: now) { choose(slot.body) }
                        .position(x: slot.x, y: slot.y)
                        .zIndex(slot.role == .center ? 2 : 1)
                }
            }
            .onChange(of: chosen) { old, new in streak(from: old, to: new, width: geometry.size.width) }
        }
        .frame(height: height)
        // The sky is taller than the header: its last points run on behind the top of the page.
        .background(alignment: .top) {
            SkyBackdrop(warp: warp, reduceMotion: reduceMotion, layout: sky(height: skyHeight), fade: PanelStyle.Layout.skyFade,
                        light: HeaderBodyArt.light(of: current), pool: height)
                .frame(height: skyHeight)
        }
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : Self.move, value: chosen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents")
    }

    /// The header's own frame: the sky under the top inset and the gap above the page.
    private var height: CGFloat { top + PanelStyle.Layout.skyHeight + PanelStyle.Layout.skyTail }
    /// The drawn sky, which goes on behind the page.
    private var skyHeight: CGFloat { height + PanelStyle.Layout.skyBleed }

    /// Tells the sky where this header's row and labels are, so its glow sits behind the Sun and its streaks thin out
    /// behind the words on any display.
    private func sky(height: CGFloat) -> SkyLayout {
        let row = top + HeaderLayout.rowDrop
        return SkyLayout(horizon: row / height, calm: (row + HeaderLayout.centerDiameter / 2) / height, calmSpan: 24 / height)
    }

    /// One easing for every move, the bodies' and the sky's alike.
    static let move = Animation.timingCurve(0.16, 1, 0.3, 1, duration: HeaderLayout.duration)

    private var current: HeaderBody { chosen.flatMap { agents.contains($0) ? .agent($0) : nil } ?? (agents.count > 1 ? .all : agents.first.map(HeaderBody.agent) ?? .all) }
    private func label(_ body: HeaderBody) -> HeaderAgentLabel? {
        if case .agent(let provider) = body { return labels[provider] }
        return nil
    }

    /// The sky streaks the way the newly chosen body travels, farther for a body that comes from farther away.
    private func streak(from old: SessionProvider?, to new: SessionProvider?, width: CGFloat) {
        guard !reduceMotion else { warp = nil; return }
        let target: HeaderBody = new.map(HeaderBody.agent) ?? .all
        let before = HeaderLayout.slots(agents: agents, chosen: old, width: width, top: top).first { $0.body == target }
        let away = (before?.x ?? width / 2 + 150) - width / 2
        let far = min(1.7, abs(away) / (110 * width / HeaderLayout.referenceWidth))
        warps += 1
        warp = SkyWarp(id: warps, direction: away < 0 ? -1 : 1, strength: 0.45 + far * 0.55, start: Date())
    }
}

/// The drawn sky with its dissolving end: the field of stars, a dusk tint toward its lower end and the mask that takes
/// it to nothing. It takes no clicks and says nothing; a header puts its bodies in front of it.
struct SkyBackdrop: View {
    let warp: SkyWarp?
    let reduceMotion: Bool
    var layout = SkyLayout()
    /// The stretch over which the sky dissolves, ending at its lower end.
    let fade: CGFloat
    /// How far up from its lower end the dusk tint reaches.
    var dusk: CGFloat = 190
    /// The chosen body's light, which pools where the sky gives way to the page, and how far below the sky's top
    /// that is; nil casts none.
    var light: Color? = nil
    var pool: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let light {
                    // Under the sky, so it shows only where the sky has thinned: a wash of the body's color behind
                    // the top of the page, widest in the middle and gone before the sides and the list.
                    EllipticalGradient(stops: [.init(color: light.opacity(0.34), location: 0), .init(color: light.opacity(0.19), location: 0.38),
                                               .init(color: light.opacity(0.055), location: 0.76), .init(color: light.opacity(0), location: 1)],
                                       center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                        .frame(width: geometry.size.width * 1.25, height: 230)
                        .position(x: geometry.size.width / 2, y: pool)
                }
                SkyField(warp: warp, reduceMotion: reduceMotion, layout: layout)
                    .overlay(SkyFade.dusk(height: geometry.size.height, reach: dusk))
                    // One picture before the mask: masked one by one, the sky and its tint would add up to more than
                    // the mask leaves of either, and the tint would thicken the tail.
                    .compositingGroup()
                    .mask { SkyFade.mask(size: geometry.size, length: fade) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The sky has no edge. It runs from one side of the panel to the other and dissolves over a long stretch that goes
/// on behind the page's first card: never steep, with a long tail, along arcs rather than a straight line, and
/// through a low dusk tint.
enum SkyFade {
    /// The arcs' horizontal half-axis as a multiple of the sky's width: the sides dissolve a little sooner.
    static let arc: CGFloat = 2
    /// How much of the sky is left `t` of the way along its dissolving stretch: it leaves slowly, is half gone a
    /// little past a quarter of the way and then thins out in a long tail, with no slope at either end. Most of a
    /// gradient between a dark sky and a light page is seen where it is steepest, so the curve is never steep.
    static func remaining(_ t: Double) -> Double {
        let t = min(1, max(0, t)), half = 0.265, lastPart = 0.62
        let body = 1 / (1 + pow(t / half, 3))
        guard t > lastPart else { return body }
        let u = (t - lastPart) / (1 - lastPart)
        return body * (1 - u * u * (3 - 2 * u))
    }
    /// Whole down to `length` points above the lower end at the middle, then dissolving along `remaining`.
    static func mask(size: CGSize, length: CGFloat) -> some View {
        let start = Double(max(0, 1 - length / max(size.height, 1))), steps = 40
        let stops = [Gradient.Stop(color: .black, location: 0)] + (0...steps).map { step -> Gradient.Stop in
            let t = Double(step) / Double(steps)
            return .init(color: .black.opacity(remaining(t)), location: start + (1 - start) * t)
        }
        // An ellipse centered on the top edge whose lower end is the sky's.
        return EllipticalGradient(stops: stops, center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
            .frame(width: 2 * arc * size.width, height: 2 * size.height)
            .position(x: size.width / 2, y: 0)
    }
    /// The tint over the sky's lower stretch: clear above it, indigo where the sky starts to thin and lavender in its
    /// tail, kept low: the sky dissolves into a surface of nearly its own color, and the tint only keeps the last of
    /// it from going flat.
    static func dusk(height: CGFloat, reach: CGFloat) -> LinearGradient {
        let indigo = Color(.sRGB, red: 0.36, green: 0.34, blue: 0.90, opacity: 0.16)
        let lavender = Color(.sRGB, red: 0.64, green: 0.55, blue: 0.99, opacity: 0.26)
        return LinearGradient(stops: [.init(color: indigo.opacity(0), location: 0), .init(color: indigo, location: 0.42),
                                      .init(color: lavender, location: 0.8), .init(color: lavender, location: 1)],
                              startPoint: UnitPoint(x: 0.5, y: Double(max(0, 1 - reach / max(height, 1)))), endPoint: .bottom)
    }
}

/// Reads each agent's own models for the header, so the minute's tick and a refresh redraw the labels only.
struct PanelHeaderHost: View {
    let agents: [SessionProvider]
    let chosen: SessionProvider?
    let top: CGFloat
    let keyboard: Bool
    @ObservedObject var account: AccountUsageModel
    @ObservedObject var limits: ClaudePlanLimitsModel
    @ObservedObject var codexHistory: LocalUsageModel
    @ObservedObject var claudeHistory: LocalUsageModel
    let waiting: [SessionProvider: Int]
    let choose: (HeaderBody) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let labels = Dictionary(uniqueKeysWithValues: agents.map { ($0, label($0, now: now)) })
            PanelHeader(agents: agents, chosen: chosen, labels: labels,
                        totals: HeaderPresentation.totals(agents.map { labels[$0]?.today }), top: top, keyboard: keyboard,
                        now: now, choose: choose)
        }
    }

    /// Each agent's weekly window as it reports it; nothing is borrowed from another window or an earlier read
    /// (AC-04.03, AC-19.10).
    private func label(_ provider: SessionProvider, now: Date) -> HeaderAgentLabel {
        switch provider {
        case .codex:
            return HeaderPresentation.codexLabel(snapshot: account.displayedSnapshot, state: account.state,
                                                 today: OverviewUsage.today(codexHistory.snapshot, now: now),
                                                 waiting: waiting[.codex] ?? 0)
        case .claude:
            let reading = limits.connection == .connected ? limits.limits?.sevenDay : nil
            let remaining = ClaudeLimitsText.remaining(reading, now: now)
            let unknown = remaining == nil
                ? HeaderPresentation.claudeUnknown(connection: limits.connection, hasReading: reading != nil, readFailed: limits.readFailed) ?? .unknown
                : nil
            return HeaderAgentLabel(provider: .claude, remaining: remaining, plan: limits.account?.plan,
                                    resetsAt: remaining == nil ? nil : reading?.resetsAt, unknown: unknown,
                                    today: OverviewUsage.today(claudeHistory.snapshot, now: now), waiting: waiting[.claude] ?? 0)
        }
    }
}

/// One body with its two labels: the full one in the row and in the center, the short one at the sides. They
/// cross-fade, and nothing but position, scale and opacity changes while a body moves.
private struct HeaderBodyView: View {
    let slot: HeaderLayout.Slot
    let label: HeaderAgentLabel?
    let totals: HeaderTotals
    let agentCount: Int
    let current: Bool
    let keyboard: Bool
    let now: Date
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovered = false

    private typealias Ink = PanelHeader.Ink
    private static let art = HeaderLayout.centerDiameter
    /// A planet's disc inside the art's frame.
    private static let disc = 2 * HeaderBodyArt.discRadius / HeaderBodyArt.box * art
    private var scale: CGFloat { slot.diameter / Self.art }
    private var radius: CGFloat { slot.diameter / 2 }
    private var unknown: Bool { slot.body != .all && label?.remaining == nil }

    var body: some View {
        Button(action: action) {
            ZStack {
                // A soft glow answers the pointer; the body itself only swells a little.
                Circle().fill(RadialGradient(colors: [Color(red: 0.78, green: 0.82, blue: 1).opacity(0.42), .clear],
                                             center: .center, startRadius: Self.art * 0.3, endRadius: Self.art * 0.62))
                    .frame(width: Self.art * 1.24, height: Self.art * 1.24)
                    .scaleEffect(scale * 1.4).opacity(hovered ? (slot.role == .center ? 0.5 : 1) : 0)
                HeaderBodyArt(slot.body, lit: slot.body == .all ? nil : label?.lit, mirrored: slot.mirrored)
                    .frame(width: Self.art, height: Self.art)
                    // A planet is dimmed by a veil over its disc, never by its own opacity: the stars behind a body
                    // must not show through it. The Sun only fades a little at the side.
                    .overlay {
                        if slot.body != .all {
                            Circle().fill(HeaderBodyDrawing.night).frame(width: Self.disc, height: Self.disc)
                                .opacity(unknown ? 0.64 : slot.role == .side ? 0.2 : 0)
                        }
                    }
                    .opacity(slot.body == .all && slot.role == .side ? 0.86 : 1)
                    .scaleEffect(scale * (hovered ? (slot.role == .center ? 1.02 : 1.06) : 1))
                if current && keyboard {
                    Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: slot.diameter * 1.18, height: slot.diameter * 1.18)
                }
                if let waiting = label?.waiting, waiting > 0 { badge }
            }
            .frame(width: Self.art, height: Self.art)
            .overlay(alignment: .top) { labels.fixedSize().offset(y: Self.art / 2 + radius + 4) }
            .background { hitArea }
        }
        .buttonStyle(.plain)
        .opacity(slot.visible ? 1 : 0)
        .allowsHitTesting(slot.visible)
        .onHover { hovered = $0 }
        .animation(PanelStyle.hover(reduce: reduceMotion), value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(spoken)
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(slot.body == .all ? "Shows the Overview" : current && agentCount > 1 ? "Returns to the Overview" : "Opens this agent's page")
        .accessibilityHidden(!slot.visible)
        .help(help)
    }

    /// The pointer's target covers the body and its label, which belong together.
    private var hitArea: some View {
        let size = slot.role == .side ? CGSize(width: 68, height: 74) : CGSize(width: 96, height: 132)
        return Color.clear.frame(width: size.width, height: size.height).contentShape(Rectangle())
            .offset(y: (size.height - Self.art) / 2 - (slot.role == .side ? 20 : 4))
    }

    /// A session of this agent waits for the developer: a small amber dot at the body's shoulder, ringed in the sky's
    /// own dark so it reads on any body. The count and the words are in the label, the help and the Overview's line.
    private var badge: some View {
        Circle().fill(Ink.low).frame(width: 9, height: 9)
            .overlay { Circle().strokeBorder(Color(red: 0.04, green: 0.035, blue: 0.1), lineWidth: 2).padding(-2) }
            .scaleEffect(slot.role == .side ? 0.8 : 1)
            .offset(x: radius * 0.7, y: -radius * 0.7)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var labels: some View {
        ZStack(alignment: .top) {
            full.opacity(slot.role == .side ? 0 : 1).scaleEffect(slot.role == .center ? 1.1 : 1, anchor: .top)
            short.opacity(slot.role == .side ? 1 : 0)
        }
        .lineLimit(1).monospacedDigit().multilineTextAlignment(.center)
        // A star behind a word never competes with it.
        .shadow(color: Color(red: 0.02, green: 0.02, blue: 0.06).opacity(0.9), radius: 2.5)
    }

    /// Figure, name and plan, then the reset and today's tokens; a chosen agent's page shows today's usage itself.
    private var full: some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: figure).font(PanelStyle.Text.headerFigure).foregroundStyle(figureColor)
                // The dash of an unknown limit stands alone: there is nothing that is left.
                if slot.body == .all || !unknown {
                    Text(verbatim: slot.body == .all ? "tokens" : "left").font(PanelStyle.Text.secondary).foregroundStyle(Ink.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: slot.body == .all ? "All" : shortName).font(PanelStyle.Text.headerName).foregroundStyle(Ink.primary)
                if let detail { Text(verbatim: detail).font(PanelStyle.Text.secondary).foregroundStyle(Ink.tertiary) }
            }
            Text(verbatim: line).font(PanelStyle.Text.secondary).foregroundStyle(Ink.tertiary)
            if slot.body != .all, let label {
                (Text(verbatim: "Today ").foregroundColor(Ink.secondary) + Text(verbatim: label.todayTokens).fontWeight(.semibold).foregroundColor(Ink.primary))
                    .font(PanelStyle.Text.secondary)
                    .opacity(slot.role == .center ? 0 : 1)
            }
        }
    }

    private var short: some View {
        VStack(spacing: 1) {
            Text(verbatim: figure).font(PanelStyle.Text.headerName.weight(.bold)).foregroundStyle(figureColor)
            Text(verbatim: slot.body == .all ? "All" : shortName).font(PanelStyle.Text.secondary.weight(.medium)).foregroundStyle(Ink.primary)
        }
    }

    private var figure: String { slot.body == .all ? totals.tokens : label?.percent ?? "—" }
    private var figureColor: Color {
        switch label?.warning ?? .none {
        case .none: Ink.primary
        case .low: Ink.low
        case .critical: Ink.critical
        }
    }
    /// The agent's full name, always written under its body (AC-19.09).
    private var shortName: String { label?.provider.displayName ?? "" }
    private var name: String { slot.body == .all ? "All agents" : label?.provider.displayName ?? "" }
    private var detail: String? {
        slot.body == .all ? "\(agentCount) agent" + (agentCount == 1 ? "" : "s") : label?.plan
    }
    private var line: String {
        if slot.body == .all { return totals.cost.map { "today · " + $0 } ?? "today" }
        return label?.reset(now: now, moment: slot.role == .center) ?? ""
    }
    private var spoken: String {
        if slot.body == .all { return totals.tokens + " tokens today" + (totals.cost.map { ", " + $0 } ?? "") }
        return label?.spoken(now: now) ?? ""
    }
    private var help: String {
        if slot.body == .all { return "Every selected agent: today's recorded tokens on this Mac and their estimated cost. Allowances are never combined." }
        return name + (label.map { " · " + $0.spoken(now: now) } ?? "")
    }
}
