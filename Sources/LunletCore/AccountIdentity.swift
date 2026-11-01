// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.01, AC-04.03, AC-04.09.
import Foundation

public struct AccountIdentity: Equatable, Sendable {
    public let email: String?
    public let plan: String?
    public init(email: String?, plan: String?) { self.email = email; self.plan = plan }
}

public struct AccountCredits: Equatable, Sendable {
    public let balance: String?
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public init(balance: String?, hasCredits: Bool?, unlimited: Bool?) {
        self.balance = balance; self.hasCredits = hasCredits; self.unlimited = unlimited
    }
}
