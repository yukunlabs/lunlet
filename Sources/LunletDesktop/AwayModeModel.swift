// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-05, AC-05.01, AC-05.03, AC-05.04, AC-05.05, AC-05.06; US-12, AC-12.04.
import Foundation
import Combine
import LunletFeishu

protocol IdleSleepControlling: AnyObject { func setEnabled(_ enabled: Bool) throws }
extension IdleSleepAssertion: IdleSleepControlling {}

@MainActor final class AwayModeModel: ObservableObject {
    enum State: Equatable { case unavailable, off, enabling, on, stopping, failed }
    @Published private(set) var state: State = .unavailable
    @Published private(set) var canEnable = false
    var isOn: Bool { state == .on || state == .enabling }
    private let coordinator: MobileCoordinator?
    private let power: any IdleSleepControlling
    private var generation: UInt64 = 0
    private var pending: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var closed = false

    /// Inert until a verified Codex input adapter supplies a coordinator; it stays unavailable.
    init() { coordinator = nil; power = IdleSleepAssertion() }
    init(coordinator: MobileCoordinator, power: any IdleSleepControlling) {
        self.coordinator = coordinator; self.power = power
    }

    func refreshAvailability() async {
        let available = await coordinator?.canEnableAway ?? false
        guard !closed else { return }
        canEnable = available
        if state == .off || state == .unavailable { state = available ? .off : .unavailable }
    }

    /// Serialize power and transport changes, including callers that overlap while
    /// awaiting the router. Superseded requests roll back before the next begins.
    func setEnabled(_ enabled: Bool) async {
        guard !closed else { return }
        generation += 1
        let token = generation, previous = pending
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !self.closed, self.generation == token else { return }
            await self.apply(enabled, token: token)
        }
        pending = task
        await task.value
        if generation == token { pending = nil }
    }

    private func apply(_ enabled: Bool, token: UInt64) async {
        guard let coordinator else { state = .unavailable; return }
        if enabled {
            await refreshAvailability()
            guard !closed, generation == token else { return }
            guard canEnable else {
                _ = await coordinator.setAwayMode(false)
                do { try power.setEnabled(false); state = .unavailable }
                catch { state = .failed }
                return
            }
            state = .enabling
            do { try power.setEnabled(true) }
            catch { state = .failed; return }
            let accepted = await coordinator.setAwayMode(true)
            guard accepted, !closed, generation == token else {
                _ = await coordinator.setAwayMode(false)
                do { try power.setEnabled(false); if !closed { state = .unavailable } }
                catch { state = .failed }
                return
            }
            state = .on
        } else {
            state = .stopping
            _ = await coordinator.setAwayMode(false)
            await refreshAvailability()
            do { try power.setEnabled(false); state = canEnable ? .off : .unavailable }
            catch { state = .failed }
        }
    }

    func shutdown() async {
        if let closing { await closing.value; return }
        closed = true; canEnable = false; generation += 1
        let previous = pending
        let task = Task {
            await previous?.value
            await coordinator?.close()
            do { try power.setEnabled(false); state = .unavailable }
            catch { state = .failed }
        }
        closing = task
        await task.value
        pending = nil
    }
}
