import Foundation
import Testing
@testable import AgentCore

/// Contract simulator, not a claim about Supermemory's processing lifecycle.
private actor LifecycleDriver: MemoryMutationDriver {
    nonisolated let providerID = "test.fenced-v1"
    nonisolated let verifiedLifecycle: Bool
    private(set) var creates = 0
    private(set) var deletes = 0
    private(set) var observations = 0
    private(set) var attempts: [MemoryIndexAttempt] = []
    private var values: [UUID: MemoryRemoteObservation] = [:]
    var createResult: MemoryRemoteObservation = .settled(providerID: "remote-one")
    var deleteResult: MemoryRemoteObservation = .deleted
    var throwAfterCreate = false
    var throwAfterDelete = false
    private var pause = false
    private var paused = false
    private var release: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    init(verified: Bool = true) { verifiedLifecycle = verified }
    func configure(create: MemoryRemoteObservation, fail: Bool = false) { createResult = create; throwAfterCreate = fail }
    func configureDelete(_ result: MemoryRemoteObservation, fail: Bool = false) { deleteResult = result; throwAfterDelete = fail }
    func pauseCreate() { pause = true }
    func waitForPause() async {
        if paused { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resumeCreate() { release?.resume(); release = nil }
    func setObserved(_ result: MemoryRemoteObservation) { for id in values.keys { values[id] = result } }
    func create(_ attempt: MemoryIndexAttempt, document: MemoryProviderDocument) async throws -> MemoryRemoteObservation {
        creates += 1; attempts.append(attempt)
        if pause {
            pause = false
            await withCheckedContinuation { continuation in
                release = continuation; paused = true; observer?.resume(); observer = nil
            }
        }
        values[attempt.uploadID] = createResult
        if throwAfterCreate { throw NSError(domain: "private-token", code: 500) }
        return createResult
    }
    func observe(_ attempt: MemoryIndexAttempt) -> MemoryRemoteObservation {
        observations += 1
        return values[attempt.uploadID] ?? .unknown
    }
    func delete(_ attempt: MemoryIndexAttempt, providerID: String) throws -> MemoryRemoteObservation {
        deletes += 1
        values[attempt.uploadID] = deleteResult
        if throwAfterDelete { throw NSError(domain: "private-token", code: 500) }
        return deleteResult
    }
}

private actor FencedReader: MemoryProvider {
    nonisolated let descriptor: MemoryProviderDescriptor
    var hits: [MemoryProviderHit] = []
    init() throws {
        descriptor = try .init(id: "test.fenced-v1", capabilities: .init(namespaceIsolation: true,
            scopeFiltering: true, idempotentRevisionFencing: false, search: true))
    }
    func setHits(_ value: [MemoryProviderHit]) { hits = value }
    func apply(_ mutation: MemoryProviderMutation) throws -> MemoryProviderReceipt { throw MemoryProviderError.unsupportedFeature }
    func search(_ query: MemorySearchQuery, in namespace: MemoryProviderNamespace) -> MemoryProviderResults {
        .init(namespace: namespace, hits: hits)
    }
}

private struct FenceFixture {
    let principal = TenantContext(tenantID: UUID(), userID: UUID(), accountID: UUID())
    let directory: URL
    var url: URL { directory.appendingPathComponent("fence.json") }
    var namespace: MemoryProviderNamespace { .init(principal: principal) }
    init() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("fence-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try RevisionFencedMemoryProvider.provision(url: url, principal: principal, providerID: "test.fenced-v1")
    }
    func clean() { try? FileManager.default.removeItem(at: directory) }
    func record(id: UUID = UUID(), content: String = "PRIVATE-CANARY-7834") throws -> MemoryRecord {
        try MemoryRecord(id: id, tenant: principal, scope: .user, kind: .sourceBacked, content: .string(content),
            sourceReferences: [MemorySourceReference(type: .conversation, reference: "private-source")], createdAt: Date())
    }
    func mutation(_ record: MemoryRecord, revision: UInt64 = 1, operation: UUID = UUID(), deleting: Bool = false) -> MemoryProviderMutation {
        .init(namespace: namespace, canonicalID: record.id, revision: revision, operationID: operation,
              action: deleting ? .delete : .upsert, document: deleting ? nil : MemoryProviderDocument(record))
    }
    func open(_ driver: LifecycleDriver, reader: FencedReader? = nil) throws -> RevisionFencedMemoryProvider {
        try .init(url: url, principal: principal, driver: driver, reader: try reader ?? FencedReader())
    }
}

@Test func fencedProviderDurableReplayAndPermanentTombstone() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver(), record = try f.record(), operation = UUID()
    let mutation = f.mutation(record, operation: operation)
    let first = try await f.open(driver).apply(mutation)
    #expect(try await f.open(driver).apply(mutation) == first)
    #expect(await driver.creates == 1)
    let deletion = f.mutation(record, revision: 2, deleting: true)
    #expect(try await f.open(driver).apply(deletion).action == .delete)
    #expect(try await f.open(driver).apply(deletion).providerMemoryID == nil)
    #expect(await driver.deletes == 1)
    await #expect(throws: MemoryProviderError.staleRevision) { try await f.open(driver).apply(mutation) }
    await #expect(throws: MemoryProviderError.mutationConflict) {
        try await f.open(driver).apply(f.mutation(record, revision: 3))
    }
    let bytes = try String(contentsOf: f.url, encoding: .utf8)
    #expect(!bytes.contains("PRIVATE-CANARY-7834"))
    #expect(!bytes.contains("private-source"))
}

