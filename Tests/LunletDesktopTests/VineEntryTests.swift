// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-16, AC-16.01, AC-16.02, AC-16.03; US-02, AC-02.03, AC-02.06; US-24, AC-24.02.
// Refs: US-03, AC-03.07, AC-03.08, AC-03.10; US-04, AC-04.03, AC-04.07, AC-04.10, AC-04.13; US-13, AC-13.07; US-12, AC-12.04.
// Refs: US-17, AC-17.05, AC-17.07.
import AppKit
import SwiftUI
import Testing
import LunletClaude
import LunletCore
@testable import LunletDesktop

@MainActor private func sublayer(_ name: String, in root: CALayer?) -> CALayer? {
    guard let root else { return nil }
    if root.name == name { return root }
    return root.sublayers?.lazy.compactMap { sublayer(name, in: $0) }.first
}

struct VineEntryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_RENDER_SUMMARY"] == "1"))
    @MainActor func renderAllowanceRulerForBothAppearances() throws {
        _ = NSApplication.shared
        for (name, scheme, background) in [("light", ColorScheme.light, Color.white), ("dark", .dark, Color(white: 0.13))] {
            let hosting = NSHostingView(rootView: AllowanceBar(remaining: 82)
                .padding(12).frame(width: 438).background(background).environment(\.colorScheme, scheme))
            hosting.frame = CGRect(x: 0, y: 0, width: 438, height: 32)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".tmp/ruler-\(name).png"))
        }
    }
    @Test func entryWrapsEachPhysicalNotchWithSymmetricTargetsAndFiniteWave() throws {
        for notch in [CGSize(width: 160, height: 26), CGSize(width: 185, height: 32), CGSize(width: 230, height: 40)] {
            let geometry = VineGeometry(notch: notch)
            #expect(geometry.size.width == notch.width + 104)
            #expect(geometry.size.height == notch.height + 17)
            let path = geometry.body()
            #expect(CGRect(origin: .zero, size: geometry.size).contains(path.boundingBoxOfPath))
            let points = geometry.points(on: path)
            #expect(points.count > 20)
            let center = geometry.location(at: 0.5, on: points)
            #expect(center.point.y > notch.height && center.point.y < notch.height + 7)
            let left = geometry.location(at: 0.2, on: points), right = geometry.location(at: 0.8, on: points)
            #expect(left.point.x < center.point.x && center.point.x < right.point.x)
        }
    }
    @Test func paletteWarmsContinuouslyWithoutThresholdJumpsOrFabricatedUnknownQuota() throws {
        #expect(AllowancePalette.colors(remaining: nil) == AllowancePalette.colors(remaining: .nan))
        let blue = AllowancePalette.colors(remaining: 72)[2]
        let gold = AllowancePalette.colors(remaining: 18)[2]
        let red = AllowancePalette.colors(remaining: 1)[2]
        #expect(blue.blue > blue.red && gold.red > gold.blue && red.red > red.green)
        for threshold in [10.0, 20.0] {
            let before = AllowancePalette.colors(remaining: threshold - 0.001)
            let after = AllowancePalette.colors(remaining: threshold + 0.001)
            for (a,b) in zip(before,after) {
                #expect(abs(a.red-b.red) < 0.001 && abs(a.green-b.green) < 0.001 && abs(a.blue-b.blue) < 0.001)
            }
        }
        // AC-04.10 design refinement: no minor 10% ticks; 20/40/60/80 and the 10% warning mark remain.
        #expect(WeeklyAllowanceMarkers.references == [20,40,60,80])
        #expect(WeeklyAllowanceMarkers.barMarks == [10,20,40,60,80])
    }
    @Test func chosenRGBTintIsSharedButLowAllowanceStillWarmsContinuously() {
        let customized = AllowancePalette.colors(remaining: 70, tintHex: "#20AA88")
        #expect(customized[1].green > customized[1].blue && customized[1].green > customized[1].red)
        #expect(AllowancePalette.colors(remaining: 5, tintHex: "#20AA88") == AllowancePalette.colors(remaining: 5))
        for threshold in [18.0, 20.0] {
            let before = AllowancePalette.colors(remaining: threshold - 0.001, tintHex: "#20AA88")
            let after = AllowancePalette.colors(remaining: threshold + 0.001, tintHex: "#20AA88")
            for (a, b) in zip(before, after) {
                #expect(abs(a.red - b.red) < 0.002 && abs(a.green - b.green) < 0.002 && abs(a.blue - b.blue) < 0.002)
            }
        }
    }

    // AC-02.03, AC-02.06: a waiting-count update changes only the badge and help text.
    @Test @MainActor func sessionStatusUpdatesNeverRebuildTheEntryArtwork() throws {
        let view = LettermarkView(frame: .init(x: 0, y: 0, width: 289, height: 49))
        let badge = try #require(view.layer?.sublayers?.first { $0.name == "session-status" } as? CATextLayer)
        #expect(badge.isHidden)
        view.setAllowance(72); view.setAccent("#4477CC"); view.layoutSubtreeIfNeeded()
        let words = try #require(view.layer?.sublayers?.first { $0.name == "lun" }?.sublayers)
        #expect(!view.needsLayout)
        let waiting = ObservedSession(sessionID: UUID(), connectionID: UUID(), liveness: .alive, phase: .approval)
        let snapshot = SessionSnapshot(observation: waiting, project: "Project", activityConfirmed: true)
        view.setSessionStatus(.init(snapshots: [snapshot], available: true, partial: false))
        #expect(!view.needsLayout && !badge.isHidden && badge.string as? String == "1")
        // The waiting badge uses the attention color and a legible size.
        #expect(badge.fontSize >= 10 && badge.frame.height >= 15 && badge.backgroundColor == NSColor.systemOrange.cgColor)
        #expect((view.toolTip ?? "").contains("1 waiting"))
        view.setAccent("#4477CC"); view.setAllowance(72)
        #expect(!view.needsLayout)
        #expect(view.layer?.sublayers?.first { $0.name == "lun" }?.sublayers?.elementsEqual(words, by: ===) == true)
    }

    @Test @MainActor func nativeWordsKeepIndependentPlacementAndStopTheirAnimations() throws {
        let view = LettermarkView(frame: .init(x: 0, y: 0, width: 289, height: 49))
        view.notchSize = .init(width: 185, height: 32)
        view.setAllowance(72); view.layoutSubtreeIfNeeded(); view.setActive(true)
        view.setPose(.working)
        let words = try #require(view.layer?.sublayers?.filter { $0.name == "lun" || $0.name == "let" })
        #expect(words.count == 2 && words[0].position.x < 52 && words[1].position.x > 237)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(words.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        } else { #expect(words.allSatisfy { !($0.animationKeys() ?? []).isEmpty }) }
        view.setActive(false)
        #expect(words.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    }

    // Light appearances get a deeper ink of the same hue; dark or undetermined ones keep the pastel baseline.
    @Test @MainActor func lightAppearanceDeepensTheLetteringWithoutChangingTheAllowancePalette() throws {
        #expect(LettermarkView.prefersDeepInk(NSAppearance(named: .aqua)))
        #expect(!LettermarkView.prefersDeepInk(NSAppearance(named: .darkAqua)))
        #expect(!LettermarkView.prefersDeepInk(nil))
        func luminance(_ color: AllowanceColor) -> Double { 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue }
        for tint in [nil, AllowanceColor(hex: 0x4477cc)] {
            let pastel = LettermarkView.vineInk(tint: tint, deep: false), deep = LettermarkView.vineInk(tint: tint, deep: true)
            #expect(zip(pastel, deep).allSatisfy { luminance($1) < luminance($0) })
        }
        #expect(LettermarkView.vineInk(tint: nil, deep: false) == LettermarkView.defaultVinePearl)
        // The vine fill and the expanded bar share one palette regardless of the lettering ink.
        #expect(AllowancePalette.colors(remaining: 62, tintHex: nil) == AllowancePalette.colors(remaining: 62))
    }

    // Refs: US-04, AC-04.13; US-03, AC-03.07.
    @Test func twistedStrandsShareFractionsMeetAtTheLetteringAndCrossBetweenMarks() {
        let geometry = VineGeometry(notch: .init(width: 185, height: 32))
        let rope = VineRope(centerline: geometry.points(on: geometry.path(VineArtwork.rope)))
        func gap(_ fraction: Double) -> CGFloat {
            let a = rope.point(0, at: fraction), b = rope.point(1, at: fraction)
            return hypot(a.x - b.x, a.y - b.y)
        }
        // Both strands leave each word as one vine, then are widest apart at every 10% mark.
        #expect(gap(0) < 0.01 && gap(0.03) < 0.01 && gap(1) < 0.01)
        for mark in [0.1, 0.2, 0.4, 0.6, 0.8, 0.9] { #expect(abs(gap(mark) - 2 * VineRope.amplitude) < 0.05) }
        // One crossing between neighboring marks, and strands alternate in front like a twisted rope.
        for crossing in stride(from: 0.15, through: 0.85, by: 0.1) { #expect(gap(crossing) < 0.05) }
        #expect(VineRope.isFront(0, segment: 1) == VineRope.isFront(1, segment: 0))
        #expect(VineRope.isFront(0, segment: 0) != VineRope.isFront(0, segment: 1))
        // The same fraction names the same place along the notch on both strands.
        for fraction in [0.2, 0.5, 0.8] { #expect(abs(rope.point(0, at: fraction).x - rope.point(1, at: fraction).x) < 0.5) }
        // The pair stays below the hardware notch and inside the entry.
        let bounds = CGRect(origin: .zero, size: geometry.size)
        for strand in rope.strands {
            #expect(strand.allSatisfy { bounds.contains($0) })
            let underNotch = strand.filter { $0.x > EntryMetrics.wing + 20 && $0.x < EntryMetrics.wing + 165 }
            #expect(underNotch.allSatisfy { $0.y - 0.9 > 32 })
        }
        // A partial path ends at its fraction; front and back halves together cover the whole strand once.
        let front = rope.path(0, front: true, through: 0.35), back = rope.path(0, front: false, through: 0.35)
        #expect(abs(max(front.boundingBoxOfPath.maxX, back.boundingBoxOfPath.maxX) - rope.point(0, at: 0.35).x) < 0.5)
        #expect(rope.path(1, front: true, through: 0).isEmpty && rope.path(1, front: false, through: 0).isEmpty)
    }

    // Refs: US-04, AC-04.13; US-16, AC-16.03; US-04, AC-04.10.
    @Test @MainActor func bothAgentsDrawTwoStrandsWithTheirOwnColorsAndFills() throws {
        let view = LettermarkView(frame: .init(x: 0, y: 0, width: 289, height: 49))
        view.setAccent("#4477CC")
        view.setAllowances([.init(provider: .claude, remaining: 35), .init(provider: .codex, remaining: 72)])
        view.layoutSubtreeIfNeeded()
        let rope = try #require(sublayer("rope", in: view.layer))
        #expect(!rope.isHidden && sublayer("vine-track", in: view.layer)?.isHidden == true)
        #expect(sublayer("vine-fill", in: view.layer)?.isHidden == true)
        func fill(_ strand: Int, _ side: String) throws -> CAGradientLayer {
            try #require(sublayer("strand-\(strand)-\(side)", in: rope)?.sublayers?.compactMap { $0 as? CAGradientLayer }.first)
        }
        // Codex is strand 0 whatever the selection order; Claude Code turns the same palette 50 degrees.
        for side in ["front", "back"] {
            let codex = try fill(0, side), claude = try fill(1, side)
            #expect(codex.colors as? [CGColor] == AllowancePalette.colors(remaining: 72, tintHex: "#4477CC").map(\.cgColor))
            #expect(claude.colors as? [CGColor] == AllowancePalette.colors(remaining: 35, tintHex: "#4477CC",
                                                                            hueShift: AgentPalette.hueShift(.claude)).map(\.cgColor))
            #expect(!codex.isHidden && !claude.isHidden)
        }
        // Each strand fills to its own value; nothing is averaged or summed.
        func reach(_ strand: Int) throws -> CGFloat {
            try ["front", "back"].map { try (fill(strand, $0).mask as? CAShapeLayer)?.path?.boundingBoxOfPath.maxX ?? 0 }.max() ?? 0
        }
        let geometry = VineGeometry(notch: view.notchSize)
        let rest = VineRope(centerline: geometry.points(on: geometry.path(VineArtwork.rope)))
        let codexReach = try reach(0), claudeReach = try reach(1)
        #expect(abs(codexReach - rest.point(0, at: 0.72).x) < 0.5 && abs(claudeReach - rest.point(1, at: 0.35).x) < 0.5)
        // One set of 20/40/60/80 marks across the pair plus the 10% warning mark.
        var marks = 0
        (sublayer("marks", in: view.layer) as? CAShapeLayer)?.path?.applyWithBlock { if $0.pointee.type == .moveToPoint { marks += 1 } }
        #expect(marks == WeeklyAllowanceMarkers.references.count)
        let warning = try #require(sublayer("warning-mark", in: view.layer) as? CAShapeLayer)
        #expect(!warning.isHidden && warning.strokeColor == LettermarkView.warningColor.cgColor)
        let value = view.accessibilityValue() as? String ?? ""
        #expect(value.contains("Claude Code 35% weekly allowance left") && value.contains("Codex 72% weekly allowance left"))
    }

    // Refs: US-04, AC-04.13; US-03, AC-03.07, AC-03.10.
    @Test @MainActor func twistedStrandsFlexWithTheWordsAndStopWithThem() throws {
        let view = LettermarkView(frame: .init(x: 0, y: 0, width: 289, height: 49))
        view.setAllowances([.init(provider: .codex, remaining: 72), .init(provider: .claude, remaining: 35)])
        view.layoutSubtreeIfNeeded(); view.setActive(true); view.setPose(.working)
        let rope = try #require(sublayer("rope", in: view.layer))
        let shapes = (rope.sublayers ?? []).flatMap { container in
            (container.sublayers ?? []).flatMap { [$0] + ([$0.mask].compactMap { $0 }) }.compactMap { $0 as? CAShapeLayer }
        }
        #expect(shapes.count == 12)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(shapes.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        } else { #expect(shapes.allSatisfy { $0.animation(forKey: "vine-flex") != nil }) }
        view.setActive(false)
        #expect(shapes.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    }

    // Refs: US-04, AC-04.13, AC-04.03; US-17, AC-17.07.
    @Test @MainActor func eachStrandKeepsItsOwnUnknownStateApartFromZero() throws {
        let view = LettermarkView(frame: .init(x: 0, y: 0, width: 289, height: 49))
        func strand(_ index: Int) throws -> (fill: CALayer, track: CAShapeLayer, glow: CAShapeLayer) {
            let layers = try #require(sublayer("strand-\(index)-front", in: view.layer)?.sublayers)
            let shapes = layers.compactMap { $0 as? CAShapeLayer }
            return (try #require(layers.first { $0 is CAGradientLayer }), shapes[1], shapes[0])
        }
        view.setAllowances([.init(provider: .codex, remaining: 64), .init(provider: .claude, remaining: nil)])
        view.layoutSubtreeIfNeeded()
        let known = try strand(0), unknown = try strand(1)
        #expect(!known.fill.isHidden && known.track.lineDashPattern == nil && !known.glow.isHidden)
        #expect(unknown.fill.isHidden && unknown.track.lineDashPattern != nil && unknown.glow.isHidden)
        #expect((view.accessibilityValue() as? String)?.contains("Claude Code weekly allowance unavailable") == true)
        // A confirmed zero is an empty solid strand, still distinguishable from the unknown one.
        view.setAllowances([.init(provider: .codex, remaining: 0), .init(provider: .claude, remaining: nil)])
        view.layoutSubtreeIfNeeded()
        let zero = try strand(0)
        #expect(zero.fill.isHidden && zero.track.lineDashPattern == nil && !zero.glow.isHidden)
        #expect((view.accessibilityValue() as? String)?.contains("Codex 0% weekly allowance left") == true)
    }

    // Refs: US-04, AC-04.13, AC-04.10; US-16, AC-16.03.
    @Test @MainActor func oneSelectedAgentKeepsTheSingleVineInThatAgentsColor() throws {
        let view = LettermarkView(frame: .init(x: 0, y: 0, width: 289, height: 49))
        view.setAllowance(72); view.layoutSubtreeIfNeeded()
        let rope = try #require(sublayer("rope", in: view.layer))
        let fill = try #require(sublayer("vine-fill", in: view.layer) as? CAGradientLayer)
        let track = try #require(sublayer("vine-track", in: view.layer) as? CAShapeLayer)
        #expect(rope.isHidden && !fill.isHidden && !track.isHidden)
        // The single vine carries the same 10% warning as every meter (AC-04.10).
        let warning = try #require(sublayer("warning-mark", in: view.layer) as? CAShapeLayer)
        #expect(!warning.isHidden && warning.path?.isEmpty == false)
        #expect(fill.colors as? [CGColor] == AllowancePalette.colors(remaining: 72).map(\.cgColor))
        // Claude Code alone keeps the single vine, filled to its value in its own turned palette.
        view.setAllowances([.init(provider: .claude, remaining: 35)]); view.layoutSubtreeIfNeeded()
        #expect(rope.isHidden && !fill.isHidden)
        #expect(fill.colors as? [CGColor] == AllowancePalette.colors(remaining: 35, hueShift: AgentPalette.hueShift(.claude)).map(\.cgColor))
        #expect(track.strokeColor == AllowancePalette.trackColor(tintHex: nil, hueShift: AgentPalette.hueShift(.claude)).cgColor.copy(alpha: 0.2))
        #expect(abs(((fill.mask as? CAShapeLayer)?.strokeEnd ?? 0) - 0.35) < 0.001)
        #expect((view.accessibilityValue() as? String)?.contains("Claude Code 35% weekly allowance left") == true)
    }

    // Refs: US-04, AC-04.13; US-17, AC-17.05; US-16, AC-16.03: two agents hang two crossing cords of five
    // smaller lanterns each, Codex's in the skin's glass and Claude Code's in its sibling color, each lit by its own
    // allowance whatever the selection order; one agent keeps the single cord.
    @Test @MainActor func lanternsHangTwoCrossingCordsForTwoAgents() throws {
        let view = LettermarkView(frame: .init(x: 0, y: 0, width: 289, height: 49))
        view.setSkin(SkinCatalog.builtins[1])
        func lamps(_ prefix: String) throws -> [CALayer] {
            try (0..<5).map { try #require(sublayer("\(prefix)-\($0)", in: view.layer)) }
        }
        func opacities(_ prefix: String) throws -> [Float] {
            try lamps(prefix).map { try #require($0.sublayers?.first { $0 is CAGradientLayer }).opacity }
        }
        func glass(_ prefix: String) throws -> CGColor? {
            (try #require(lamps(prefix).first?.sublayers?.first { $0 is CAGradientLayer }) as? CAGradientLayer)?.colors?.first as! CGColor?
        }
        for order in [[AgentAllowance(provider: .claude, remaining: 30), .init(provider: .codex, remaining: 90)],
                      [AgentAllowance(provider: .codex, remaining: 90), .init(provider: .claude, remaining: 30)]] {
            view.setAllowances(order)
            view.layoutSubtreeIfNeeded()
            #expect(sublayer("rope", in: view.layer)?.isHidden == true)
            let scene = try #require(view.layer?.sublayers?.first { $0.name == "lanterns" })
            #expect(scene.sublayers?.filter { $0.name?.hasPrefix("lamp-") == true }.count == 10)
            #expect(sublayer("cord-codex", in: scene) != nil && sublayer("cord-claude", in: scene) != nil)
            // Codex's 90% lights four and a half of its lamps; Claude Code's 30% one and a half of its own.
            let codex = try opacities("lamp-codex"), claude = try opacities("lamp-claude")
            #expect(abs(codex[3] - 1) < 0.001 && abs(codex[4] - 0.56) < 0.001)
            #expect(abs(claude[0] - 1) < 0.001 && abs(claude[1] - 0.56) < 0.001 && abs(claude[3] - 0.12) < 0.001)
            #expect(try glass("lamp-codex") != glass("lamp-claude"))
            // The lamps interleave along the width, Codex's first, and each pair's lamps are smaller than a single cord's.
            let xs = try (lamps("lamp-codex") + lamps("lamp-claude")).map(\.position.x)
            #expect(xs[0] < xs[5])
            #expect(xs[5] < xs[1])
            #expect(xs[4] < xs[9])
            #expect(try lamps("lamp-codex").allSatisfy { $0.transform.m11 < 1 })
        }
        view.setAllowances([.init(provider: .claude, remaining: 30)])
        view.layoutSubtreeIfNeeded()
        let scene = try #require(view.layer?.sublayers?.first { $0.name == "lanterns" })
        let lampCount = scene.sublayers?.filter { $0.name?.hasPrefix("lamp-") == true }.count
        #expect(lampCount == 5)
        #expect(sublayer("cord-claude", in: scene) == nil && sublayer("lamp-0", in: scene)?.transform.m11 == 1)
        let single = try (0..<5).map { try #require(sublayer("lamp-\($0)", in: view.layer)) }
            .map { try #require($0.sublayers?.first { $0 is CAGradientLayer }).opacity }
        let firstLamp = single[0], secondLamp = single[1]
        #expect(abs(firstLamp - 1) < 0.001)
        #expect(abs(secondLamp - 0.56) < 0.001)
    }

    // Refs: US-04, AC-04.13, AC-04.03; US-33, AC-33.09.
    @Test @MainActor func entryAllowancesFollowSelectionAndUseOnlyAConnectedUnexpiredClaudeWeek() {
        let now = Date(timeIntervalSince1970: 1_793_390_400)
        func limits(used: Double, resetIn: TimeInterval) -> ClaudePlanLimits {
            .init(fiveHour: .init(usedPercent: 90, resetsAt: now.addingTimeInterval(600), at: now),
                  sevenDay: .init(usedPercent: used, resetsAt: now.addingTimeInterval(resetIn), at: now), weekly: [])
        }
        let week = limits(used: 30, resetIn: 86_400)
        #expect(NotchEntryController.allowances(providers: [.codex, .claude], codex: 72, claude: week, claudeConnected: true, now: now)
                == [.init(provider: .codex, remaining: 72), .init(provider: .claude, remaining: 70)])
        // Selection order is kept; the Claude value never depends on Codex's, and the five-hour window is not used.
        #expect(NotchEntryController.allowances(providers: [.claude, .codex], codex: nil, claude: week, claudeConnected: true, now: now)
                == [.init(provider: .claude, remaining: 70), .init(provider: .codex, remaining: nil)])
        #expect(NotchEntryController.allowances(providers: [.claude], codex: 72, claude: week, claudeConnected: true, now: now)
                == [.init(provider: .claude, remaining: 70)])
        // Not connected, no reading, or a passed weekly reset is unknown, never zero or a stale value.
        for (claude, connected) in [(week, false), (nil, true), (limits(used: 30, resetIn: -60), true)] {
            #expect(NotchEntryController.allowances(providers: [.codex, .claude], codex: 72, claude: claude,
                                                    claudeConnected: connected, now: now)[1] == .init(provider: .claude, remaining: nil))
        }
        #expect(NotchEntryController.allowances(providers: [], codex: 5, claude: nil, claudeConnected: false, now: now)
                == [.init(provider: .codex, remaining: 5)])
    }

    // Synthetic renders for visual review; not physical-screen evidence.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_RENDER_SUMMARY"] == "1"))
    @MainActor func renderTwistedEntryOnLightAndDarkMenuBars() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNLET_RENDER_DIRECTORY"]
                            ?? FileManager.default.currentDirectoryPath + "/.tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notch = CGSize(width: 185, height: 32), size = VineGeometry(notch: notch).size, scale: CGFloat = 4
        let cases: [(String, [AgentAllowance])] = [
            ("both", [.init(provider: .codex, remaining: 72), .init(provider: .claude, remaining: 35)]),
            ("both-low", [.init(provider: .codex, remaining: 15), .init(provider: .claude, remaining: 8)]),
            ("one-unknown", [.init(provider: .codex, remaining: 64), .init(provider: .claude, remaining: nil)]),
            ("zero-and-unknown", [.init(provider: .codex, remaining: 0), .init(provider: .claude, remaining: nil)]),
            ("single-codex", [.init(provider: .codex, remaining: 72)]),
            ("single-claude", [.init(provider: .claude, remaining: 35)]),
        ]
        for (appearance, name, background) in [("light", NSAppearance.Name.aqua, 0xe9e9ee), ("dark", .darkAqua, 0x1d1d22)] {
            for (label, allowances) in cases {
                let view = LettermarkView(frame: .init(origin: .zero, size: size))
                view.appearance = NSAppearance(named: name); view.notchSize = notch
                view.setAllowances(allowances); view.layoutSubtreeIfNeeded()
                let layer = try #require(view.layer)
                let context = try #require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.scaleBy(x: scale, y: scale)
                context.setFillColor(AllowanceColor(hex: background).cgColor); context.fill(CGRect(origin: .zero, size: size))
                context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.addPath(CGPath(roundedRect: .init(x: EntryMetrics.wing, y: -10, width: notch.width, height: notch.height + 10),
                                       cornerWidth: 8, cornerHeight: 8, transform: nil))
                context.fillPath()
                layer.render(in: context)
                let image = try #require(context.makeImage())
                let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("entry-\(label)-\(appearance).png"))
            }
        }
    }
}
