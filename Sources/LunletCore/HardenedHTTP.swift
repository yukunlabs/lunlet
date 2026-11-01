// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-01, AC-01.02, AC-01.04; US-14, AC-14.01, AC-14.03.
// Refs: US-20, AC-20.04, AC-20.05, AC-20.06; US-12, AC-12.02.
import Foundation

/// Refuses every HTTP redirect, because provider endpoints are exact. Subclasses may add
/// delegate behavior but must keep their own state lock-protected or immutable.
open class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    override public init() { super.init() }

    open func urlSession(_ session: URLSession, task: URLSessionTask,
                         willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                         completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Network hardening shared by every provider client: no persistent caches, cookies or
/// stored credentials, no redirects, and response bodies read only up to a fixed bound.
public enum HardenedHTTP {
    /// A nil resource timeout keeps the system default, for long-lived sockets.
    public static func session(configuration: URLSessionConfiguration = .ephemeral, requestTimeout: TimeInterval,
                               resourceTimeout: TimeInterval?, delegate: RedirectBlocker = RedirectBlocker()) -> URLSession {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        if let resourceTimeout { configuration.timeoutIntervalForResource = resourceTimeout }
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Reads at most `limit` bytes and throws `overflow` for a longer body.
    public static func body(_ bytes: URLSession.AsyncBytes, limit: Int, overflow: any Error) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw overflow }
            data.append(byte)
        }
        return data
    }
}
