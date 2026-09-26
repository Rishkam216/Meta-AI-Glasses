import Foundation

/// Security identity attached by trusted backend/session code. Models and external
/// content must never be authoritative sources for these identifiers.
public struct TenantContext: Codable, Sendable, Hashable {
    public let tenantID: UUID
    public let userID: UUID
    public let accountID: UUID?

    public init(tenantID: UUID, userID: UUID, accountID: UUID? = nil) {
        self.tenantID = tenantID
        self.userID = userID
        self.accountID = accountID
    }

    /// Current private-context boundary. Future shared-workspace ACLs must be an
    /// explicit layer above this exact-principal comparison.
    public func isSamePrincipal(as other: TenantContext) -> Bool {
        self == other
    }
}

public enum ContextValidationError: Error, Sendable, Equatable {
    case emptyScopeReference
    case unexpectedScopeReference
    case scopeReferenceTooLong
    case invalidFreshnessWindow
    case invalidMaxAge
    case emptyKey
    case keyTooLong
    case emptySourceReference
    case sourceReferenceTooLong
}

public enum ContextAccessError: Error, Sendable, Equatable {
    case principalMismatch
}

public enum ContextScopeKind: String, Codable, Sendable, Hashable {
    case user
    case session
    case interface
    case device
    case task
    case project
    case application
    case connectedService = "connected_service"
}

/// Provider- and platform-neutral context scope. The reference is intentionally
/// opaque; the owning subsystem interprets it. User scope is the only scope that
/// does not carry a reference.
public struct ContextScope: Codable, Sendable, Hashable {
    public let kind: ContextScopeKind
    public let referenceID: String?

    private enum CodingKeys: String, CodingKey { case kind, referenceID }

    public init(kind: ContextScopeKind, referenceID: String? = nil) throws {
        if kind == .user {
            guard referenceID == nil else { throw ContextValidationError.unexpectedScopeReference }
        } else {
            guard let referenceID else { throw ContextValidationError.emptyScopeReference }
            let trimmed = referenceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ContextValidationError.emptyScopeReference }
            guard referenceID.utf8.count <= 256 else { throw ContextValidationError.scopeReferenceTooLong }
        }
        self.kind = kind
        self.referenceID = referenceID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: values.decode(ContextScopeKind.self, forKey: .kind),
            referenceID: values.decodeIfPresent(String.self, forKey: .referenceID)
        )
    }

    public static let user = ContextScope(validatedKind: .user, referenceID: nil)

    public static func session(_ id: UUID) -> ContextScope {
        ContextScope(validatedKind: .session, referenceID: id.uuidString)
    }

    public static func device(_ id: UUID) -> ContextScope {
        ContextScope(validatedKind: .device, referenceID: id.uuidString)
    }

    public static func task(_ id: UUID) -> ContextScope {
        ContextScope(validatedKind: .task, referenceID: id.uuidString)
    }

    private init(validatedKind: ContextScopeKind, referenceID: String?) {
        kind = validatedKind
        self.referenceID = referenceID
    }
}

/// Classification controls how downstream compilers treat a context item.
/// `externalContent`, `memory`, and `modelGenerated` are context, not authority.
public enum ContextTrustClass: String, Codable, Sendable, Hashable {
    case userInstruction = "user_instruction"
    case systemState = "system_state"
    case toolResult = "tool_result"
    case externalContent = "external_content"
    case memory
    case modelGenerated = "model_generated"
}

public enum ContextOrigin: String, Codable, Sendable, Hashable {
    case user
    case system
    case tool
    case externalService = "external_service"
    case memoryProvider = "memory_provider"
    case model
    case applicationAdapter = "application_adapter"
}

public struct ContextProvenance: Codable, Sendable, Equatable {
    public let origin: ContextOrigin
    public let trust: ContextTrustClass
    public let sourceReference: String?

    private enum CodingKeys: String, CodingKey { case origin, trust, sourceReference }

    public init(origin: ContextOrigin, trust: ContextTrustClass,
                sourceReference: String? = nil) throws {
        if let sourceReference {
            let trimmed = sourceReference.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ContextValidationError.emptySourceReference }
            guard sourceReference.utf8.count <= 1_024 else {
                throw ContextValidationError.sourceReferenceTooLong
            }
        }
        self.origin = origin
        self.trust = trust
        self.sourceReference = sourceReference
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            origin: values.decode(ContextOrigin.self, forKey: .origin),
            trust: values.decode(ContextTrustClass.self, forKey: .trust),
            sourceReference: values.decodeIfPresent(String.self, forKey: .sourceReference)
        )
    }
}

/// Links one context observation to live runtime entities without making any of
/// them authoritative identity. TenantContext remains the ownership boundary.
public struct ContextBindings: Codable, Sendable, Equatable {
    public let sessionID: UUID?
    public let deviceID: UUID?
    public let taskID: UUID?

