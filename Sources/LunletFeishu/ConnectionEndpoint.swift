// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.02, AC-01.04, AC-01.05.
// Refs: US-11, AC-11.01, AC-11.02; US-12, AC-12.02, AC-12.04.
import Foundation

protocol FeishuEndpointProviding: Sendable {
    func requestConnectionEndpoint() async throws -> FeishuConnectionEndpoint
}
extension FeishuBotClient: FeishuEndpointProviding {}

struct FeishuConnectionSettings: Equatable, Sendable, Decodable {
    var pingInterval: Int? = nil
    var maximumReconnects: Int? = nil
    var reconnectInterval: Int? = nil
    var reconnectNonce: Int? = nil

    var pingSeconds: Int { pingInterval ?? 120 }
    var reconnectCount: Int { maximumReconnects ?? -1 }
    var reconnectSeconds: Int { reconnectInterval ?? 120 }
    var reconnectJitterSeconds: Int { reconnectNonce ?? 30 }

    func validate() throws {
        guard (1...3_600).contains(pingSeconds), (-1...1_000).contains(reconnectCount),
              (0...3_600).contains(reconnectSeconds), (0...3_600).contains(reconnectJitterSeconds) else {
            throw FeishuBotFailure.invalidResponse
        }
    }

    enum CodingKeys: String, CodingKey {
        case pingInterval = "PingInterval", maximumReconnects = "ReconnectCount"
        case reconnectInterval = "ReconnectInterval", reconnectNonce = "ReconnectNonce"
    }
}

struct FeishuConnectionEndpoint: Sendable, CustomStringConvertible {
    let url: URL
    let serviceID: Int32
    let deviceID: String
    let settings: FeishuConnectionSettings
    var description: String { "Feishu connection endpoint (redacted)" }

    static func decode(_ data: Data, applicationID: String) throws -> Self {
        guard data.count <= 65_536, !applicationID.isEmpty,
              let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.code == 0,
              reply.data.url.utf8.count <= 16_384,
              reply.data.url == reply.data.url.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: reply.data.url), components.scheme?.lowercased() == "wss",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.fragment == nil, let url = URL(string: reply.data.url),
              let items = components.queryItems else { throw FeishuBotFailure.invalidResponse }
        let services = items.filter { $0.name == "service_id" }
        let devices = items.filter { $0.name == "device_id" }
        let apps = items.filter { $0.name == "app_id" }
        guard services.count == 1, let service = services[0].value, !service.isEmpty,
              service.utf8.allSatisfy({ (48...57).contains($0) }), let serviceID = Int32(service), serviceID > 0,
              devices.count == 1, let device = devices[0].value, !device.isEmpty, device.utf8.count <= 512,
              device.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0)
                  && !CharacterSet.controlCharacters.contains($0) }),
              apps.isEmpty || (apps.count == 1 && apps[0].value == applicationID) else { throw FeishuBotFailure.invalidResponse }
        let settings = reply.data.settings ?? FeishuConnectionSettings()
        try settings.validate()
        // Keep the signed query byte-for-byte; URLComponents is validation only.
        return Self(url: url, serviceID: serviceID, deviceID: device, settings: settings)
    }

    private struct Reply: Decodable {
        let code: Int
        let data: Payload
        struct Payload: Decodable {
            let url: String
            let settings: FeishuConnectionSettings?
            enum CodingKeys: String, CodingKey { case url = "URL", settings = "ClientConfig" }
        }
    }
}
