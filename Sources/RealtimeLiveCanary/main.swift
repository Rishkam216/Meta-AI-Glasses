import AgentCore
import Darwin
import Foundation
import MacRuntime

private enum LiveCanaryError: Error, Sendable, CustomStringConvertible {
    case missingAPIKey
    case invalidAPIKey
    case secretMintFailed
    case invalidSecretResponse
    case timeout
    case providerClosed
    case unexpectedToolIntent
    case providerFailure(String)
    case tooManyEvents
    case responseTooLarge
    case markerMissing

    var description: String {
        switch self {
        case .missingAPIKey: return "missing_api_key"
        case .invalidAPIKey: return "invalid_api_key"
        case .secretMintFailed: return "secret_mint_failed"
        case .invalidSecretResponse: return "invalid_secret_response"
        case .timeout: return "timeout"
        case .providerClosed: return "provider_closed"
        case .unexpectedToolIntent: return "unexpected_tool_intent"
        case .providerFailure(let code): return "provider_failure_\(code)"
        case .tooManyEvents: return "too_many_events"
        case .responseTooLarge: return "response_too_large"
        case .markerMissing: return "marker_missing"
        }
    }
}

private struct ClientSecretResponse: Decodable {
    let value: String
    let expiresAt: Int?

    enum CodingKeys: String, CodingKey {
        case value
        case expiresAt = "expires_at"
    }
}

private let realtimeModel = "gpt-realtime-2.1"
private let marker = "CANARY_OK"
private let maxMintResponseBytes = 64 * 1_024
private let maxAssistantBytes = 512
private let maxProviderEvents = 24
private let totalTimeoutNanoseconds: UInt64 = 25_000_000_000

@main
private struct RealtimeLiveCanary {
    static func main() async {
        do {
            try await withTimeout(totalTimeoutNanoseconds) {
                try await runCanary()
            }
            print("REALTIME_LIVE_CANARY_OK")
        } catch {
            fputs("REALTIME_LIVE_CANARY_FAILED: \(safeError(error))\n", stderr)
            exit(1)
        }
    }

    private static func runCanary() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["OPENAI_API_KEY"], !apiKey.isEmpty else {
            throw LiveCanaryError.missingAPIKey
        }
        guard validSecret(apiKey, maxBytes: 8 * 1_024) else {
            throw LiveCanaryError.invalidAPIKey
        }

        let ephemeralCredential = try await mintClientSecret(apiKey: apiKey)

        let provider = try OpenAIRealtimeProvider(
            model: realtimeModel,
            credentialProvider: { ephemeralCredential }
        )
        let session = try await provider.openSession(agentSessionID: UUID())

        do {
            let compiledContext = try await emptyRealtimeContext()
            let turnID = UUID()

            try await session.send(.turnContext(RealtimeTurnContext(
                turnID: turnID,
                context: compiledContext,
                capabilities: []
            )))
            try await session.send(.userText(RealtimeUserText(
                turnID: turnID,
                text: "Reply with exactly CANARY_OK and nothing else."
            )))

            var assistant = ""
            for _ in 0..<maxProviderEvents {
                try Task.checkCancellation()
                guard let event = try await session.nextEvent() else {
                    throw LiveCanaryError.providerClosed
                }

                switch event {
                case .assistantText(let text):
                    guard text.turnID == turnID else { continue }
                    assistant += text.text
                    guard assistant.utf8.count <= maxAssistantBytes else {
                        throw LiveCanaryError.responseTooLarge
                    }

                case .turnCompleted(let completed):
                    guard completed.turnID == turnID else { continue }
                    await session.close()
                    guard assistant.contains(marker) else {
                        throw LiveCanaryError.markerMissing
                    }
                    return

                case .toolIntent:
                    throw LiveCanaryError.unexpectedToolIntent

                case .failure(let failure):
                    throw LiveCanaryError.providerFailure(failure.code)
                }
            }

            throw LiveCanaryError.tooManyEvents
        } catch {
            await session.close()
            throw error
        }
    }

    private static func mintClientSecret(apiKey: String) async throws -> String {
        guard let endpoint = URL(string: "https://api.openai.com/v1/realtime/client_secrets") else {
            throw LiveCanaryError.secretMintFailed
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("agent_realtime_live_canary", forHTTPHeaderField: "OpenAI-Safety-Identifier")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "session": [
                "type": "realtime",
                "model": realtimeModel
            ]
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LiveCanaryError.secretMintFailed
        }

        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            throw LiveCanaryError.secretMintFailed
        }
        guard data.count <= maxMintResponseBytes else {
            throw LiveCanaryError.invalidSecretResponse
        }

        let decoded: ClientSecretResponse
        do {
            decoded = try JSONDecoder().decode(ClientSecretResponse.self, from: data)
        } catch {
            throw LiveCanaryError.invalidSecretResponse
        }
        guard validSecret(decoded.value, maxBytes: 8 * 1_024) else {
            throw LiveCanaryError.invalidSecretResponse
        }
        if let expiresAt = decoded.expiresAt {
            let now = Int(Date().timeIntervalSince1970)
            guard expiresAt > now else {
                throw LiveCanaryError.invalidSecretResponse
            }
        }
        return decoded.value
    }

    private static func emptyRealtimeContext() async throws -> CompiledContext {
        let store = InMemoryContextService()
        let compiler = ContextCompiler(store: store)
        let principal = TenantContext(tenantID: UUID(), userID: UUID())
        let request = try ContextCompilationRequest(
            consumer: .realtime,
            includeUserScope: true,
            maxItems: 1,
            maxBytes: 1_024,
            refreshStaleEphemeral: false,
            maxRefreshItems: 0
        )
        return try await compiler.compile(request, as: principal)
    }

    private static func validSecret(_ value: String, maxBytes: Int) -> Bool {
        guard value.utf8.count >= 8,
              value.utf8.count <= maxBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f ||
            CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    private static func safeError(_ error: Error) -> String {
        if let error = error as? LiveCanaryError {
            return error.description
        }
        if let error = error as? OpenAIRealtimeError {
            switch error {
            case .invalidEndpoint: return "invalid_endpoint"
            case .invalidModel: return "invalid_model"
            case .invalidCredential: return "invalid_credential"
            case .credentialUnavailable: return "credential_unavailable"
            case .invalidState: return "invalid_state"
            case .handshakeTimeout: return "handshake_timeout"
            case .handshakeFailed: return "handshake_failed"
            case .responseTooLarge: return "response_too_large"
            case .invalidResponse: return "invalid_response"
            case .providerFailure(let code): return "provider_failure_\(code)"
            }
        }
        if let error = error as? URLError {
            return "url_error_\(error.code.rawValue)"
        }
        if error is CancellationError {
            return "cancelled"
        }
        return "unexpected_error"
    }
}

private func withTimeout<T: Sendable>(
    _ nanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw LiveCanaryError.timeout
        }

        guard let first = try await group.next() else {
            throw LiveCanaryError.timeout
        }
        group.cancelAll()
        return first
    }
}
