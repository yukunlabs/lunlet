// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.01, AC-20.03, AC-20.05, AC-20.06.
import LunletMessaging

/// One construction point for user-owned bot clients, shared by setup and delivery.
enum BotClientFactory {
    static func client(_ credentials: BotCredentials) -> any ChannelReplyClient {
        switch credentials.channel {
        case .slack: SlackBotClient(credentials: credentials)
        case .telegram: TelegramBotClient(credentials: credentials)
        }
    }
}

extension CommunicationChannel {
    /// The bot-token provider for this choice; Feishu uses its own registration flow.
    var botChannel: BotChannel? { BotChannel(rawValue: rawValue) }
}
