import Foundation
import Testing
@testable import AgentCore

private func contextItem(
    tenant: TenantContext,
    id: UUID = UUID(),
    scope: ContextScope = .user,
    key: String,
    value: JSONValue,
    observedAt: Date,
    validUntil: Date? = nil,
    createdAt: Date? = nil
) throws -> ContextItem {
    try ContextItem(
        id: id,
        tenant: tenant,
        scope: scope,
        key: key,
        value: value,
        provenance: ContextProvenance(origin: .system, trust: .systemState),
        freshness: ContextFreshness(
            classification: scope.kind == .device ? .ephemeral : .session,
            observedAt: observedAt,
            validUntil: validUntil
        ),
        createdAt: createdAt ?? observedAt
    )
}

@Test func writeRejectsDifferentPrincipal() async throws {
    let owner = TenantContext(tenantID: UUID(), userID: UUID())
    let other = TenantContext(tenantID: owner.tenantID, userID: UUID())
    let store = InMemoryContextService()
    let item = try contextItem(
        tenant: owner,
        key: "canary",
        value: .string("ALPHA-PINEAPPLE-7834"),
        observedAt: Date(timeIntervalSince1970: 1_000)
    )

    await #expect(throws: ContextServiceError.ownershipMismatch) {
        try await store.put(item, as: other)
    }
    #expect(await store.get(item.id, as: owner) == nil)
    #expect(await store.get(item.id, as: other) == nil)
}

@Test func directLookupCannotCrossTenantBoundary() async throws {
    let tenantA = TenantContext(tenantID: UUID(), userID: UUID())
    let tenantB = TenantContext(tenantID: UUID(), userID: UUID())
    let sharedID = UUID()
    let store = InMemoryContextService()
    let item = try contextItem(
        tenant: tenantA,
        id: sharedID,
        key: "secret",
        value: .string("ALPHA-PINEAPPLE-7834"),
        observedAt: Date(timeIntervalSince1970: 1_000)
    )
    try await store.put(item, as: tenantA)

    #expect(await store.get(sharedID, as: tenantA)?.value == .string("ALPHA-PINEAPPLE-7834"))
    #expect(await store.get(sharedID, as: tenantB) == nil)
}

@Test func semanticStyleQueryIsPartitionedBeforeFiltering() async throws {
    let tenantA = TenantContext(tenantID: UUID(), userID: UUID())
    let tenantB = TenantContext(tenantID: UUID(), userID: UUID())
    let now = Date(timeIntervalSince1970: 2_000)
    let store = InMemoryContextService()

    try await store.put(
        contextItem(tenant: tenantA, key: "project_note",
                    value: .string("ALPHA-PINEAPPLE-7834"), observedAt: now),
        as: tenantA
    )
    try await store.put(
        contextItem(tenant: tenantB, key: "project_note",
                    value: .string("BETA-ZEBRA-9911"), observedAt: now),
        as: tenantB
    )

    let query = try ContextQuery(keys: ["project_note"], includeStale: true)
    let a = await store.query(query, as: tenantA, now: now)
    let b = await store.query(query, as: tenantB, now: now)

    #expect(a.map(\.value) == [.string("ALPHA-PINEAPPLE-7834")])
    #expect(b.map(\.value) == [.string("BETA-ZEBRA-9911")])
}

@Test func staleItemsAreExcludedUnlessExplicitlyRequested() async throws {
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let observed = Date(timeIntervalSince1970: 1_000)
    let policy = try ContextFreshnessPolicy(ephemeralMaxAge: 10)
    let store = InMemoryContextService(freshnessPolicy: policy)
    let device = UUID()
    let item = try contextItem(
        tenant: tenant,
        scope: .device(device),
        key: "frontmost_app",
        value: .string("Safari"),
        observedAt: observed
    )
    try await store.put(item, as: tenant)

    let afterExpiry = observed.addingTimeInterval(11)
    #expect(await store.query(try ContextQuery(), as: tenant, now: afterExpiry).isEmpty)
    #expect(await store.query(try ContextQuery(includeStale: true), as: tenant, now: afterExpiry).count == 1)
}

@Test func queryFiltersScopeAndKeysWithinPrincipalPartition() async throws {
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let now = Date(timeIntervalSince1970: 1_000)
    let store = InMemoryContextService()
    let deviceID = UUID()

    try await store.put(
        contextItem(tenant: tenant, scope: .device(deviceID), key: "frontmost_app",
                    value: .string("Safari"), observedAt: now),
        as: tenant
    )
    try await store.put(
        contextItem(tenant: tenant, scope: .user, key: "preferred_language",
                    value: .string("en"), observedAt: now),
        as: tenant
    )

    let query = try ContextQuery(scopeKinds: [.device], keys: ["frontmost_app"], includeStale: true)
    let result = await store.query(query, as: tenant, now: now)

    #expect(result.count == 1)
    #expect(result[0].scope.kind == .device)
    #expect(result[0].key == "frontmost_app")
}

@Test func wrongPrincipalCannotDeleteAnotherUsersContext() async throws {
    let owner = TenantContext(tenantID: UUID(), userID: UUID())
    let other = TenantContext(tenantID: owner.tenantID, userID: UUID())
    let now = Date(timeIntervalSince1970: 1_000)
    let store = InMemoryContextService()
    let item = try contextItem(tenant: owner, key: "private",
                               value: .string("secret"), observedAt: now)
    try await store.put(item, as: owner)

    #expect(await store.remove(item.id, as: other) == false)
    #expect(await store.get(item.id, as: owner) != nil)
    #expect(await store.remove(item.id, as: owner) == true)
    #expect(await store.get(item.id, as: owner) == nil)
}
