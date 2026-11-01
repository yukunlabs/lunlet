// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.04, AC-20.05, AC-20.06; US-12, AC-12.02.
import Foundation
import Testing
@testable import LunletMessaging

@MainActor struct ChannelHTTPClientTests {
    @Test func pairingExpiresAndCredentialDescriptionsStayRedacted() {
        let now = Date(timeIntervalSince1970: 1000)
        let code = PairingChallenge(code: "0123456789ABCDEF0123456789ABCDEF", now: now)
        #expect(code.isValid(at: now))
        #expect(!code.isValid(at: now.addingTimeInterval(600)))
        #expect(!code.isValid(at: now.addingTimeInterval(-1)))
        let credentials = BotCredentials(channel: .telegram, botToken: "synthetic-private-token")
        #expect(!String(describing: credentials).contains("synthetic-private-token"))
        #expect(!String(reflecting: credentials).contains("synthetic-private-token"))
    }
    @Test func rejectsUntrustedEndpointsBeforeNetworkingAndClosingIsFinal() async throws {
        let client = ChannelHTTPClient(allowedHosts: ["slack.com"])
        for url in ["http://slack.com/api/auth.test", "https://slack.com.attacker.invalid/api/auth.test",
                    "https://user:password@slack.com/api/auth.test", "https://slack.com:444/api/auth.test",
                    "https://api.telegram.org/bot1:token/getMe"] {
            await #expect(throws: BotChannelFailure.invalidCredentials) {
                try await client.post(URL(string: url)!, body: Data("{}".utf8))
            }
        }
        for url in ["ws://wss.slack.com/link/", "wss://slack.com.attacker.invalid/link/", "wss://wss.slack.com:444/link/",
                    "wss://wss.attacker.invalid/link/"] {
            await #expect(throws: BotChannelFailure.invalidCredentials) {
                _ = try await client.openSocket(URL(string: url)!)
            }
        }
        await #expect(throws: BotChannelFailure.invalidCredentials) {
            try await client.post(URL(string: "https://slack.com/api/auth.test")!, body: Data("{}".utf8), timeout: 41)
        }
        await client.close()
        await #expect(throws: BotChannelFailure.canceled) {
            try await client.post(URL(string: "https://slack.com/api/auth.test")!, body: Data("{}".utf8))
        }
    }
    @Test func slackSocketModeAcceptsOnlyItsOwnSocketHosts() {
        #expect(SlackBotClient.validSocketEndpoint(URL(string: "wss://wss-primary.slack.com/link/?ticket=synthetic")!))
        for url in ["wss://slack.com/link/", "wss://api.slack.com/link/", "wss://wss.primary.slack.com/link/",
                    "ws://wss-primary.slack.com/link/", "wss://wss-primary.slack.com:444/link/",
                    "wss://user@wss-primary.slack.com/link/", "wss://wss-primary.slack.com/link/#fragment"] {
            #expect(!SlackBotClient.validSocketEndpoint(URL(string: url)!))
        }
    }
}
