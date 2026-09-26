import Foundation
import Testing
@testable import AgentCore

@Test func tenantOwnershipIsExactAcrossTenantUserAndAccount() throws {
    let tenantID = UUID()
    let userID = UUID()
    let accountID = UUID()
    let owner = TenantContext(tenantID: tenantID, userID: userID, accountID: accountID)
    let otherTenant = TenantContext(tenantID: UUID(), userID: userID, accountID: accountID)
    let otherUser = TenantContext(tenantID: tenantID, userID: UUID(), accountID: accountID)
    let otherAccount = TenantContext(tenantID: tenantID, userID: userID, accountID: UUID())

    #expect(owner.isSamePrincipal(as: owner))
    #expect(!owner.isSamePrincipal(as: otherTenant))
    #expect(!owner.isSamePrincipal(as: otherUser))
    #expect(!owner.isSamePrincipal(as: otherAccount))
}

@Test func scopeValidationPreventsAmbiguousReferences() throws {
    #expect(throws: ContextValidationError.unexpectedScopeReference) {
        _ = try ContextScope(kind: .user, referenceID: "should-not-exist")
    }
    #expect(throws: ContextValidationError.emptyScopeReference) {
        _ = try ContextScope(kind: .device)
    }
    #expect(throws: ContextValidationError.emptyScopeReference) {
        _ = try ContextScope(kind: .application, referenceID: "   ")
    }

    let deviceID = UUID()
    let scope = ContextScope.device(deviceID)
    #expect(scope.kind == .device)
    #expect(scope.referenceID == deviceID.uuidString)
}

@Test func contextItemRoundTripPreservesOwnershipProvenanceFreshnessAndBindings() throws {
    let tenant = TenantContext(tenantID: UUID(), userID: UUID(), accountID: UUID())
    let sessionID = UUID()
    let deviceID = UUID()
    let taskID = UUID()
    let observed = Date(timeIntervalSince1970: 1_000)
    let expires = Date(timeIntervalSince1970: 1_030)

    let item = try ContextItem(
        tenant: tenant,
        scope: ContextScope.device(deviceID),
        key: "frontmost_app",
        value: .object([
            "name": .string("Safari"),
            "bundle_id": .string("com.apple.Safari")
        ]),
        provenance: ContextProvenance(
            origin: .applicationAdapter,
            trust: .systemState,
            sourceReference: "ui.get_frontmost_app"
        ),
        freshness: ContextFreshness(
            classification: .ephemeral,
            observedAt: observed,
            validUntil: expires
        ),
        bindings: ContextBindings(sessionID: sessionID, deviceID: deviceID, taskID: taskID),
        createdAt: observed
    )

    let encoded = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(ContextItem.self, from: encoded)

    #expect(decoded == item)
    #expect(decoded.tenant == tenant)
    #expect(decoded.provenance.trust == .systemState)
    #expect(decoded.freshness.classification == .ephemeral)
    #expect(decoded.bindings.sessionID == sessionID)
    #expect(decoded.bindings.deviceID == deviceID)
    #expect(decoded.bindings.taskID == taskID)
}

@Test func ownershipGuardFailsClosedForDifferentPrincipal() throws {
    let owner = TenantContext(tenantID: UUID(), userID: UUID())
    let attacker = TenantContext(tenantID: owner.tenantID, userID: UUID())
    let observed = Date(timeIntervalSince1970: 1_000)
    let item = try ContextItem(
        tenant: owner,
        scope: .user,
        key: "preferred_language",
        value: .string("en"),
        provenance: ContextProvenance(origin: .user, trust: .userInstruction),
        freshness: ContextFreshness(classification: .longTerm, observedAt: observed),
        createdAt: observed
    )

    try item.requireOwnership(by: owner)
    #expect(throws: ContextAccessError.principalMismatch) {
        try item.requireOwnership(by: attacker)
    }
}

