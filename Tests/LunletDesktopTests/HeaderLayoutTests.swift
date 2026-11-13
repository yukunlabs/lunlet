// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-19, AC-19.02, AC-19.09; US-24, AC-24.04.
import CoreGraphics
import Testing
import LunletCore
@testable import LunletDesktop

struct HeaderLayoutTests {
    private let width: CGFloat = 430

    // Refs: US-19, AC-19.02, AC-19.09.
    @Test func agentsKeepTheirOrderAroundTheSunAndOneAgentHasNoSun() {
        #expect(HeaderLayout.order([.codex]) == [.agent(.codex)])
        #expect(HeaderLayout.order([.codex, .claude]) == [.agent(.codex), .all, .agent(.claude)])
        #expect(HeaderLayout.order([.claude, .codex]) == [.agent(.claude), .all, .agent(.codex)])
        #expect(HeaderLayout.order([]) == [])
    }

    // Refs: US-19, AC-19.09.
    @Test func theOverviewIsOneRowWithTheSunInTheCenter() throws {
        let slots = HeaderLayout.slots(agents: [.codex, .claude], chosen: nil, width: width, top: 30)
        #expect(slots.map(\.body) == [.agent(.codex), .all, .agent(.claude)])
        #expect(slots.allSatisfy { $0.role == .row && $0.visible && $0.y == 60 && $0.diameter == 54 })
        #expect(slots.map(\.x) == [215 - 122, 215, 215 + 122])
        // The lit side of a body faces the Sun.
        #expect(slots.map(\.mirrored) == [true, false, false])
    }

    // Refs: US-19, AC-19.09.
    @Test func aChosenAgentTakesTheCenterAndTheOthersDrawBackOnTheirOwnSide() throws {
        let codex = HeaderLayout.slots(agents: [.codex, .claude], chosen: .codex, width: width, top: 30)
        #expect(codex.map(\.role) == [.center, .side, .side])
        #expect(codex.map(\.x) == [215, 215 + 108, 215 + 172])
        #expect(codex.map(\.diameter) == [64, 34, 26])
        #expect(codex.map(\.distance) == [0, 1, 2] && codex.allSatisfy(\.visible))
        #expect(codex.map(\.mirrored) == [true, false, false])
        let claude = HeaderLayout.slots(agents: [.codex, .claude], chosen: .claude, width: width, top: 30)
        #expect(claude.map(\.x) == [215 - 172, 215 - 108, 215])
        #expect(claude.map(\.role) == [.side, .side, .center])
        #expect(claude.map(\.mirrored) == [true, false, false])
        // The bodies at the sides sit a little lower than the chosen one, which is larger.
        #expect(claude[2].y == 66 && claude[0].y == 70)
    }

    // Refs: US-19, AC-19.09; US-03, AC-03.11. The hardware notch covers the middle of the band above the header.
    @Test func everyBodyStaysClearOfTheNotchBand() {
        for top: CGFloat in [14, 32, 38] {
            for agents in [[SessionProvider.codex], [.codex, .claude]] {
                for chosen in [SessionProvider?.none, .codex, .claude] {
                    for slot in HeaderLayout.slots(agents: agents, chosen: chosen, width: 454, top: top) {
                        // Two points clear, so the little a body swells under the pointer stays below the band too.
                        #expect(slot.y - slot.diameter / 2 >= top + 2, "\(slot.body) at \(slot.y) under \(top)")
                    }
                }
            }
        }
    }

    // Refs: US-19, AC-19.02.
    @Test func oneAgentIsAlwaysInTheCenterWithoutASun() {
        for chosen in [SessionProvider?.none, .codex, .claude] {
            let slots = HeaderLayout.slots(agents: [.codex], chosen: chosen, width: width, top: 30)
            #expect(slots.count == 1 && slots[0].body == .agent(.codex) && slots[0].role == .center && slots[0].x == 215)
            #expect(!slots[0].mirrored && slots[0].diameter == 64)
        }
    }

    // Refs: US-19, AC-19.09.
    @Test func positionsFollowTheHeadersWidthAndAnUnselectedChoiceIsTheOverview() {
        let wide = HeaderLayout.slots(agents: [.codex, .claude], chosen: nil, width: 470, top: 34)
        #expect(wide[1].x == 235 && abs(wide[0].x - (235 - 122 * 470 / 430)) < 0.001 && wide[0].y == 64)
        // Claude Code is not a selected agent here, so asking for it shows the Overview.
        #expect(HeaderLayout.slots(agents: [.codex], chosen: .claude, width: width, top: 30).first?.role == .center)
        let three = HeaderLayout.slots(agents: [.codex, .claude, .codex], chosen: nil, width: width, top: 30)
        #expect(three.map(\.diameter) == [44, 44, 44, 44] && three[2].body == .all && three[1].x == 215 - 86)
    }

    // Refs: US-19, AC-19.02, AC-19.09.
    @Test func choosingABodyOpensItsPageAndTheSunOrTheSameBodyReturnsToTheOverview() {
        let agents: [SessionProvider] = [.codex, .claude]
        #expect(HeaderLayout.page(choosing: .agent(.codex), open: nil, agents: agents) == .codex)
        #expect(HeaderLayout.page(choosing: .agent(.claude), open: .codex, agents: agents) == .claude)
        #expect(HeaderLayout.page(choosing: .agent(.codex), open: .codex, agents: agents) == nil)
        #expect(HeaderLayout.page(choosing: .all, open: .claude, agents: agents) == nil)
        // One agent has no Overview to return to, and an agent that is not selected cannot be opened.
        #expect(HeaderLayout.page(choosing: .agent(.codex), open: .codex, agents: [.codex]) == .codex)
        #expect(HeaderLayout.page(choosing: .agent(.claude), open: nil, agents: [.codex]) == .codex)
    }

    // Refs: US-24, AC-24.04.
    @Test func leftAndRightMoveToTheNeighboringBody() {
        let agents: [SessionProvider] = [.codex, .claude]
        #expect(HeaderLayout.neighbor(of: nil, agents: agents, step: -1) == .agent(.codex))
        #expect(HeaderLayout.neighbor(of: nil, agents: agents, step: 1) == .agent(.claude))
        #expect(HeaderLayout.neighbor(of: .codex, agents: agents, step: 1) == .all)
        #expect(HeaderLayout.neighbor(of: .codex, agents: agents, step: -1) == nil)
        #expect(HeaderLayout.neighbor(of: .claude, agents: agents, step: 1) == nil)
        // One agent has no neighbor to move to.
        #expect(HeaderLayout.neighbor(of: .codex, agents: [.codex], step: 1) == nil)
    }
}
