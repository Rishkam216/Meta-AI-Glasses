import Foundation
import Testing
@testable import AgentCore

@Test func canonicalContextSearchRanksAcrossFullBoundedScopePage() async throws {
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let ledger = InMemoryMemoryLedger()
    let service = try MemoryService(principal: principal, ledger: ledger)

    let targetTime = Date(timeIntervalSince1970: 1_000)
    let target = try MemoryRecord(
        tenant: principal,
        scope: .user,
        kind: .sourceBacked,
        content: .string("needle-banana-7834 is the relevant long-term fact"),
        sourceReferences: [
            MemorySourceReference(
                type: .conversation,
                reference: "ranking-target",
                sourceTimestamp: targetTime
            )
        ],
        confidence: 0.9,
        createdAt: targetTime
    )
    _ = try await service.remember(target, as: principal, at: targetTime)

    // Keep the relevant memory older than the previous 24-candidate prefilter.
    // Retrieval must rank over the full bounded ledger page, not only the newest
    // records selected by the requested result count.
    for index in 0..<30 {
        let timestamp = Date(timeIntervalSince1970: 2_000 + Double(index))
        let decoy = try MemoryRecord(
            tenant: principal,
            scope: .user,
            kind: .sourceBacked,
            content: .string("unrelated decoy fact number \(index)"),
            sourceReferences: [
                MemorySourceReference(
                    type: .conversation,
                    reference: "ranking-decoy-\(index)",
                    sourceTimestamp: timestamp
                )
            ],
            confidence: 0.9,
            createdAt: timestamp
        )
        _ = try await service.remember(decoy, as: principal, at: timestamp)
    }

    let query = try MemoryContextQuery(
        text: "needle banana relevant fact",
        scopes: [.user],
        limit: 1
    )
    let results = try await service.retrieveForContext(query, as: principal)

    #expect(results.count == 1)
    #expect(results[0].record.id == target.id)
}