@Test func fencedProviderCrashAfterClaimDoesNotResendOrAcknowledgeDelete() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver(), record = try f.record()
    let mutation = f.mutation(record)
    // Simulate a crash immediately after fsync of dispatch intent, before network.
    let journal = try MemoryMutationJournal(url: f.url, principal: f.principal, providerID: driver.providerID)
    #expect(try journal.acceptAndClaim(mutation, maxDocumentBytes: 32_768) != nil)
    for _ in 0..<3 {
        await #expect(throws: MemoryProviderError.operationPending) { try await f.open(driver).apply(mutation) }
    }
    let deletion = f.mutation(record, revision: 2, deleting: true)
    await #expect(throws: MemoryProviderError.operationPending) { try await f.open(driver).apply(deletion) }
    #expect(await driver.creates == 0)
    #expect(await driver.deletes == 0)
    #expect(!String(decoding: try Data(contentsOf: f.url), as: UTF8.self).contains("PRIVATE-CANARY-7834"))
}

@Test func fencedProviderLostCreateResponseReconcilesWithoutReplay() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver(), record = try f.record()
    await driver.configure(create: .settled(providerID: "remote-one"), fail: true)
    let mutation = f.mutation(record)
    await #expect(throws: MemoryProviderError.unavailable) { try await f.open(driver).apply(mutation) }
    let receipt = try await f.open(driver).apply(mutation)
    #expect(receipt.providerMemoryID == "remote-one")
    #expect(await driver.creates == 1)
    #expect(await driver.observations == 1)
}

@Test func fencedProviderNeverDeletesWhileAnEarlierCreateCanStillRun() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver(), record = try f.record()
    await driver.pauseCreate()
    let provider = try f.open(driver)
    let upsert = f.mutation(record), deletion = f.mutation(record, revision: 2, deleting: true)
    let task = Task { try await provider.apply(upsert) }
    await driver.waitForPause()
    // Another process/handle accepts deletion while original worker is paused
    // AFTER durable claim and BEFORE issuing the remote create.
    await #expect(throws: MemoryProviderError.operationPending) { try await f.open(driver).apply(deletion) }
    #expect(await driver.deletes == 0)
    await driver.resumeCreate()
    await #expect(throws: MemoryProviderError.staleRevision) { try await task.value }
    #expect(try await f.open(driver).apply(deletion).action == .delete)
    #expect(await driver.creates == 1)
    #expect(await driver.deletes == 1)
    await #expect(throws: MemoryProviderError.staleRevision) { try await f.open(driver).apply(upsert) }
}

@Test func fencedProviderProcessingIsNotAcknowledgementOrPermissionToDelete() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver(), record = try f.record()
    await driver.configure(create: .processing(providerID: "remote-one"))
    let upsert = f.mutation(record), deletion = f.mutation(record, revision: 2, deleting: true)
    await #expect(throws: MemoryProviderError.operationPending) { try await f.open(driver).apply(upsert) }
    await #expect(throws: MemoryProviderError.operationPending) { try await f.open(driver).apply(deletion) }
    #expect(await driver.deletes == 0)
    await driver.setObserved(.settled(providerID: "remote-one"))
    // This invocation only observes completion; the following one claims delete.
    await #expect(throws: MemoryProviderError.operationPending) { try await f.open(driver).apply(deletion) }
    #expect(try await f.open(driver).apply(deletion).action == .delete)
    #expect(await driver.creates == 1)
    #expect(await driver.deletes == 1)
}

