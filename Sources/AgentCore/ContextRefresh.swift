import Foundation

public enum ContextRefreshSourceKind: String, Codable, Sendable, Hashable {
    case deviceRuntime = "device_runtime"
    case application
    case connectedService = "connected_service"
}

public enum ContextRefreshError: Error, Sendable, Equatable {
    case invalidAdapterID
    case duplicateAdapterID(String)
    case ambiguousAdapters([String])
    case ownershipMismatch
}

/// Tenant-free description of a context item that needs to be refreshed. The
/// authoritative principal is passed separately by trusted backend code.
public struct ContextRefreshTarget: Sendable, Equatable {
    public let itemID: UUID
    public let scope: ContextScope
    public let key: String
    public let bindings: ContextBindings
    public let freshnessClass: ContextFreshnessClass
    public let priorSourceReference: String?

    public init(item: ContextItem) {
        itemID = item.id
        scope = item.scope
        key = item.key
        bindings = item.bindings
        freshnessClass = item.freshness.classification
        priorSourceReference = item.provenance.sourceReference
    }
}

/// Adapter output intentionally contains no tenant, scope, key, bindings, trust,
/// or origin fields. Those security-sensitive fields are preserved or assigned by
/// ContextRefreshCoordinator rather than accepted from provider data.
public struct ContextRefreshValue: Sendable, Equatable {
    public let value: JSONValue
    public let observedAt: Date
    public let validUntil: Date?
    public let sourceReference: String?

    public init(value: JSONValue, observedAt: Date = Date(),
                validUntil: Date? = nil, sourceReference: String? = nil) {
        self.value = value
        self.observedAt = observedAt
        self.validUntil = validUntil
        self.sourceReference = sourceReference
    }
}

public protocol ContextRefreshAdapter: Sendable {
    var adapterID: String { get }
    var sourceKind: ContextRefreshSourceKind { get }
    func supports(_ target: ContextRefreshTarget) -> Bool
    func refresh(_ target: ContextRefreshTarget,
                 as principal: TenantContext,
                 now: Date) async throws -> ContextRefreshValue?
}

public protocol ApplicationContextAdapter: ContextRefreshAdapter {}

public extension ApplicationContextAdapter {
    var sourceKind: ContextRefreshSourceKind { .application }
}

public protocol ConnectedServiceContextAdapter: ContextRefreshAdapter {}

public extension ConnectedServiceContextAdapter {
    var sourceKind: ContextRefreshSourceKind { .connectedService }
}

public protocol DeviceRuntimeContextAdapter: ContextRefreshAdapter {}

public extension DeviceRuntimeContextAdapter {
    var sourceKind: ContextRefreshSourceKind { .deviceRuntime }
}

public enum ContextRefreshOutcome: Sendable, Equatable {
    case refreshed(ContextItem)
    case unsupported
}

public protocol ContextRefreshing: Sendable {
    func refresh(_ item: ContextItem,
                 as principal: TenantContext,
                 now: Date) async throws -> ContextRefreshOutcome
}

/// Refreshes already-known context in place. It never searches across tenants and
/// never lets an adapter change item ownership/scope/key/bindings or assign trust.
public actor ContextRefreshCoordinator: ContextRefreshing {
    private let store: any ContextStoring
    private var adapters: [String: any ContextRefreshAdapter] = [:]

    public init(store: any ContextStoring) {
        self.store = store
    }

    public func register(_ adapter: any ContextRefreshAdapter) throws {
        let trimmed = adapter.adapterID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, adapter.adapterID.utf8.count <= 128 else {
            throw ContextRefreshError.invalidAdapterID
        }
        guard adapters[adapter.adapterID] == nil else {
            throw ContextRefreshError.duplicateAdapterID(adapter.adapterID)
        }
        adapters[adapter.adapterID] = adapter
    }

    public func refresh(_ item: ContextItem,
                        as principal: TenantContext,
                        now: Date = Date()) async throws -> ContextRefreshOutcome {
        guard item.isOwned(by: principal) else {
            throw ContextRefreshError.ownershipMismatch
        }

        let target = ContextRefreshTarget(item: item)
        let matches = adapters.values
            .filter { $0.supports(target) }
            .sorted { $0.adapterID < $1.adapterID }

        guard !matches.isEmpty else { return .unsupported }
        guard matches.count == 1, let adapter = matches.first else {
            throw ContextRefreshError.ambiguousAdapters(matches.map(\.adapterID))
        }

        // Copy the selected adapter before awaiting provider work so actor
        // reentrancy cannot change which adapter owns this refresh mid-flight.
        guard let refreshed = try await adapter.refresh(
            target,
            as: principal,
            now: now
        ) else {
            return .unsupported
        }

        let provenance: ContextProvenance
        switch adapter.sourceKind {
        case .deviceRuntime:
            provenance = try ContextProvenance(
                origin: .system,
                trust: .systemState,
                sourceReference: refreshed.sourceReference
            )
        case .application:
            provenance = try ContextProvenance(
                origin: .applicationAdapter,
                trust: .systemState,
                sourceReference: refreshed.sourceReference
            )
        case .connectedService:
            provenance = try ContextProvenance(
                origin: .externalService,
                trust: .externalContent,
                sourceReference: refreshed.sourceReference
            )
        }

        let updated = try ContextItem(
            id: item.id,
            tenant: principal,
            scope: item.scope,
            key: item.key,
            value: refreshed.value,
            provenance: provenance,
            freshness: ContextFreshness(
                classification: item.freshness.classification,
                observedAt: refreshed.observedAt,
                validUntil: refreshed.validUntil
            ),
            bindings: item.bindings,
            createdAt: item.createdAt
        )
        try await store.put(updated, as: principal)
        return .refreshed(updated)
    }
}
