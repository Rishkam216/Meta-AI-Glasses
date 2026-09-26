import Foundation

public enum MemoryContextError: Error, Sendable, Equatable {
    case invalidQuery
    case invalidLimit
    case invalidMaxBytes
    case invalidProviderID
    case ownershipMismatch
    case invalidResponse
}

/// The compiler can use canonical retrieval without a memory provider, or opt in
/// to one configured provider deployment. Provider choice is infrastructure
/// configuration, never authoritative model output.
public enum MemoryContextRetrievalStrategy: Sendable, Equatable {
    case canonical
    case provider(String)
}

/// Selective long-term-memory request. Tenant identity is deliberately absent;
/// the authenticated caller passes TenantContext separately.
public struct MemoryContextQuery: Sendable, Equatable {
    public let text: String
    public let scopes: Set<MemoryScope>
    public let limit: Int
    public let maxBytes: Int
    public let strategy: MemoryContextRetrievalStrategy

    public init(text: String,
                scopes: Set<MemoryScope>,
                limit: Int = 8,
                maxBytes: Int = 16_384,
                strategy: MemoryContextRetrievalStrategy = .canonical) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, text.utf8.count <= 4_096 else {
            throw MemoryContextError.invalidQuery
        }
        guard (1...16).contains(scopes.count) else {
            throw MemoryContextError.invalidQuery
        }
        guard (1...32).contains(limit) else {
            throw MemoryContextError.invalidLimit
        }
        guard (256...262_144).contains(maxBytes) else {
            throw MemoryContextError.invalidMaxBytes
        }
        if case .provider(let providerID) = strategy,
           !validMemoryProviderID(providerID) {
            throw MemoryContextError.invalidProviderID
        }
        self.text = text
        self.scopes = scopes
        self.limit = limit
        self.maxBytes = maxBytes
        self.strategy = strategy
    }
}

public protocol MemoryContextRetrieving: Sendable {
    func retrieve(_ query: MemoryContextQuery,
                  as principal: TenantContext,
                  now: Date) async throws -> [ContextItem]
}

/// Converts canonical MemoryService results into untrusted long-term context.
/// Raw source references and tenant identifiers are intentionally not copied into
/// provider-facing context. Canonical IDs and provenance categories are retained.
public struct MemoryContextRetriever: MemoryContextRetrieving, Sendable {
    private let service: MemoryService

    public init(service: MemoryService) {
        self.service = service
    }

    public func retrieve(_ query: MemoryContextQuery,
                         as principal: TenantContext,
                         now: Date = Date()) async throws -> [ContextItem] {
        let retrieved: [RetrievedMemory]
        do {
            retrieved = try await service.retrieveForContext(query, as: principal)
        } catch MemoryLedgerError.ownershipMismatch {
            throw MemoryContextError.ownershipMismatch
        } catch is CancellationError {
            throw CancellationError()
        }

        var seen: Set<UUID> = []
        var items: [ContextItem] = []
        var encodedBytes = 0
        let encoder = JSONEncoder()

        for result in retrieved {
            let record = result.record
            guard record.tenant == principal,
                  record.state == .active,
                  query.scopes.contains(record.scope),
                  seen.insert(record.id).inserted else {
                throw MemoryContextError.invalidResponse
            }

            let item = try contextItem(for: result, principal: principal, now: now)
            let size = try encoder.encode(item).count
            guard encodedBytes + size <= query.maxBytes else { continue }
            items.append(item)
            encodedBytes += size
            if items.count == query.limit { break }
        }

        return items
    }

    private func contextItem(for retrieved: RetrievedMemory,
                             principal: TenantContext,
                             now: Date) throws -> ContextItem {
        let record = retrieved.record
        let sourceTypes = Set(record.sourceReferences.map(\.type.rawValue)).sorted()
        let derivedIDs = record.derivedFromMemoryIDs
            .map { $0.uuidString.lowercased() }
            .sorted()

        let value: JSONValue = .object([
            "canonical_memory_id": .string(record.id.uuidString.lowercased()),
            "content": record.content,
            "memory_kind": .string(record.kind.rawValue),
            "confidence": record.confidence.map(JSONValue.number) ?? .null,
            "retrieval_score": .number(retrieved.score),
            "source_types": .array(sourceTypes.map(JSONValue.string)),
            "derived_from_memory_ids": .array(derivedIDs.map(JSONValue.string))
        ])

        return try ContextItem(
            id: record.id,
            tenant: principal,
            scope: contextScope(for: record.scope),
            key: "memory",
            value: value,
            provenance: ContextProvenance(
                origin: .memoryService,
                trust: .memory,
                sourceReference: "memory:\(record.id.uuidString.lowercased())"
            ),
            freshness: ContextFreshness(
                classification: .longTerm,
                observedAt: record.updatedAt
            ),
            bindings: .none,
            createdAt: record.createdAt
        )
    }

    private func contextScope(for scope: MemoryScope) throws -> ContextScope {
        switch scope.kind {
        case .user:
            return .user
        case .project:
            guard let referenceID = scope.referenceID else {
                throw MemoryContextError.invalidResponse
            }
            return try .project(referenceID)
        case .workspace:
            guard let referenceID = scope.referenceID else {
                throw MemoryContextError.invalidResponse
            }
            return try .workspace(referenceID)
        }
    }
}