    public init(sessionID: UUID? = nil, deviceID: UUID? = nil, taskID: UUID? = nil) {
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.taskID = taskID
    }

    public static let none = ContextBindings()
}

public enum ContextFreshnessClass: String, Codable, Sendable, Hashable {
    case ephemeral
    case session
    case project
    case longTerm = "long_term"
}

/// Configurable maximum ages. No class receives an implicit lifetime here; the
/// Context Service chooses policy explicitly for the product/environment.
public struct ContextFreshnessPolicy: Sendable, Equatable {
    private let maxAges: [ContextFreshnessClass: TimeInterval]

    public init(ephemeralMaxAge: TimeInterval? = nil,
                sessionMaxAge: TimeInterval? = nil,
                projectMaxAge: TimeInterval? = nil,
                longTermMaxAge: TimeInterval? = nil) throws {
        let pairs: [(ContextFreshnessClass, TimeInterval?)] = [
            (.ephemeral, ephemeralMaxAge),
            (.session, sessionMaxAge),
            (.project, projectMaxAge),
            (.longTerm, longTermMaxAge)
        ]
        var values: [ContextFreshnessClass: TimeInterval] = [:]
        for (key, value) in pairs {
            guard let value else { continue }
            guard value >= 0, value.isFinite else { throw ContextValidationError.invalidMaxAge }
            values[key] = value
        }
        maxAges = values
    }

    public func maxAge(for classification: ContextFreshnessClass) -> TimeInterval? {
        maxAges[classification]
    }
}

public struct ContextFreshness: Codable, Sendable, Equatable {
    public let classification: ContextFreshnessClass
    public let observedAt: Date
    public let validUntil: Date?

    private enum CodingKeys: String, CodingKey { case classification, observedAt, validUntil }

    public init(classification: ContextFreshnessClass, observedAt: Date,
                validUntil: Date? = nil) throws {
        if let validUntil, validUntil < observedAt {
            throw ContextValidationError.invalidFreshnessWindow
        }
        self.classification = classification
        self.observedAt = observedAt
        self.validUntil = validUntil
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            classification: values.decode(ContextFreshnessClass.self, forKey: .classification),
            observedAt: values.decode(Date.self, forKey: .observedAt),
            validUntil: values.decodeIfPresent(Date.self, forKey: .validUntil)
        )
    }

    public func isStale(at now: Date, policy: ContextFreshnessPolicy) -> Bool {
        if let validUntil, now >= validUntil { return true }
        guard let maxAge = policy.maxAge(for: classification) else { return false }
        let age = now.timeIntervalSince(observedAt)
        return age >= 0 && age >= maxAge
    }
}

/// Portable unit of contextual state. It always carries principal ownership,
/// provenance/trust, freshness, and scope; none of those may be reconstructed by
/// a model after retrieval.
public struct ContextItem: Codable, Sendable, Equatable {
    public let id: UUID
    public let tenant: TenantContext
    public let scope: ContextScope
    public let key: String
    public let value: JSONValue
    public let provenance: ContextProvenance
    public let freshness: ContextFreshness
    public let bindings: ContextBindings
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, tenant, scope, key, value, provenance, freshness, bindings, createdAt
    }

    public init(id: UUID = UUID(), tenant: TenantContext, scope: ContextScope,
                key: String, value: JSONValue, provenance: ContextProvenance,
                freshness: ContextFreshness, bindings: ContextBindings = .none,
                createdAt: Date = Date()) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ContextValidationError.emptyKey }
        guard key.utf8.count <= 256 else { throw ContextValidationError.keyTooLong }

        self.id = id
        self.tenant = tenant
        self.scope = scope
        self.key = key
        self.value = value
        self.provenance = provenance
        self.freshness = freshness
        self.bindings = bindings
        self.createdAt = createdAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            tenant: values.decode(TenantContext.self, forKey: .tenant),
            scope: values.decode(ContextScope.self, forKey: .scope),
            key: values.decode(String.self, forKey: .key),
            value: values.decode(JSONValue.self, forKey: .value),
            provenance: values.decode(ContextProvenance.self, forKey: .provenance),
            freshness: values.decode(ContextFreshness.self, forKey: .freshness),
            bindings: values.decode(ContextBindings.self, forKey: .bindings),
            createdAt: values.decode(Date.self, forKey: .createdAt)
        )
    }

    public func isOwned(by principal: TenantContext) -> Bool {
        tenant.isSamePrincipal(as: principal)
    }

    public func requireOwnership(by principal: TenantContext) throws {
        guard isOwned(by: principal) else { throw ContextAccessError.principalMismatch }
    }

    public func isStale(at now: Date, policy: ContextFreshnessPolicy) -> Bool {
        freshness.isStale(at: now, policy: policy)
    }
}
