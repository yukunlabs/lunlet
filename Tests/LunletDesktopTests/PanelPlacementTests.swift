// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-03, AC-03.05, AC-03.07, AC-03.09, AC-03.11; US-13, AC-13.01, AC-13.06, AC-13.08.
// Refs: US-19, AC-19.05; US-24, AC-24.03.
import Foundation
import Testing
@testable import LunletDesktop

struct PanelPlacementTests {
    @Test func entryPlacementArtworkAndSkinBoundsShareOneGeometry() throws {
        #expect(EntryMetrics.wing == 52 && EntryMetrics.artworkSize == CGSize(width: 273, height: 44))
        for notch in [CGRect(x: 600, y: 950, width: 185, height: 32), CGRect(x: 1900, y: -40, width: 230, height: 40)] {
            let screen = PanelScreen(frame: .init(x: notch.midX - 700, y: notch.maxY - 982, width: 1400, height: 982),
                                     visibleFrame: .zero, safeTop: notch.height, notch: notch)
            let entry = try #require(PanelPlacement.entry(screen: screen))
            #expect(entry.size == VineGeometry(notch: notch.size).size)
            #expect(entry.minX == notch.minX - EntryMetrics.wing && entry.maxY == notch.maxY)
        }
        #expect(NotchSurfaceView.retractionDelay > .milliseconds(Int(NotchSurfaceView.collapseDuration * 1000)))
    }
    @Test func cueIslandCentersOnThePhysicalNotchAndStaysOnItsScreen() {
        let screen = PanelScreen(frame: .init(x: 0, y: 0, width: 1512, height: 982),
                                 visibleFrame: .init(x: 0, y: 0, width: 1512, height: 950), safeTop: 32,
                                 notch: .init(x: 663.5, y: 950, width: 185, height: 32))
        let cue = PanelPlacement.cue(size: .init(width: 529, height: 62), screen: screen)
        #expect(cue == CGRect(x: 491.5, y: 920, width: 529, height: 62))
        #expect(cue.contains(screen.notch!) && cue.minY == screen.notch!.minY - 30)
        let wide = PanelPlacement.cue(size: .init(width: 1600, height: 62), screen: screen)
        #expect(wide.width == screen.frame.width && screen.frame.contains(wide))
    }
    @Test func aNotchPanelUsesThePhysicalScreenCenterDespiteASideDockOrStageManager() {
        let screen = PanelScreen(frame: .init(x: 0, y: 0, width: 1512, height: 982),
                                 visibleFrame: .init(x: 120, y: 90, width: 1392, height: 859), safeTop: 32)
        let panel = PanelPlacement.frame(size: .init(width: 360, height: 560), screen: screen)
        #expect(panel.midX == 756)
        #expect(panel.maxY == 950)
        #expect(screen.frame.contains(panel))
    }
    @Test func anExternalDisplayKeepsItsNonzeroOriginAndFallsBelowTheMenuBar() {
        let screen = PanelScreen(frame: .init(x: -180, y: 982, width: 1920, height: 1080),
                                 visibleFrame: .init(x: -180, y: 982, width: 1920, height: 1056), safeTop: 0)
        let panel = PanelPlacement.frame(size: .init(width: 360, height: 560), screen: screen)
        #expect(panel.midX == 780 && panel.maxY == 2038)
        #expect(screen.visibleFrame.contains(panel))
    }
    @Test func aSmallDisplayKeepsAllControlsWithinItsAvailableArea() {
        let screen = PanelScreen(frame: .init(x: 800, y: -300, width: 320, height: 300),
                                 visibleFrame: .init(x: 800, y: -280, width: 320, height: 256), safeTop: 0)
        let panel = PanelPlacement.frame(size: .init(width: 360, height: 560), screen: screen)
        #expect(panel == screen.visibleFrame)
    }
    @Test func splitLetteringAndVineWrapTheRealNotchOnAnOffsetDisplay() throws {
        let screen = PanelScreen(frame: .init(x: -1512, y: 982, width: 1512, height: 982),
                                 visibleFrame: .init(x: -1512, y: 1000, width: 1512, height: 932), safeTop: 32,
                                 notch: .init(x: -856, y: 1932, width: 200, height: 32))
        let entry = try #require(PanelPlacement.entry(screen: screen))
        #expect(entry.midX == screen.notch!.midX && entry.maxY == screen.frame.maxY)
        #expect(entry.width == screen.notch!.width + 104 && entry.height == screen.notch!.height + 17)
        #expect(screen.frame.contains(entry))
        let cue = PanelPlacement.cue(size: .init(width: 250, height: 30), screen: screen)
        #expect(cue.midX == screen.notch!.midX && cue.maxY == screen.frame.maxY)
        #expect(screen.frame.contains(cue))
    }
    @Test func overviewAndCueEncloseThePhysicalNotchInsteadOfStartingBelowIt() {
        let screen = PanelScreen(frame: .init(x: 0, y: 0, width: 1512, height: 982),
                                 visibleFrame: .init(x: 0, y: 0, width: 1512, height: 950), safeTop: 32,
                                 notch: .init(x: 663.5, y: 950, width: 185, height: 32))
        let overview = PanelPlacement.panel(tabRow: false, screen: screen)
        #expect(overview.maxY == 982 && overview.midX == screen.notch!.midX)
        #expect(overview.contains(screen.notch!))
        let cue = PanelPlacement.cue(size: .init(width: 565, height: 40), screen: screen)
        #expect(cue.maxY == 982 && cue.midX == screen.notch!.midX)
        #expect(cue.contains(screen.notch!))
    }


