import Foundation

public enum MemoryProviderError: Error, Sendable, Equatable {
    case invalidConfiguration
    case invalidQuery
    case unsupportedFeature
    case invalidResponse
    case unavailable
    case documentTooLarge
    case synchronizationBusy
}

/// Identifies a stable provider deployment/index generation, not merely a vendor.
/// Change this ID when intentionally building a new index from the canonical ledger.
public struct MemoryProviderDescriptor: Sendable, Equatable {
    public let id: String
    public let capabilities: MemoryProviderCapabilities
    public let maxDocumentBytes: Int
    public let maxResults: Int

    public init(id: String, capabilities: MemoryProviderCapabilities,
                maxDocumentBytes: Int = 32_768, maxResults: Int = 100) throws {
        guard validMemoryProviderID(id), (256...1_048_576).contains(maxDocumentBytes),
              (1...100).contains(maxResults) else { throw MemoryProviderError.invalidConfiguration }
        self.id = id
        self.capabilities = capabilities
        self.maxDocumentBytes = maxDocumentBytes
        self.maxResults = maxResults
    }
}

public struct MemoryProviderCapabilities: Sendable, Equatable {
    public let namespaceIsolation: Bool
    public let scopeFiltering: Bool
    public let idempotentRevisionFencing: Bool
    public let search: Bool
    public let profile: Bool

    public init(namespaceIsolation: Bool, scopeFiltering: Bool,
                idempotentRevisionFencing: Bool, search: Bool, profile: Bool = false) {
        self.namespaceIsolation = namespaceIsolation
        self.scopeFiltering = scopeFiltering
        self.idempotentRevisionFencing = idempotentRevisionFencing
        self.search = search
        self.profile = profile
    }
}

func validMemoryProviderID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
        (97...122).contains($0) || (48...57).contains($0) || [45, 46, 58, 95].contains($0)
    }
}

/// Derived only from the authenticated principal by MemoryService. Every adapter
/// must constrain its remote container BEFORE retrieval, not search globally.
public struct MemoryProviderNamespace: Sendable, Hashable {
    public let value: String
    init(principal: TenantContext) {
        value = "v1.\(principal.tenantID.uuidString.lowercased()).\(principal.userID.uuidString.lowercased()).\(principal.accountID?.uuidString.lowercased() ?? "none")"
    }
}

public struct MemorySearchQuery: Sendable, Equatable {
    public let text: String
    public let scopes: Set<MemoryScope>
    public let limit: Int

    public init(text: String, scopes: Set<MemoryScope>, limit: Int = 10) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 4_096, (1...16).contains(scopes.count),
              (1...100).contains(limit) else { throw MemoryProviderError.invalidQuery }
        self.text = text
        self.scopes = scopes
        self.limit = limit
    }
}

/// Minimum provider payload: no account IDs, raw source references, private
/// provider metadata, conversation dump, or authorization fields.
public struct MemoryProviderDocument: Codable, Sendable, Equatable {
    public let canonicalID: UUID
    public let scope: MemoryScope
    public let kind: MemoryKind
    public let content: JSONValue
    public let confidence: Double?

    init(_ record: MemoryRecord) {
        canonicalID = record.id; scope = record.scope; kind = record.kind
        content = record.content; confidence = record.confidence
    }
}

public enum MemorySyncAction: String, Codable, Sendable { case upsert, delete }

public struct MemoryProviderMutation: Sendable, Equatable {
    public let namespace: MemoryProviderNamespace
    public let canonicalID: UUID
    public let revision: UInt64
    public let operationID: UUID
    public let action: MemorySyncAction
    public let document: MemoryProviderDocument?
}

public struct MemoryProviderReceipt: Sendable, Equatable {
    public let namespace: MemoryProviderNamespace
    public let canonicalID: UUID
    public let revision: UInt64
    public let operationID: UUID
    public let action: MemorySyncAction
    public let providerMemoryID: String?

    public init(namespace: MemoryProviderNamespace, canonicalID: UUID, revision: UInt64,
                operationID: UUID, action: MemorySyncAction, providerMemoryID: String? = nil) {
        self.namespace = namespace; self.canonicalID = canonicalID; self.revision = revision
        self.operationID = operationID; self.action = action; self.providerMemoryID = providerMemoryID
    }
}

/// Providers return references/scores, never authoritative facts or instructions.
public struct MemoryProviderHit: Sendable, Equatable {
    public let canonicalID: UUID
    public let providerMemoryID: String
    public let score: Double
    public init(canonicalID: UUID, providerMemoryID: String, score: Double) {
        self.canonicalID = canonicalID; self.providerMemoryID = providerMemoryID; self.score = score
    }
}

public struct MemoryProviderResults: Sendable, Equatable {
    public let namespace: MemoryProviderNamespace
    public let hits: [MemoryProviderHit]
    public init(namespace: MemoryProviderNamespace, hits: [MemoryProviderHit]) {
        self.namespace = namespace; self.hits = hits
    }
}

/// Adapter requirements:
/// - Namespace AND requested scopes are applied before candidate retrieval.
/// - apply is idempotent per namespace/canonicalID/revision. Lower revisions must
///   never replace higher ones; deletion fences survive deletion of the document.
/// - A receipt means the revision fence is committed, not merely queued.
/// - Timeouts/cancellation must be implemented by the adapter's transport.
/// - Provider SDK types and raw exceptions never cross this boundary.
/// A vendor lacking these guarantees needs an enforcing adapter/gateway; do not
/// advertise capabilities it cannot demonstrate with real integration tests.
public protocol MemoryProvider: Sendable {
    var descriptor: MemoryProviderDescriptor { get }
    func apply(_ mutation: MemoryProviderMutation) async throws -> MemoryProviderReceipt
    func search(_ query: MemorySearchQuery, in namespace: MemoryProviderNamespace) async throws -> MemoryProviderResults
    func profile(scopes: Set<MemoryScope>, limit: Int, in namespace: MemoryProviderNamespace) async throws -> MemoryProviderResults
}

public extension MemoryProvider {
    func profile(scopes: Set<MemoryScope>, limit: Int, in namespace: MemoryProviderNamespace) async throws -> MemoryProviderResults {
        throw MemoryProviderError.unsupportedFeature
    }
}
