// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.02, AC-01.04, AC-01.05.
// Refs: US-11, AC-11.01, AC-11.02; US-12, AC-12.02, AC-12.04.
import Foundation
import Testing
@testable import LunletFeishu

struct ConnectionEndpointTests {
    private func reply(_ url: String, settings: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["code": 0, "msg": "ok", "data": ["URL": url, "ClientConfig": settings]])
    }

    @Test func preservesTheSignedURLAndUsesDocumentedSecondUnits() throws {
        let url = "wss://stream.synthetic.invalid/ws/v2?device_id=synthetic&service_id=42&app_id=cli_synthetic&ticket=a%2Fb+%3D&x=1&x=2"
        let endpoint = try FeishuConnectionEndpoint.decode(reply(url, settings: ["PingInterval": 60, "ReconnectCount": 3,
                                                                                "ReconnectInterval": 1, "ReconnectNonce": 0]), applicationID: "cli_synthetic")
        #expect(endpoint.url.absoluteString == url)
        #expect(endpoint.serviceID == 42 && endpoint.deviceID == "synthetic")
        #expect(endpoint.settings.pingSeconds == 60 && endpoint.settings.reconnectCount == 3)
        #expect(endpoint.settings.reconnectSeconds == 1 && endpoint.settings.reconnectJitterSeconds == 0)
        #expect(!String(describing: endpoint).contains("ticket"))
    }

    @Test func absentConfigurationUsesOnlyTheDocumentedSDKDefaults() throws {
        let endpoint = try FeishuConnectionEndpoint.decode(reply("wss://stream.synthetic.invalid/ws?device_id=d&service_id=42"), applicationID: "cli_synthetic")
        #expect(endpoint.settings.pingSeconds == 120 && endpoint.settings.reconnectCount == -1)
        #expect(endpoint.settings.reconnectSeconds == 120 && endpoint.settings.reconnectJitterSeconds == 30)
    }

    @Test(arguments: [
        "ws://stream.synthetic.invalid/ws?device_id=d&service_id=42",
        "wss://user@stream.synthetic.invalid/ws?device_id=d&service_id=42",
        "wss://stream.synthetic.invalid/ws?device_id=d&service_id=42#",
        "wss://stream.synthetic.invalid/ws?device_id=d&service_id=0",
        "wss://stream.synthetic.invalid/ws?device_id=d&service_id=2147483648",
        "wss://stream.synthetic.invalid/ws?device_id=d&service_id=42&service_id=43",
        "wss://stream.synthetic.invalid/ws?device_id=d&device_id=other&service_id=42",
        "wss://stream.synthetic.invalid/ws?device_id=&service_id=42",
        "wss://stream.synthetic.invalid/ws?device_id=d&service_id=42&app_id=cli_other",
    ]) func rejectsUnsafeEndpointsAndAmbiguousConnectionIdentities(_ url: String) throws {
        let data = try reply(url)
        #expect(throws: FeishuBotFailure.invalidResponse) { try FeishuConnectionEndpoint.decode(data, applicationID: "cli_synthetic") }
    }

    @Test(arguments: ["zero", "boolean", "negative", "excessive"])
    func invalidHeartbeatConfigurationCannotCreateAConnection(_ variant: String) throws {
        let value: Any = variant == "boolean" ? true : variant == "zero" ? 0 : variant == "negative" ? -1 : 3601
        let data = try reply("wss://stream.synthetic.invalid/ws?device_id=d&service_id=42", settings: ["PingInterval": value])
        #expect(throws: FeishuBotFailure.invalidResponse) { try FeishuConnectionEndpoint.decode(data, applicationID: "cli_synthetic") }
    }
}
