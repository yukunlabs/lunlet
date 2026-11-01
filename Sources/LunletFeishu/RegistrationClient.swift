// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-14, AC-14.01, AC-14.02, AC-14.03, AC-14.06.
// Refs: US-01, AC-01.01, AC-01.02, AC-01.04, AC-01.05.
import Foundation
import LunletCore

public actor RegistrationClient {
    private let flow = RegistrationFlow()
    private var diagnostic = DiagnosticOperation()
    private let session: URLSession
    private let uptime: @Sendable () -> TimeInterval

    public init() {
        self.init(configuration: .ephemeral, uptime: { ProcessInfo.processInfo.systemUptime })
    }

    init(configuration: URLSessionConfiguration, uptime: @escaping @Sendable () -> TimeInterval) {
        session = HardenedHTTP.session(configuration: configuration, requestTimeout: 20, resourceTimeout: 20)
        self.uptime = uptime
    }

    deinit { session.invalidateAndCancel() }

    public func requestCode() async throws -> RegistrationCode {
        try Task.checkCancellation()
        diagnostic = DiagnosticOperation()
        DiagnosticLog.record(.registration, component: .feishu, outcome: .started, operation: diagnostic)
        let state = try await perform(flow.begin(now: uptime()))
        switch state {
        case .awaitingAuthorization(let code): return code
        case .failed(let error): throw error
        default: throw RegistrationFailure.invalidResponse
        }
    }

    public func pollAuthorization() async throws -> RegistrationState {
        try Task.checkCancellation()
        let previous = flow.state
        guard let request = flow.poll(now: uptime()) else {
            if case .awaitingAuthorization = previous, case .failed(let error) = flow.state {
                FeishuDiagnostics.failure(.registration, operation: diagnostic, error: error)
            }
            return flow.state
        }
        return try await perform(request)
    }

    public func pollingDelay() -> TimeInterval? { flow.pollingDelay(now: uptime()) }
    public func cancel() {
        switch flow.state {
        case .requestingCode, .awaitingAuthorization:
            DiagnosticLog.record(.registration, component: .feishu, outcome: .cancelled, operation: diagnostic)
        default: break
        }
        flow.cancel()
    }

    private func perform(_ request: RegistrationRequest) async throws -> RegistrationState {
        let diagnostic = diagnostic
        let attempt = flow.attemptID
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request.urlRequest)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw RegistrationFailure.invalidResponse }
            let data = try await HardenedHTTP.body(bytes, limit: 65_536, overflow: RegistrationFailure.invalidResponse)
            try Task.checkCancellation()
            guard flow.receive(data, status: response.statusCode, requestID: request.id, now: uptime()) else {
                throw CancellationError()
            }
            switch flow.state {
            case .authorized:
                DiagnosticLog.record(.registration, component: .feishu, outcome: .completed, operation: diagnostic)
            case .failed(let error): FeishuDiagnostics.failure(.registration, operation: diagnostic, error: error)
            default: break
            }
            return flow.state
        } catch {
            FeishuDiagnostics.failure(.registration, operation: diagnostic, error: error)
            guard flow.attemptID == attempt else { throw CancellationError() }
            if error is CancellationError || Task.isCancelled {
                flow.cancel()
                throw CancellationError()
            }
            let failure = (error as? RegistrationFailure) ?? .networkUnavailable
            flow.transportFailed(requestID: request.id, failure: failure)
            throw failure
        }
    }
}
