import Foundation

public enum ContextServiceError: Error, Sendable, Equatable {
    case principalMismatch
    case invalidLimit
    case invalidKey
}

/// Exact-match query over already-collected context. Semantic retrieval and long-term
/// memory are separate subsystems. Tenant identity is deliberately not part of the
/// query so models/callers cannot select a different principal through query data.
public struct ContextQuery: Sendable, Equatable {
    public let scope: ContextScope?
    public let key: String?
    public let trust: ContextTrustClass?
    public let origin: ContextOrigin?
    public let sessionID: UUID?
    public let deviceID: UUID?
    public let taskID: UUID?
    public let includeStale: Bool
    public let limit: Int

    public init(scope: ContextScope? = nil,
                key: String? = nil,
                trust: ContextTrustClass? = nil,
                origin: ContextOrigin? = nil,
                sessionID: UUID? = nil,
                deviceID: UUID? = nil,
                taskID: UUID? = nil,
                includeStale: Bool = false,
                limit: Int = 100) throws {
        guard (1...100).contains(limit) else { throw ContextServiceError.invalidLimit }
        if let key {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, key.utf8.count <= 256 else {
                throw ContextServiceError.invalidKey
            }
        }
        self.scope = scope
        self.key = key
        self.trust = trust
        self.origin = origin
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.taskID = taskID
        self.includeStale = includeStale
        self.limit = limit
    }
}

public protocol ContextServing: Sendable {
    func store(_ item: ContextItem, for principal: TenantContext) async throws
    func item(id: UUID, for principal: TenantContext) async -> ContextItem?
    func search(_ query: ContextQuery, for principal: TenantContext, at now: Date) async -> [ContextItem]
    func remove(id: UUID, for principal: TenantContext) async -> Bool
    func removeAll(for principal: TenantContext) async
    func count(for principal: TenantContext) async -> Int
}

/// Reference Context Service for portable/session state. It partitions storage by
/// exact principal before retrieval, so a request for one principal never scans a
/// global collection and filters another user's rows afterward.
///
/// This actor is intentionally in-memory. Durable/distributed storage can implement
/// `ContextServing` later while preserving these semantics and adding database-level
/// isolation. Long-term user memory belongs to the separate Memory Service.
public actor ContextService: ContextServing {
    private var partitions: [TenantContext: [UUID: ContextItem]] = [:]
    private let freshnessPolicy: ContextFreshnessPolicy

    public init(freshnessPolicy: ContextFreshnessPolicy) {
        self.freshnessPolicy = freshnessPolicy
    }

    public func store(_ item: ContextItem, for principal: TenantContext) throws {
        guard item.isOwned(by: principal) else { throw ContextServiceError.principalMismatch }
        partitions[principal, default: [:]][item.id] = item
    }

    public func item(id: UUID, for principal: TenantContext) -> ContextItem? {
        partitions[principal]?[id]
    }

    public func search(_ query: ContextQuery, for principal: TenantContext,
                       at now: Date = Date()) -> [ContextItem] {
        guard let partition = partitions[principal] else { return [] }

        let matches = partition.values.filter { item in
            if !query.includeStale, item.isStale(at: now, policy: freshnessPolicy) { return false }
            if let scope = query.scope, item.scope != scope { return false }
            if let key = query.key, item.key != key { return false }
            if let trust = query.trust, item.provenance.trust != trust { return false }
            if let origin = query.origin, item.provenance.origin != origin { return false }
            if let sessionID = query.sessionID, item.bindings.sessionID != sessionID { return false }
            if let deviceID = query.deviceID, item.bindings.deviceID != deviceID { return false }
            if let taskID = query.taskID, item.bindings.taskID != taskID { return false }
            return true
        }

        return matches.sorted { lhs, rhs in
            if lhs.freshness.observedAt != rhs.freshness.observedAt {
                return lhs.freshness.observedAt > rhs.freshness.observedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }.prefix(query.limit).map { $0 }
    }

    public func remove(id: UUID, for principal: TenantContext) -> Bool {
        guard var partition = partitions[principal] else { return false }
        guard partition.removeValue(forKey: id) != nil else { return false }
        if partition.isEmpty {
            partitions.removeValue(forKey: principal)
        } else {
            partitions[principal] = partition
        }
        return true
    }

    public func removeAll(for principal: TenantContext) {
        partitions.removeValue(forKey: principal)
    }

    public func count(for principal: TenantContext) -> Int {
        partitions[principal]?.count ?? 0
    }
}
