import Foundation
import Testing
@testable import AgentCore

private func historyMemory(
    id: UUID = UUID(),
    tenant: TenantContext,
    scope: MemoryScope = .user,
    content: String,
    createdAt: Date,
    state: MemoryLifecycleState = .active,
    supersedes: [UUID] = [],
    supersededBy: UUID? = nil
) throws -> MemoryRecord {
    try MemoryRecord(
        id: id,
        tenant: tenant,
        scope: scope,
        kind: .sourceBacked,
        content: .string(content),
        sourceReferences: [
            MemorySourceReference(
                type: .userEntry,
                reference: "test:\(id.uuidString)",
                sourceTimestamp: createdAt
            )
        ],
        state: state,
        supersedes: supersedes,
        supersededBy: supersededBy,
        createdAt: createdAt
    )
}

@Test func normalInsertRejectsPrebuiltHistoricalRecord() async throws {
    let ledger = InMemoryMemoryLedger()
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let recordID = UUID()
    let historical = try historyMemory(
        id: recordID,
        tenant: tenant,
        content: "historical",
        createdAt: Date(timeIntervalSince1970: 1_000),
        state: .superseded,
        supersededBy: UUID()
    )

    await #expect(throws: MemoryLedgerError.nonActiveInsert) {
        try await ledger.insert(historical, as: tenant)
    }
    #expect(await ledger.memory(id: historical.id, as: tenant) == nil)
}

@Test func supersedeRequiresAtLeastOneTarget() async throws {
    let ledger = InMemoryMemoryLedger()
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let record = try historyMemory(
        tenant: tenant,
        content: "not actually replacing anything",
        createdAt: Date(timeIntervalSince1970: 1_000)
    )

    await #expect(throws: MemoryLedgerError.supersessionRequiresTarget) {
        try await ledger.supersede(
            with: record,
            as: tenant,
            at: Date(timeIntervalSince1970: 1_001)
        )
    }
}

@Test func supersessionCannotMoveHistoryBackwardInTime() async throws {
    let ledger = InMemoryMemoryLedger()
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let old = try historyMemory(
        tenant: tenant,
        content: "old",
        createdAt: Date(timeIntervalSince1970: 2_000)
    )
    try await ledger.insert(old, as: tenant)
    let replacement = try historyMemory(
        tenant: tenant,
        content: "new",
        createdAt: Date(timeIntervalSince1970: 3_000),
        supersedes: [old.id]
    )

    await #expect(throws: MemoryLedgerError.nonMonotonicSupersession(replacement.id)) {
        try await ledger.supersede(
            with: replacement,
            as: tenant,
            at: Date(timeIntervalSince1970: 2_500)
        )
    }
    #expect(await ledger.memory(id: old.id, as: tenant)?.state == .active)
    #expect(await ledger.memory(id: replacement.id, as: tenant) == nil)
}

@Test func supersessionCannotCrossMemoryScopes() async throws {
    let ledger = InMemoryMemoryLedger()
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let project = try MemoryScope.project("secnd")
    let old = try historyMemory(
        tenant: tenant,
        scope: .user,
        content: "user-level fact",
        createdAt: Date(timeIntervalSince1970: 1_000)
    )
    try await ledger.insert(old, as: tenant)
    let replacement = try historyMemory(
        tenant: tenant,
        scope: project,
        content: "project fact",
        createdAt: Date(timeIntervalSince1970: 2_000),
        supersedes: [old.id]
    )

    await #expect(throws: MemoryLedgerError.supersessionScopeMismatch(old.id)) {
        try await ledger.supersede(
            with: replacement,
            as: tenant,
            at: Date(timeIntervalSince1970: 2_000)
        )
    }
    #expect(await ledger.memory(id: old.id, as: tenant)?.state == .active)
}
