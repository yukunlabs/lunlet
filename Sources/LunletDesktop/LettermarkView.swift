// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-17, AC-17.01, AC-17.03, AC-17.04, AC-17.05, AC-17.06, AC-17.07, AC-17.08.
// Refs: US-02, AC-02.03, AC-02.05; US-16, AC-16.02, AC-16.03; US-24, AC-24.02.
// Refs: US-03, AC-03.07, AC-03.08, AC-03.10; US-04, AC-04.03, AC-04.07, AC-04.10, AC-04.13; US-13, AC-13.07; US-12, AC-12.04.
import AppKit
import LunletCore
import QuartzCore

/// One selected agent's weekly remaining allowance for the entry. Nil is unknown, never zero (AC-17.07).
struct AgentAllowance: Equatable {
    let provider: SessionProvider
    let remaining: Double?
    init(provider: SessionProvider, remaining: Double?) {
        self.provider = provider; self.remaining = AllowancePalette.normalized(remaining)
    }
}

/// One transparent native entry: fixed letter placement, independent motion, and a measured vine.
@MainActor final class LettermarkView: HoverTrackingView {
    enum Pose { case resting, awake, working, finished }
    override var isFlipped: Bool { true }
    var clicked: (() -> Void)?
    var notchSize = EntryMetrics.referenceNotch { didSet { needsLayout = true } }
    private let left = CALayer(), right = CALayer(), body = CALayer()
    private let lanterns = LanternScene()
    private var skin = SkinCatalog.builtins[0]
    private let track = CAShapeLayer(), vineHighlight = CAShapeLayer(), rearTrack = CAShapeLayer(), ticks = CAShapeLayer()
    private let fill = CAGradientLayer(), rearFill = CAGradientLayer()
    private let fillMask = CAShapeLayer(), rearMask = CAShapeLayer()
    private var pose = Pose.resting, active = false, detailsVisible = false
    /// Selected agents in their saved order. The first leads a single vine and the lanterns; with the vine skin,
    /// two agents twist into a pair of strands, each with its own value and unknown state (AC-04.13).
    private var allowances = [AgentAllowance(provider: .codex, remaining: nil)]
    private var remaining: Double? { allowances.first?.remaining }
    private var leadHueShift: Double { allowances.first.map { AgentPalette.hueShift($0.provider) } ?? 0 }
    private var twisted: Bool { skin.kind == .vine && allowances.count > 1 }
    /// Codex first, so each agent keeps the same strand whatever the selection order.
    private var ropeAllowances: [AgentAllowance] {
        let order = SessionProvider.allCases
        return Array(allowances.sorted { (order.firstIndex(of: $0.provider) ?? 0) < (order.firstIndex(of: $1.provider) ?? 0) }.prefix(2))
    }
    private let rope = CALayer(), warningTick = CAShapeLayer()
    /// Back and front layers for each strand of the pair.
    private let strandLayers = (0..<2).map { _ in [StrandLayers(), StrandLayers()] }
    private var accentHex: String?
    private var accessibilityObservation: NotificationObservation?
    private var bodyPath: CGPath?
    private var pulsePath: CGPath?
    private var sessionStatus = CompactSessionStatus(snapshots: [], available: false, partial: false)
    private let statusBadge = CenteredTextLayer()
    /// Parsed vectors for the current notch and skin; layout reuses them instead of re-parsing.
    private var parsedPaths: [String: CGPath] = [:]
    private var parsedNotch: CGSize?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.isGeometryFlipped = true; layer?.masksToBounds = false
        left.name = "lun"; right.name = "let"
        for item in [body, lanterns.layer, left, right] { layer?.addSublayer(item) }
        statusBadge.name = "session-status"
        // The waiting count uses the panel's attention color and stays at least 10 points.
        statusBadge.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        statusBadge.fontSize = 10; statusBadge.alignmentMode = .center
        statusBadge.foregroundColor = NSColor.white.cgColor
        statusBadge.cornerRadius = Self.badgeHeight / 2; statusBadge.isHidden = true
        layer?.addSublayer(statusBadge)
        body.addSublayer(rearTrack); body.addSublayer(rearFill)
        body.addSublayer(vineHighlight); body.addSublayer(track); body.addSublayer(fill)
        track.name = "vine-track"; fill.name = "vine-fill"; ticks.name = "marks"
        rope.name = "rope"; body.addSublayer(rope)
        // Back halves of both strands, then front halves, so the strands alternate at each crossing.
        for side in 0..<2 {
            for (index, strand) in strandLayers.enumerated() {
                strand[side].container.name = "strand-\(index)-" + (side == 1 ? "front" : "back")
                rope.addSublayer(strand[side].container)
            }
        }
        body.addSublayer(ticks); body.addSublayer(warningTick)
        warningTick.name = "warning-mark"; warningTick.fillColor = nil; warningTick.lineCap = .round
        warningTick.lineWidth = 1.1; warningTick.strokeColor = Self.warningColor.cgColor
        fill.mask = fillMask; rearFill.mask = rearMask
        for (mask, width) in [(fillMask, 2.6), (rearMask, 1.45)] {
            mask.fillColor = nil; mask.strokeColor = NSColor.white.cgColor; mask.lineWidth = width; mask.lineCap = .round
        }
        for item in [fill, rearFill] { item.locations = [0, 0.4, 1] }
        rearFill.opacity = 0.5
        for (item, width) in [(track, 2.4), (rearTrack, 1.35), (vineHighlight, 3.2), (ticks, 0.85)] {
            item.fillColor = nil; item.lineWidth = width; item.lineCap = .round
        }
        vineHighlight.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Open Lunlet sessions")
        updateHelp()
        // Reduce Transparency changes the badge backing as well as motion.
        accessibilityObservation = NotificationObservation(center: NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in
                self?.needsLayout = true; self?.animate()
            }
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true // Badge and lantern outline colors resolve against the appearance.
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let geometry = VineGeometry(notch: notchSize)
        statusBadge.frame = badgeFrame
        statusBadge.contentsScale = window?.backingScaleFactor ?? 2
        statusBadge.backgroundColor = NSColor.systemOrange.cgColor
        deepInk = Self.prefersDeepInk(effectiveAppearance)
        body.frame = bounds
        bodyPath = path(skin.bodyPath ?? VineArtwork.body, on: geometry)
        pulsePath = skin.bodyPath == nil ? path(VineArtwork.pulse, on: geometry) : nil
        fillMask.lineWidth = skin.strokeWidth; track.lineWidth = max(0.5, skin.strokeWidth - 0.2)
        for item in [track, vineHighlight, fillMask] { item.frame = bounds; item.path = bodyPath }
        let rear = path(VineArtwork.rear, on: geometry)
        for item in [rearTrack, rearMask] { item.frame = bounds; item.path = rear }
        fill.frame = bounds; rearFill.frame = bounds
        for item in body.sublayers ?? [] where item.name == "foliage" { item.removeFromSuperlayer() }
        let curls = shape(path(VineArtwork.curls, on: geometry), width: 1.05, color: pearl[2])
        curls.name = "foliage"; curls.isHidden = !skin.foliage; body.addSublayer(curls)
        let samples = geometry.points(on: bodyPath ?? path(VineArtwork.body, on: geometry))
        let ropes = twisted ? twistedRopes(geometry) : nil
        for fraction in [0.3, 0.74] {
            // On the pair a sprout hangs from the lower strand, clear of the crossings.
            let location = ropes.map { sproutLocation(at: fraction, on: $0.rest) } ?? geometry.location(at: fraction, on: samples)
            let sprout = shape(path(VineArtwork.sprout), width: 0.5, color: pearl[2], filled: true)
            sprout.name = "foliage"
            let placement = CGAffineTransform(translationX: location.point.x, y: location.point.y)
            sprout.setAffineTransform(placement.rotated(by: location.angle))
            sprout.opacity = 0.65; sprout.isHidden = !skin.foliage; body.addSublayer(sprout)
        }
        let marks = CGMutablePath(), warning = CGMutablePath()
        if let ropes {
            // One set of marks across both strands; the 10% warning reaches a little further (AC-04.13).
            let reach = VineRope.amplitude + strandWidth / 2 + 0.6
            for fraction in WeeklyAllowanceMarkers.references {
                let (a, b) = ropes.rest.mark(at: fraction / 100, reach: reach)
                marks.move(to: a); marks.addLine(to: b)
            }
            let (a, b) = ropes.rest.mark(at: WeeklyAllowanceMarkers.warning / 100, reach: reach + 0.9)
            warning.move(to: a); warning.addLine(to: b)
        } else {
            // The single vine carries the same ruler and 10% warning as every meter (AC-04.10).
            for fraction in WeeklyAllowanceMarkers.barMarks {
                let location = geometry.location(at: fraction / 100, on: samples)
                let reach = fraction == WeeklyAllowanceMarkers.warning ? 2.6 : 1.7
                let nx = -sin(location.angle) * reach, ny = cos(location.angle) * reach
                let path = fraction == WeeklyAllowanceMarkers.warning ? warning : marks
                path.move(to: .init(x: location.point.x - nx, y: location.point.y - ny))
                path.addLine(to: .init(x: location.point.x + nx, y: location.point.y + ny))
            }
        }
        ticks.frame = bounds; ticks.path = marks; ticks.strokeColor = pearl[3].withAlphaComponent(0.7).cgColor
        warningTick.frame = bounds; warningTick.path = warning
        let festive = skin.kind == .lantern
        configureWord(left, x: EntryMetrics.outerInset, source: [skin.leftWord ?? VineArtwork.leftInk,
            festive ? "M5 19 C3 22 6 24 8 21 C9 19 6 18 5 19" : VineArtwork.leftTendril,
            festive ? "M30 6 C32 3 36 4 35 7 C34 9 31 9 30 6 Z" : VineArtwork.leftShoot,
            festive ? "M34 7 C33 10 36 11 35 13" : VineArtwork.leftVein])
        configureWord(right, x: EntryMetrics.wing + notchSize.width + 4, source: [skin.rightWord ?? VineArtwork.rightInk,
            festive ? "M31 20 C33 18 36 20 34 22 C32 24 30 21 31 20" : VineArtwork.rightTendril,
            festive ? "M27 4 C29 1 33 2 32 5 C31 7 28 7 27 4 Z" : VineArtwork.rightShoot,
            festive ? "M30 5 C29 8 32 9 31 11" : VineArtwork.rightVein])
        lanterns.layer.frame = bounds
        // One agent keeps one cord of lanterns; two agents hang two crossing cords, Codex first (AC-04.13).
        if festive {
            lanterns.render(notch: notchSize, allowances: allowances.count > 1 ? ropeAllowances : Array(allowances.prefix(1)),
                            accentHex: accentHex)
        }
        lanterns.layer.isHidden = !festive || detailsVisible
        applyAllowance(geometry: geometry, samples: samples)
        rope.frame = bounds; rope.isHidden = ropes == nil
        if let ropes { applyRope(ropes.rest, flexed: ropes.flexed) }
        CATransaction.commit()
    }
    /// The low-allowance mark color shared with the expanded meter.
    static let warningColor = AllowanceColor(red: 0.82, green: 0.25, blue: 0.31)
    private var strandWidth: CGFloat { CGFloat(skin.strokeWidth) * 0.62 }
    private func twistedRopes(_ geometry: VineGeometry) -> (rest: VineRope, flexed: VineRope?) {
        let rest = VineRope(centerline: geometry.points(on: path(skin.bodyPath ?? VineArtwork.rope, on: geometry)))
        let flexed = skin.bodyPath == nil
            ? VineRope(centerline: geometry.points(on: path(VineArtwork.ropePulse, on: geometry))) : nil
        return (rest, flexed)
    }
    private func sproutLocation(at fraction: Double, on rope: VineRope) -> (point: CGPoint, angle: CGFloat) {
        let lower = (0..<2).map { rope.point($0, at: fraction) }.max { $0.y < $1.y } ?? .zero
        let ahead = VineRope.sample(rope.center, at: fraction + 0.01), behind = VineRope.sample(rope.center, at: fraction - 0.01)
        return (lower, atan2(ahead.y - behind.y, ahead.x - behind.x))
    }
    /// Each strand fills to its own agent's remaining in that agent's palette; the two are never combined.
    private func applyRope(_ rope: VineRope, flexed: VineRope?) {
        for (index, allowance) in ropeAllowances.enumerated() {
            let shift = AgentPalette.hueShift(allowance.provider), value = allowance.remaining
            let colors = AllowancePalette.colors(remaining: value, tintHex: accentHex, hueShift: shift).map(\.cgColor)
            let track = AllowancePalette.trackColor(tintHex: accentHex, hueShift: shift).cgColor
            let through = (value ?? 0) / 100
            let start = rope.point(index, at: 0), end = rope.point(index, at: through)
            for (side, layers) in strandLayers[index].enumerated() {
                let front = side == 1
                layers.rest = (rope.path(index, front: front), rope.path(index, front: front, through: through))
                layers.flexed = flexed.map { ($0.path(index, front: front), $0.path(index, front: front, through: through)) }
                layers.apply(width: strandWidth, bounds: bounds, colors: colors, track: track, unknown: value == nil,
                             empty: value == nil || value == 0, start: start, end: end)
            }
        }
    }
    /// Untinted vine lettering; the middle tone is the vine's fallback accent.
    static let defaultVinePearl = [0xf3f4ff, 0xd8e4ff, 0xb7afe5, 0x917bc5].map(AllowanceColor.init(hex:))
    /// The control tint that seeds the deeper lettering when no accent is chosen.
    static let defaultDeepInk = AllowanceColor(hex: 0x856bc7)
    static let badgeHeight: CGFloat = 15
    /// A light appearance gets deeper lettering. The entry window inherits the system appearance; the menu bar's
    /// actual wallpaper-dependent tint is not public, so an undetermined appearance keeps the pastel baseline.
    static func prefersDeepInk(_ appearance: NSAppearance?) -> Bool {
        let match = appearance?.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        return match == .aqua || match == .vibrantLight
    }
    /// Vine lettering and decoration colors; the allowance fill keeps the shared palette (AC-04.10).
    static func vineInk(tint: AllowanceColor?, deep: Bool) -> [AllowanceColor] {
        if deep {
            let base = tint ?? defaultDeepInk
            return [base.blended(toward: .init(hex: 0xffffff), amount: 0.2), base,
                    base.blended(toward: .init(hex: 0), amount: 0.18), base.blended(toward: .init(hex: 0), amount: 0.35)]
        }
        guard let tint else { return defaultVinePearl }
        return [tint.blended(toward: .init(hex: 0xffffff), amount: 0.85),
                tint.blended(toward: .init(hex: 0xffffff), amount: 0.5), tint,
                tint.blended(toward: .init(hex: 0), amount: 0.15)]
    }
    private var deepInk = false
    private var badgeFrame: CGRect {
        let width = max(Self.badgeHeight, (statusBadge.string as? String).map { CGFloat($0.count) * 6.5 + 8 } ?? 0)
        return .init(x: bounds.width - width, y: 1, width: width, height: Self.badgeHeight)
    }
    private var pearl: [NSColor] {
        // The caller supplies the resolved accent, which already includes a skin's own color.
        let tint = accentHex.flatMap(AllowanceColor.init(hexString:))
        if skin.kind == .lantern {
            let glass = tint ?? SkinKind.lantern.fallbackAccent
            return [0.92, 0.78, 0.58, 0.2].map { glass.blended(toward: .init(hex: 0xfff0ce), amount: $0).nsColor }
        }
        return Self.vineInk(tint: tint, deep: deepInk).map(\.nsColor)
    }
    private func path(_ source: String, on geometry: VineGeometry? = nil) -> CGPath {
        if parsedNotch != notchSize { parsedPaths.removeAll(); parsedNotch = notchSize }
        let key = (geometry == nil ? "raw:" : "mapped:") + source
        if let cached = parsedPaths[key] { return cached }
        let parsed = geometry.map { $0.path(source) } ?? VinePath.make(source)
        parsedPaths[key] = parsed
        return parsed
    }
    private func shape(_ path: CGPath, width: CGFloat, color: NSColor, filled: Bool = false) -> CAShapeLayer {
        let item = CAShapeLayer(); item.path = path; item.lineWidth = width; item.lineCap = .round; item.lineJoin = .round
        item.fillColor = filled ? color.cgColor : nil; item.strokeColor = filled ? nil : color.cgColor
        item.contentsScale = window?.backingScaleFactor ?? 2
        return item
    }
    private func configureWord(_ container: CALayer, x: CGFloat, source: [String]) {
        let word = EntryMetrics.wordSize
        container.bounds = .init(origin: .zero, size: word)
        container.anchorPoint = .init(x: 0.5, y: 0.85)
        container.position = .init(x: x + word.width / 2, y: (notchSize.height - EntryMetrics.referenceNotch.height) / 2 + 5 + 22.1)
        container.sublayers?.forEach { $0.removeFromSuperlayer() }
        let transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        for (index, source) in source.enumerated() {
            var mapping = transform
            let scaled = path(source).copy(using: &mapping)!
            if index == 0 || index == 2 {
                let gradient = CAGradientLayer()
                gradient.frame = container.bounds; gradient.colors = pearl.map(\.cgColor)
                gradient.startPoint = .init(x: 0, y: 0); gradient.endPoint = .init(x: 0.65, y: 1)
                let mask = shape(scaled, width: 2.65, color: .white, filled: index == 2)
                mask.frame = container.bounds; gradient.mask = mask; container.addSublayer(gradient)
            } else { container.addSublayer(shape(scaled, width: index == 1 ? 1.1 : 0.3,
                                                 color: index == 1 ? pearl[2] : NSColor.white.withAlphaComponent(0.4))) }
        }
    }
    func setSkin(_ next: SkinDefinition) {
        guard next != skin else { return }
        do { try next.validate(); skin = next }
        catch { skin = SkinCatalog.builtins[0] }
        parsedPaths.removeAll(); lanterns.stopAnimations(); needsLayout = true
    }
    func setAccent(_ hex: String?) {
        guard hex != accentHex else { return }
        accentHex = hex; needsLayout = true
    }
    /// A single Codex allowance.
    func setAllowance(_ value: Double?) { setAllowances([.init(provider: .codex, remaining: value)]) }
    func setAllowances(_ next: [AgentAllowance]) {
        let next = next.isEmpty ? [AgentAllowance(provider: .codex, remaining: nil)] : next
        guard next != allowances else { return }
        allowances = next; updateHelp(); needsLayout = true
    }
    /// The single vine shows the first selected agent in that agent's palette.
    private func applyAllowance(geometry: VineGeometry, samples: [CGPoint]) {
        let colors = AllowancePalette.colors(remaining: remaining, tintHex: accentHex, hueShift: leadHueShift).map(\.cgColor)
        let trackColor = AllowancePalette.trackColor(tintHex: accentHex, hueShift: leadHueShift).cgColor
        for item in [fill, rearFill] {
            item.colors = colors
            let start = geometry.location(at: 0, on: samples).point
            let end = geometry.location(at: (remaining ?? 0) / 100, on: samples).point
            item.startPoint = .init(x: start.x / bounds.width, y: start.y / bounds.height)
            item.endPoint = .init(x: max(start.x + 1, end.x) / bounds.width, y: end.y / bounds.height)
            item.isHidden = twisted || remaining == nil || remaining == 0
        }
        fillMask.strokeEnd = (remaining ?? 0) / 100; rearMask.strokeEnd = (remaining ?? 0) / 100
        track.strokeColor = trackColor.copy(alpha: remaining == nil ? 0.5 : 0.2)
        track.lineDashPattern = remaining == nil ? [2, 5] : nil
        rearTrack.strokeColor = trackColor.copy(alpha: 0.1)
        track.isHidden = twisted
        rearTrack.isHidden = twisted || remaining == nil; vineHighlight.isHidden = twisted || remaining == nil
        body.isHidden = detailsVisible || skin.kind != .vine
    }
    /// Names each agent's remaining allowance, or that it is unavailable, separately (AC-04.13).
    static func allowanceDescription(_ allowances: [AgentAllowance]) -> String {
        allowances.map { allowance in
            allowance.remaining.map {
                allowance.provider.displayName + " \($0.formatted(.number.precision(.fractionLength(0...1))))% weekly allowance left"
            } ?? allowance.provider.displayName + " weekly allowance unavailable"
        }.joined(separator: " · ")
    }
    private func updateHelp() {
        let quota = Self.allowanceDescription(allowances)
        toolTip = "Lunlet · " + sessionStatus.description + " · " + quota + " · Hover to preview · Click to keep open"
        setAccessibilityValue(sessionStatus.description + " · " + quota)
    }
    /// The badge has a fixed frame, so a status change never rebuilds the artwork.
    func setSessionStatus(_ status: CompactSessionStatus) {
        guard status != sessionStatus else { return }
        sessionStatus = status
        CATransaction.begin(); CATransaction.setDisableActions(true)
        statusBadge.string = status.badge; statusBadge.isHidden = status.badge.isEmpty
        statusBadge.frame = badgeFrame
        CATransaction.commit()
        updateHelp()
    }
    func setDetailsVisible(_ visible: Bool) {
        detailsVisible = visible; body.isHidden = visible || skin.kind != .vine
        lanterns.layer.isHidden = visible || skin.kind != .lantern
    }
    func setPose(_ pose: Pose, replay: Bool = false) {
        guard pose != self.pose || replay else { return }; self.pose = pose; animate()
    }
    func setActive(_ active: Bool) {
        guard active != self.active else { return }; self.active = active; animate()
    }
    private func animate() {
        lanterns.stopAnimations()
        for word in [left, right] { word.removeAllAnimations() }
        for item in [track, vineHighlight, fillMask] { item.removeAllAnimations() }
        for layers in strandLayers.joined() { layers.stopAnimations() }
        guard active, pose != .resting, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if skin.kind == .lantern { lanterns.react() }
        for (word, sign) in [(left, -1.0), (right, 1.0)] {
            let action = CAKeyframeAnimation(keyPath: "transform")
            action.values = [(0.0, 0.0, 0.0), (sign * 2.8, -2.5, sign * 0.12), (-sign * 0.5, 0.6, -sign * 0.04), (0, 0, 0)].map { x, y, angle in
                NSValue(caTransform3D: CATransform3DMakeAffineTransform(CGAffineTransform(translationX: x, y: y).rotated(by: angle)))
            }
            action.keyTimes = [0, 0.28, 0.56, 1]; action.duration = 1.1
            action.timingFunctions = Array(repeating: .init(name: .easeInEaseOut), count: 3)
            word.add(action, forKey: "vine-wake")
        }
        if twisted {
            for layers in strandLayers.joined() { layers.flex() }
        } else if skin.kind == .vine, let bodyPath, let pulsePath {
            for item in [track, vineHighlight, fillMask] {
                let motion = CAKeyframeAnimation(keyPath: "path")
                motion.values = [bodyPath, pulsePath, bodyPath]; motion.keyTimes = [0, 0.28, 1]; motion.duration = 1.1
                motion.timingFunctions = [.init(name: .easeInEaseOut), .init(name: .easeInEaseOut)]
                item.add(motion, forKey: "vine-flex")
            }
        }
    }
    override func mouseUp(with event: NSEvent) { clicked?() }
    override func accessibilityPerformPress() -> Bool { clicked?(); return true }
    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(EntryMenu.make(target: self, open: #selector(openPanel)), with: event, for: self)
    }
    @objc private func openPanel() { clicked?() }
}

