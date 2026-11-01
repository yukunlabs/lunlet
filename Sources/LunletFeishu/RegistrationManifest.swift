// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.01, AC-01.03, AC-01.05, AC-01.07.
import Foundation
import zlib

enum RegistrationManifest {
    static func verificationURL(_ url: URL) throws -> URL {
        let hosts = ["open.feishu.cn", "accounts.feishu.cn", "open.larksuite.com", "accounts.larksuite.com"]
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", hosts.contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443 else {
            throw RegistrationFailure.invalidResponse
        }
        let manifest: [String: Any] = [
            "preset": false,
            "scopes": ["tenant": ["im:message:send_as_bot"]],
            "callbacks": ["items": ["card.action.trigger"]],
        ]
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let encoded = try gzip(json).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let additions = [
            "from": "sdk", "tp": "sdk", "source": "lunlet", "name": "Lunlet",
            "desc": "Continue existing Codex CLI sessions from Feishu",
            "addons": encoded,
        ]
        var items = (parts.queryItems ?? []).filter { additions[$0.name] == nil && $0.name != "createOnly" }
        items += additions.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        parts.queryItems = items
        guard let result = parts.url else { throw RegistrationFailure.invalidResponse }
        return result
    }

    private static func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8,
                            Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RegistrationFailure.invalidResponse
        }
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(data.count))))
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw RegistrationFailure.invalidResponse }
        return Data(output.prefix(Int(stream.total_out)))
    }
}
