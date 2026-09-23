import Foundation

public enum ContextCompilationError: Error, Sendable, Equatable {
    case invalidMaxItems
    case invalidByteBudget
    case invalidAllowedKey
}

public enum ContextConsumerRole: String, Codable, Sendable, Hashable {
    case realtime
    case boundedDecision = "bounded_decision"
    case reasoning
}

/// Provider-neutral safety budget. `maxEncodedBytes` limits the sum of compiled
/// item encodings; provider adapters may add their own envelope overhead later.
public struct ContextCompilationBudget: Sendable, Equatable {
    public let maxItems: Int
    public let maxEncodedBytes: Int

    public init(maxItems: Int = 32, maxEncodedBytes: Int = 64 * 1024) throws {
        guard (1...100).contains(maxItems) else { throw ContextCompilationError.invalidMaxItems }
        guard (256...(1 * 1024 * 1024)).contains(maxEncodedBytes) else {
            throw ContextCompilationError.invalidByteBudget
        }
        self.maxItems = maxItems
        self.maxEncodedBytes = maxEncodedBytes
    }
}

/// Caller selects relevant scopes; the compiler enforces tenant isolation through
/// ContextServing, role policy, trust labels, stale filtering, and payload bounds.
/// Tenant/user identity is deliberately not represented in this request's model-
/// facing selection fields.
public struct ContextCompilationRequest: Sendable, Equatable {
    public let role: ContextConsumerRole
    public let scopes: [ContextScope]
    public let includeUserScope: Bool
    public let allowedKeys: Set<String>?
    public let includeExternalContent: Bool
    public let includeMemory: Bool
    public let includeModelGenerated: Bool
    public let budget: ContextCompilationBudget

    public init(role: ContextConsumerRole,
                scopes: [ContextScope] = [],
                includeUserScope: Bool = false,
                allowedKeys: Set<String>? = nil,
                includeExternalContent: Bool = false,
                includeMemory: Bool = false,
                includeModelGenerated: Bool = false,
                budget: ContextCompilationBudget) throws {
        if let allowedKeys {
            for key in allowedKeys {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, key.utf8.count <= 256 else {
                    throw ContextCompilationError.invalidAllowedKey
                }
            }
        }
        self.role = role
        self.scopes = scopes
        self.includeUserScope = includeUserScope
        self.allowedKeys = allowedKeys
        self.includeExternalContent = includeExternalContent
        self.includeMemory = includeMemory
        self.includeModelGenerated = includeModelGenerated
        self.budget = budget
    }
}

/// Model-bound context intentionally excludes TenantContext. Provider adapters
/// receive only the already-authorized contextual content and its provenance.
public struct CompiledContextItem: Codable, Sendable, Equatable {
    public let id: UUID
    public let scopeKind: ContextScopeKind
    public let scopeReferenceID: String?
    public let key: String
    public let value: JSONValue
    public let trust: ContextTrustClass
    public let origin: ContextOrigin
    public let sourceReference: String?
    public let observedAt: Date
    public let validUntil: Date?
    public let bindings: ContextBindings

    init(_ item: ContextItem) {
        id = item.id
        scopeKind = item.scope.kind
        scopeReferenceID = item.scope.referenceID
        key = item.key
        value = item.value
        trust = item.provenance.trust
        origin = item.provenance.origin
        sourceReference = item.provenance.sourceReference
        observedAt = item.freshness.observedAt
        validUntil = item.freshness.validUntil
        bindings = item.bindings
    }
}

public struct ContextCompilationStats: Codable, Sendable, Equatable {
    public let considered: Int
    public let excludedByPolicy: Int
    public let excludedByBudget: Int
    public let estimatedEncodedBytes: Int
}

public struct CompiledContext: Codable, Sendable, Equatable {
    public let role: ContextConsumerRole
    public let generatedAt: Date
    public let items: [CompiledContextItem]
    public let stats: ContextCompilationStats
}

public struct ContextCompiler: Sendable {
    private let service: any ContextServing

    public init(service: any ContextServing) {
        self.service = service
    }

    public func compile(_ request: ContextCompilationRequest,
                        for principal: TenantContext,
                        at now: Date = Date()) async throws -> CompiledContext {
        var requestedScopes = Set(request.scopes)
        if request.includeUserScope { requestedScopes.insert(.user) }

        var unique: [UUID: ContextItem] = [:]
        for scope in requestedScopes {
            let query = try ContextQuery(scope: scope, includeStale: false, limit: 100)
            for item in await service.search(query, for: principal, at: now) {
                unique[item.id] = item
            }
        }

        let ordered = unique.values.sorted { lhs, rhs in
            if lhs.freshness.observedAt != rhs.freshness.observedAt {
                return lhs.freshness.observedAt > rhs.freshness.observedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let allowedTrust = allowedTrustClasses(for: request)
        var policyAccepted: [ContextItem] = []
        policyAccepted.reserveCapacity(ordered.count)
        var excludedByPolicy = 0

        for item in ordered {
            if !allowedTrust.contains(item.provenance.trust) {
                excludedByPolicy += 1
                continue
            }
            if let keys = request.allowedKeys, !keys.contains(item.key) {
                excludedByPolicy += 1
                continue
            }
            policyAccepted.append(item)
        }

        let encoder = JSONEncoder()
        var compiled: [CompiledContextItem] = []
        compiled.reserveCapacity(min(request.budget.maxItems, policyAccepted.count))
        var estimatedBytes = 0
        var excludedByBudget = 0

        for item in policyAccepted {
            let candidate = CompiledContextItem(item)
            let candidateSize = try encoder.encode(candidate).count
            guard compiled.count < request.budget.maxItems,
                  estimatedBytes + candidateSize <= request.budget.maxEncodedBytes else {
                excludedByBudget += 1
                continue
            }
            compiled.append(candidate)
            estimatedBytes += candidateSize
        }

        return CompiledContext(
            role: request.role,
            generatedAt: now,
            items: compiled,
            stats: ContextCompilationStats(
                considered: ordered.count,
                excludedByPolicy: excludedByPolicy,
                excludedByBudget: excludedByBudget,
                estimatedEncodedBytes: estimatedBytes
            )
        )
    }

    private func allowedTrustClasses(for request: ContextCompilationRequest) -> Set<ContextTrustClass> {
        var allowed: Set<ContextTrustClass>
        switch request.role {
        case .boundedDecision:
            // Bounded decision providers receive curated state/tool evidence only.
            return [.systemState, .toolResult]
        case .realtime, .reasoning:
            allowed = [.userInstruction, .systemState, .toolResult]
        }

        if request.includeExternalContent { allowed.insert(.externalContent) }
        if request.includeMemory { allowed.insert(.memory) }
        if request.role == .reasoning, request.includeModelGenerated {
            allowed.insert(.modelGenerated)
        }
        return allowed
    }
}
