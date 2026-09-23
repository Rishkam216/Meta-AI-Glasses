import Foundation
import Testing
@testable import AgentCore

private func sourceMemory(
    id: UUID = UUID(),
    tenant: TenantContext,
    scope: MemoryScope = .user,
    content: String,
    source: String = "conversation:1",
    createdAt: Date = Date(timeIntervalSince1970: 1_000),
    supersedes: [UUID] = []
) throws -> MemoryRecord {
    try MemoryRecord(
        id: id,
        tenant: tenant,
        scope: scope,
        kind: .sourceBacked,
        content: .string(content),
        sourceReferences: [
            MemorySourceReference(
                type: .conversation,
                reference: source,
                sourceTimestamp: createdAt
            )
        ],
        supersedes: supersedes,
        createdAt: createdAt
    )
}

@Test func canonicalRecordRoundTripPreservesSourceProvenanceAndOwnership() throws {
    let tenant = TenantContext(tenantID: UUID(), userID: UUID(), accountID: UUID())
    let created = Date(timeIntervalSince1970: 1_000)
    let record = try sourceMemory(
        tenant: tenant,
        content: "SECND backend is deployed on Render",
        source: "conversation:829/message:14",
        createdAt: created
    )

    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(MemoryRecord.self, from: data)

    #expect(decoded == record)
    #expect(decoded.tenant == tenant)
    #expect(decoded.sourceReferences.count == 1)
    #expect(decoded.sourceReferences[0].sourceTimestamp == created)
    #expect(decoded.state == .active)
    #expect(decoded.supersededBy == nil)
}

@Test func malformedWireMemoryCannotBypassValidation() throws {
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let valid = try sourceMemory(tenant: tenant, content: "valid")
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String: Any]
    object["confidence"] = 1.5
    let invalidConfidence = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: MemoryValidationError.invalidConfidence) {
        _ = try JSONDecoder().decode(MemoryRecord.self, from: invalidConfidence)
    }

    object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String: Any]
    object["state"] = "superseded"
    object.removeValue(forKey: "supersededBy")
    let invalidLifecycle = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: MemoryValidationError.inconsistentLifecycle) {
        _ = try JSONDecoder().decode(MemoryRecord.self, from: invalidLifecycle)
    }
}

@Test func insertRejectsWrongPrincipalAndNeverCreatesCrossTenantCopy() async throws {
    let owner = TenantContext(tenantID: UUID(), userID: UUID())
    let other = TenantContext(tenantID: owner.tenantID, userID: UUID())
    let ledger = InMemoryMemoryLedger()
    let record = try sourceMemory(
        tenant: owner,
        content: "ALPHA-PINEAPPLE-7834"
    )

    await #expect(throws: MemoryLedgerError.ownershipMismatch) {
        try await ledger.insert(record, as: other)
    }
    #expect(await ledger.memory(id: record.id, as: owner) == nil)
    #expect(await ledger.memory(id: record.id, as: other) == nil)
}

@Test func sameCanonicalIDIsIsolatedAcrossPrincipals() async throws {
    let ledger = InMemoryMemoryLedger()
    let sharedID = UUID()
    let a = TenantContext(tenantID: UUID(), userID: UUID())
    let b = TenantContext(tenantID: UUID(), userID: UUID())
    let recordA = try sourceMemory(id: sharedID, tenant: a, content: "ALPHA-PINEAPPLE-7834")
    let recordB = try sourceMemory(id: sharedID, tenant: b, content: "BETA-ZEBRA-9911")

    try await ledger.insert(recordA, as: a)
    try await ledger.insert(recordB, as: b)

    #expect(await ledger.memory(id: sharedID, as: a)?.content == .string("ALPHA-PINEAPPLE-7834"))
    #expect(await ledger.memory(id: sharedID, as: b)?.content == .string("BETA-ZEBRA-9911"))
}

@Test func derivedMemoryMustReferenceCanonicalMemoryInSamePartition() async throws {
    let ledger = InMemoryMemoryLedger()
    let owner = TenantContext(tenantID: UUID(), userID: UUID())
    let other = TenantContext(tenantID: owner.tenantID, userID: UUID())
    let source = try sourceMemory(tenant: owner, content: "I use my MacBook for SECND")
    try await ledger.insert(source, as: owner)

    let derived = try MemoryRecord(
        tenant: owner,
        scope: .user,
        kind: .derived,
        content: .object(["preferred_coding_device": .string("MacBook")]),
        derivedFromMemoryIDs: [source.id],
        confidence: 0.9
    )
    try await ledger.insert(derived, as: owner)
    #expect(await ledger.memory(id: derived.id, as: owner)?.derivedFromMemoryIDs == [source.id])

    let crossPartitionDerived = try MemoryRecord(
        tenant: other,
        scope: .user,
        kind: .derived,
        content: .string("should fail"),
        derivedFromMemoryIDs: [source.id]
    )
    await #expect(throws: MemoryLedgerError.derivedMemoryNotFound(source.id)) {
        try await ledger.insert(crossPartitionDerived, as: other)
    }
}

