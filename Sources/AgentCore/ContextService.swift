import Foundation

public enum ContextServiceError: Error, Sendable, Equatable {
    case ownershipMismatch
    case invalidLimit
    case invalidKey
}

/// Exact-match query over already-collected context. Tenant identity is not part
/// of the query; the trusted caller passes `TenantContext` separately.
public struct ContextQuery: Sendable, Equatable {
    public let exactScope: ContextScope?
    public let scopeKinds: Set<ContextScopeKind>?
    public let keys: Set<String>?
    public let trust: Set<ContextTrustClass>?
    public let origins: Set<ContextOrigin>?
    public let freshnessClasses: Set<ContextFreshnessClass>?
    public let sessionID: UUID?
    public let deviceID: UUID?
    public let taskID: UUID?
    public let includeStale: Bool
    public let onlyStale: Bool
    public let limit: Int

    public init(exactScope: ContextScope? = nil,
                scopeKinds: Set<ContextScopeKind>? = nil,
                keys: Set<String>? = nil,
                trust: Set<ContextTrustClass>? = nil,
                origins: Set<ContextOrigin>? = nil,
                freshnessClasses: Set<ContextFreshnessClass>? = nil,
                sessionID: UUID? = nil,
                deviceID: UUID? = nil,
                taskID: UUID? = nil,
                includeStale: Bool = false,
                onlyStale: Bool = false,
                limit: Int = 100) throws {
        guard (1...100).contains(limit) else { throw ContextServiceError.invalidLimit }
        if let keys {
            for key in keys {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, key.utf8.count <= 256 else {
                    throw ContextServiceError.invalidKey
                }
            }
        }
        self.exactScope = exactScope
        self.scopeKinds = scopeKinds
        self.keys = keys
        self.trust = trust
        self.origins = origins
        self.freshnessClasses = freshnessClasses
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.taskID = taskID
        self.includeStale = includeStale
        self.onlyStale = onlyStale
        self.limit = limit
    }

    func matches(_ item: ContextItem,
                 freshnessPolicy: ContextFreshnessPolicy,
                 now: Date) -> Bool {
        let isStale = item.isStale(at: now, policy: freshnessPolicy)
        if onlyStale {
            if !isStale { return false }
        } else if !includeStale, isStale {
            return false
        }
        if let exactScope, item.scope != exactScope {
            return false
        }
        if let scopeKinds, !scopeKinds.contains(item.scope.kind) {
            return false
        }
        if let keys, !keys.contains(item.key) {
            return false
        }
        if let trust, !trust.contains(item.provenance.trust) {
            return false
        }
        if let origins, !origins.contains(item.provenance.origin) {
            return false
        }
        if let freshnessClasses,
           !freshnessClasses.contains(item.freshness.classification) {
            return false
        }
        if let sessionID, item.bindings.sessionID != sessionID {
            return false
        }
        if let deviceID, item.bindings.deviceID != deviceID {
            return false
        }
        if let taskID, item.bindings.taskID != taskID {
            return false
        }
        return true
    }
}

func orderedContextItems<S: Sequence>(_ items: S,
                                      matching query: ContextQuery,
                                      freshnessPolicy: ContextFreshnessPolicy,
                                      now: Date) -> [ContextItem]
where S.Element == ContextItem {
    items.filter { query.matches($0, freshnessPolicy: freshnessPolicy, now: now) }
        .sorted { lhs, rhs in
            if lhs.freshness.observedAt != rhs.freshness.observedAt {
                return lhs.freshness.observedAt > rhs.freshness.observedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        .prefix(query.limit)
        .map { $0 }
}

public protocol ContextStoring: Sendable {
    func put(_ item: ContextItem, as principal: TenantContext) async throws
    func get(_ id: UUID, as principal: TenantContext) async -> ContextItem?
    func query(_ query: ContextQuery, as principal: TenantContext, now: Date) async -> [ContextItem]
    @discardableResult
    func remove(_ id: UUID, as principal: TenantContext) async -> Bool
    func removeAll(as principal: TenantContext) async
    func count(as principal: TenantContext) async -> Int
}

/// Tenant-partitioned in-memory reference implementation. Durable/distributed
/// implementations must preserve the same partition-before-filter semantics.
public actor InMemoryContextService: ContextStoring {
    private var itemsByPrincipal: [TenantContext: [UUID: ContextItem]] = [:]
    private let freshnessPolicy: ContextFreshnessPolicy

    public init(freshnessPolicy: ContextFreshnessPolicy = try! ContextFreshnessPolicy()) {
        self.freshnessPolicy = freshnessPolicy
    }

    public func put(_ item: ContextItem, as principal: TenantContext) throws {
        guard item.isOwned(by: principal) else {
            throw ContextServiceError.ownershipMismatch
        }
        itemsByPrincipal[principal, default: [:]][item.id] = item
    }

    public func get(_ id: UUID, as principal: TenantContext) -> ContextItem? {
        itemsByPrincipal[principal]?[id]
    }

    public func query(_ query: ContextQuery, as principal: TenantContext,
                      now: Date = Date()) -> [ContextItem] {
        guard let partition = itemsByPrincipal[principal] else { return [] }
        return orderedContextItems(
            partition.values,
            matching: query,
            freshnessPolicy: freshnessPolicy,
            now: now
        )
    }

    @discardableResult
    public func remove(_ id: UUID, as principal: TenantContext) -> Bool {
        guard var partition = itemsByPrincipal[principal] else { return false }
        guard partition.removeValue(forKey: id) != nil else { return false }
        if partition.isEmpty {
            itemsByPrincipal.removeValue(forKey: principal)
        } else {
            itemsByPrincipal[principal] = partition
        }
        return true
    }

    public func removeAll(as principal: TenantContext) {
        itemsByPrincipal.removeValue(forKey: principal)
    }

    public func count(as principal: TenantContext) -> Int {
        itemsByPrincipal[principal]?.count ?? 0
    }
}
