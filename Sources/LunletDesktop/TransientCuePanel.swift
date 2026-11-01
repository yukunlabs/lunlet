// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-13, AC-13.01, AC-13.02, AC-13.03, AC-13.04, AC-13.05, AC-13.06, AC-13.07, AC-13.08.
// Refs: US-03, AC-03.10, AC-03.11; US-12, AC-12.04.
import AppKit
import QuartzCore
import SwiftUI
import LunletCore

@MainActor final class TransientCuePanel: TaskCuePresenting {
    private var panel: FloatingPanel?
    private var surface: NotchSurfaceView?
    private var retraction: Task<Void, Never>?
    private var presenting = false
    private var closed = false
    var isVisible: Bool { presenting && panel?.isVisible == true }
    var changed: ((LettermarkView.Pose?) -> Void)?
    private let expanded: @MainActor () -> Bool
    init(expanded: @escaping @MainActor () -> Bool = { false }) {
        self.expanded = expanded
    }

    func show(_ cues: [TaskCue]) {
        guard !closed, !expanded(), let cue = cues.last,
              let screen = PanelScreen.notchDisplay ?? NSScreen.main ?? NSScreen.screens.first else { hideImmediately(); return }
        retraction?.cancel(); retraction = nil
        let panel: FloatingPanel
        if let existing = self.panel { panel = existing }
        else {
            panel = FloatingPanel(identifier: "Lunlet.cue", title: "Lunlet activity", acceptsKey: false)
            panel.ignoresMouseEvents = true; panel.hasShadow = false
            self.panel = panel
        }
        let geometry = PanelScreen(screen)
        let text = TaskCueText(cue: cue)
        let frame = PanelPlacement.cue(size: text.size(screen: geometry), screen: geometry)
        // The newest cue replaces the current one in place (AC-13.05).
        let surface = Self.surface(text: text, screen: geometry, frame: frame)
        panel.contentView = surface; self.surface = surface
        panel.setFrame(frame, display: true)
        switch cue.phase {
        case .started: changed?(.working)
        case .finished(.stopped), .finished(.failed): changed?(.awake)
        case .finished: changed?(.finished)
        }
        surface.setExpanded(true, animated: !presenting && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        presenting = true
        panel.orderFrontRegardless()
    }
    func hide() {
        guard presenting, !closed, SystemDisplayState.isAvailable,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { hideImmediately(); return }
        presenting = false
        surface?.setExpanded(false, animated: true)
        retraction?.cancel()
        retraction = Task { [weak self] in
            do { try await Task.sleep(for: NotchSurfaceView.retractionDelay) } catch { return }
            guard let self, !self.presenting else { return }
            self.hideImmediately()
        }
    }
    func hideImmediately() {
        retraction?.cancel(); retraction = nil; presenting = false
        surface?.stopAnimations(); panel?.orderOut(nil); changed?(nil)
    }
    func shutdown() {
        closed = true; hideImmediately()
        panel?.close(); panel?.contentView = nil; panel = nil; surface = nil; changed = nil
    }

    /// The black island continuing the notch, or the same content in a black pill below the menu bar.
    static func surface(text: TaskCueText, screen: PanelScreen, frame: CGRect) -> NotchSurfaceView {
        let content: AnyView
        if let notch = screen.notch {
            content = AnyView(IslandCueLabel(text: text, leftWing: notch.minX - frame.minX, rightWing: frame.maxX - notch.maxX,
                                             notchWidth: notch.width, notchHeight: notch.height))
        } else { content = AnyView(PillCueLabel(text: text)) }
        let surface = NotchSurfaceView(content: content, style: .island)
        surface.frame = CGRect(origin: .zero, size: frame.size)
        surface.notchWidth = screen.notch?.width; surface.notchHeight = screen.notch?.height ?? 0
        surface.notchCenterX = screen.notch.map { $0.midX - frame.minX }
        return surface
    }
}

/// The band beside the notch holds the status (leading) and project (trailing) outside the lettering
/// clearance; the preview row continues below the notch.
private struct IslandCueLabel: View {
    let text: TaskCueText
    let leftWing: CGFloat
    let rightWing: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                CueStatusLabel(text: text)
                    .frame(width: max(0, leftWing - TaskCueText.wingPadding), alignment: .leading)
                    .padding(.leading, TaskCueText.edgePadding).padding(.trailing, TaskCueText.notchClearance)
                Color.clear.frame(width: notchWidth)
                CueProjectLabel(text: text)
                    .frame(width: max(0, rightWing - TaskCueText.wingPadding), alignment: .trailing)
                    .padding(.leading, TaskCueText.notchClearance).padding(.trailing, TaskCueText.edgePadding)
            }.frame(height: notchHeight)
            CuePreviewLabel(text: text)
                .padding(.top, TaskCueText.previewInset).padding(.horizontal, TaskCueText.previewPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .cueAccessibility(text)
    }
}

private struct PillCueLabel: View {
    let text: TaskCueText
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: TaskCueText.pillGap) {
                CueStatusLabel(text: text)
                Spacer(minLength: 0)
                CueProjectLabel(text: text)
            }
            CuePreviewLabel(text: text)
        }
        .padding(.horizontal, TaskCueText.pillPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cueAccessibility(text)
    }
}

private struct CueStatusLabel: View {
    let text: TaskCueText
    var body: some View {
        HStack(spacing: TaskCueText.symbolSpacing) {
            Image(systemName: text.symbol).foregroundStyle(text.tint).frame(width: TaskCueText.symbolWidth)
            Text(text.status).foregroundStyle(.white)
        }
        .font(Font(TaskCueText.statusFont as CTFont)).lineLimit(1).fixedSize()
    }
}

private struct CueProjectLabel: View {
    let text: TaskCueText
    var body: some View {
        Text(verbatim: text.title).font(Font(TaskCueText.projectFont as CTFont)).foregroundStyle(.white)
            .lineLimit(1).truncationMode(.tail)
    }
}

private struct CuePreviewLabel: View {
    let text: TaskCueText
    var body: some View {
        Text(verbatim: text.context).font(Font(TaskCueText.previewFont as CTFont)).foregroundStyle(.white.opacity(0.75))
            .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .center)
    }
}

private extension View {
    /// One element reading "Started, project, preview"; semantic colors resolve against the black surface.
    func cueAccessibility(_ text: TaskCueText) -> some View {
        environment(\.colorScheme, .dark)
            .accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: text.accessibilityLabel))
    }
}
