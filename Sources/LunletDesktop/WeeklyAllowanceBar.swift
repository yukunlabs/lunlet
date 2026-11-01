// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-16, AC-16.02, AC-16.03; US-24, AC-24.02.
// Refs: US-04, AC-04.03, AC-04.07, AC-04.10; US-17, AC-17.07; US-33, AC-33.09.
import LunletCore
import SwiftUI

enum WeeklyAllowanceMarkers {
    /// Ruler marks shared by the bar and the vine; there are no minor 10% ticks.
    static let references: [Double] = [20, 40, 60, 80]
    /// The low-allowance boundary, drawn longer and in red on the expanded bar.
    static let warning: Double = 10
    static var barMarks: [Double] { [warning] + references }
}

/// The one meter for every allowance and plan limit, Codex and Claude alike: a 6-point track, a fill exactly as
/// tall in the selected palette's gradient, colored by remaining allowance so the low-allowance warnings apply to
/// every agent, and marks drawn as overlays that never change its height. A small non-zero fill keeps a full-height
/// round minimum; zero stays an empty track; unknown is a dashed empty track, never a fill, marks or zero.
struct PanelMeter: View {
    /// The filled share, 0 through 100.
    let fill: Double?
    /// Remaining allowance, 0 through 100, which selects the palette colors.
    let remaining: Double?
    var accentHex: String? = nil
    /// The agent's palette variant (AgentPalette); zero keeps the selected palette.
    var hueShift: Double = 0
    /// Short separators inside the track, such as the 20/40/60/80 ruler.
    var marks: [Double] = []
    /// The taller red low-allowance mark.
    var warning: Double? = nil
    /// The even-pace tick.
    var tick: Double? = nil

    /// The fill's width: zero stays empty, and a small share is at least as wide as the track is tall.
    static func fillWidth(_ value: Double, width: CGFloat) -> CGFloat {
        guard value > 0, width > 0 else { return 0 }
        return min(width, max(PanelStyle.Layout.meterHeight, width * min(100, value) / 100))
    }

    var body: some View {
        let height = PanelStyle.Layout.meterHeight
        if let fill = AllowancePalette.normalized(fill), let remaining = AllowancePalette.normalized(remaining) {
            Capsule().fill(AllowancePalette.trackColor(tintHex: accentHex, hueShift: hueShift).color.opacity(0.2))
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule().fill(AllowancePalette.gradient(remaining: remaining, tintHex: accentHex, hueShift: hueShift))
                            .frame(width: Self.fillWidth(fill, width: geometry.size.width), height: height)
                    }
                }
                .overlay {
                    GeometryReader { geometry in
                        ForEach(marks, id: \.self) { percent in
                            mark(Color(nsColor: .windowBackgroundColor).opacity(0.85), height: height - 3)
                                .position(x: geometry.size.width * percent / 100, y: height / 2)
                        }
                        if let warning {
                            mark(Color(red: 0.82, green: 0.25, blue: 0.31), height: height + 3)
                                .position(x: geometry.size.width * warning / 100, y: height / 2)
                        }
                        if let tick, tick.isFinite {
                            mark(Color.primary.opacity(0.55), height: height + 4)
                                .position(x: geometry.size.width * min(100, max(0, tick)) / 100, y: height / 2)
                        }
                    }
                }
                .frame(height: height)
        } else {
            Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.tertiary)
                .frame(height: height)
        }
    }

    private func mark(_ color: Color, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 0.75).fill(color).frame(width: 1.5, height: height).allowsHitTesting(false)
    }
}

/// One agent window's remaining allowance, Codex and Claude alike: the 20/40/60/80 ruler,
/// the red 10% low-allowance mark, the agent's palette and an optional even-pace tick, all in remaining terms.
struct AllowanceBar: View {
    let remaining: Double?
    var accentHex: String? = nil
    var agent: SessionProvider = .codex
    /// Remaining at even pace by the latest reading's time; a comparison, never a forecast.
    var evenPace: Double? = nil
    var label = "Weekly allowance remaining"
    var body: some View {
        if let value = AllowancePalette.normalized(remaining) {
            PanelMeter(fill: value, remaining: value, accentHex: accentHex, hueShift: AgentPalette.hueShift(agent),
                       marks: WeeklyAllowanceMarkers.references, warning: WeeklyAllowanceMarkers.warning, tick: evenPace)
                .help("Remaining allowance. The red mark indicates the 10% low-allowance threshold. Yellow below 20%; "
                    + "deeper red below 10%." + (evenPace.map { " The tick marks even pace, " + Self.percent($0)
                        + " left by the latest reading's time; it is not a forecast." } ?? ""))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue("\(Self.percent(value)) left. "
                    + "Low-allowance threshold at 10 percent; other marks at 20, 40, 60, and 80 percent.")
        } else {
            PanelMeter(fill: nil, remaining: nil)
                .help("Unavailable; nothing is shown as zero.")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue("Unavailable")
        }
    }
    private static func percent(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) + "%" }
}
