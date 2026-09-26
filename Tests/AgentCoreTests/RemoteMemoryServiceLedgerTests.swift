import Foundation
import Testing
@testable import AgentCore

private actor SnapshotStoreDouble: CanonicalMemorySnapshotStore {
    private var revision: UInt64
    private var snapshot: PortableMemoryExport?
    private var conflictsRemaining: Int
    private var loadCount = 0
    private var commitCount = 0

    init(revision: UInt64 = 0, snapshot: PortableMemoryExport? = nil,
         conflictsRemaining: Int = 0) {
        self.revision = revision
        self.snapshot = snapshot
        self.conflictsRemaining = conflictsRemaining
    }

    func load() -> CanonicalMemoryRemoteState {
        loadCount += 1
        return CanonicalMemoryRemoteState(revision: revision, snapshot: snapshot)
    }

    func commit(_ snapshot: PortableMemoryExport, expectedRevision: UInt64) throws -> UInt64 {
        commitCount += 1
        if conflictsRemaining > 0 {
            conflictsRemaining -= 1
            throw CanonicalMemoryStoreError.stateConflict
        }
        guard expectedRevision == revision else { throw CanonicalMemoryStoreError.stateConflict }
        revision += 1
        self.snapshot = snapshot
        return revision
    }

    func counts() -> (loads: Int, commits: Int) { (loadCount, commitCount) }
}

private func remoteRecord(_ principal: TenantContext, id: UUID = UUID(),
                          content: String = "REMOTE-CANARY") throws -> MemoryRecord {
    try MemoryRecord(id: id, tenant: principal, scope: .user, kind: .sourceBacked,
                     content: .string(content),
                     sourceReferences: [MemorySourceReference(type: .userEntry, reference: "test")],
                     createdAt: Date(timeIntervalSince1970: 1_000))
}

@Test func remoteLedgerPersistsMemoryServiceStateAcrossInstancesAndDeletion() async throws {
    let principal = TenantContext(tenantID: UUID(), userID: UUID(), accountID: UUID())
    let store = SnapshotStoreDouble()
    let firstLedger = RemoteMemoryServiceLedger(principal: principal, store: store)
    let service = try MemoryService(principal: principal, ledger: firstLedger)
    let record = try remoteRecord(principal)

    let receipt = try await service.remember(record, as: principal,
                                             at: Date(timeIntervalSince1970: 1_100))
    #expect(receipt.memoryID == record.id)
    #expect(receipt.pendingProviderOperations == 0)

    let secondLedger = RemoteMemoryServiceLedger(principal: principal, store: store)
    let restored = try await secondLedger.export(as: principal,
                                                  at: Date(timeIntervalSince1970: 1_200))
    #expect(restored.memories == [record])
    #expect(restored.tombstones.isEmpty)

    _ = try await service.forget(id: record.id, as: principal,
                                 at: Date(timeIntervalSince1970: 1_300))
    let afterDelete = try await secondLedger.export(as: principal,
                                                     at: Date(timeIntervalSince1970: 1_400))
    #expect(afterDelete.memories.isEmpty)
    #expect(afterDelete.tombstones.map(\.memoryID) == [record.id])
}

@Test func remoteLedgerRetriesCASConflictWithoutDroppingMutation() async throws {
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let store = SnapshotStoreDouble(conflictsRemaining: 1)
    let ledger = RemoteMemoryServiceLedger(principal: principal, store: store)
    let record = try remoteRecord(principal)

    try await ledger.insert(record, as: principal)
    #expect(try await ledger.memory(id: record.id, as: principal) == record)
    let counts = await store.counts()
    #expect(counts.commits == 2)
    #expect(counts.loads >= 3) // two mutation attempts plus the verification read
}

@Test func remoteLedgerPersistsProviderQueueAtomicallyWithCanonicalMemory() async throws {
    let principal = TenantContext(tenantID: UUID(), userID: UUID(), accountID: UUID())
    let store = SnapshotStoreDouble()
    let ledger = RemoteMemoryServiceLedger(principal: principal, store: store)
    let record = try remoteRecord(principal)
    let timestamp = Date(timeIntervalSince1970: 2_000)

    try await ledger.remember(record, replacing: false, providers: ["test.index-v1"],
                              as: principal, at: timestamp)
    let restarted = RemoteMemoryServiceLedger(principal: principal, store: store)
    let snapshot = try await restarted.export(as: principal, at: timestamp)

    #expect(snapshot.memories.map(\.id) == [record.id])
    #expect(snapshot.synchronization.providers == ["test.index-v1"])
    #expect(snapshot.synchronization.entries.count == 1)
    #expect(snapshot.synchronization.entries[0].memoryID == record.id)
    #expect(snapshot.synchronization.entries[0].action == .upsert)
    #expect(snapshot.synchronization.entries[0].acknowledged == false)
}

@Test func remoteLedgerRejectsForeignCallerBeforeTouchingRemoteStore() async throws {
    let owner = TenantContext(tenantID: UUID(), userID: UUID())
    let foreign = TenantContext(tenantID: owner.tenantID, userID: UUID())
    let store = SnapshotStoreDouble()
    let ledger = RemoteMemoryServiceLedger(principal: owner, store: store)

    do {
        _ = try await ledger.export(as: foreign, at: Date())
        Issue.record("foreign caller unexpectedly reached the ledger")
    } catch {
        #expect(error as? MemoryLedgerError == .ownershipMismatch)
    }
    #expect(await store.counts().loads == 0)
}

@Test func remoteLedgerRefusesMalformedForeignSnapshotInsteadOfOverwritingIt() async throws {
    let owner = TenantContext(tenantID: UUID(), userID: UUID())
    let foreign = TenantContext(tenantID: UUID(), userID: UUID())
    let foreignRecord = try remoteRecord(foreign)
    let poisoned = PortableMemoryExport(exportedAt: Date(timeIntervalSince1970: 1),
                                        memories: [foreignRecord], providerMappings: [])
    let store = SnapshotStoreDouble(revision: 1, snapshot: poisoned)
    let ledger = RemoteMemoryServiceLedger(principal: owner, store: store)

    do {
        _ = try await ledger.export(as: owner, at: Date())
        Issue.record("foreign remote snapshot unexpectedly loaded")
    } catch {
        #expect(error as? CanonicalMemoryStoreError == .invalidResponse)
    }
    #expect(await store.counts().commits == 0)
}
