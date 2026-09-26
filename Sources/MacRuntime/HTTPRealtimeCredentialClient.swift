import Foundation

public enum RealtimeCredentialClientError: Error, Sendable, Equatable {
    case invalidEndpoint
    case unauthenticated
    case forbidden
    case unavailable
    case invalidResponse
}

private final class RealtimeCredentialRefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Retrieves a short-lived Realtime credential from our authenticated backend.
/// The standard OpenAI API key never enters this process or the Mac Keychain.
public actor HTTPRealtimeCredentialClient {
    public typealias BearerTokenProvider = @Sendable () async throws -> String

    private static let maxResponseBytes = 16 * 1_024
    private let endpoint: URL
    private let expectedModel: String
    private let tokenProvider: BearerTokenProvider
    private let session: URLSession

    public init(endpoint: URL,
                expectedModel: String = "gpt-realtime-2.1",
                bearerTokenProvider: @escaping BearerTokenProvider) throws {
        try Self.validate(endpoint)
        guard Self.validModel(expectedModel) else {
            throw RealtimeCredentialClientError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.expectedModel = expectedModel
        self.tokenProvider = bearerTokenProvider

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        self.session = URLSession(
            configuration: configuration,
            delegate: RealtimeCredentialRefuseRedirects(),
            delegateQueue: nil
        )
    }

    // Internal seam preserves production transport policy while allowing native
    // tests to inject a URLProtocol-backed ephemeral URLSession.
    init(endpoint: URL,
         expectedModel: String = "gpt-realtime-2.1",
         bearerTokenProvider: @escaping BearerTokenProvider,
         session: URLSession) throws {
        try Self.validate(endpoint)
        guard Self.validModel(expectedModel) else {
            throw RealtimeCredentialClientError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.expectedModel = expectedModel
        self.tokenProvider = bearerTokenProvider
        self.session = session
    }

    public func credential() async throws -> String {
        let agentToken: String
        do {
            agentToken = try await tokenProvider()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RealtimeCredentialClientError {
            throw error
        } catch {
            throw RealtimeCredentialClientError.unauthenticated
        }
        guard Self.validAgentToken(agentToken) else {
            throw RealtimeCredentialClientError.unauthenticated
        }

        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(agentToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RealtimeCredentialClientError.unavailable
        }

        guard data.count <= Self.maxResponseBytes,
              let http = response as? HTTPURLResponse else {
            throw RealtimeCredentialClientError.invalidResponse
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard contentType.hasPrefix("application/json") else {
            throw RealtimeCredentialClientError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            let envelope: SuccessEnvelope
            do { envelope = try JSONDecoder().decode(SuccessEnvelope.self, from: data) }
            catch { throw RealtimeCredentialClientError.invalidResponse }
            guard envelope.error == nil,
                  let result = envelope.result,
                  result.model == expectedModel,
                  Self.validCredential(result.credential) else {
                throw RealtimeCredentialClientError.invalidResponse
            }
            return result.credential
        case 401:
            throw RealtimeCredentialClientError.unauthenticated
        case 403:
            throw RealtimeCredentialClientError.forbidden
        case 400, 413, 415:
            throw RealtimeCredentialClientError.invalidResponse
        case 500...599:
            throw RealtimeCredentialClientError.unavailable
        default:
            throw RealtimeCredentialClientError.invalidResponse
        }
    }

    private static func validate(_ endpoint: URL) throws {
        guard endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil,
              endpoint.path == "/v1/realtime/credential",
              let scheme = endpoint.scheme?.lowercased(),
              let host = endpoint.host?.lowercased() else {
            throw RealtimeCredentialClientError.invalidEndpoint
        }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw RealtimeCredentialClientError.invalidEndpoint
        }
    }

    private static func validAgentToken(_ token: String) -> Bool {
        guard token.utf8.count == 43 else { return false }
        return token.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) ||
            (97...122).contains(byte) || byte == 45 || byte == 95
        }
    }

    private static func validCredential(_ credential: String) -> Bool {
        guard (8...(8 * 1_024)).contains(credential.utf8.count),
              credential == credential.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return credential.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7E
        }
    }

    private static func validModel(_ model: String) -> Bool {
        guard (1...128).contains(model.utf8.count) else { return false }
        return model.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) ||
            (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 95
        }
    }

    private struct ResultBody: Decodable {
        let credential: String
        let model: String
        let expiresAt: Int64?
    }

    private struct SuccessEnvelope: Decodable {
        let result: ResultBody?
        let error: String?
    }
}
