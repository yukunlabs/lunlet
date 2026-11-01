// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.08; US-03, AC-03.08, AC-03.10; US-12, AC-12.04.
// Refs: US-24, AC-24.01, AC-24.02.
import AppKit
import SwiftUI
import Testing
@testable import LunletDesktop

struct UsageHoverPlacementTests {
    @Test func prefersTheLeftOfTheOverviewAndClampsToUsableDisplayBounds() {
        let frame = UsageHoverPlacement.frame(size: .init(width: 320, height: 270),
            parent: .init(x: 565, y: 500, width: 470, height: 340),
            visible: .init(x: 0, y: 80, width: 1600, height: 720))
        #expect(frame == CGRect(x: 237, y: 500, width: 320, height: 270))
    }

    @Test func fallsBackToTheRightAndHandlesOffsetOrSmallDisplays() {
        let right = UsageHoverPlacement.frame(size: .init(width: 320, height: 270),
            parent: .init(x: -1000, y: 500, width: 470, height: 340),
            visible: .init(x: -1100, y: 40, width: 1100, height: 760))
        #expect(right == CGRect(x: -522, y: 500, width: 320, height: 270))
        let small = UsageHoverPlacement.frame(size: .init(width: 320, height: 270),
            parent: .init(x: 2000, y: -400, width: 200, height: 200),
            visible: .init(x: 1900, y: -200, width: 250, height: 180))
        #expect(small == CGRect(x: 1900, y: -200, width: 250, height: 180))
        let high = UsageHoverPlacement.frame(size: .init(width: 320, height: 270),
            parent: .init(x: 565, y: 750, width: 470, height: 340),
            visible: .init(x: 0, y: 80, width: 1600, height: 720))
        #expect(high.maxY == 800)
        let notch = UsageHoverPlacement.frame(size: .init(width: 320, height: 395),
            parent: .init(x: 520, y: 592, width: 470, height: 390),
            visible: .init(x: 0, y: 90, width: 1512, height: 859))
        #expect(notch.minY == 592 && notch.maxY == 949 && notch.height == 357)
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_PANEL"] == "1"))
@MainActor struct UsageHoverPanelTests {
    private func fixture() -> (UsageHoverPanelController, NSPanel, NSView) {
        _ = NSApplication.shared
        let parent = NSPanel(contentRect: .init(x: 600, y: 400, width: 470, height: 340),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let anchor = NSView(frame: .init(x: 24, y: 220, width: 420, height: 80))
        parent.contentView?.addSubview(anchor)
        parent.orderFrontRegardless()
        let controller = UsageHoverPanelController(observesSystemEvents: false)
        controller.setContent { AnyView(Text("Synthetic usage chart")) }
        return (controller, parent, anchor)
    }

    @Test func hoverOpensANonKeyWindowWithoutNavigationAndCrossingsRetainIt() async throws {
        let (controller, parent, anchor) = fixture()
        defer { controller.shutdown(); parent.close() }
        var visibility: [Bool] = []
        controller.visibilityChanged = { visibility.append($0) }
        controller.anchorHoverChanged(true, anchor: anchor)
        #expect(!controller.isVisible)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.isVisible && controller.window?.isKeyWindow == false)
        let popup = try #require(controller.window)
        #expect(popup.frame.maxX < parent.frame.minX)
        controller.popupHoverChanged(true)
        controller.anchorHoverChanged(false, anchor: anchor)
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.isVisible)
        controller.anchorHoverChanged(true, anchor: anchor)
        controller.popupHoverChanged(false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.isVisible)
        controller.anchorHoverChanged(false, anchor: anchor)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.isVisible)
        controller.popupHoverChanged(true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.isVisible)
        controller.popupHoverChanged(false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!controller.isVisible && visibility == [true, false])
    }

    @Test func keyboardChartCanOpenWithoutHoverAndEscapeReturnsToTheParent() async throws {
        let (controller, parent, anchor) = fixture()
        defer { controller.shutdown(); parent.close() }
        controller.anchorAttached(anchor)
        var interactions = 0, parentDismissals = 0
        controller.interactionOccurred = { interactions += 1 }
        controller.dismissalRequested = { parentDismissals += 1 }
        controller.showForKeyboard()
        #expect(controller.isVisible && interactions == 1)
        controller.popupHoverChanged(false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.isVisible)
        controller.window?.cancelOperation(nil)
        #expect(!controller.isVisible && parent.isVisible && parentDismissals == 0)
        controller.showForKeyboard()
        #expect(controller.isVisible)
        controller.anchorRemoved(anchor)
        controller.showForKeyboard()
        #expect(!controller.isVisible)
    }

    @Test func parentCloseCancelsPendingOpenAndLatePopupEventsCannotResurrectIt() async throws {
        let (controller, parent, anchor) = fixture()
        defer { controller.shutdown(); parent.close() }
        controller.anchorHoverChanged(true, anchor: anchor)
        controller.hide(); controller.hide()
        controller.popupHoverChanged(true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!controller.isVisible)
        controller.anchorHoverChanged(false, anchor: anchor)
        controller.anchorHoverChanged(true, anchor: anchor)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.isVisible)
        controller.hide()
        controller.popupHoverChanged(true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(!controller.isVisible)
    }

    @Test func freshParentPresentationRearmsHoverWithoutAHiddenWindowExitEvent() async throws {
        let (controller, parent, anchor) = fixture()
        defer { controller.shutdown(); parent.close() }
        controller.anchorHoverChanged(true, anchor: anchor)
        controller.hide()
        controller.anchorHoverChanged(true, anchor: anchor)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!controller.isVisible)
        controller.prepareForParentPresentation()
        controller.anchorHoverChanged(true, anchor: anchor)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.isVisible)
    }

    @Test func interactionPinsTheParentAndEscapeRequestsItsDismissal() async throws {
        let (controller, parent, anchor) = fixture()
        defer { controller.shutdown(); parent.close() }
        var interactions = 0, dismissals = 0
        controller.interactionOccurred = { interactions += 1 }
        controller.dismissalRequested = { dismissals += 1; controller.hide() }
        controller.anchorHoverChanged(true, anchor: anchor)
        try await Task.sleep(for: .milliseconds(300))
        controller.handleInteraction(.scrollWheel, in: parent)
        #expect(interactions == 0)
        controller.handleInteraction(.leftMouseDown, in: controller.window)
        #expect(interactions == 1)
        controller.window?.cancelOperation(nil)
        #expect(dismissals == 1 && !controller.isVisible)
    }

    @Test func shutdownCancelsPendingOpenAndReleasesTheOwnedWindow() async throws {
        let (controller, parent, anchor) = fixture()
        defer { parent.close() }
        controller.anchorHoverChanged(true, anchor: anchor)
        controller.shutdown(); controller.shutdown()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!controller.isVisible && controller.window == nil)
        controller.anchorHoverChanged(true, anchor: anchor)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.window == nil)
    }

    @Test func leavingBeforeTheOpenDelayOrRemovingTheAnchorCancelsPresentation() async throws {
        let (controller, parent, anchor) = fixture()
        defer { controller.shutdown(); parent.close() }
        controller.anchorHoverChanged(true, anchor: anchor)
        controller.anchorHoverChanged(false, anchor: anchor)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!controller.isVisible)
        controller.anchorHoverChanged(true, anchor: anchor)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.isVisible)
        controller.anchorRemoved(anchor)
        #expect(!controller.isVisible)
        controller.popupHoverChanged(true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(!controller.isVisible)
    }

    @Test func shutdownRemovesTheVisibleNativeWindowAndHiddenParentCannotReopenIt() async throws {
        let (controller, parent, anchor) = fixture()
        defer { controller.shutdown(); parent.close() }
        controller.anchorHoverChanged(true, anchor: anchor)
        try await Task.sleep(for: .milliseconds(300))
        let popup = try #require(controller.window)
        parent.orderOut(nil)
        controller.reposition()
        #expect(!popup.isVisible)
        controller.anchorHoverChanged(false, anchor: anchor)
        controller.anchorHoverChanged(true, anchor: anchor)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!controller.isVisible)
        parent.orderFrontRegardless()
        controller.anchorHoverChanged(true, anchor: anchor)
        try await Task.sleep(for: .milliseconds(300))
        #expect(popup.isVisible)
        controller.shutdown()
        #expect(controller.window == nil && !popup.isVisible && popup.contentView == nil)
    }
}