/// One strand's layers on one side of the twist: a soft glow, a track and the fill to remaining (AC-04.13).
/// Unknown is a dashed track without a fill; zero is a solid empty track (AC-17.07).
@MainActor private final class StrandLayers {
    let container = CALayer(), glow = CAShapeLayer(), track = CAShapeLayer(), fill = CAGradientLayer(), mask = CAShapeLayer()
    /// Resting and flexed track and fill paths for the one-shot wake motion.
    var rest: (track: CGPath, fill: CGPath)?
    var flexed: (track: CGPath, fill: CGPath)?
    init() {
        for item in [glow, track, mask] { item.fillColor = nil; item.lineJoin = .round }
        // Butt ends keep the translucent track even where a strand passes from back to front.
        glow.lineCap = .butt; mask.lineCap = .round; mask.strokeColor = NSColor.white.cgColor
        glow.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
        fill.locations = [0, 0.4, 1]; fill.mask = mask
        for item in [glow, track, fill] { container.addSublayer(item) }
    }
    func apply(width: CGFloat, bounds: CGRect, colors: [CGColor], track color: CGColor, unknown: Bool, empty: Bool,
               start: CGPoint, end: CGPoint) {
        container.frame = bounds
        for item in [glow, track, fill, mask] { item.frame = bounds }
        glow.path = rest?.track; track.path = rest?.track; mask.path = rest?.fill
        glow.lineWidth = width + 0.7; track.lineWidth = max(0.5, width - 0.15); mask.lineWidth = width
        glow.isHidden = unknown
        track.strokeColor = color.copy(alpha: unknown ? 0.5 : 0.2)
        track.lineDashPattern = unknown ? [1.6, 3.4] : nil; track.lineCap = unknown ? .round : .butt
        fill.colors = colors; fill.isHidden = empty
        let width = max(1, bounds.width), height = max(1, bounds.height)
        fill.startPoint = .init(x: start.x / width, y: start.y / height)
        fill.endPoint = .init(x: max(start.x + 1, end.x) / width, y: end.y / height)
    }
    func stopAnimations() { for item in [glow, track, mask] { item.removeAllAnimations() } }
    func flex() {
        guard let rest, let flexed else { return }
        for (item, resting, moved) in [(glow, rest.track, flexed.track), (track, rest.track, flexed.track),
                                       (mask, rest.fill, flexed.fill)] {
            let motion = CAKeyframeAnimation(keyPath: "path")
            motion.values = [resting, moved, resting]; motion.keyTimes = [0, 0.28, 1]; motion.duration = 1.1
            motion.timingFunctions = [.init(name: .easeInEaseOut), .init(name: .easeInEaseOut)]
            item.add(motion, forKey: "vine-flex")
        }
    }
}

/// Draws its single line vertically centered, so the badge digits sit in the middle of the capsule.
private final class CenteredTextLayer: CATextLayer {
    override func draw(in context: CGContext) {
        let offset = (bounds.height - fontSize * 1.2) / 2
        context.saveGState(); context.translateBy(x: 0, y: isGeometryFlipped ? -offset : offset)
        super.draw(in: context)
        context.restoreGState()
    }
}
