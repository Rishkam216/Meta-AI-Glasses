import Foundation

public enum ContextConsumerKind: String, Codable, Sendable, Hashable {
    case realtime
    case boundedDecision = "bounded_decision"
    case reasoning
}

public enum ContextCompilationError: Error, Sendable, Equatable {
    case invalidMaxItems
    case invalidMaxBytes
    case invalidMaxRefreshItems
    case invalidAllowedKey
}

public struct ContextCompilationRequest: Sendable, Equatable {
    public let consumer: ContextConsumerKind
    public let sessionID: UUID?
    public let interfaceID: UUID?
    public let deviceID: UUID?
    public let taskID: UUID?
    public let additionalScopes: Set<ContextScope>
    public let includeUserScope: Bool
    public let requestedKeys: Set<String>?
    public let includeExternalContent: Bool
    public let includeMemory: Bool
    public let includeModelGenerated: Bool
    public let maxItems: Int
    public let maxBytes: Int
    public let refreshStaleEphemeral: Bool
    public let maxRefreshItems: Int

    public init(consumer: ContextConsumerKind,
                sessionID: UUID? = nil,
                interfaceID: UUID? = nil,
                deviceID: UUID? = nil,
                taskID: UUID? = nil,
                additionalScopes: Set<ContextScope> = [],
                includeUserScope: Bool = false,
                requestedKeys: Set<String>? = nil,
                includeExternalContent: Bool = false,
                includeMemory: Bool = false,
                includeModelGenerated: Bool = false,
                maxItems: Int = 32,
                maxBytes: Int = 32_768,
                refreshStaleEphemeral: Bool = true,
                maxRefreshItems: Int = 8) throws {
        guard (1...100).contains(maxItems) else {
            throw ContextCompilationError.invalidMaxItems
        }
        guard (256...(1 * 1_024 * 1_024)).contains(maxBytes) else {
            throw ContextCompilationError.invalidMaxBytes
        }
        guard (0...32).contains(maxRefreshItems) else {
            throw ContextCompilationError.invalidMaxRefreshItems
        }
        if let requestedKeys {
            for key in requestedKeys {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, key.utf8.count <= 256 else {
                    throw ContextCompilationError.invalidAllowedKey
                }
            }
        }
        self.consumer = consumer
        self.sessionID = sessionID
        self.interfaceID = interfaceID
        self.deviceID = deviceID
        self.taskID = taskID
        self.additionalScopes = additionalScopes
        self.includeUserScope = includeUserScope
        self.requestedKeys = requestedKeys
        self.includeExternalContent = includeExternalContent
        self.includeMemory = includeMemory
        self.includeModelGenerated = includeModelGenerated
        self.maxItems = maxItems
        self.maxBytes = maxBytes
        self.refreshStaleEphemeral = refreshStaleEphemeral
        self.maxRefreshItems = maxRefreshItems
    }
}

/// Provider-facing representation deliberately omits tenant/account/user IDs.
/// Provenance is preserved so downstream prompts can distinguish instructions
/// from external/untrusted content.
public struct CompiledContextItem: Codable, Sendable, Equatable {
    public let id: UUID
    public let scope: ContextScope
    public let key: String
    public let value: JSONValue
    public let provenance: ContextProvenance
    public let freshness: ContextFreshness
    public let bindings: ContextBindings

    init(_ item: ContextItem) {
        id = item.id
        scope = item.scope
        key = item.key
        value = item.value
        provenance = item.provenance
        freshness = item.freshness
        bindings = item.bindings
    }
}

public struct ContextRefreshSummary: Codable, Sendable, Equatable {
    public let attempted: Int
    public let refreshed: Int
    public let unsupported: Int
    public let failed: Int

    public static let none = ContextRefreshSummary(
        attempted: 0,
        refreshed: 0,
        unsupported: 0,
        failed: 0
    )
}

public struct CompiledContext: Codable, Sendable, Equatable {
    public let consumer: ContextConsumerKind
    public let items: [CompiledContextItem]
    public let consideredItemCount: Int
    public let omittedByPolicyCount: Int
    public let omittedByBudgetCount: Int
    public let encodedBytes: Int
    public let refreshSummary: ContextRefreshSummary
}

public struct ContextCompiler: Sendable {
    private let store: any ContextStoring
    private let refresher: (any ContextRefreshing)?

    public init(store: any ContextStoring,
                refresher: (any ContextRefreshing)? = nil) {
        self.store = store
        self.refresher = refresher
    }

