// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.04, AC-20.06; US-12, AC-12.02.
import Foundation
import LunletMessaging

/// Only the provider's private pairing result is persisted, outside preferences.
struct BotEnrollment: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let schemaVersion: Int
    let credentials: BotCredentials
    let binding: BotBinding
    init(credentials: BotCredentials, binding: BotBinding) throws {
        schemaVersion = 1; self.credentials = credentials; self.binding = binding
        try validate(channel: credentials.channel)
    }
    static func decode(_ data: Data, channel: BotChannel) throws -> Self {
        guard data.count <= 65_536 else { throw BotChannelFailure.invalidResponse }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(channel: channel)
        return value
    }
    private func validate(channel: BotChannel) throws {
        guard schemaVersion == 1, channel == credentials.channel, channel == binding.channel,
              !credentials.botToken.isEmpty, credentials.botToken.utf8.count <= 4096,
              !credentials.botToken.contains(where: \.isWhitespace),
              !binding.botName.isEmpty, binding.botName.utf8.count <= 256,
              !binding.botName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw BotChannelFailure.invalidResponse
        }
        func valid(_ value: String?, _ pattern: String) -> Bool {
            guard let value, value.utf8.count <= 128 else { return false }
            return value.range(of: pattern, options: .regularExpression) != nil
        }
        switch channel {
        case .telegram:
            guard credentials.appToken == nil, valid(binding.botID, #"\A[0-9]+\z"#), Int64(binding.botID).map({ $0 > 0 }) == true,
                  valid(binding.ownerID, #"\A[0-9]+\z"#), Int64(binding.ownerID).map({ $0 > 0 }) == true,
                  binding.ownerID == binding.chatID, binding.workspaceID == nil, binding.applicationID == nil else {
                throw BotChannelFailure.invalidResponse
            }
        case .slack:
            guard let app = credentials.appToken, !app.isEmpty, app.utf8.count <= 4096, !app.contains(where: \.isWhitespace),
                  valid(binding.botID, #"\AB[A-Z0-9]+\z"#), valid(binding.ownerID, #"\A[UW][A-Z0-9]+\z"#),
                  valid(binding.chatID, #"\AD[A-Z0-9]+\z"#), valid(binding.workspaceID, #"\AT[A-Z0-9]+\z"#),
                  valid(binding.applicationID, #"\AA[A-Z0-9]+\z"#) else { throw BotChannelFailure.invalidResponse }
        }
    }
    var description: String { "Bot enrollment (redacted)" }
    var debugDescription: String { description }
}
