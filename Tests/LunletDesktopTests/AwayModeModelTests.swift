// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-05, AC-05.01, AC-05.03, AC-05.04, AC-05.05, AC-05.06; US-12, AC-12.04.
import Foundation
import Testing
import LunletCore
import LunletFeishu
@testable import LunletDesktop

private actor NoMessageSender: FeishuCardSending {
    private(set) var closed = false
    func sendCard(_ delivery: FeishuCardDelivery, owner: FeishuOwner) throws -> FeishuMessageReceipt {
        throw URLError(.unsupportedURL)
    }
    func close() { closed = true }
}
private final class PowerControl: IdleSleepControlling {
    enum Failure: Error { case denied }
    var enabled = false
    var denyEnable = false
    var history: [Bool] = []
    func setEnabled(_ enabled: Bool) throws {
        if enabled && denyEnable { throw Failure.denied }
        self.enabled = enabled; history.append(enabled)
    }
}

@MainActor struct AwayModeModelTests {
    private func ready(_ coordinator: MobileCoordinator) async {
        await coordinator.configure(owner: .init(applicationID: "cli_test", tenantID: "tenant_test", userID: "ou_test"),
                                    connectionID: UUID(), callbacksVerified: true, adapterAvailable: true)
    }
    @Test func unavailableIntegrationNeverAcquiresPowerAndPowerFailureNeverEnablesMobile() async {
        let sender = NoMessageSender(), coordinator = MobileCoordinator(sender: sender, onAction: { _ in })
        let power = PowerControl(), model = AwayModeModel(coordinator: coordinator, power: power)
        await model.setEnabled(true)
        #expect(!power.enabled && model.state == .unavailable)
        #expect(await coordinator.awayMode == false)
        await ready(coordinator); await model.refreshAvailability()
        #expect(model.canEnable)
        power.denyEnable = true
        await model.setEnabled(true)
        #expect(model.state == .failed && !power.enabled)
        #expect(await coordinator.awayMode == false)
        await model.shutdown()
    }
    @Test func explicitOffAndQuitCloseMobileBeforeReleasingOwnedPower() async {
        let sender = NoMessageSender(), coordinator = MobileCoordinator(sender: sender, onAction: { _ in })
        let power = PowerControl(), model = AwayModeModel(coordinator: coordinator, power: power)
        await ready(coordinator); await model.refreshAvailability(); await model.setEnabled(true)
        #expect(model.state == .on && power.enabled)
        #expect(await coordinator.awayMode)
        await model.setEnabled(false)
        #expect(model.state == .off && !power.enabled)
        #expect(await coordinator.awayMode == false)
        await model.setEnabled(true); await model.shutdown(); await model.shutdown()
        #expect(!power.enabled && !model.canEnable)
        #expect(await coordinator.awayMode == false)
        #expect(await sender.closed)
        await model.setEnabled(true)
        #expect(!power.enabled)
    }
    @Test func losingReadinessThenRequestingEnableCannotStrandASleepAssertion() async {
        let sender = NoMessageSender(), coordinator = MobileCoordinator(sender: sender, onAction: { _ in })
        let power = PowerControl(), model = AwayModeModel(coordinator: coordinator, power: power)
        await ready(coordinator); await model.setEnabled(true)
        #expect(power.enabled)
        await coordinator.configure(owner: nil, connectionID: nil, callbacksVerified: false, adapterAvailable: false)
        await model.setEnabled(true)
        #expect(!power.enabled && !model.isOn && !model.canEnable)
        #expect(await coordinator.awayMode == false)
        await model.shutdown()
    }

    @Test func overlappingTogglesAndQuitCannotResurrectAwayMode() async {
        let sender = NoMessageSender(), coordinator = MobileCoordinator(sender: sender, onAction: { _ in })
        let power = PowerControl(), model = AwayModeModel(coordinator: coordinator, power: power)
        await ready(coordinator)
        let first = Task { await model.setEnabled(true) }
        let second = Task { await model.setEnabled(false) }
        await first.value; await second.value
        #expect(model.state == .off && !power.enabled)
        let enable = Task { await model.setEnabled(true) }
        await model.shutdown(); await enable.value
        #expect(!power.enabled && !model.canEnable)
        #expect(await coordinator.awayMode == false)
    }
}
