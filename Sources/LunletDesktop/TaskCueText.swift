// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-13, AC-13.01, AC-13.06, AC-13.07, AC-13.08; US-03, AC-03.11.
import AppKit
import SwiftUI
import LunletCore

/// Display-only text and measured geometry. These labels never route an action.
@MainActor struct TaskCueText {
    /// Wing text keeps this clearance from the notch: the entry window draws the lettering
    /// (`EntryMetrics.wing`) above the cue, and the text stays 12 points beyond it.
    static let notchClearance: CGFloat = 64
    static let edgePadding: CGFloat = 12
    static let wingPadding = notchClearance + edgePadding
    /// Each wing's text column: wide enough for every complete status, so short text still makes a clearly
    /// visible island, and capped so a long project name truncates instead of covering the menu bar.
    static let wingText: ClosedRange<CGFloat> = 96...180
    /// The row below the notch. Its line starts low enough to clear the entry's hanging vine or lanterns,
    /// which the entry window draws above the cue.
    static let previewRow: CGFloat = 30
    static let previewInset: CGFloat = 13
    /// Horizontal inset of the centered preview, clear of the rounded bottom corners.
    static let previewPadding: CGFloat = 20
    static let symbolWidth: CGFloat = 16
    static let symbolSpacing: CGFloat = 5
    /// Displays without a notch show the same rows in a pill below the menu bar.
    static let pillPadding: CGFloat = 16
    static let pillGap: CGFloat = 24
    static let pillHeight: CGFloat = 58
    /// System text sizes (headline and callout); nothing smaller than 12 points.
    static let statusFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let projectFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let previewFont = NSFont.systemFont(ofSize: 12)
    let cue: TaskCue
    /// The project.
    var title: String { cue.title }
    /// The bounded local prompt preview, or the task fallback when none exists.
    var context: String { cue.context ?? "Task " + String(cue.turnID.suffix(6)).uppercased() }
    var status: String {
        switch cue.phase {
        case .started: "Started"
        case .finished(.succeeded): "Completed"
        case .finished(.failed): "Failed"
        case .finished(.stopped): "Stopped"
        case .finished(.unknown): "Finished"
        }
    }
    var symbol: String {
        switch cue.phase {
        case .started: "play.circle.fill"
        case .finished(.succeeded): "checkmark.circle.fill"
        case .finished(.failed): "exclamationmark.triangle.fill"
        case .finished(.stopped): "stop.circle.fill"
        case .finished(.unknown): "flag.circle"
        }
    }
    /// Applied only to the symbol; the status word always accompanies it.
    var tint: Color {
        switch cue.phase {
        case .started: .blue
        case .finished(.succeeded): .green
        case .finished(.failed): .red
        case .finished(.stopped): .orange
        case .finished(.unknown): .gray
        }
    }
    /// One VoiceOver element: status, project, then preview.
    var accessibilityLabel: String { [status, title, context].joined(separator: ", ") }
    var statusWidth: CGFloat { Self.symbolWidth + Self.symbolSpacing + Self.width(status, font: Self.statusFont) }
    var projectWidth: CGFloat { Self.width(title, font: Self.projectFont) }
    var previewWidth: CGFloat { Self.width(context, font: Self.previewFont) }
    /// Symmetric wings sized from the wider of status and project.
    func notchWings() -> (left: CGFloat, right: CGFloat) {
        let text = min(Self.wingText.upperBound, max(Self.wingText.lowerBound, statusWidth, projectWidth))
        return (text + Self.wingPadding, text + Self.wingPadding)
    }
    /// The island continues the notch and extends below it; without a notch, the pill holds the same rows.
    func size(screen: PanelScreen) -> CGSize {
        if let notch = screen.notch {
            let wings = notchWings()
            return .init(width: min(screen.frame.width, notch.width + wings.left + wings.right),
                         height: notch.height + Self.previewRow)
        }
        let wing = notchWings().left - Self.wingPadding
        let rows = min(2 * Self.wingText.upperBound + Self.pillGap, max(2 * wing + Self.pillGap, previewWidth))
        return .init(width: min(screen.visibleFrame.width, rows + 2 * Self.pillPadding), height: Self.pillHeight)
    }
    /// Includes slack for rounding, so SwiftUI never truncates text measured to fit.
    private static func width(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}