@Test func fencedProviderLostDeleteResponseDoesNotResendDelete() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver(), record = try f.record()
    _ = try await f.open(driver).apply(f.mutation(record))
    await driver.configureDelete(.deleted, fail: true)
    let deletion = f.mutation(record, revision: 2, deleting: true)
    await #expect(throws: MemoryProviderError.unavailable) { try await f.open(driver).apply(deletion) }
    #expect(try await f.open(driver).apply(deletion).action == .delete)
    #expect(await driver.deletes == 1)
}

@Test func fencedProviderDeletionRemainsPendingUntilStrongConfirmation() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver(), record = try f.record()
    _ = try await f.open(driver).apply(f.mutation(record))
    await driver.configureDelete(.unknown)
    let deletion = f.mutation(record, revision: 2, deleting: true)
    for _ in 0..<3 {
        await #expect(throws: MemoryProviderError.operationPending) { try await f.open(driver).apply(deletion) }
    }
    #expect(await driver.deletes == 1)
    await driver.setObserved(.deleted)
    #expect(try await f.open(driver).apply(deletion).action == .delete)
}

@Test func fencedProviderUnknownIDDeletionNeverSendsAndBlocksLaterUpload() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver(), record = try f.record()
    let deletion = f.mutation(record, revision: 10, deleting: true)
    #expect(try await f.open(driver).apply(deletion).action == .delete)
    await #expect(throws: MemoryProviderError.mutationConflict) { try await f.open(driver).apply(f.mutation(record, revision: 11)) }
    #expect(await driver.creates == 0)
    #expect(await driver.deletes == 0)
}

@Test func fencedProviderImmutableContentAndRevisionConflicts() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver(), record = try f.record()
    let original = f.mutation(record)
    _ = try await f.open(driver).apply(original)
    await #expect(throws: MemoryProviderError.mutationConflict) { try await f.open(driver).apply(f.mutation(record)) }
    let changed = try f.record(id: record.id, content: "changed")
    await #expect(throws: MemoryProviderError.mutationConflict) {
        try await f.open(driver).apply(f.mutation(changed, revision: 2))
    }
    #expect(try await f.open(driver).apply(f.mutation(record, revision: 2)).revision == 2)
    #expect(await driver.creates == 1)
}

@Test func fencedProviderRejectsForeignPrincipalDeploymentMissingAndCorruptJournal() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver()
    let other = TenantContext(tenantID: f.principal.tenantID, userID: UUID())
    #expect(throws: MemoryLedgerError.ownershipMismatch) {
        try RevisionFencedMemoryProvider(url: f.url, principal: other, driver: driver, reader: FencedReader())
    }
    #expect(throws: MemoryProviderError.invalidConfiguration) {
        try RevisionFencedMemoryProvider.provision(url: f.url, principal: f.principal, providerID: driver.providerID)
    }
    #expect(throws: MemoryProviderError.invalidConfiguration) {
        try MemoryMutationJournal(url: f.url, principal: f.principal, providerID: "another-deployment")
    }
    let provider = try f.open(driver)
    let record = try f.record()
    let wrong = MemoryProviderMutation(namespace: .init(principal: other), canonicalID: record.id,
        revision: 1, operationID: UUID(), action: .upsert, document: MemoryProviderDocument(record))
    await #expect(throws: MemoryProviderError.invalidQuery) { try await provider.apply(wrong) }
    try Data("corrupt".utf8).write(to: f.url)
    await #expect(throws: MemoryPersistenceError.corruptFile) { try await provider.apply(f.mutation(record)) }
    try FileManager.default.removeItem(at: f.url)
    #expect(throws: MemoryPersistenceError.missingFile) { try f.open(driver) }
    #expect(await driver.creates == 0)
}

@Test func fencedProviderUnverifiedLifecycleCannotBeEnabled() throws {
    let f = try FenceFixture(); defer { f.clean() }
    #expect(throws: MemoryProviderError.invalidConfiguration) { try f.open(LifecycleDriver(verified: false)) }
}

@Test func fencedProviderFiltersTombstonesWhileRemoteDeletionIsPending() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver(), reader = try FencedReader(), record = try f.record()
    let provider = try f.open(driver, reader: reader)
    _ = try await provider.apply(f.mutation(record))
    await reader.setHits([.init(canonicalID: record.id, providerMemoryID: "remote-one", score: 0.9)])
    let query = try MemorySearchQuery(text: "canary", scopes: [.user])
    #expect(try await provider.search(query, in: f.namespace).hits.count == 1)
    await driver.configureDelete(.unknown)
    await #expect(throws: MemoryProviderError.operationPending) { try await provider.apply(f.mutation(record, revision: 2, deleting: true)) }
    #expect(try await f.open(driver, reader: reader).search(query, in: f.namespace).hits.isEmpty)
}

