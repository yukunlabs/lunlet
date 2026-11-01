// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-22, AC-22.01, AC-22.02, AC-22.03; US-20, AC-20.02, AC-20.04; US-01, AC-01.01, AC-01.02; US-12, AC-12.02.
import SwiftUI

/// The connection card attached to the footer's channel entry. Every channel shares its shape: the channel and its
/// state in the title row, then either the saved connection's readiness stages or the numbered setup steps, with the
/// line that needs the owner's attention first and the next action at the bottom right (AC-22.03).
struct ConnectionCard: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var setup: FeishuSetupModel
    @ObservedObject var botSetup: BotChannelSetupModel
    @ObservedObject var notifications: LockedCompletionNotifications
    /// The tallest body the panel can hold above its footer.
    let bodyLimit: CGFloat
    let close: () -> Void
    @ViewState private var bodyHeight: CGFloat = 204

    static let width: CGFloat = 340
    /// The title row, the card padding, the gap to the body and a breath of panel above the card.
    static let chrome: CGFloat = 28 + 2 * PanelStyle.Space.margin + PanelStyle.Space.module + PanelStyle.Space.medium

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.module) {
            HStack(spacing: PanelStyle.Space.medium) {
                Text(channelName).font(PanelStyle.Text.title)
                    .help("Mobile access requires a verified bot owner and is subject to organization policies.")
                StatusChip(word: health.word, tone: health.tone)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(PanelIconButtonStyle())
                .padding(.trailing, -6)
                .accessibilityLabel("Close connection card")
            }
            ScrollView {
                content.background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ConnectionContentHeight.self, value: geometry.size.height)
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(height: min(max(120, bodyLimit), max(1, bodyHeight)))
            .onPreferenceChange(ConnectionContentHeight.self) { [height = $bodyHeight] value in
                height.wrappedValue = value.rounded(.up)
            }
        }
        .padding(PanelStyle.Space.margin).frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PanelStyle.separator, lineWidth: 0.5))
        .overlay(alignment: .bottomLeading) {
            // The caret points at the footer entry that owns this card.
            CardCaret().fill(.regularMaterial).frame(width: 14, height: 7).offset(x: 36, y: 7).accessibilityHidden(true)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.module) {
            // The stages matter once a connection is saved; before that the setup steps take the room (AC-22.03).
            if hasSavedConnection { ReadinessStageList(stages: stages) }
            if preferences.value.channel == .feishu { FeishuSetupPanel(setup: setup, notifications: notifications) }
            else { BotChannelSetupPanel(model: botSetup, notifications: notifications) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasSavedConnection: Bool {
        if preferences.value.channel == .feishu { if case .enrolled = setup.state { return true } else { return false } }
        return botSetup.state == .enrolled
    }
    private var stages: [ReadinessStage] {
        preferences.value.channel == .feishu
            ? setup.readinessStages(delivery: notifications.status, authorization: notifications.authorizationCheck)
            : botSetup.readinessStages(delivery: notifications.status, authorization: notifications.authorizationCheck)
    }
    private var channelName: String { preferences.value.channel == .feishu ? setup.platformName : preferences.value.channel.title }
    private var health: ChannelHealth { ChannelHealth(stages: stages) }
}

private struct ConnectionContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct CardCaret: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .init(x: rect.minX, y: rect.minY)); path.addLine(to: .init(x: rect.midX, y: rect.maxY))
        path.addLine(to: .init(x: rect.maxX, y: rect.minY)); path.closeSubpath()
        return path
    }
}

/// A connection state word with a colored dot; the word, not the color, carries the meaning.
struct StatusChip: View {
    let word: String
    let tone: PanelTone
    var body: some View {
        HStack(spacing: PanelStyle.Space.tight) {
            Circle().fill(tone == .neutral ? Color.secondary : tone.color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(word)
        }
        .font(PanelStyle.Text.secondary.weight(.medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, PanelStyle.Space.hairline)
        .background(PanelStyle.moduleFill, in: Capsule())
    }
}

/// The factual readiness stages, shared by Settings and the attached connection card (AC-22.03).
struct ReadinessStageList: View {
    let stages: [ReadinessStage]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(stages) { stage in
                HStack(spacing: PanelStyle.Space.medium) {
                    Image(systemName: stage.symbol).foregroundStyle(stage.tone == .neutral ? Color.secondary : stage.tone.color)
                        .frame(width: 16).accessibilityHidden(true)
                    Text(stage.id)
                    Spacer(minLength: PanelStyle.Space.medium)
                    Text(stage.value).foregroundStyle(ReadinessStage.valueStyle(stage.tone))
                        .multilineTextAlignment(.trailing)
                }
                .font(PanelStyle.Text.secondary)
                .frame(minHeight: 18)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, PanelStyle.Space.medium).padding(.vertical, PanelStyle.Space.tight)
        .background(PanelStyle.moduleFill, in: RoundedRectangle(cornerRadius: PanelStyle.Radius.row, style: .continuous))
    }
}

// MARK: - The setup vocabulary every channel's card speaks

/// One numbered setup step: a clear title, then its controls and notes.
struct SetupStep<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PanelStyle.Space.small) {
            Text("\(number)").font(Font.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 12)
                .accessibilityLabel("Step \(number)")
            VStack(alignment: .leading, spacing: PanelStyle.Space.tight) {
                Text(title).font(Font.subheadline.weight(.semibold))
                content()
            }
        }
    }
}

/// A quiet line under a step or field: where a value comes from, or what happens next.
struct SetupNote: View {
    let text: String
    var body: some View {
        Text(text).font(Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The one line that says what went wrong or what the owner must do now; never a quiet caption.
struct SetupAlert: View {
    let text: String
    var tone: PanelTone = .failure
    var body: some View {
        Label(text, systemImage: tone == .failure ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
            .font(Font.subheadline).foregroundStyle(tone.color).fixedSize(horizontal: false, vertical: true)
    }
}
