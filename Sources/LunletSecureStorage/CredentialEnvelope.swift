// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.02; US-20, AC-20.04; US-36, AC-36.04; US-26, AC-26.02; US-14, AC-14.01.
import CryptoKit
import Foundation
import IOKit
import Security

/// The secret the credential file's key is derived from, with its kind recorded in each sealed file.
///
/// Owner decision of 2026-11-01: an unsigned build has no place a process running as the user cannot reach (the
/// Keychain pins items to the build, the Secure Enclave and the data-protection keychain need a provisioned signing
/// identity), so the key is bound to this Mac and this user account instead. A copy of the file on another Mac or
/// under another account, a backup or a secret scanner sees no token; a process running as the user is not kept
/// out, and the documentation says so. A signed release can add a Keychain or Secure Enclave binding without
/// changing the file format.
public struct CredentialBinding: Sendable {
    public let kind: String
    private let source: @Sendable () throws -> Data

    init(kind: String, source: @escaping @Sendable () throws -> Data) { self.kind = kind; self.source = source }

    /// This Mac's hardware UUID and the current user's numeric ID.
    public static let machine = CredentialBinding(kind: "machine") {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != IO_OBJECT_NULL else { throw SecureStorageFailure(status: errSecNotAvailable) }
        defer { IOObjectRelease(entry) }
        let property = IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        guard let uuid = property?.takeRetainedValue() as? String, !uuid.isEmpty else {
            throw SecureStorageFailure(status: errSecNotAvailable)
        }
        return Data("\(uuid)\n\(getuid())".utf8)
    }

    /// Fixed material for tests; never a default.
    public static func fixed(_ material: Data) -> CredentialBinding { CredentialBinding(kind: "fixed") { material } }

    public func material() throws -> Data { try source() }
}

/// The sealed file: a JSON object whose `sealed` field holds the AES-GCM nonce, ciphertext and tag of the payload
/// under a key derived with HKDF-SHA256 from the binding's material, a fresh per-save salt and the service name.
/// The header fields are authenticated with the payload, so a file renamed to another service, or edited, is refused.
enum CredentialEnvelope {
    static let format = "com.lunlet.credential-envelope"
    static let version = 1
    private static let saltBytes = 32

    static func isEnvelope(_ object: [String: Any]) -> Bool { object["format"] as? String == format }

    static func seal(_ payload: Data, service: String, binding: CredentialBinding) throws -> Data {
        var salt = Data(count: saltBytes)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltBytes, $0.baseAddress!) }
        guard status == errSecSuccess else { throw SecureStorageFailure(status: status) }
        let key = try key(service: service, binding: binding, salt: salt)
        let box: AES.GCM.SealedBox
        do { box = try AES.GCM.seal(payload, using: key, authenticating: authenticated(service: service, kind: binding.kind)) }
        catch { throw SecureStorageFailure(status: errSecInternalError) }
        guard let combined = box.combined else { throw SecureStorageFailure(status: errSecInternalError) }
        let object: [String: Any] = ["format": format, "version": version, "binding": binding.kind,
                                     "salt": salt.base64EncodedString(), "sealed": combined.base64EncodedString()]
        do { return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        catch { throw SecureStorageFailure(status: errSecInternalError) }
    }

    static func open(_ object: [String: Any], service: String, binding: CredentialBinding) throws -> Data {
        guard object["version"] as? Int == version, let kind = object["binding"] as? String, kind == binding.kind,
              let salt = (object["salt"] as? String).flatMap({ Data(base64Encoded: $0) }), salt.count == saltBytes,
              let sealed = (object["sealed"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let box = try? AES.GCM.SealedBox(combined: sealed) else { throw SecureStorageFailure(status: errSecDecode) }
        let key = try key(service: service, binding: binding, salt: salt)
        do { return try AES.GCM.open(box, using: key, authenticating: authenticated(service: service, kind: kind)) }
        catch { throw SecureStorageFailure(status: errSecDecode) }
    }

    private static func key(service: String, binding: CredentialBinding, salt: Data) throws -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: try binding.material()), salt: salt,
                               info: Data("com.lunlet.credentials/\(version)/\(service)".utf8), outputByteCount: 32)
    }

    private static func authenticated(service: String, kind: String) -> Data {
        Data("\(format)\n\(version)\n\(kind)\n\(service)".utf8)
    }
}