@Test func supersessionKeepsHistoryAndActiveQueryReturnsNewFact() async throws {
    let ledger = InMemoryMemoryLedger()
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let old = try sourceMemory(
        tenant: tenant,
        content: "SECND backend is deployed on Render",
        createdAt: Date(timeIntervalSince1970: 1_000)
    )
    try await ledger.insert(old, as: tenant)

    let replacement = try sourceMemory(
        tenant: tenant,
        content: "SECND backend is deployed on AWS",
        source: "conversation:replacement",
        createdAt: Date(timeIntervalSince1970: 2_000),
        supersedes: [old.id]
    )
    try await ledger.supersede(
        with: replacement,
        as: tenant,
        at: Date(timeIntervalSince1970: 2_000)
    )

    let storedOld = await ledger.memory(id: old.id, as: tenant)
    #expect(storedOld?.state == .superseded)
    #expect(storedOld?.supersededBy == replacement.id)
    #expect(await ledger.memory(id: replacement.id, as: tenant)?.state == .active)

    let active = await ledger.query(try MemoryLedgerQuery(), as: tenant)
    #expect(active.map(\.id) == [replacement.id])

    let history = await ledger.query(
        try MemoryLedgerQuery(includeSuperseded: true),
        as: tenant
    )
    #expect(Set(history.map(\.id)) == Set([old.id, replacement.id]))
}

@Test func failedSupersessionIsAtomicAndCannotReparentHistoricalFact() async throws {
    let ledger = InMemoryMemoryLedger()
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let first = try sourceMemory(tenant: tenant, content: "v1")
    try await ledger.insert(first, as: tenant)

    let missingID = UUID()
    let invalid = try sourceMemory(
        tenant: tenant,
        content: "invalid",
        supersedes: [first.id, missingID]
    )
    await #expect(throws: MemoryLedgerError.supersededMemoryNotFound(missingID)) {
        try await ledger.supersede(with: invalid, as: tenant, at: Date(timeIntervalSince1970: 2_000))
    }
    #expect(await ledger.memory(id: first.id, as: tenant)?.state == .active)
    #expect(await ledger.memory(id: invalid.id, as: tenant) == nil)

    let second = try sourceMemory(tenant: tenant, content: "v2", supersedes: [first.id])
    try await ledger.supersede(with: second, as: tenant, at: Date(timeIntervalSince1970: 2_000))

    let third = try sourceMemory(tenant: tenant, content: "v3", supersedes: [first.id])
    await #expect(throws: MemoryLedgerError.memoryAlreadySuperseded(first.id)) {
        try await ledger.supersede(with: third, as: tenant, at: Date(timeIntervalSince1970: 3_000))
    }
    #expect(await ledger.memory(id: first.id, as: tenant)?.supersededBy == second.id)
}

@Test func plainInsertCannotCreateHalfSupersession() async throws {
    let ledger = InMemoryMemoryLedger()
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let old = try sourceMemory(tenant: tenant, content: "old")
    try await ledger.insert(old, as: tenant)
    let replacement = try sourceMemory(tenant: tenant, content: "new", supersedes: [old.id])

    await #expect(throws: MemoryLedgerError.supersessionRequiresTransaction) {
        try await ledger.insert(replacement, as: tenant)
    }
    #expect(await ledger.memory(id: old.id, as: tenant)?.state == .active)
    #expect(await ledger.memory(id: replacement.id, as: tenant) == nil)
}

@Test func providerMappingsAreReplaceableAndCanonicalIDStaysStable() async throws {
    let ledger = InMemoryMemoryLedger()
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let memory = try sourceMemory(tenant: tenant, content: "portable")
    try await ledger.insert(memory, as: tenant)

    let supermemory = try MemoryProviderMapping(
        memoryID: memory.id,
        provider: " SuperMemory ",
        providerMemoryID: " sm_123 ",
        metadata: .object(["container": .string("user-private")])
    )
    let zep = try MemoryProviderMapping(
        memoryID: memory.id,
        provider: "zep",
        providerMemoryID: "zep_987"
    )
    try await ledger.setProviderMapping(supermemory, as: tenant)
    try await ledger.setProviderMapping(zep, as: tenant)

    let mappings = await ledger.providerMappings(memoryID: memory.id, as: tenant)
    #expect(mappings.map(\.provider) == ["supermemory", "zep"])
    #expect(mappings.allSatisfy { $0.memoryID == memory.id })
    #expect(await ledger.memory(id: memory.id, as: tenant)?.id == memory.id)
}

