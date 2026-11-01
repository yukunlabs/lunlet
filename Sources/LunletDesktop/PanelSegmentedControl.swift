// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.05; US-23, AC-23.01, AC-23.02; US-24, AC-24.01, AC-24.02.
import AppKit
import SwiftUI

/// The one segmented style in the panel, shared by the provider tabs and the Active/History switch:
/// an elevated pill slides to the selection on a subtle translucent track. Its appearance comes only from
/// `PanelSegmentedStyle`, which has no window key or active-state input, so a non-key hover preview and the
/// pinned key panel draw it identically.
struct PanelSegmentedControl<Value: Hashable>: View {
    struct Segment {
        let value: Value
        let title: String
        /// A trailing figure such as a count, drawn secondary in the label's size.
        var detail: String? = nil
        var accessibilityLabel: String? = nil
    }
    @Binding var selection: Value
    let segments: [Segment]
    var size: PanelSegmentedStyle.Size = .regular
    /// The group's VoiceOver label.
    let label: String
    @Namespace private var namespace
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let style = PanelSegmentedStyle(size: size, scheme: scheme, contrast: contrast)
        let track = RoundedRectangle(cornerRadius: style.trackRadius, style: .continuous)
        HStack(spacing: 0) {
            ForEach(segments.indices, id: \.self) { index in segment(segments[index], style: style) }
        }
        .padding(style.inset)
        .frame(height: style.height)
        .background(style.track, in: track)
        .overlay { if let border = style.border { track.strokeBorder(border, lineWidth: 1) } }
        .overlay {
            // Focus follows Full Keyboard Access like a native control; arrows move the selection.
            if focused {
                track.stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3).padding(-1.5)
                    .accessibilityHidden(true)
            }
        }
        .focusable(interactions: .activate)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .animation(PanelStyle.selection(reduce: reduceMotion), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isTabBar)
    }

    private func segment(_ segment: Segment, style: PanelSegmentedStyle) -> some View {
        let selected = segment.value == selection
        return HStack(spacing: style.detailSpacing) {
            // Sized for the semibold selection so choosing a segment never shifts the others.
            Text(segment.title).fontWeight(.semibold).hidden()
                .overlay { Text(segment.title).fontWeight(selected ? .semibold : .regular) }
            if let detail = segment.detail {
                Text(detail).font(style.detailFont).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .font(style.font)
        .foregroundStyle(selected ? .primary : .secondary)
        .lineLimit(1).fixedSize()
        .padding(.horizontal, style.padding)
        .frame(maxHeight: .infinity)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: style.pillRadius, style: .continuous)
                    .fill(style.pill)
                    .overlay {
                        if let border = style.border {
                            RoundedRectangle(cornerRadius: style.pillRadius, style: .continuous).strokeBorder(border, lineWidth: 1)
                        }
                    }
                    .shadow(color: style.shadow, radius: 1.5, y: 0.5)
                    .matchedGeometryEffect(id: "selection", in: namespace)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = segment.value }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segment.accessibilityLabel ?? segment.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selection = segment.value }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        guard segments.contains(where: { $0.value == selection }) else { return .ignored }
        if let next = Self.neighbor(of: selection, offset: offset, in: segments.map(\.value)) { selection = next }
        return .handled
    }
    /// The segment an arrow key selects; the ends do not wrap, as in a native segmented control.
    static func neighbor(of value: Value, offset: Int, in values: [Value]) -> Value? {
        guard let index = values.firstIndex(of: value), values.indices.contains(index + offset) else { return nil }
        return values[index + offset]
    }
}

/// Everything the segmented control's appearance depends on: size, color scheme and contrast. There is
/// deliberately no key-window or control-active-state input.
struct PanelSegmentedStyle: Equatable {
    enum Size { case regular, small }
    let height: CGFloat
    let inset: CGFloat
    let padding: CGFloat
    let trackRadius: CGFloat
    let pillRadius: CGFloat
    let font: Font
    let detailFont: Font
    let detailSpacing: CGFloat
    let track: Color
    let pill: Color
    let shadow: Color
    let border: Color?

    init(size: Size, scheme: ColorScheme, contrast: ColorSchemeContrast) {
        let dark = scheme == .dark
        switch size {
        case .regular:
            // The 28 pt hit target of a header control; concentric 8 / 6 radii inside a 2 pt inset.
            height = PanelStyle.Layout.headerHeight; trackRadius = 8; pillRadius = 6
            font = PanelStyle.Text.primary
        case .small:
            height = PanelStyle.Layout.listHeaderHeight; trackRadius = 7; pillRadius = 5
            font = PanelStyle.Text.secondary
        }
        inset = PanelStyle.Space.hairline
        // The first label starts on the cards' text edge when the track starts on their outer edge.
        padding = PanelStyle.Grid.textInset - inset
        // A count shares its label's size; the secondary color sets it apart.
        detailFont = font
        detailSpacing = PanelStyle.Space.tight
        track = dark ? .white.opacity(0.08) : .black.opacity(0.06)
        pill = dark ? .white.opacity(0.22) : .white
        shadow = .black.opacity(dark ? 0.3 : 0.15)
        border = contrast == .increased ? Color(nsColor: .separatorColor) : nil
    }
}
