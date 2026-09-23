import Foundation

public struct ContextQuery: Sendable, Equatable {
    public let scopeKinds: Set<ContextScopeKind>?
    public let keys: Set<String>?
    public let includeStale: Bool

    public init(scopeKinds: Set<ContextScopeKind>? = nil,
                keys: Set<String>? = nil,
                includeStale: Bool = false) {
        self.scopeKinds = scopeKinds
        self.keys = keys
        self.includeStale = includeStale
    }
}

public enum ContextServiceError: Error, Sendable, Equatable {
    case ownershipMismatch
}

public protocol ContextStoring: Sendable {
    func put(_ item: ContextItem, as principal: TenantContext) async throws
    func get(_ id: UUID, as principal: TenantContext) async -> ContextItem?
    func query(_ query: ContextQuery, as principal: TenantContext, now: Date) async -> [ContextItem]
    @discardableResult
    func remove(_ id: UUID, as principal: TenantContext) async -> Bool
}

/// Tenant-partitioned in-memory context store used by AgentCore and tests.
/// The top-level key is the trusted TenantContext, so searches never scan a
/// global pool and filter ownership afterward.
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
        var partition = itemsByPrincipal[principal, default: [:]]
        partition[item.id] = item
        itemsByPrincipal[principal] = partition
    }

    public func get(_ id: UUID, as principal: TenantContext) -> ContextItem? {
        itemsByPrincipal[principal]?[id]
    }

    public func query(_ query: ContextQuery, as principal: TenantContext,
                      now: Date = Date()) -> [ContextItem] {
        guard let partition = itemsByPrincipal[principal] else { return [] }

        return partition.values
            .filter { item in
                if let scopeKinds = query.scopeKinds,
                   !scopeKinds.contains(item.scope.kind) {
                    return false
                }
                if let keys = query.keys,
                   !keys.contains(item.key) {
                    return false
                }
                if !query.includeStale,
                   item.isStale(at: now, policy: freshnessPolicy) {
                    return false
                }
                return true
            }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.createdAt < $1.createdAt
            }
    }

    @discardableResult
    public func remove(_ id: UUID, as principal: TenantContext) -> Bool {
        guard var partition = itemsByPrincipal[principal] else { return false }
        let removed = partition.removeValue(forKey: id) != nil
        if partition.isEmpty {
            itemsByPrincipal.removeValue(forKey: principal)
        } else {
            itemsByPrincipal[principal] = partition
        }
        return removed
    }

    public func removeAll(as principal: TenantContext) {
        itemsByPrincipal.removeValue(forKey: principal)
    }
}
