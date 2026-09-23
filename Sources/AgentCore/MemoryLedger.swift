import Foundation

public enum MemoryValidationError: Error, Sendable, Equatable {
    case emptyScopeReference
    case unexpectedScopeReference
    case scopeReferenceTooLong
    case emptySourceReference
    case sourceReferenceTooLong
    case invalidConfidence
    case invalidLimit
    case emptyProviderName
    case providerNameTooLong
    case emptyProviderMemoryID
    case providerMemoryIDTooLong
    case duplicateSupersededMemory
    case selfSupersession
    case duplicateDerivedMemory
    case selfDerivation
    case inconsistentLifecycle
    case updatedBeforeCreated
}

public enum MemoryLedgerError: Error, Sendable, Equatable {
    case ownershipMismatch
    case duplicateMemory(UUID)
    case memoryNotFound(UUID)
    case derivedMemoryNotFound(UUID)
    case supersededMemoryNotFound(UUID)
    case memoryAlreadySuperseded(UUID)
    case supersessionScopeMismatch(UUID)
    case supersessionRequiresTransaction
    case supersessionRequiresTarget
    case nonActiveInsert
    case nonMonotonicSupersession(UUID)
    case providerMappingConflict
}

public enum MemoryScopeKind: String, Codable, Sendable, Hashable {
    case user
    case project
    case workspace
}

/// Long-term memory scope is independent from short-lived ContextScope. Private
/// user memory has no external scope reference; project/workspace scopes do.
public struct MemoryScope: Codable, Sendable, Hashable {
    public let kind: MemoryScopeKind
    public let referenceID: String?

    private enum CodingKeys: String, CodingKey { case kind, referenceID }

    public init(kind: MemoryScopeKind, referenceID: String? = nil) throws {
        if kind == .user {
            guard referenceID == nil else { throw MemoryValidationError.unexpectedScopeReference }
        } else {
            guard let referenceID else { throw MemoryValidationError.emptyScopeReference }
            let trimmed = referenceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw MemoryValidationError.emptyScopeReference }
            guard referenceID.utf8.count <= 256 else { throw MemoryValidationError.scopeReferenceTooLong }
        }
        self.kind = kind
        self.referenceID = referenceID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: values.decode(MemoryScopeKind.self, forKey: .kind),
            referenceID: values.decodeIfPresent(String.self, forKey: .referenceID)
        )
    }

    public static let user = MemoryScope(validatedKind: .user, referenceID: nil)

    public static func project(_ id: String) throws -> MemoryScope {
        try MemoryScope(kind: .project, referenceID: id)
    }

    public static func workspace(_ id: String) throws -> MemoryScope {
        try MemoryScope(kind: .workspace, referenceID: id)
    }

    private init(validatedKind: MemoryScopeKind, referenceID: String?) {
        kind = validatedKind
        self.referenceID = referenceID
    }
}

public enum MemoryKind: String, Codable, Sendable, Hashable {
    case sourceBacked = "source_backed"
    case derived
}

public enum MemorySourceType: String, Codable, Sendable, Hashable {
    case conversation
    case contextItem = "context_item"
    case connectedService = "connected_service"
    case file
    case userEntry = "user_entry"
    case importRecord = "import_record"
}

public struct MemorySourceReference: Codable, Sendable, Equatable, Hashable {
    public let type: MemorySourceType
    public let reference: String
    public let sourceTimestamp: Date?

    private enum CodingKeys: String, CodingKey { case type, reference, sourceTimestamp }

    public init(type: MemorySourceType, reference: String,
                sourceTimestamp: Date? = nil) throws {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MemoryValidationError.emptySourceReference }
        guard reference.utf8.count <= 1_024 else {
            throw MemoryValidationError.sourceReferenceTooLong
        }
        self.type = type
        self.reference = reference
        self.sourceTimestamp = sourceTimestamp
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            type: values.decode(MemorySourceType.self, forKey: .type),
            reference: values.decode(String.self, forKey: .reference),
            sourceTimestamp: values.decodeIfPresent(Date.self, forKey: .sourceTimestamp)
        )
    }
}

/// ACL enforcement is a later layer. Every memory is private at this milestone.
public enum MemoryVisibility: String, Codable, Sendable, Hashable {
    case privateUser = "private_user"
}

public enum MemoryLifecycleState: String, Codable, Sendable, Hashable {
    case active
    case superseded
}