@Test func fencedProviderServiceIntegrationRetainsPendingAndAcknowledgesOnce() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver(), ledger = InMemoryMemoryLedger(), record = try f.record()
    await driver.configure(create: .processing(providerID: "remote-one"))
    let service = try MemoryService(principal: f.principal, ledger: ledger,
        providers: [f.open(driver)], providerProcessingEnabled: true)
    _ = try await service.remember(record, as: f.principal)
    let pending = try await service.synchronize(as: f.principal)
    #expect(pending.remaining == 1 && pending.acknowledged == 0)
    #expect(pending.failures.first?.reason == .operationPending)
    await driver.setObserved(.settled(providerID: "remote-one"))
    #expect(try await service.synchronize(as: f.principal).acknowledged == 1)
    _ = try await service.forget(id: record.id, as: f.principal)
    #expect(try await service.synchronize(as: f.principal).remaining == 0)
    #expect(await driver.creates == 1)
    #expect(await driver.deletes == 1)
}

@Test func fencedProviderConcurrentIdenticalRetryOnlyObserves() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver(), record = try f.record()
    await driver.pauseCreate()
    let mutation = f.mutation(record), provider = try f.open(driver)
    let task = Task { try await provider.apply(mutation) }
    await driver.waitForPause()
    await #expect(throws: MemoryProviderError.operationPending) { try await f.open(driver).apply(mutation) }
    #expect(await driver.creates == 1)
    await driver.resumeCreate()
    #expect(try await task.value.providerMemoryID == "remote-one")
    #expect(try await f.open(driver).apply(mutation).providerMemoryID == "remote-one")
    #expect(await driver.creates == 1)
}

@Test func fencedProviderCancellationPersistsRemoteOutcomeBeforeReturning() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver(), record = try f.record()
    await driver.pauseCreate()
    let mutation = f.mutation(record), provider = try f.open(driver)
    let task = Task { try await provider.apply(mutation) }
    await driver.waitForPause()
    task.cancel()
    await driver.resumeCreate()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await f.open(driver).apply(mutation).providerMemoryID == "remote-one")
    #expect(await driver.creates == 1)
}

@Test func fencedProviderLateObservationCannotReverseCompletedDeletion() throws {
    let f = try FenceFixture(); defer { f.clean() }
    let journal = try MemoryMutationJournal(url: f.url, principal: f.principal, providerID: "test.fenced-v1")
    let record = try f.record(), mutation = f.mutation(record)
    let creation = try #require(try journal.acceptAndClaim(mutation, maxDocumentBytes: 32_768))
    let delayedObservation = try #require(try journal.acceptAndClaim(mutation, maxDocumentBytes: 32_768))
    try journal.record(.settled(providerID: "remote-one"), for: creation)
    let deletion = f.mutation(record, revision: 2, deleting: true)
    let removal = try #require(try journal.acceptAndClaim(deletion, maxDocumentBytes: 32_768))
    try journal.record(.deleted, for: removal)
    try journal.record(.processing(providerID: "remote-one"), for: delayedObservation)
    #expect(try journal.receipt(for: deletion).action == .delete)
    #expect(throws: MemoryProviderError.staleRevision) { try journal.receipt(for: mutation) }
}

@Test func fencedProviderMalformedRemoteIdentityAndPrematureDeletionFailClosed() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver(), record = try f.record(), mutation = f.mutation(record)
    await driver.configure(create: .processing(providerID: "remote-one"))
    await #expect(throws: MemoryProviderError.operationPending) { try await f.open(driver).apply(mutation) }
    await driver.setObserved(.settled(providerID: "foreign-document"))
    await #expect(throws: MemoryProviderError.invalidResponse) { try await f.open(driver).apply(mutation) }
    await driver.setObserved(.deleted)
    await #expect(throws: MemoryProviderError.invalidResponse) { try await f.open(driver).apply(mutation) }
    #expect(await driver.creates == 1)
}

@Test func fencedProviderInvalidMutationDoesNotChangeJournalOrSend() async throws {
    let f = try FenceFixture(); defer { f.clean() }
    let driver = LifecycleDriver(), provider = try f.open(driver)
    let record = try f.record(content: String(repeating: "a", count: 33_000))
    let before = try Data(contentsOf: f.url)
    await #expect(throws: MemoryProviderError.documentTooLarge) { try await provider.apply(f.mutation(record)) }
    await #expect(throws: MemoryProviderError.invalidQuery) { try await provider.apply(f.mutation(record, revision: 0)) }
    #expect(try Data(contentsOf: f.url) == before)
    #expect(await driver.creates == 0)
}