    public func compile(_ request: ContextCompilationRequest,
                        as principal: TenantContext,
                        now: Date = Date()) async throws -> CompiledContext {
        let scopes = try requestedScopes(for: request)
        let refreshSummary = try await refreshIfNeeded(
            request,
            scopes: scopes,
            principal: principal,
            now: now
        )

        var unique: [UUID: ContextItem] = [:]
        for scope in scopes {
            let query = try ContextQuery(
                exactScope: scope,
                keys: request.requestedKeys,
                includeStale: false,
                limit: 100
            )
            for item in await store.query(query, as: principal, now: now) {
                unique[item.id] = item
            }
        }

        let allowed = allowedTrust(for: request)
        let ordered = unique.values.sorted { lhs, rhs in
            let left = specificity(of: lhs, for: request)
            let right = specificity(of: rhs, for: request)
            if left != right { return left > right }
            if lhs.freshness.observedAt != rhs.freshness.observedAt {
                return lhs.freshness.observedAt > rhs.freshness.observedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var accepted: [ContextItem] = []
        accepted.reserveCapacity(ordered.count)
        var omittedByPolicy = 0
        for item in ordered {
            guard allowed.contains(item.provenance.trust) else {
                omittedByPolicy += 1
                continue
            }
            accepted.append(item)
        }

        var compiled: [CompiledContextItem] = []
        compiled.reserveCapacity(min(request.maxItems, accepted.count))
        var encodedBytes = 0
        var omittedByBudget = 0
        let encoder = JSONEncoder()

        for item in accepted {
            let candidate = CompiledContextItem(item)
            let size = try encoder.encode(candidate).count
            guard compiled.count < request.maxItems,
                  encodedBytes + size <= request.maxBytes else {
                omittedByBudget += 1
                continue
            }
            compiled.append(candidate)
            encodedBytes += size
        }

        return CompiledContext(
            consumer: request.consumer,
            items: compiled,
            consideredItemCount: ordered.count,
            omittedByPolicyCount: omittedByPolicy,
            omittedByBudgetCount: omittedByBudget,
            encodedBytes: encodedBytes,
            refreshSummary: refreshSummary
        )
    }

    private func refreshIfNeeded(_ request: ContextCompilationRequest,
                                 scopes: Set<ContextScope>,
                                 principal: TenantContext,
                                 now: Date) async throws -> ContextRefreshSummary {
        guard request.refreshStaleEphemeral,
              request.maxRefreshItems > 0,
              let refresher else {
            return .none
        }

        var unique: [UUID: ContextItem] = [:]
        for scope in scopes {
            let staleQuery = try ContextQuery(
                exactScope: scope,
                keys: request.requestedKeys,
                freshnessClasses: [.ephemeral],
                includeStale: true,
                onlyStale: true,
                limit: 100
            )
            for item in await store.query(staleQuery, as: principal, now: now) {
                unique[item.id] = item
            }
        }

        let stale = unique.values.sorted {
            if $0.freshness.observedAt != $1.freshness.observedAt {
                return $0.freshness.observedAt > $1.freshness.observedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(request.maxRefreshItems)

        var attempted = 0
        var refreshed = 0
        var unsupported = 0
        var failed = 0

        for item in stale {
            attempted += 1
            do {
                switch try await refresher.refresh(item, as: principal, now: now) {
                case .refreshed:
                    refreshed += 1
                case .unsupported:
                    unsupported += 1
                }
            } catch ContextRefreshError.ownershipMismatch {
                throw ContextRefreshError.ownershipMismatch
            } catch {
                failed += 1
            }
        }

        return ContextRefreshSummary(
            attempted: attempted,
            refreshed: refreshed,
            unsupported: unsupported,
            failed: failed
        )
    }

    private func requestedScopes(for request: ContextCompilationRequest) throws -> Set<ContextScope> {
        var scopes = request.additionalScopes
        if request.includeUserScope { scopes.insert(.user) }
        if let sessionID = request.sessionID { scopes.insert(.session(sessionID)) }
        if let interfaceID = request.interfaceID {
            scopes.insert(try ContextScope(kind: .interface, referenceID: interfaceID.uuidString))
        }
        if let deviceID = request.deviceID { scopes.insert(.device(deviceID)) }
        if let taskID = request.taskID { scopes.insert(.task(taskID)) }
        return scopes
    }

    private func allowedTrust(for request: ContextCompilationRequest) -> Set<ContextTrustClass> {
        if request.consumer == .boundedDecision {
            return [.systemState, .toolResult]
        }

        var allowed: Set<ContextTrustClass> = [.userInstruction, .systemState, .toolResult]
        if request.includeExternalContent { allowed.insert(.externalContent) }
        if request.includeMemory { allowed.insert(.memory) }
        if request.consumer == .reasoning, request.includeModelGenerated {
            allowed.insert(.modelGenerated)
        }
        return allowed
    }

    private func specificity(of item: ContextItem,
                             for request: ContextCompilationRequest) -> Int {
        if let taskID = request.taskID, item.scope == .task(taskID) { return 5 }
        if let deviceID = request.deviceID, item.scope == .device(deviceID) { return 4 }
        if let interfaceID = request.interfaceID,
           item.scope.kind == .interface,
           item.scope.referenceID == interfaceID.uuidString { return 3 }
        if let sessionID = request.sessionID, item.scope == .session(sessionID) { return 2 }
        if item.scope == .user { return 1 }
        return 0
    }
}
