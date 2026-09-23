import Foundation
import Testing
@testable import AgentCore

private func makeContextItem(
    id: UUID = UUID(),
    tenant: TenantContext,
    scope: ContextScope = .user,
    key: String,
    value: JSONValue = .string("value"),
    trust: ContextTrustClass = .systemState,
    origin: ContextOrigin = .system,
    observedAt: Date,
    validUntil: Date? = nil,
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
        freshness: ContextFreshness(
            classification: .ephemeral,
            observedAt: observedAt,
            validUntil: validUntil
        ),
        bindings: ContextBindings(sessionID: sessionID, deviceID: deviceID, taskID: taskID),
        createdAt: observedAt
    )
}

@Test func storeRejectsMismatchedPrincipal() async throws {
    let service = ContextService(freshnessPolicy: try ContextFreshnessPolicy(ephemeralMaxAge: 60))
    let owner = TenantContext(tenantID: UUID(), userID: UUID())
    let other = TenantContext(tenantID: owner.tenantID, userID: UUID())
    let item = try makeContextItem(tenant: owner, key: "state", observedAt: Date())

    do {
        try await service.store(item, for: other)
        Issue.record("Context item was stored under the wrong principal")
    } catch let error as ContextServiceError {
        #expect(error == .principalMismatch)
    }
    #expect(await service.count(for: owner) == 0)
    #expect(await service.count(for: other) == 0)
}

@Test func sameItemIDCanExistInDifferentPrincipalPartitionsWithoutCollision() async throws {
    let service = ContextService(freshnessPolicy: try ContextFreshnessPolicy())
    let sharedID = UUID()
    let a = TenantContext(tenantID: UUID(), userID: UUID())
    let b = TenantContext(tenantID: UUID(), userID: UUID())
    let now = Date(timeIntervalSince1970: 1_000)
    let itemA = try makeContextItem(id: sharedID, tenant: a, key: "secret", value: .string("A"), observedAt: now)
    let itemB = try makeContextItem(id: sharedID, tenant: b, key: "secret", value: .string("B"), observedAt: now)

    try await service.store(itemA, for: a)
    try await service.store(itemB, for: b)

    #expect(await service.item(id: sharedID, for: a)?.value == .string("A"))
    #expect(await service.item(id: sharedID, for: b)?.value == .string("B"))
}

@Test func searchNeverCrossesPrincipalPartition() async throws {
    let service = ContextService(freshnessPolicy: try ContextFreshnessPolicy())
    let a = TenantContext(tenantID: UUID(), userID: UUID())
    let b = TenantContext(tenantID: UUID(), userID: UUID())
    let now = Date(timeIntervalSince1970: 1_000)

    try await service.store(
        makeContextItem(tenant: a, key: "canary", value: .string("ALPHA-PINEAPPLE-7834"), observedAt: now),
        for: a
    )
    try await service.store(
        makeContextItem(tenant: b, key: "canary", value: .string("BETA-ZEBRA-9911"), observedAt: now),
        for: b
    )

    let query = try ContextQuery(key: "canary")
    let aResults = await service.search(query, for: a, at: now)
    let bResults = await service.search(query, for: b, at: now)

    #expect(aResults.map(\.value) == [.string("ALPHA-PINEAPPLE-7834")])
    #expect(bResults.map(\.value) == [.string("BETA-ZEBRA-9911")])
}

@Test func staleItemsAreHiddenByDefaultAndCanBeRequestedExplicitly() async throws {
    let policy = try ContextFreshnessPolicy(ephemeralMaxAge: 10)
    let service = ContextService(freshnessPolicy: policy)
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let observed = Date(timeIntervalSince1970: 1_000)

    try await service.store(
        makeContextItem(tenant: principal, key: "frontmost_app", observedAt: observed),
        for: principal
    )

    let now = observed.addingTimeInterval(11)
    #expect(await service.search(try ContextQuery(key: "frontmost_app"), for: principal, at: now).isEmpty)
    #expect(await service.search(
        try ContextQuery(key: "frontmost_app", includeStale: true),
        for: principal,
        at: now
    ).count == 1)
}

@Test func searchFiltersScopeTrustOriginAndBindingsBeforeLimiting() async throws {
    let service = ContextService(freshnessPolicy: try ContextFreshnessPolicy())
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let sessionID = UUID()
    let deviceID = UUID()
    let taskID = UUID()
    let now = Date(timeIntervalSince1970: 1_000)

    let wanted = try makeContextItem(
        tenant: principal,
        scope: ContextScope.device(deviceID),
        key: "ui_state",
        trust: .toolResult,
        origin: .tool,
        observedAt: now,
        sessionID: sessionID,
        deviceID: deviceID,
        taskID: taskID
    )
    let wrongTrust = try makeContextItem(
        tenant: principal,
        scope: ContextScope.device(deviceID),
        key: "ui_state",
        trust: .externalContent,
        origin: .externalService,
        observedAt: now.addingTimeInterval(1),
        sessionID: sessionID,
        deviceID: deviceID,
        taskID: taskID
    )

    try await service.store(wanted, for: principal)
    try await service.store(wrongTrust, for: principal)

    let query = try ContextQuery(
        scope: ContextScope.device(deviceID),
        key: "ui_state",
        trust: .toolResult,
        origin: .tool,
        sessionID: sessionID,
        deviceID: deviceID,
        taskID: taskID,
        limit: 1
    )
    let results = await service.search(query, for: principal, at: now.addingTimeInterval(2))
    #expect(results.map(\.id) == [wanted.id])
}

@Test func searchOrdersNewestFirstWithStableTieBreakAndAppliesLimit() async throws {
    let service = ContextService(freshnessPolicy: try ContextFreshnessPolicy())
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)

    let oldItem = try makeContextItem(tenant: principal, key: "event", value: .string("old"), observedAt: older)
    let newItem = try makeContextItem(tenant: principal, key: "event", value: .string("new"), observedAt: newer)
    try await service.store(oldItem, for: principal)
    try await service.store(newItem, for: principal)

    let results = await service.search(try ContextQuery(key: "event", limit: 1), for: principal, at: newer)
    #expect(results.map(\.value) == [.string("new")])
}

@Test func queryBoundsRejectUnboundedOrInvalidRequests() throws {
    #expect(throws: ContextServiceError.invalidLimit) { _ = try ContextQuery(limit: 0) }
    #expect(throws: ContextServiceError.invalidLimit) { _ = try ContextQuery(limit: 101) }
    #expect(throws: ContextServiceError.invalidKey) { _ = try ContextQuery(key: "   ") }
    #expect(throws: ContextServiceError.invalidKey) {
        _ = try ContextQuery(key: String(repeating: "x", count: 257))
    }
}

@Test func removalAndClearArePartitionLocal() async throws {
    let service = ContextService(freshnessPolicy: try ContextFreshnessPolicy())
    let sharedID = UUID()
    let a = TenantContext(tenantID: UUID(), userID: UUID())
    let b = TenantContext(tenantID: UUID(), userID: UUID())
    let now = Date(timeIntervalSince1970: 1_000)

    try await service.store(makeContextItem(id: sharedID, tenant: a, key: "state", observedAt: now), for: a)
    try await service.store(makeContextItem(id: sharedID, tenant: b, key: "state", observedAt: now), for: b)

    #expect(await service.remove(id: sharedID, for: a))
    #expect(await service.item(id: sharedID, for: a) == nil)
    #expect(await service.item(id: sharedID, for: b) != nil)

    await service.removeAll(for: a)
    #expect(await service.count(for: b) == 1)
}
