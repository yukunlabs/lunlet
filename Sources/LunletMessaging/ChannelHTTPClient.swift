// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-20, AC-20.04, AC-20.05, AC-20.06; US-12, AC-12.02.
import Foundation
import LunletCore

/// Provider-only network owner for one provider's exact hosts. No redirects, persistent
/// caches, cookies or raw network errors; provider-specific checks stay in each client.
public actor ChannelHTTPClient {
    private let session: URLSession
    private let allowedHosts: Set<String>
    private var closed = false
    public init(allowedHosts: Set<String>, configuration: URLSessionConfiguration = .ephemeral) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        session = HardenedHTTP.session(configuration: configuration, requestTimeout: 40, resourceTimeout: 45)
    }
    deinit { session.invalidateAndCancel() }
    /// `timeout` must cover a provider long poll, within the session's 40-second request limit.
    public func post(_ endpoint: URL, bearer: String? = nil, body: Data,
                     contentType: String = "application/json; charset=utf-8", timeout: TimeInterval = 15) async throws -> Data {
        guard !closed, !Task.isCancelled else { throw BotChannelFailure.canceled }
        guard validHTTP(endpoint), body.count <= 1_048_576, timeout > 0, timeout <= 40,
              bearer.map({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains(where: \.isWhitespace) }) ?? true else {
            throw BotChannelFailure.invalidCredentials
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.url == endpoint else { throw BotChannelFailure.invalidResponse }
            switch response.statusCode {
            case 200..<300: break
            case 401: throw BotChannelFailure.unauthorized
            case 403: throw BotChannelFailure.permissionDenied
            case 429: throw BotChannelFailure.rateLimited
            default: throw BotChannelFailure.unavailable
            }
            guard response.expectedContentLength <= 1_048_576 else { throw BotChannelFailure.invalidResponse }
            let data = try await HardenedHTTP.body(bytes, limit: 1_048_576, overflow: BotChannelFailure.invalidResponse)
            guard !closed, !Task.isCancelled else { throw BotChannelFailure.canceled }
            return data
        } catch {
            if closed || Task.isCancelled { throw BotChannelFailure.canceled }
            throw (error as? BotChannelFailure) ?? .unavailable
        }
    }
    /// Opens a socket only to a subdomain of an allowed host; callers apply their stricter provider check first.
    public func openSocket(_ endpoint: URL) throws -> any ChannelSocket {
        guard !closed, !Task.isCancelled else { throw BotChannelFailure.canceled }
        guard endpoint.scheme == "wss", let host = endpoint.host?.lowercased(),
              allowedHosts.contains(where: { host.hasSuffix("." + $0) }),
              Self.withoutCredentials(endpoint) else { throw BotChannelFailure.invalidCredentials }
        let task = session.webSocketTask(with: endpoint)
        task.maximumMessageSize = 1_048_576
        task.resume()
        return OwnedChannelSocket(task: task)
    }
    public func close() { guard !closed else { return }; closed = true; session.invalidateAndCancel() }
    private func validHTTP(_ endpoint: URL) -> Bool {
        endpoint.scheme == "https" && allowedHosts.contains(endpoint.host?.lowercased() ?? "") && Self.withoutCredentials(endpoint)
    }
    private static func withoutCredentials(_ endpoint: URL) -> Bool {
        endpoint.user == nil && endpoint.password == nil && endpoint.fragment == nil
            && (endpoint.port == nil || endpoint.port == 443)
    }
}

private final class OwnedChannelSocket: ChannelSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var pending: CheckedContinuation<URLSessionWebSocketTask.Message, any Error>?
    private var closed = false
    init(task: URLSessionWebSocketTask) { self.task = task }
    /// A pending receive is resumed by the socket's next message, by cancellation or by `close`, whichever comes
    /// first; the system task's own callback is not relied on to fire after a cancel, so no waiter outlives the socket.
    func receive() async throws -> Data {
        let message: URLSessionWebSocketTask.Message = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !closed, !Task.isCancelled, pending == nil else {
                    lock.unlock(); continuation.resume(throwing: BotChannelFailure.canceled); return
                }
                pending = continuation
                lock.unlock()
                task.receive { [weak self] result in self?.finish(result) }
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
            finish(.failure(BotChannelFailure.canceled))
        }
        switch message {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw BotChannelFailure.invalidResponse
        }
    }
    private func finish(_ result: Result<URLSessionWebSocketTask.Message, any Error>) {
        lock.lock(); let continuation = pending; pending = nil; let wasClosed = closed; lock.unlock()
        guard let continuation else { return }
        switch result {
        case .success(let message): continuation.resume(returning: message)
        case .failure(let error):
            continuation.resume(throwing: wasClosed || error as? BotChannelFailure == .canceled ? BotChannelFailure.canceled : .unavailable)
        }
    }
    func send(_ data: Data) async throws {
        guard !Task.isCancelled else { throw BotChannelFailure.canceled }
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { throw BotChannelFailure.invalidResponse }
        do { try await task.send(.string(text)) }
        catch { throw Task.isCancelled ? BotChannelFailure.canceled : BotChannelFailure.unavailable }
    }
    func close() {
        lock.lock(); closed = true; lock.unlock()
        task.cancel(with: .goingAway, reason: nil)
        finish(.failure(BotChannelFailure.canceled))
    }
    deinit { task.cancel(with: .goingAway, reason: nil) }
}