@Test func providerExternalIDCannotIdentifyTwoCanonicalMemoriesWithinPrincipal() async throws {
    let ledger = InMemoryMemoryLedger()
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let one = try sourceMemory(tenant: tenant, content: "one")
    let two = try sourceMemory(tenant: tenant, content: "two")
    try await ledger.insert(one, as: tenant)
    try await ledger.insert(two, as: tenant)

    try await ledger.setProviderMapping(
        MemoryProviderMapping(memoryID: one.id, provider: "supermemory", providerMemoryID: "sm_shared"),
        as: tenant
    )
    await #expect(throws: MemoryLedgerError.providerMappingConflict) {
        try await ledger.setProviderMapping(
            MemoryProviderMapping(memoryID: two.id, provider: "SUPERMEMORY", providerMemoryID: "sm_shared"),
            as: tenant
        )
    }
}

@Test func sameProviderExternalIDMayExistInDifferentTenantPartitions() async throws {
    let ledger = InMemoryMemoryLedger()
    let a = TenantContext(tenantID: UUID(), userID: UUID())
    let b = TenantContext(tenantID: UUID(), userID: UUID())
    let one = try sourceMemory(tenant: a, content: "one")
    let two = try sourceMemory(tenant: b, content: "two")
    try await ledger.insert(one, as: a)
    try await ledger.insert(two, as: b)

    try await ledger.setProviderMapping(
        MemoryProviderMapping(memoryID: one.id, provider: "supermemory", providerMemoryID: "external_1"),
        as: a
    )
    try await ledger.setProviderMapping(
        MemoryProviderMapping(memoryID: two.id, provider: "supermemory", providerMemoryID: "external_1"),
        as: b
    )

    #expect(await ledger.providerMappings(memoryID: one.id, as: a).count == 1)
    #expect(await ledger.providerMappings(memoryID: two.id, as: b).count == 1)
}

@Test func portableExportContainsCanonicalHistoryAndProviderMappingsOnlyForPrincipal() async throws {
    let ledger = InMemoryMemoryLedger()
    let a = TenantContext(tenantID: UUID(), userID: UUID())
    let b = TenantContext(tenantID: UUID(), userID: UUID())
    let old = try sourceMemory(tenant: a, content: "old")
    try await ledger.insert(old, as: a)
    let replacement = try sourceMemory(tenant: a, content: "new", supersedes: [old.id])
    try await ledger.supersede(with: replacement, as: a, at: Date(timeIntervalSince1970: 2_000))
    try await ledger.setProviderMapping(
        MemoryProviderMapping(memoryID: replacement.id, provider: "supermemory", providerMemoryID: "sm_new"),
        as: a
    )

    let foreign = try sourceMemory(tenant: b, content: "BETA-ZEBRA-9911")
    try await ledger.insert(foreign, as: b)

    let exportedAt = Date(timeIntervalSince1970: 9_999)
    let export = await ledger.export(as: a, at: exportedAt)
    #expect(export.formatVersion == 3)
    #expect(export.exportedAt == exportedAt)
    #expect(Set(export.memories.map(\.id)) == Set([old.id, replacement.id]))
    #expect(export.providerMappings.map(\.providerMemoryID) == ["sm_new"])
    #expect(!export.memories.contains { $0.id == foreign.id })

    let roundTrip = try JSONDecoder().decode(
        PortableMemoryExport.self,
        from: JSONEncoder().encode(export)
    )
    #expect(roundTrip == export)
}

@Test func canonicalMemoryJSONDoesNotContainProviderIdentity() throws {
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let memory = try sourceMemory(tenant: tenant, content: "canonical")
    let json = String(data: try JSONEncoder().encode(memory), encoding: .utf8)!

    #expect(!json.contains("providerMemoryID"))
    #expect(!json.contains("supermemory"))
}

@Test func queryIsBoundedAndFiltersScopeAndKind() async throws {
    let ledger = InMemoryMemoryLedger()
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let project = try MemoryScope.project("secnd")
    let source = try sourceMemory(tenant: tenant, scope: project, content: "source")
    try await ledger.insert(source, as: tenant)
    let derived = try MemoryRecord(
        tenant: tenant,
        scope: project,
        kind: .derived,
        content: .string("derived"),
        derivedFromMemoryIDs: [source.id],
        createdAt: Date(timeIntervalSince1970: 2_000)
    )
    try await ledger.insert(derived, as: tenant)

    let result = await ledger.query(
        try MemoryLedgerQuery(scope: project, kinds: [.derived], limit: 1),
        as: tenant
    )
    #expect(result.map(\.id) == [derived.id])

    #expect(throws: MemoryValidationError.invalidLimit) {
        _ = try MemoryLedgerQuery(limit: 0)
    }
    #expect(throws: MemoryValidationError.invalidLimit) {
        _ = try MemoryLedgerQuery(limit: 101)
    }
}

