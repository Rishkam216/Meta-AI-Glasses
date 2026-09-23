import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Read-only preparation for Supermemory integration. The current direct API
/// cannot prove our durable revision-fence contract, so MemoryService rejects
/// this provider. No mutation is sent and no synchronization receipt is issued.
public struct SupermemoryProvider: MemoryProvider {
    public let descriptor: MemoryProviderDescriptor
    private let principal: TenantContext
    private let readsEnabled: Bool
    private let credential: @Sendable () throws -> String
    private let transport: any SupermemoryTransport

    public init(id: String, principal: TenantContext, readsEnabled: Bool = false,
                credential: @escaping @Sendable () throws -> String) throws {
        try self.init(id: id, principal: principal, readsEnabled: readsEnabled,
                      credential: credential, transport: SupermemoryHTTPTransport())
    }

    init(id: String, principal: TenantContext, readsEnabled: Bool = false,
         credential: @escaping @Sendable () throws -> String,
         transport: any SupermemoryTransport) throws {
        descriptor = try MemoryProviderDescriptor(id: id, capabilities: .init(
            namespaceIsolation: true, scopeFiltering: true,
            idempotentRevisionFencing: false, search: true, profile: false))
        self.principal = principal
        self.readsEnabled = readsEnabled
        self.credential = credential
        self.transport = transport
    }

    public func apply(_ mutation: MemoryProviderMutation) async throws -> MemoryProviderReceipt {
        throw MemoryProviderError.unsupportedFeature
    }

    /// Explicit diagnostic read path while service integration remains gated.
    /// These references are untrusted; callers must resolve them through the
    /// canonical ledger before consuming any memory. No provider text is returned.
    public func searchReferences(_ query: MemorySearchQuery, as caller: TenantContext) async throws -> MemoryProviderResults {
        try await search(query, in: MemoryProviderNamespace(principal: caller))
    }

    public func search(_ query: MemorySearchQuery, in namespace: MemoryProviderNamespace) async throws -> MemoryProviderResults {
        guard namespace == MemoryProviderNamespace(principal: principal) else {
            throw MemoryProviderError.invalidQuery
        }
        guard readsEnabled else { throw MemoryProviderError.unsupportedFeature }
        do {
            try Task.checkCancellation()
            let token = try credential()
            guard !token.isEmpty, token.utf8.count <= 4_096,
                  token.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw MemoryProviderError.invalidConfiguration
            }
            let scopes = try Set(query.scopes.map(Self.scopeToken))
            let tag = Self.containerTag(principal)
            func condition(_ key: String, _ value: String) -> [String: Any] {
                ["key": key, "value": value, "filterType": "metadata", "ignoreCase": false]
            }
            let body: [String: Any] = [
                "q": query.text, "containerTag": tag, "limit": query.limit,
                "includeFullDocs": false, "includeSummary": false,
                "onlyMatchingChunks": true, "rewriteQuery": false, "rerank": false,
                "filters": ["AND": [
                    condition("ag_namespace", tag),
                    condition("ag_deployment", descriptor.id),
                    ["OR": scopes.sorted().map { condition("ag_scope", $0) }]
                ]]
            ]
            var request = URLRequest(url: URL(string: "https://api.supermemory.ai/v3/search")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let data = try await transport.send(request)
            try Task.checkCancellation()
            guard data.count <= SupermemoryHTTPTransport.maximumResponseBytes else {
                throw MemoryProviderError.invalidResponse
            }
            let response = try JSONDecoder().decode(SearchResponse.self, from: data)
            guard response.results.count <= query.limit else { throw MemoryProviderError.invalidResponse }
            var seen = Set<UUID>()
            var remoteIDs = Set<String>()
            let hits = try response.results.map { item -> MemoryProviderHit in
                guard item.metadata.ag_namespace == tag,
                      item.metadata.ag_deployment == descriptor.id,
                      scopes.contains(item.metadata.ag_scope),
                      let canonicalID = UUID(uuidString: item.metadata.ag_id),
                      seen.insert(canonicalID).inserted,
                      remoteIDs.insert(item.documentId).inserted,
                      !item.documentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      item.documentId.utf8.count <= 1_024,
                      item.score.isFinite, (0...1).contains(item.score) else {
                    throw MemoryProviderError.invalidResponse
                }
                return MemoryProviderHit(canonicalID: canonicalID, providerMemoryID: item.documentId, score: item.score)
            }
            return MemoryProviderResults(namespace: namespace, hits: hits)
        } catch is CancellationError { throw CancellationError() }
        catch let error as MemoryProviderError { throw error }
        catch is DecodingError { throw MemoryProviderError.invalidResponse }
        catch { throw MemoryProviderError.unavailable }
    }

    /// Injective UUID encoding, 99 ASCII characters at most (vendor limit: 100).
    /// Stable identifiers are partition keys, not anonymization or credentials.
    static func containerTag(_ principal: TenantContext) -> String {
        func compact(_ id: UUID) -> String { id.uuidString.lowercased().replacingOccurrences(of: "-", with: "") }
        return "n" + compact(principal.tenantID) + "_" + compact(principal.userID)
            + "_" + (principal.accountID.map(compact) ?? "none")
    }

    static func scopeToken(_ scope: MemoryScope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(scope).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct SearchResponse: Decodable { let results: [Item] }
    private struct Item: Decodable {
        let documentId: String
        let score: Double
        let metadata: Metadata
    }
    private struct Metadata: Decodable {
        let ag_namespace: String
        let ag_deployment: String
        let ag_scope: String
        let ag_id: String
    }
}

protocol SupermemoryTransport: Sendable {
    func send(_ request: URLRequest) async throws -> Data
}

struct SupermemoryHTTPTransport: SupermemoryTransport {
    static let maximumResponseBytes = 1_048_576
    func send(_ request: URLRequest) async throws -> Data {
        try await SupermemoryRequest().send(request)
    }
}

/// One session per bounded request: no shared cookies, cache, credentials,
/// redirects, automatic application retries, or provider body logging.
/// The lock protects cancellation and delegate callbacks, including completion.
final class SupermemoryRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var finished = false

    func send(_ request: URLRequest, configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                configuration.timeoutIntervalForRequest = 15
                configuration.timeoutIntervalForResource = 15
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.continuation = continuation
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation, session = session, task = task
        self.continuation = nil; self.session = nil; self.task = nil
        data.removeAll(keepingCapacity: false)
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            completionHandler(.cancel)
            finish(.failure(MemoryProviderError.unavailable))
            return
        }
        guard response.mimeType?.lowercased() == "application/json",
              response.expectedContentLength <= Int64(SupermemoryHTTPTransport.maximumResponseBytes) else {
            completionHandler(.cancel)
            finish(.failure(MemoryProviderError.invalidResponse))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard chunk.count <= SupermemoryHTTPTransport.maximumResponseBytes - data.count else {
            lock.unlock()
            finish(.failure(MemoryProviderError.invalidResponse))
            return
        }
        data.append(chunk)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if error != nil {
            finish(.failure(MemoryProviderError.unavailable))
        } else {
            let received = lock.withLock { data }
            finish(.success(received))
        }
    }
}