/// Canonical provider-independent memory record. Provider-specific IDs and
/// embeddings never become part of canonical identity.
public struct MemoryRecord: Codable, Sendable, Equatable {
    public let id: UUID
    public let tenant: TenantContext
    public let scope: MemoryScope
    public let kind: MemoryKind
    public let content: JSONValue
    public let sourceReferences: [MemorySourceReference]
    public let derivedFromMemoryIDs: [UUID]
    public let confidence: Double?
    public let visibility: MemoryVisibility
    public let state: MemoryLifecycleState
    public let supersedes: [UUID]
    public let supersededBy: UUID?
    public let createdAt: Date
    public let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, tenant, scope, kind, content, sourceReferences,
             derivedFromMemoryIDs, confidence, visibility, state,
             supersedes, supersededBy, createdAt, updatedAt
    }

    public init(id: UUID = UUID(), tenant: TenantContext, scope: MemoryScope,
                kind: MemoryKind, content: JSONValue,
                sourceReferences: [MemorySourceReference] = [],
                derivedFromMemoryIDs: [UUID] = [], confidence: Double? = nil,
                visibility: MemoryVisibility = .privateUser,
                state: MemoryLifecycleState = .active,
                supersedes: [UUID] = [], supersededBy: UUID? = nil,
                createdAt: Date = Date(), updatedAt: Date? = nil) throws {
        if let confidence {
            guard confidence.isFinite, (0...1).contains(confidence) else {
                throw MemoryValidationError.invalidConfidence
            }
        }

        let uniqueSupersedes = Set(supersedes)
        guard uniqueSupersedes.count == supersedes.count else {
            throw MemoryValidationError.duplicateSupersededMemory
        }
        guard !uniqueSupersedes.contains(id) else {
            throw MemoryValidationError.selfSupersession
        }

        let uniqueDerived = Set(derivedFromMemoryIDs)
        guard uniqueDerived.count == derivedFromMemoryIDs.count else {
            throw MemoryValidationError.duplicateDerivedMemory
        }
        guard !uniqueDerived.contains(id) else {
            throw MemoryValidationError.selfDerivation
        }

        switch state {
        case .active:
            guard supersededBy == nil else { throw MemoryValidationError.inconsistentLifecycle }
        case .superseded:
            guard supersededBy != nil else { throw MemoryValidationError.inconsistentLifecycle }
        }

        let finalUpdatedAt = updatedAt ?? createdAt
        guard finalUpdatedAt >= createdAt else { throw MemoryValidationError.updatedBeforeCreated }

        self.id = id
        self.tenant = tenant
        self.scope = scope
        self.kind = kind
        self.content = content
        self.sourceReferences = sourceReferences
        self.derivedFromMemoryIDs = derivedFromMemoryIDs
        self.confidence = confidence
        self.visibility = visibility
        self.state = state
        self.supersedes = supersedes
        self.supersededBy = supersededBy
        self.createdAt = createdAt
        self.updatedAt = finalUpdatedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            tenant: values.decode(TenantContext.self, forKey: .tenant),
            scope: values.decode(MemoryScope.self, forKey: .scope),
            kind: values.decode(MemoryKind.self, forKey: .kind),
            content: values.decode(JSONValue.self, forKey: .content),
            sourceReferences: values.decode([MemorySourceReference].self, forKey: .sourceReferences),
            derivedFromMemoryIDs: values.decode([UUID].self, forKey: .derivedFromMemoryIDs),
            confidence: values.decodeIfPresent(Double.self, forKey: .confidence),
            visibility: values.decode(MemoryVisibility.self, forKey: .visibility),
            state: values.decode(MemoryLifecycleState.self, forKey: .state),
            supersedes: values.decode([UUID].self, forKey: .supersedes),
            supersededBy: values.decodeIfPresent(UUID.self, forKey: .supersededBy),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            updatedAt: values.decode(Date.self, forKey: .updatedAt)
        )
    }

    func replacingLifecycle(state: MemoryLifecycleState,
                            supersededBy: UUID?,
                            updatedAt: Date) throws -> MemoryRecord {
        try MemoryRecord(
            id: id,
            tenant: tenant,
            scope: scope,
            kind: kind,
            content: content,
            sourceReferences: sourceReferences,
            derivedFromMemoryIDs: derivedFromMemoryIDs,
            confidence: confidence,
            visibility: visibility,
            state: state,
            supersedes: supersedes,
            supersededBy: supersededBy,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

/// Replaceable provider mapping. Multiple providers can map to one canonical
/// memory, but one provider external ID cannot identify two canonical memories
/// inside the same principal partition.
public struct MemoryProviderMapping: Codable, Sendable, Equatable {
    public let memoryID: UUID
    public let provider: String
    public let providerMemoryID: String
    public let metadata: JSONValue?
    public let indexedAt: Date

    private enum CodingKeys: String, CodingKey {
        case memoryID, provider, providerMemoryID, metadata, indexedAt
    }

    public init(memoryID: UUID, provider: String, providerMemoryID: String,
                metadata: JSONValue? = nil, indexedAt: Date = Date()) throws {
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedProvider.isEmpty else { throw MemoryValidationError.emptyProviderName }
        guard normalizedProvider.utf8.count <= 128 else {
            throw MemoryValidationError.providerNameTooLong
        }
        let normalizedExternalID = providerMemoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedExternalID.isEmpty else {
            throw MemoryValidationError.emptyProviderMemoryID
        }
        guard normalizedExternalID.utf8.count <= 1_024 else {
            throw MemoryValidationError.providerMemoryIDTooLong
        }
        self.memoryID = memoryID
        self.provider = normalizedProvider
        self.providerMemoryID = normalizedExternalID
        self.metadata = metadata
        self.indexedAt = indexedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            memoryID: values.decode(UUID.self, forKey: .memoryID),
            provider: values.decode(String.self, forKey: .provider),
            providerMemoryID: values.decode(String.self, forKey: .providerMemoryID),
            metadata: values.decodeIfPresent(JSONValue.self, forKey: .metadata),
            indexedAt: values.decode(Date.self, forKey: .indexedAt)
        )
    }
}

public struct MemoryLedgerQuery: Sendable, Equatable {
    public let scope: MemoryScope?
    public let kinds: Set<MemoryKind>?
    public let includeSuperseded: Bool
    public let limit: Int

    public init(scope: MemoryScope? = nil, kinds: Set<MemoryKind>? = nil,
                includeSuperseded: Bool = false, limit: Int = 100) throws {
        guard (1...100).contains(limit) else { throw MemoryValidationError.invalidLimit }
        self.scope = scope
        self.kinds = kinds
        self.includeSuperseded = includeSuperseded
        self.limit = limit
    }
}

public struct PortableMemoryExport: Codable, Sendable, Equatable {
    public let formatVersion: Int
    public let exportedAt: Date
    public let memories: [MemoryRecord]
    public let providerMappings: [MemoryProviderMapping]

    public init(exportedAt: Date = Date(), memories: [MemoryRecord],
                providerMappings: [MemoryProviderMapping]) {
        formatVersion = 1
        self.exportedAt = exportedAt
        self.memories = memories
        self.providerMappings = providerMappings
    }
}

public protocol MemoryLedgerStoring: Sendable {
    func insert(_ record: MemoryRecord, as principal: TenantContext) async throws
    func memory(id: UUID, as principal: TenantContext) async -> MemoryRecord?
    func query(_ query: MemoryLedgerQuery, as principal: TenantContext) async -> [MemoryRecord]
    func supersede(with record: MemoryRecord, as principal: TenantContext,
                   at timestamp: Date) async throws
    func setProviderMapping(_ mapping: MemoryProviderMapping,
                            as principal: TenantContext) async throws
    func providerMappings(memoryID: UUID, as principal: TenantContext) async -> [MemoryProviderMapping]
    func export(as principal: TenantContext, at timestamp: Date) async -> PortableMemoryExport
}

/// In-memory canonical reference ledger. Durable storage will later implement the
/// same tenant-partition-first semantics plus database-level isolation.
public actor InMemoryMemoryLedger: MemoryLedgerStoring {
    private struct Partition: Sendable {
        var memories: [UUID: MemoryRecord] = [:]
        var mappings: [String: MemoryProviderMapping] = [:]
    }

    private var partitions: [TenantContext: Partition] = [:]

    public init() {}

    public func insert(_ record: MemoryRecord, as principal: TenantContext) throws {
        guard record.tenant.isSamePrincipal(as: principal) else {
            throw MemoryLedgerError.ownershipMismatch
        }
        guard record.state == .active, record.supersededBy == nil else {
            throw MemoryLedgerError.nonActiveInsert
        }
        guard record.supersedes.isEmpty else {
            throw MemoryLedgerError.supersessionRequiresTransaction
        }

        var partition = partitions[principal, default: Partition()]
        guard partition.memories[record.id] == nil else {
            throw MemoryLedgerError.duplicateMemory(record.id)
        }
        try validateDerivedReferences(record, in: partition)
        partition.memories[record.id] = record
        partitions[principal] = partition
    }

    public func memory(id: UUID, as principal: TenantContext) -> MemoryRecord? {
        partitions[principal]?.memories[id]
    }

    public func query(_ query: MemoryLedgerQuery,
                      as principal: TenantContext) -> [MemoryRecord] {
        guard let partition = partitions[principal] else { return [] }
        return partition.memories.values
            .filter { record in
                if !query.includeSuperseded, record.state != .active { return false }
                if let scope = query.scope, record.scope != scope { return false }
                if let kinds = query.kinds, !kinds.contains(record.kind) { return false }
                return true
            }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(query.limit)
            .map { $0 }
    }

    public func supersede(with record: MemoryRecord, as principal: TenantContext,
                          at timestamp: Date = Date()) throws {
        guard record.tenant.isSamePrincipal(as: principal) else {
            throw MemoryLedgerError.ownershipMismatch
        }
        guard record.state == .active, record.supersededBy == nil else {
            throw MemoryValidationError.inconsistentLifecycle
        }
        guard !record.supersedes.isEmpty else {
            throw MemoryLedgerError.supersessionRequiresTarget
        }
        guard timestamp >= record.createdAt else {
            throw MemoryLedgerError.nonMonotonicSupersession(record.id)
        }

        var partition = partitions[principal, default: Partition()]
        guard partition.memories[record.id] == nil else {
            throw MemoryLedgerError.duplicateMemory(record.id)
        }
        try validateDerivedReferences(record, in: partition)

        var oldRecords: [(UUID, MemoryRecord)] = []
        oldRecords.reserveCapacity(record.supersedes.count)
        for oldID in record.supersedes {
            guard let old = partition.memories[oldID] else {
                throw MemoryLedgerError.supersededMemoryNotFound(oldID)
            }
            guard old.state == .active else {
                throw MemoryLedgerError.memoryAlreadySuperseded(oldID)
            }
            guard old.scope == record.scope else {
                throw MemoryLedgerError.supersessionScopeMismatch(oldID)
            }
            guard timestamp >= old.updatedAt else {
                throw MemoryLedgerError.nonMonotonicSupersession(oldID)
            }
            oldRecords.append((oldID, old))
        }

        for (oldID, old) in oldRecords {
            partition.memories[oldID] = try old.replacingLifecycle(
                state: .superseded,
                supersededBy: record.id,
                updatedAt: timestamp
            )
        }
        partition.memories[record.id] = record
        partitions[principal] = partition
    }

    public func setProviderMapping(_ mapping: MemoryProviderMapping,
                                   as principal: TenantContext) throws {
        guard var partition = partitions[principal],
              partition.memories[mapping.memoryID] != nil else {
            throw MemoryLedgerError.memoryNotFound(mapping.memoryID)
        }

        let canonicalKey = Self.mappingKey(provider: mapping.provider, memoryID: mapping.memoryID)
        if let existing = partition.mappings[canonicalKey],
           existing.providerMemoryID != mapping.providerMemoryID {
            throw MemoryLedgerError.providerMappingConflict
        }
        if partition.mappings.values.contains(where: {
            $0.provider == mapping.provider &&
            $0.providerMemoryID == mapping.providerMemoryID &&
            $0.memoryID != mapping.memoryID
        }) {
            throw MemoryLedgerError.providerMappingConflict
        }

        partition.mappings[canonicalKey] = mapping
        partitions[principal] = partition
    }

    public func providerMappings(memoryID: UUID,
                                 as principal: TenantContext) -> [MemoryProviderMapping] {
        guard let partition = partitions[principal], partition.memories[memoryID] != nil else {
            return []
        }
        return partition.mappings.values
            .filter { $0.memoryID == memoryID }
            .sorted { lhs, rhs in
                if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
                return lhs.providerMemoryID < rhs.providerMemoryID
            }
    }

    public func export(as principal: TenantContext,
                       at timestamp: Date = Date()) -> PortableMemoryExport {
        let partition = partitions[principal] ?? Partition()
        let memories = partition.memories.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let mappings = partition.mappings.values.sorted { lhs, rhs in
            if lhs.memoryID != rhs.memoryID { return lhs.memoryID.uuidString < rhs.memoryID.uuidString }
            if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
            return lhs.providerMemoryID < rhs.providerMemoryID
        }
        return PortableMemoryExport(
            exportedAt: timestamp,
            memories: memories,
            providerMappings: mappings
        )
    }

    private func validateDerivedReferences(_ record: MemoryRecord,
                                           in partition: Partition) throws {
        for sourceID in record.derivedFromMemoryIDs {
            guard partition.memories[sourceID] != nil else {
                throw MemoryLedgerError.derivedMemoryNotFound(sourceID)
            }
        }
    }

    private static func mappingKey(provider: String, memoryID: UUID) -> String {
        "\(provider)|\(memoryID.uuidString)"
    }
}
