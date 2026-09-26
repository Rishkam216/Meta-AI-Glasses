import AgentCore
import Foundation

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Native macOS transport for the canonical memory backend. It is deliberately
/// small: AgentCore owns memory semantics; this type owns HTTPS/loopback HTTP,
/// bearer authentication, bounded JSON and sanitized status mapping.
public actor HTTPMemorySnapshotStore: CanonicalMemorySnapshotStore {
    public typealias BearerTokenProvider = @Sendable () async throws -> String

    private static let maxResponseBytes = 8_500_000
    private let endpoint: URL
    private let tokenProvider: BearerTokenProvider
    private let session: URLSession

    public init(endpoint: URL, bearerTokenProvider: @escaping BearerTokenProvider) throws {
        try Self.validate(endpoint)
        self.endpoint = endpoint
        self.tokenProvider = bearerTokenProvider
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: configuration,
                                  delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public init(endpoint: URL, bearerToken: String) throws {
        try Self.validate(endpoint)
        guard Self.validToken(bearerToken) else { throw CanonicalMemoryStoreError.unauthenticated }
        self.endpoint = endpoint
        self.tokenProvider = { bearerToken }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: configuration,
                                  delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public func load() async throws -> CanonicalMemoryRemoteState {
        let body = try JSONEncoder().encode(LoadRequest())
        return try await perform(body, as: CanonicalMemoryRemoteState.self)
    }

    public func commit(_ snapshot: PortableMemoryExport,
                       expectedRevision: UInt64) async throws -> UInt64 {
        guard expectedRevision <= 9_007_199_254_740_990 else {
            throw CanonicalMemoryStoreError.invalidRequest
        }
        let body = try JSONEncoder().encode(CommitRequest(
            input: CommitInput(expectedRevision: expectedRevision, snapshot: snapshot)
        ))
        let result = try await perform(body, as: CommitResult.self)
        return result.revision
    }

    private func perform<T: Decodable>(_ body: Data, as type: T.Type) async throws -> T {
        let token: String
        do { token = try await tokenProvider() }
        catch is CancellationError { throw CancellationError() }
        catch let error as CanonicalMemoryStoreError { throw error }
        catch { throw CanonicalMemoryStoreError.unavailable }
        guard Self.validToken(token) else { throw CanonicalMemoryStoreError.unauthenticated }

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw CanonicalMemoryStoreError.unavailable }

        guard data.count <= Self.maxResponseBytes,
              let http = response as? HTTPURLResponse else {
            throw CanonicalMemoryStoreError.invalidResponse
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard contentType.hasPrefix("application/json") else {
            throw CanonicalMemoryStoreError.invalidResponse
        }

        if http.statusCode == 200 {
            let envelope: SuccessEnvelope<T>
            do { envelope = try JSONDecoder().decode(SuccessEnvelope<T>.self, from: data) }
            catch { throw CanonicalMemoryStoreError.invalidResponse }
            guard envelope.error == nil, let result = envelope.result else {
                throw CanonicalMemoryStoreError.invalidResponse
            }
            return result
        }

        let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error)
        switch http.statusCode {
        case 400, 413, 415:
            throw CanonicalMemoryStoreError.invalidRequest
        case 401:
            throw CanonicalMemoryStoreError.unauthenticated
        case 403:
            throw CanonicalMemoryStoreError.forbidden
        case 409 where code == "state_conflict":
            throw CanonicalMemoryStoreError.stateConflict
        case 409:
            throw CanonicalMemoryStoreError.invalidRequest
        case 500...599:
            throw CanonicalMemoryStoreError.unavailable
        default:
            throw CanonicalMemoryStoreError.invalidResponse
        }
    }

    private static func validate(_ endpoint: URL) throws {
        guard endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path == "/v1/memory", let scheme = endpoint.scheme?.lowercased(),
              let host = endpoint.host?.lowercased() else {
            throw CanonicalMemoryStoreError.invalidRequest
        }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw CanonicalMemoryStoreError.invalidRequest
        }
    }

    private static func validToken(_ token: String) -> Bool {
        guard token.utf8.count == 43 else { return false }
        return token.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) ||
            (97...122).contains(byte) || byte == 45 || byte == 95
        }
    }

    private struct LoadRequest: Encodable { let operation = "canonical_load" }
    private struct CommitInput: Encodable {
        let expectedRevision: UInt64
        let snapshot: PortableMemoryExport
    }
    private struct CommitRequest: Encodable {
        let operation = "canonical_commit"
        let input: CommitInput
    }
    private struct CommitResult: Decodable { let revision: UInt64 }
    private struct SuccessEnvelope<T: Decodable>: Decodable {
        let result: T?
        let error: String?
    }
    private struct ErrorEnvelope: Decodable { let error: String }
}