@Test func freshnessUsesEarliestExplicitOrPolicyBoundary() throws {
    let observed = Date(timeIntervalSince1970: 1_000)
    let policy = try ContextFreshnessPolicy(ephemeralMaxAge: 30, sessionMaxAge: 3_600)
    let explicit = try ContextFreshness(
        classification: .ephemeral,
        observedAt: observed,
        validUntil: observed.addingTimeInterval(10)
    )
    let policyOnly = try ContextFreshness(classification: .ephemeral, observedAt: observed)
    let longTerm = try ContextFreshness(classification: .longTerm, observedAt: observed)

    #expect(!explicit.isStale(at: observed.addingTimeInterval(9), policy: policy))
    #expect(explicit.isStale(at: observed.addingTimeInterval(10), policy: policy))
    #expect(!policyOnly.isStale(at: observed.addingTimeInterval(29), policy: policy))
    #expect(policyOnly.isStale(at: observed.addingTimeInterval(30), policy: policy))
    #expect(!longTerm.isStale(at: observed.addingTimeInterval(10_000_000), policy: policy))
}

@Test func invalidFreshnessAndPolicyAreRejected() throws {
    let observed = Date(timeIntervalSince1970: 1_000)
    #expect(throws: ContextValidationError.invalidFreshnessWindow) {
        _ = try ContextFreshness(
            classification: .ephemeral,
            observedAt: observed,
            validUntil: observed.addingTimeInterval(-1)
        )
    }
    #expect(throws: ContextValidationError.invalidMaxAge) {
        _ = try ContextFreshnessPolicy(ephemeralMaxAge: -1)
    }
    #expect(throws: ContextValidationError.invalidMaxAge) {
        _ = try ContextFreshnessPolicy(sessionMaxAge: .infinity)
    }
}

@Test func itemAndSourceIdentifiersAreBounded() throws {
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let observed = Date(timeIntervalSince1970: 1_000)
    let provenance = try ContextProvenance(origin: .system, trust: .systemState)
    let freshness = try ContextFreshness(classification: .session, observedAt: observed)

    #expect(throws: ContextValidationError.emptyKey) {
        _ = try ContextItem(
            tenant: tenant,
            scope: .user,
            key: "   ",
            value: .null,
            provenance: provenance,
            freshness: freshness
        )
    }
    #expect(throws: ContextValidationError.keyTooLong) {
        _ = try ContextItem(
            tenant: tenant,
            scope: .user,
            key: String(repeating: "x", count: 257),
            value: .null,
            provenance: provenance,
            freshness: freshness
        )
    }
    #expect(throws: ContextValidationError.emptySourceReference) {
        _ = try ContextProvenance(origin: .tool, trust: .toolResult, sourceReference: "  ")
    }
    #expect(throws: ContextValidationError.sourceReferenceTooLong) {
        _ = try ContextProvenance(
            origin: .tool,
            trust: .toolResult,
            sourceReference: String(repeating: "x", count: 1_025)
        )
    }
}

@Test func externalContentClassificationSurvivesSerializationWithoutBecomingInstruction() throws {
    let provenance = try ContextProvenance(
        origin: .externalService,
        trust: .externalContent,
        sourceReference: "email:message-123"
    )
    let encoded = try JSONEncoder().encode(provenance)
    let decoded = try JSONDecoder().decode(ContextProvenance.self, from: encoded)

    #expect(decoded.trust == .externalContent)
    #expect(decoded.trust != .userInstruction)
    #expect(decoded.origin == .externalService)
}

@Test func decodedWireDataCannotBypassValidation() throws {
    let invalidScope = Data(#"{"kind":"device","referenceID":"   "}"#.utf8)
    #expect(throws: ContextValidationError.emptyScopeReference) {
        _ = try JSONDecoder().decode(ContextScope.self, from: invalidScope)
    }

    let invalidProvenance = Data(#"{"origin":"tool","trust":"tool_result","sourceReference":""}"#.utf8)
    #expect(throws: ContextValidationError.emptySourceReference) {
        _ = try JSONDecoder().decode(ContextProvenance.self, from: invalidProvenance)
    }
}
