// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-03, AC-03.05, AC-03.07, AC-03.09, AC-03.10, AC-03.11; US-13, AC-13.01, AC-13.06, AC-13.07, AC-13.08.
// Refs: US-19, AC-19.05; US-24, AC-24.03; US-39, AC-39.05.
import AppKit

struct PanelScreen {
    let frame: CGRect
    let visibleFrame: CGRect
    let safeTop: CGFloat
    let notch: CGRect?
    init(frame: CGRect, visibleFrame: CGRect, safeTop: CGFloat, notch: CGRect? = nil) {
        self.frame = frame; self.visibleFrame = visibleFrame; self.safeTop = safeTop; self.notch = notch
    }
    init(_ screen: NSScreen) {
        let notch: CGRect?
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
            notch = CGRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                           width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        } else { notch = nil }
        self.init(frame: screen.frame, visibleFrame: screen.visibleFrame,
                  safeTop: screen.safeAreaInsets.top, notch: notch)
    }
    @MainActor static var current: PanelScreen? { (NSScreen.main ?? NSScreen.screens.first).map(Self.init) }
    @MainActor static var notchDisplay: NSScreen? { NSScreen.screens.first { PanelScreen($0).notch != nil } }
}

/// The menu-bar band beside the notch that holds the panel header: its height and the panel body's width on
/// each side of the notch. The lettering the entry window draws above the panel keeps its clearance.
struct NotchBand: Equatable {
    let height: CGFloat
    let leading: CGFloat
    let trailing: CGFloat
    /// Reserved beside the notch for the lun / let lettering, which spans the entry window's wing.
    static let letteringClearance = EntryMetrics.wing
    /// Room for the header on each side between the body margin and the lettering.
    var leadingWidth: CGFloat { max(0, leading - Self.letteringClearance - PanelStyle.Space.margin) }
    var trailingWidth: CGFloat { max(0, trailing - Self.letteringClearance - PanelStyle.Space.margin) }
}

enum PanelPlacement {
    /// The panel body's width; its height follows the layout budget (`PanelStyle.Layout.panelHeight`).
    static let panelWidth: CGFloat = 470
    static func frame(size: CGSize, screen: PanelScreen) -> CGRect {
        let visible = screen.visibleFrame
        let top = screen.notch != nil ? screen.frame.maxY : (screen.safeTop > 0 ? screen.frame.maxY - screen.safeTop : visible.maxY)
        let width = min(max(0, size.width), visible.width)
        let height = min(max(0, size.height), max(0, top - visible.minY))
        let x = max(visible.minX, min((screen.notch?.midX ?? screen.frame.midX) - width / 2, visible.maxX - width))
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
    /// The companion window: the body flush with the top edge below a notch, widened by the shoulders that meet
    /// the menu bar on each side; elsewhere the body alone below the menu bar.
    static func panel(tabRow: Bool, screen: PanelScreen) -> CGRect {
        let height = PanelStyle.Layout.panelHeight(notchHeight: screen.notch?.height, tabRow: tabRow)
        let body = frame(size: .init(width: panelWidth, height: height), screen: screen)
        return body.insetBy(dx: -NotchSurfaceGeometry.bodyInset(notchWidth: screen.notch?.width), dy: 0)
    }
    /// The companion window as the dog's bubble: the body plus its tail above the anchor (the dog's head) when it
    /// fits, else below it, centered on the anchor and kept inside the visible area, without notch shoulders
    /// (AC-39.05). `tail(panel:anchor:)` says which edge the tail is on and where its tip points.
    static func panel(near anchor: CGRect, tabRow: Bool, screen: PanelScreen) -> CGRect {
        let visible = screen.visibleFrame
        let height = min(PanelStyle.Layout.panelHeight(notchHeight: nil, tabRow: tabRow) + BubbleTail.height, visible.height)
        let width = min(panelWidth, visible.width)
        var y = anchor.maxY + bubbleGap
        if y + height > visible.maxY { y = anchor.minY - bubbleGap - height }
        y = min(max(y, visible.minY), visible.maxY - height)
        let x = min(max(anchor.midX - width / 2, visible.minX), visible.maxX - width)
        return CGRect(x: x, y: y, width: width, height: height)
    }
    /// Room between the tail's tip and the dog's head.
    static let bubbleGap: CGFloat = 4
    /// The tail of a bubble panel at `panel`, pointing at the anchor it was placed beside.
    static func tail(panel: CGRect, anchor: CGRect) -> BubbleTail {
        BubbleTail(edge: panel.midY >= anchor.midY ? .bottom : .top, x: anchor.midX - panel.minX)
    }
    /// The header band beside the notch inside a companion window frame, or nil without a notch.
    static func band(panel: CGRect, screen: PanelScreen) -> NotchBand? {
        guard let notch = screen.notch else { return nil }
        let body = panel.insetBy(dx: NotchSurfaceGeometry.bodyInset(notchWidth: notch.width), dy: 0)
        return NotchBand(height: notch.height, leading: max(0, notch.minX - body.minX), trailing: max(0, body.maxX - notch.maxX))
    }
    static func entry(screen: PanelScreen) -> CGRect? {
        let wing = EntryMetrics.wing
        guard let notch = screen.notch, notch.width > 0, notch.height > 0,
              notch.minX - screen.frame.minX >= wing, screen.frame.maxX - notch.maxX >= wing else { return nil }
        return CGRect(origin: .init(x: notch.minX - wing, y: notch.minY - EntryMetrics.drop),
                      size: VineGeometry(notch: notch.size).size)
    }
    /// A notch cue is centered on the notch and flush with the top edge; otherwise it sits below the menu bar.
    static func cue(size: CGSize, screen: PanelScreen) -> CGRect {
        guard let notch = screen.notch else { return frame(size: size, screen: screen) }
        let width = min(size.width, screen.frame.width)
        let height = max(size.height, notch.height + 6)
        return CGRect(x: max(screen.frame.minX, min(notch.midX - width / 2, screen.frame.maxX - width)),
                      y: screen.frame.maxY - height, width: width, height: height)
    }
}
