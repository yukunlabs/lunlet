// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.02, AC-19.09; US-24, AC-24.04.
import CoreGraphics
import LunletCore

/// Where the header's bodies rest: one row around the Sun for the Overview, and the chosen agent in the center with
/// the others drawn back to the sides for an agent's page (AC-19.09).
enum HeaderLayout {
    enum Role: Equatable { case row, center, side }
    struct Slot: Equatable {
        var body: HeaderBody
        var x: CGFloat
        var y: CGFloat
        var diameter: CGFloat
        var role: Role
        /// A body left of the Sun is mirrored, so its lit side faces the Sun.
        var mirrored: Bool
        var visible: Bool
        /// How many places from the chosen body, which staggers the move.
        var distance: Int
    }

    /// Measurements are for a header 430 points wide; horizontal distances follow the actual width.
    static let referenceWidth: CGFloat = 430
    static let centerDiameter: CGFloat = 64
    /// The row's center below the header's top inset; the larger chosen body's center, low enough for its disc to
    /// stay clear of the notch band; and how much lower the bodies beside it sit.
    static let rowDrop: CGFloat = 30
    static let centerDrop: CGFloat = 36
    static let sideDrop: CGFloat = 4
    /// One move, the same for the bodies and the sky's streak.
    static let duration: Double = 0.72

    /// Leading to trailing: the first half of the agents, the Sun, then the rest. One agent has no Sun (AC-19.02).
    static func order(_ agents: [SessionProvider]) -> [HeaderBody] {
        guard agents.count > 1 else { return agents.map(HeaderBody.agent) }
        let lead = (agents.count + 1) / 2
        return agents.prefix(lead).map(HeaderBody.agent) + [.all] + agents.dropFirst(lead).map(HeaderBody.agent)
    }

    /// `chosen` nil, or an agent that is not selected, is the Overview. `top` is the header's inset below the notch
    /// band.
    static func slots(agents: [SessionProvider], chosen: SessionProvider?, width: CGFloat, top: CGFloat) -> [Slot] {
        let order = order(agents), center = width / 2, unit = width / referenceWidth
        guard let sun = order.firstIndex(of: .all) else {
            return order.map { Slot(body: $0, x: center, y: top + centerDrop, diameter: centerDiameter, role: .center,
                                    mirrored: false, visible: true, distance: 0) }
        }
        guard let chosen, let place = order.firstIndex(of: .agent(chosen)) else {
            // Up to one body on each side keeps the larger size and the wider step.
            let wide = max(sun, order.count - sun - 1) <= 1
            let step = (wide ? 122 : 86) * unit, diameter: CGFloat = wide ? 54 : 44
            return order.enumerated().map { index, body in
                Slot(body: body, x: center + step * CGFloat(index - sun), y: top + rowDrop, diameter: diameter, role: .row,
                     mirrored: index < sun, visible: true, distance: abs(index - sun))
            }
        }
        // The second place stays far enough inside the edge for a long name under its body.
        let offsets: [CGFloat] = [0, 108, 172, 250], diameters: [CGFloat] = [centerDiameter, 34, 26, 18]
        let sunAway = sun - place
        var slots = order.enumerated().map { index, body -> Slot in
            var away = index - place, steps = abs(away)
            guard steps > 0 else {
                return Slot(body: body, x: center, y: top + centerDrop, diameter: centerDiameter, role: .center,
                            mirrored: false, visible: true, distance: 0)
            }
            // The Sun stays in view at the second place, and the body it displaces steps out.
            if body == .all && steps > 2 { away = away.signum() * 2; steps = 2 }
            else if abs(sunAway) > 2 && away == sunAway.signum() * 2 { steps = 3 }
            let near = min(steps, 3)
            return Slot(body: body, x: center + CGFloat(away.signum()) * offsets[near] * unit, y: top + centerDrop + sideDrop,
                        diameter: diameters[near], role: .side, mirrored: false, visible: steps <= 2, distance: steps)
        }
        let sunX = slots[sun].x
        for index in slots.indices where slots[index].body != .all { slots[index].mirrored = slots[index].x < sunX }
        return slots
    }

    /// The agent page that is open after a body is chosen: an agent's body opens its page; the Sun, or the open agent's
    /// body again, returns to the Overview, which is nil. One agent's page is always open (AC-19.02).
    static func page(choosing body: HeaderBody, open: SessionProvider?, agents: [SessionProvider]) -> SessionProvider? {
        guard agents.count > 1 else { return agents.first }
        guard case .agent(let provider) = body, agents.contains(provider), provider != open else { return nil }
        return provider
    }

    /// The body one place to the leading (-1) or trailing (+1) side of the current choice, nil at either end.
    static func neighbor(of chosen: SessionProvider?, agents: [SessionProvider], step: Int) -> HeaderBody? {
        let order = order(agents)
        let current: HeaderBody = chosen.flatMap { order.contains(.agent($0)) ? .agent($0) : nil } ?? .all
        guard let place = order.firstIndex(of: current), order.indices.contains(place + step) else { return nil }
        return order[place + step]
    }
}
