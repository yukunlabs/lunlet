// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-05, AC-05.04, AC-05.05; US-12, AC-12.04.
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import LunletDesktop

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUNLET_TEST_POWER"] == "1"))
func ownedSleepAssertionIsIdempotentAndReleasedOnDisableAndDestruction() throws {
    let reason = "Lunlet power test \(UUID().uuidString)"
    func ownedAssertions() throws -> [[String: Any]] {
        var raw: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&raw)
        try #require(status == kIOReturnSuccess)
        // A successful query can leave the output nil when there are no
        // assertions anywhere. An enabled owned assertion must still be found.
        guard let all = raw?.takeRetainedValue() as NSDictionary? else { return [] }
        let own = all[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] as? [[String: Any]] ?? []
        return own.filter { $0[kIOPMAssertionNameKey] as? String == reason }
    }
    var assertion: IdleSleepAssertion? = IdleSleepAssertion(reason: reason)
    #expect(try ownedAssertions().isEmpty)
    try assertion?.setEnabled(true)
    try assertion?.setEnabled(true)
    #expect(assertion?.isEnabled == true)
    let active = try ownedAssertions()
    #expect(active.count == 1)
    #expect(active.first?[kIOPMAssertionTypeKey] as? String == "PreventUserIdleSystemSleep")
    try assertion?.setEnabled(false)
    try assertion?.setEnabled(false)
    #expect(assertion?.isEnabled == false)
    #expect(try ownedAssertions().isEmpty)
    try assertion?.setEnabled(true)
    assertion = nil
    #expect(try ownedAssertions().isEmpty)
}