    @Test func noHardwareNotchDoesNotInventAnEntryOrPlaceCuesInTheMenuBar() {
        let screen = PanelScreen(frame: .init(x: 0, y: 0, width: 1920, height: 1080),
                                 visibleFrame: .init(x: 0, y: 24, width: 1920, height: 1032), safeTop: 0)
        #expect(PanelPlacement.entry(screen: screen) == nil)
        #expect(PanelPlacement.cue(size: .init(width: 250, height: 40), screen: screen).maxY == 1056)
    }

    // Design direction: the header moves into the notch band, reclaiming the header row; several agents add
    // a tab row below the band; every display keeps the same page budget, so exactly three whole rows show.
    @Test func panelHeightKeepsThePageBudgetWithTheHeaderInTheNotchBand() {
        let layout = PanelStyle.Layout.self
        #expect(layout.panelHeight(notchHeight: 32, tabRow: false) == 397)
        #expect(layout.panelHeight(notchHeight: 32, tabRow: true) == 425)
        #expect(layout.panelHeight(notchHeight: nil, tabRow: false) == 393 && layout.panelHeight(notchHeight: nil, tabRow: true) == 393)
        for notch in [CGFloat(26), 32, 40] {
            let height = layout.panelHeight(notchHeight: notch, tabRow: false)
            #expect(height - notch - layout.headerGap - layout.footerHeight == layout.pageHeight)
        }
        #expect(layout.pageHeight >= 3 * layout.rowHeight + 2 * layout.listVerticalInset)
    }
    // The window adds the shoulders on both sides of a 470 pt body hanging from the top edge; the band beside the
    // notch keeps the lettering's clearance on each side and fits Refresh and Settings at full size.
    @Test func notchPanelWidensForItsShouldersAndKeepsTheLetteringClear() throws {
        for width in [CGFloat(160), 185, 230] {
            let notch = CGRect(x: 756 - width / 2, y: 950, width: width, height: 32)
            let screen = PanelScreen(frame: .init(x: 0, y: 0, width: 1512, height: 982),
                                     visibleFrame: .init(x: 0, y: 0, width: 1512, height: 950), safeTop: 32, notch: notch)
            let frame = PanelPlacement.panel(tabRow: true, screen: screen)
            #expect(frame.width == PanelPlacement.panelWidth + 2 * NotchSurfaceGeometry.shoulderRadius)
            #expect(frame.midX == notch.midX && frame.maxY == screen.frame.maxY && frame.height == 425)
            let band = try #require(PanelPlacement.band(panel: frame, screen: screen))
            let body = frame.insetBy(dx: NotchSurfaceGeometry.shoulderRadius, dy: 0)
            #expect(band.height == 32 && band.leading == notch.minX - body.minX && band.trailing == body.maxX - notch.maxX)
            // The header ends before the lettering, which spans the entry wing beside the notch.
            #expect(body.minX + PanelStyle.Space.margin + band.leadingWidth <= notch.minX - EntryMetrics.wing)
            #expect(body.maxX - PanelStyle.Space.margin - band.trailingWidth >= notch.maxX + EntryMetrics.wing)
            #expect(band.trailingWidth >= 2 * PanelStyle.Layout.iconButton)
        }
        let plain = PanelScreen(frame: .init(x: 0, y: 0, width: 1920, height: 1080),
                                visibleFrame: .init(x: 0, y: 0, width: 1920, height: 1056), safeTop: 0)
        let simple = PanelPlacement.panel(tabRow: true, screen: plain)
        #expect(simple.width == PanelPlacement.panelWidth && simple.maxY == 1056 && simple.height == 393)
        #expect(PanelPlacement.band(panel: simple, screen: plain) == nil)
    }
}
