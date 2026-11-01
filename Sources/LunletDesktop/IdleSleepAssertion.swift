// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-14, AC-14.01, AC-14.02, AC-14.03, AC-14.06.
// Refs: US-05, AC-05.04, AC-05.05; US-12, AC-12.04.
import Foundation
import LunletCore
import IOKit.pwr_mgt

struct PowerAssertionFailure: Error, Equatable, Sendable {
    let code: IOReturn
}

/// Confine this resource to its owner's executor.
final class IdleSleepAssertion {
    private let diagnostic = DiagnosticOperation()
    private let reason: String
    private var assertionID: IOPMAssertionID?
    var isEnabled: Bool { assertionID != nil }

    init(reason: String = "Lunlet Away Mode") { self.reason = reason }

    deinit {
        if let assertionID {
            let status = IOPMAssertionRelease(assertionID)
            DiagnosticLog.record(.powerAssertion, component: .power, outcome: status == kIOReturnSuccess ? .stopped : .failed,
                                 operation: diagnostic, code: Int(status))
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard assertionID == nil else { return }
            var id: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
            guard status == kIOReturnSuccess else {
                DiagnosticLog.record(.powerAssertion, component: .power, outcome: .failed, operation: diagnostic, code: Int(status))
                throw PowerAssertionFailure(code: status)
            }
            assertionID = id
            DiagnosticLog.record(.powerAssertion, component: .power, outcome: .completed, operation: diagnostic)
        } else if let assertionID {
            let status = IOPMAssertionRelease(assertionID)
            guard status == kIOReturnSuccess else {
                DiagnosticLog.record(.powerAssertion, component: .power, outcome: .failed, operation: diagnostic, code: Int(status))
                throw PowerAssertionFailure(code: status)
            }
            self.assertionID = nil
            DiagnosticLog.record(.powerAssertion, component: .power, outcome: .stopped, operation: diagnostic)
        }
    }
}
