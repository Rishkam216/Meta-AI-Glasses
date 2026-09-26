import Foundation

/// Failures exposed by the remote canonical snapshot boundary. The transport must
/// sanitize server/network errors before they reach this layer; memory payloads,
/// SQL, credentials and provider responses must never appear in error text.
public enum CanonicalMemoryStoreError: Error, Sendable, Equatable {
    case unauthenticated
    case forbidden
    case invalidRequest
    case stateConflict
    case unavailable
    case invalidResponse
}

/// One authenticated principal's complete canonical MemoryServiceLedger state.
/// Revision zero is the only valid representation of an uninitialized store and
/// must carry a nil snapshot.
public struct CanonicalMemoryRemoteState: Codable, Sendable, Equatable {
    public let revision: UInt64
    public let snapshot: PortableMemoryExport?

    public init(revision: UInt64, snapshot: PortableMemoryExport?) {
        self.revision = revision
        self.snapshot = snapshot
    }
}

/// Provider-neutral persistence boundary. Authentication and network details live
/// in a platform/server adapter; AgentCore only requires load + compare-and-swap.
public protocol CanonicalMemorySnapshotStore: Sendable {
    func load() async throws -> CanonicalMemoryRemoteState
    func commit(_ snapshot: PortableMemoryExport, expectedRevision: UInt64) async throws -> UInt64
}

/// Cloud-backed MemoryServiceLedger. Swift's already-tested MemoryLedgerState
/// remains the semantic authority for lineage, supersession, deletion families,
/// provider mappings and provider synchronization. The remote store persists the
/// resulting v3 snapshot atomically and detects concurrent writers with CAS.
public actor RemoteMemoryServiceLedger: MemoryServiceLedger {
    private static let maxSafeRevision: UInt64 = 9_007_199_254_740_991
    private static let conflictAttempts = 4

    private let principal: TenantContext
    private let store: any CanonicalMemorySnapshotStore

    public init(principal: TenantContext, store: any CanonicalMemorySnapshotStore) {
        self.principal = principal
        self.store = store
    }

    public func insert(_ record: MemoryRecord, as principal: TenantContext) async throws {
        try requireOwner(principal)
        try await mutate { state in try state.insert(record, as: principal) }
    }

    public func memory(id: UUID, as principal: TenantContext) async throws -> MemoryRecord? {
        try requireOwner(principal)
        let (_, state) = try await loadState()
        return state.memory(id: id, as: principal)
    }

    public func query(_ query: MemoryLedgerQuery, as principal: TenantContext) async throws -> [MemoryRecord] {
        try requireOwner(principal)
        let (_, state) = try await loadState()
        return state.query(query, as: principal)
    }

    public func supersede(with record: MemoryRecord, as principal: TenantContext,
                          at timestamp: Date) async throws {
        try requireOwner(principal)
        try await mutate { state in
            try state.supersede(with: record, as: principal, at: timestamp)
        }
    }

    public func setProviderMapping(_ mapping: MemoryProviderMapping,
                                   as principal: TenantContext) async throws {
        try requireOwner(principal)
        try await mutate { state in try state.setProviderMapping(mapping, as: principal) }
    }

    public func providerMappings(memoryID: UUID,
                                 as principal: TenantContext) async throws -> [MemoryProviderMapping] {
        try requireOwner(principal)
        let (_, state) = try await loadState()
        return state.providerMappings(memoryID: memoryID, as: principal)
    }

    public func export(as principal: TenantContext, at timestamp: Date) async throws -> PortableMemoryExport {
        try requireOwner(principal)
        let (_, state) = try await loadState()
        return state.export(as: principal, at: timestamp)
    }

    public func forget(id: UUID, as principal: TenantContext, at timestamp: Date) async throws {
        try requireOwner(principal)
        try await mutate { state in try state.forget(id: id, as: principal, at: timestamp) }
    }

    public func enrollProviders(_ providers: Set<String>, as principal: TenantContext) async throws {
        try requireOwner(principal)
        try await mutate { state in try state.enrollProviders(providers, as: principal) }
    }

    public func remember(_ record: MemoryRecord, replacing: Bool, providers: Set<String>,
                         as principal: TenantContext, at timestamp: Date) async throws {
        try requireOwner(principal)
        try await mutate { state in
            try state.remember(record, replacing: replacing, providers: providers,
                               as: principal, at: timestamp)
        }
    }

    public func forget(id: UUID, providers: Set<String>, as principal: TenantContext,
                       at timestamp: Date) async throws {
        try requireOwner(principal)
        try await mutate { state in
            try state.forget(id: id, providers: providers, as: principal, at: timestamp)
        }
    }

    public func markAttempt(_ entry: MemorySyncEntry, as principal: TenantContext,
                            at timestamp: Date) async throws -> Bool {
        try requireOwner(principal)
        return try await mutate { state in
            try state.markAttempt(entry, as: principal, at: timestamp)
        }
    }

    public func acknowledge(_ entry: MemorySyncEntry, providerMemoryID: String?,
                            as principal: TenantContext, at timestamp: Date) async throws -> Bool {
        try requireOwner(principal)
        return try await mutate { state in
            try state.acknowledge(entry, providerMemoryID: providerMemoryID,
                                  as: principal, at: timestamp)
        }
    }

    private func requireOwner(_ caller: TenantContext) throws {
        guard caller == principal else { throw MemoryLedgerError.ownershipMismatch }
    }

    private func loadState() async throws -> (UInt64, MemoryLedgerState) {
        let remote = try await store.load()
        guard remote.revision <= Self.maxSafeRevision,
              (remote.revision == 0) == (remote.snapshot == nil) else {
            throw CanonicalMemoryStoreError.invalidResponse
        }
        guard let snapshot = remote.snapshot else { return (0, MemoryLedgerState()) }
        do {
            return (remote.revision, try MemoryLedgerState(restoring: snapshot, as: principal))
        } catch {
            // A malformed/foreign remote snapshot is storage corruption, not a
            // caller validation failure. Never try to repair it by overwriting it.
            throw CanonicalMemoryStoreError.invalidResponse
        }
    }

    private func mutate<T: Sendable>(
        _ operation: @Sendable (inout MemoryLedgerState) throws -> T
    ) async throws -> T {
        for attempt in 0..<Self.conflictAttempts {
            try Task.checkCancellation()
            let (revision, loaded) = try await loadState()
            var state = loaded
            let comparisonTime = Date(timeIntervalSince1970: 0)
            let before = state.export(as: principal, at: comparisonTime)
            let result = try operation(&state)
            let after = state.export(as: principal, at: comparisonTime)

            // Idempotent retries that discover the desired state already present
            // must not create meaningless remote revisions.
            if before == after { return result }

            let snapshot = state.export(as: principal, at: Date())
            do {
                let committed = try await store.commit(snapshot, expectedRevision: revision)
                guard committed == revision + 1, committed <= Self.maxSafeRevision else {
                    throw CanonicalMemoryStoreError.invalidResponse
                }
                return result
            } catch CanonicalMemoryStoreError.stateConflict {
                if attempt + 1 == Self.conflictAttempts { throw CanonicalMemoryStoreError.stateConflict }
                continue
            }
        }
        throw CanonicalMemoryStoreError.stateConflict
    }
}
