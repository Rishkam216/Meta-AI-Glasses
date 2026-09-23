import Foundation
import Testing
@testable import AgentCore

private func advancedContextItem(
    id: UUID = UUID(),
    tenant: TenantContext,
    scope: ContextScope = .user,
    key: String,
    value: JSONValue = .string("value"),
    trust: ContextTrustClass = .systemState,
    origin: ContextOrigin = .system,
    observedAt: Date,
    sessionID: UUID? = nil,
    deviceID: UUID? = nil,
    taskID: UUID? = nil
) throws -> ContextItem {
    try ContextItem(
        id: id,
        tenant: tenant,
        scope: scope,
        key: key,
        value: value,
        provenance: ContextProvenance(origin: origin, trust: trust),
        freshness: ContextFreshness(classification: .ephemeral, observedAt: observedAt),
        bindings: ContextBindings(sessionID: sessionID, deviceID: deviceID, taskID: taskID),
        createdAt: observedAt
    )
}

@Test func sameContextIDCanExistInDifferentPrincipalPartitions() async throws {
    let store = InMemoryContextService()
    let sharedID = UUID()
    let a = TenantContext(tenantID: UUID(), userID: UUID())
    let b = TenantContext(tenantID: UUID(), userID: UUID())
    let now = Date(timeIntervalSince1970: 1_000)

    try await store.put(
        advancedContextItem(id: sharedID, tenant: a, key: "secret", value: .string("A"), observedAt: now),
        as: a
    )
    try await store.put(
        advancedContextItem(id: sharedID, tenant: b, key: "secret", value: .string("B"), observedAt: now),
        as: b
    )

    #expect(await store.get(sharedID, as: a)?.value == .string("A"))
    #expect(await store.get(sharedID, as: b)?.value == .string("B"))
}

@Test func queryFiltersScopeTrustOriginAndBindingsBeforeLimit() async throws {
    let store = InMemoryContextService()
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let sessionID = UUID()
    let deviceID = UUID()
    let taskID = UUID()
    let now = Date(timeIntervalSince1970: 2_000)

    let wanted = try advancedContextItem(
        tenant: principal,
        scope: .device(deviceID),
        key: "ui_state",
        trust: .toolResult,
        origin: .tool,
        observedAt: now,
        sessionID: sessionID,
        deviceID: deviceID,
        taskID: taskID
    )
    let wrongTrust = try advancedContextItem(
        tenant: principal,
        scope: .device(deviceID),
        key: "ui_state",
        trust: .externalContent,
        origin: .externalService,
        observedAt: now.addingTimeInterval(1),
        sessionID: sessionID,
        deviceID: deviceID,
        taskID: taskID
    )

    try await store.put(wanted, as: principal)
    try await store.put(wrongTrust, as: principal)

    let query = try ContextQuery(
        exactScope: .device(deviceID),
        keys: ["ui_state"],
        trust: [.toolResult],
        origins: [.tool],
        sessionID: sessionID,
        deviceID: deviceID,
        taskID: taskID,
        includeStale: true,
        limit: 1
    )
    let results = await store.query(query, as: principal, now: now.addingTimeInterval(2))
    #expect(results.map(\.id) == [wanted.id])
}

@Test func queryOrdersNewestFirstAndAppliesLimitAfterFiltering() async throws {
    let store = InMemoryContextService()
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)

    try await store.put(
        advancedContextItem(tenant: principal, key: "event", value: .string("old"), observedAt: older),
        as: principal
    )
    try await store.put(
        advancedContextItem(tenant: principal, key: "event", value: .string("new"), observedAt: newer),
        as: principal
    )
    try await store.put(
        advancedContextItem(tenant: principal, key: "other", value: .string("newest-but-filtered"), observedAt: newer.addingTimeInterval(1)),
        as: principal
    )

    let results = await store.query(
        try ContextQuery(keys: ["event"], includeStale: true, limit: 1),
        as: principal,
        now: newer.addingTimeInterval(2)
    )
    #expect(results.map(\.value) == [.string("new")])
}

@Test func queryBoundsRejectInvalidLimitsAndKeys() throws {
    #expect(throws: ContextServiceError.invalidLimit) {
        _ = try ContextQuery(limit: 0)
    }
    #expect(throws: ContextServiceError.invalidLimit) {
        _ = try ContextQuery(limit: 101)
    }
    #expect(throws: ContextServiceError.invalidKey) {
        _ = try ContextQuery(keys: ["   "])
    }
    #expect(throws: ContextServiceError.invalidKey) {
        _ = try ContextQuery(keys: [String(repeating: "x", count: 257)])
    }
}

@Test func countRemoveAndClearRemainPartitionLocal() async throws {
    let store = InMemoryContextService()
    let sharedID = UUID()
    let a = TenantContext(tenantID: UUID(), userID: UUID())
    let b = TenantContext(tenantID: UUID(), userID: UUID())
    let now = Date(timeIntervalSince1970: 3_000)

    try await store.put(
        advancedContextItem(id: sharedID, tenant: a, key: "state", observedAt: now),
        as: a
    )
    try await store.put(
        advancedContextItem(id: sharedID, tenant: b, key: "state", observedAt: now),
        as: b
    )

    #expect(await store.count(as: a) == 1)
    #expect(await store.count(as: b) == 1)
    #expect(await store.remove(sharedID, as: a))
    #expect(await store.get(sharedID, as: a) == nil)
    #expect(await store.get(sharedID, as: b) != nil)

    await store.removeAll(as: a)
    #expect(await store.count(as: a) == 0)
    #expect(await store.count(as: b) == 1)
}
