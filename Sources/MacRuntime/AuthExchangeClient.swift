import AgentCore
import Foundation

private final class RefuseAuthRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum AuthExchangeError: Error, Sendable, Equatable {
    case invalidEndpoint
    case invalidExternalToken
    case unauthenticated
    case unavailable
    case invalidResponse
}

/// Uses a short-lived external provider token only for the exchange request.
/// The returned opaque agent session is persisted through the injected store.
public actor AuthExchangeClient {
    private static let maxResponseBytes = 16_384
    private let endpoint: URL
    private let credentialStore: any AgentSessionCredentialStoring
    private let session: URLSession

    public init(endpoint: URL, credentialStore: any AgentSessionCredentialStoring) throws {
        try Self.validate(endpoint)
        self.endpoint = endpoint
        self.credentialStore = credentialStore
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: configuration,
                                  delegate: RefuseAuthRedirects(), delegateQueue: nil)
    }

    public func exchange(externalAccessToken: String) async throws -> AgentSessionCredential {
        guard Self.validExternalToken(externalAccessToken) else { throw AuthExchangeError.invalidExternalToken }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(externalAccessToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AuthExchangeError.unavailable }

        guard data.count <= Self.maxResponseBytes, let http = response as? HTTPURLResponse else {
            throw AuthExchangeError.invalidResponse
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard contentType.hasPrefix("application/json") else { throw AuthExchangeError.invalidResponse }
        if http.statusCode == 401 { throw AuthExchangeError.unauthenticated }
        if (500...599).contains(http.statusCode) { throw AuthExchangeError.unavailable }
        guard http.statusCode == 200 else { throw AuthExchangeError.invalidResponse }

        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw AuthExchangeError.invalidResponse }
        guard envelope.error == nil, let result = envelope.result,
              let expiry = Self.parseISO8601(result.expiresAt) else {
            throw AuthExchangeError.invalidResponse
        }
        let credential: AgentSessionCredential
        do { credential = try AgentSessionCredential(token: result.token, expiresAt: expiry, identity: result.identity) }
        catch { throw AuthExchangeError.invalidResponse }
        guard !credential.isExpired() else { throw AuthExchangeError.invalidResponse }
        do { try await credentialStore.save(credential) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AuthExchangeError.unavailable }
        return credential
    }

    public func logout() async throws {
        guard let credential = try await credentialStore.load() else { return }
        var request = URLRequest(url: endpoint.deletingLastPathComponent().appendingPathComponent("logout"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AuthExchangeError.invalidResponse }
            if http.statusCode != 200 && http.statusCode != 401 { throw AuthExchangeError.unavailable }
        } catch is CancellationError { throw CancellationError() }
        catch let error as AuthExchangeError { throw error }
        catch { throw AuthExchangeError.unavailable }
        try await credentialStore.clear()
    }

    private static func validate(_ endpoint: URL) throws {
        guard endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path == "/v1/auth/exchange", let scheme = endpoint.scheme?.lowercased(),
              let host = endpoint.host?.lowercased() else { throw AuthExchangeError.invalidEndpoint }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else { throw AuthExchangeError.invalidEndpoint }
    }

    private static func validExternalToken(_ token: String) -> Bool {
        let count = token.utf8.count
        return count >= 16 && count <= 16_384 && !token.contains(where: { $0.isWhitespace })
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private struct Envelope: Decodable {
        let result: ExchangeResult?
        let error: String?
    }
    private struct ExchangeResult: Decodable {
        let token: String
        let expiresAt: String
        let identity: TenantContext
    }
}
