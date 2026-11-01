// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.03, AC-20.04, AC-20.06; US-12, AC-12.02.
import Foundation
import LunletCore

public enum BotChannel: String, Codable, Sendable { case slack, telegram }

public struct BotCredentials: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let channel: BotChannel
    public let botToken: String
    public let appToken: String?
    public init(channel: BotChannel, botToken: String, appToken: String? = nil) {
        self.channel = channel; self.botToken = botToken; self.appToken = appToken
    }
    public var description: String { "Bot credentials (redacted)" }
    public var debugDescription: String { description }
}

public struct BotIdentity: Equatable, Sendable {
    public let channel: BotChannel
    public let id: String
    public let name: String
    public let workspaceID: String?
    public let applicationID: String?
    public init(channel: BotChannel, id: String, name: String, workspaceID: String? = nil, applicationID: String? = nil) {
        self.channel = channel; self.id = id; self.name = name; self.workspaceID = workspaceID; self.applicationID = applicationID
    }
}

public struct BotBinding: Codable, Equatable, Sendable {
    public let channel: BotChannel
    public let botID: String
    public let botName: String
    public let ownerID: String
    public let chatID: String
    public let workspaceID: String?
    public let applicationID: String?
    public init(channel: BotChannel, botID: String, botName: String, ownerID: String, chatID: String,
                workspaceID: String? = nil, applicationID: String? = nil) {
        self.channel = channel; self.botID = botID; self.botName = botName; self.ownerID = ownerID; self.chatID = chatID
        self.workspaceID = workspaceID; self.applicationID = applicationID
    }
}

public struct PairingChallenge: Sendable {
    public let code: String
    public let createdAt: Date
    public let expiresAt: Date
    public init(code: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""), now: Date = Date()) {
        self.code = code; createdAt = now; expiresAt = now.addingTimeInterval(600)
    }
    public func isValid(at now: Date) -> Bool { now >= createdAt && now < expiresAt && !code.isEmpty }
}

public struct BotMessageReceipt: Equatable, Sendable {
    public let messageID: String
    public let chatID: String
    public init(messageID: String, chatID: String) { self.messageID = messageID; self.chatID = chatID }
}

public enum BotChannelFailure: Error, Equatable, Sendable {
    case invalidCredentials, invalidResponse, unauthorized, permissionDenied, rateLimited, unavailable
    case deliveryUncertain, expired, canceled, webhookInUse, identityMismatch
}

public extension DiagnosticReason {
    /// The allowlisted reason for a channel failure; never the provider's text.
    init(_ failure: BotChannelFailure) {
        switch failure {
        case .invalidCredentials: self = .invalidInput
        case .unauthorized: self = .authentication
        case .permissionDenied: self = .permission
        case .rateLimited: self = .rateLimit
        case .invalidResponse, .identityMismatch: self = .invalidResponse
        case .unavailable: self = .provider
        case .expired: self = .timeout
        case .webhookInUse: self = .protocolViolation
        case .deliveryUncertain, .canceled: self = .unknown
        }
    }
}

public protocol ChannelBotClient: Sendable {
    func prepare() async throws -> BotIdentity
    func pair(_ challenge: PairingChallenge) async throws -> BotBinding
    func checkAuthorization(_ binding: BotBinding) async throws
    func sendCompletion(_ snapshot: SessionSnapshot, binding: BotBinding) async throws -> BotMessageReceipt
    func close() async
}

public protocol ChannelSocket: Sendable {
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func close() async
}
