import Foundation
import Testing
@testable import AgentCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct LedgerFixture {
    let directory: URL
    let principal = TenantContext(tenantID: UUID(), userID: UUID(), accountID: UUID())
    var url: URL { directory.appendingPathComponent("memory.json") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("memory-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    func clean() { try? FileManager.default.removeItem(at: directory) }
    func open(maxFileBytes: Int = 64 * 1_024 * 1_024) throws -> FileBackedMemoryLedger {
        try FileBackedMemoryLedger(url: url, principal: principal, maxFileBytes: maxFileBytes)
    }
    func record(id: UUID = UUID(), content: String = "ALPHA-PINEAPPLE-7834",
                derived: [UUID] = [], supersedes: [UUID] = [],
                time: Double = 1_000.125) throws -> MemoryRecord {
        try MemoryRecord(id: id, tenant: principal, scope: .user,
                         kind: derived.isEmpty ? .sourceBacked : .derived,
                         content: .string(content),
                         sourceReferences: [MemorySourceReference(type: .conversation, reference: "session:1/turn:2")],
                         derivedFromMemoryIDs: derived, supersedes: supersedes,
                         createdAt: Date(timeIntervalSince1970: time))
    }
}

@Test func durableLedgerPreservesHistoryMappingsAndFractionalDatesAcrossRestart() async throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let ledger = try f.open()
    let source = try f.record()
    try await ledger.insert(source, as: f.principal)
    let derived = try f.record(content: "derived", derived: [source.id])
    try await ledger.insert(derived, as: f.principal)
    let newer = try f.record(content: "updated", supersedes: [source.id], time: 2_000.25)
    let timestamp = Date(timeIntervalSince1970: 2_001.875)
    try await ledger.supersede(with: newer, as: f.principal, at: timestamp)
    let mapping = try MemoryProviderMapping(memoryID: newer.id, provider: "Supermemory",
                                            providerMemoryID: "provider-1", metadata: .string("index-v1"), indexedAt: timestamp)
    try await ledger.setProviderMapping(mapping, as: f.principal)
    let before = try await ledger.export(as: f.principal, at: timestamp)
    let reopened = try f.open()
    #expect(try await reopened.export(as: f.principal, at: timestamp) == before)
    #expect(try await reopened.memory(id: source.id, as: f.principal)?.createdAt == source.createdAt)
    #expect(try await reopened.memory(id: source.id, as: f.principal)?.supersededBy == newer.id)
    #expect(try await reopened.memory(id: newer.id, as: f.principal)?.updatedAt == timestamp)
    #expect(try await reopened.query(MemoryLedgerQuery(), as: f.principal).count == 2)
    #expect(try await reopened.providerMappings(memoryID: newer.id, as: f.principal) == [mapping])
}

@Test func durableLedgerRejectsDifferentTenantUserOrAccountOnEveryAPI() async throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let ledger = try f.open()
    let record = try f.record()
    try await ledger.insert(record, as: f.principal)
    let strangers = [
        TenantContext(tenantID: UUID(), userID: f.principal.userID, accountID: f.principal.accountID),
        TenantContext(tenantID: f.principal.tenantID, userID: UUID(), accountID: f.principal.accountID),
        TenantContext(tenantID: f.principal.tenantID, userID: f.principal.userID),
        TenantContext(tenantID: f.principal.tenantID, userID: f.principal.userID, accountID: UUID())
    ]
    for stranger in strangers {
        #expect(throws: MemoryLedgerError.ownershipMismatch) {
            _ = try FileBackedMemoryLedger(url: f.url, principal: stranger)
        }
        await #expect(throws: MemoryLedgerError.ownershipMismatch) { _ = try await ledger.memory(id: record.id, as: stranger) }
        await #expect(throws: MemoryLedgerError.ownershipMismatch) { _ = try await ledger.query(MemoryLedgerQuery(), as: stranger) }
        await #expect(throws: MemoryLedgerError.ownershipMismatch) { _ = try await ledger.export(as: stranger) }
        await #expect(throws: MemoryLedgerError.ownershipMismatch) { _ = try await ledger.providerMappings(memoryID: record.id, as: stranger) }
        await #expect(throws: MemoryLedgerError.ownershipMismatch) { try await ledger.insert(record, as: stranger) }
        await #expect(throws: MemoryLedgerError.ownershipMismatch) { try await ledger.supersede(with: record, as: stranger) }
        await #expect(throws: MemoryLedgerError.ownershipMismatch) {
            try await ledger.setProviderMapping(MemoryProviderMapping(memoryID: record.id, provider: "p", providerMemoryID: "x"), as: stranger)
        }
        await #expect(throws: MemoryLedgerError.ownershipMismatch) { try await ledger.forget(id: record.id, as: stranger) }
    }
    #expect(try await ledger.memory(id: record.id, as: f.principal) == record)
}

@Test func durableLedgerCanaryIsolationWithSameIDsAndProviderIDs() async throws {
    let a = try LedgerFixture(); defer { a.clean() }
    let b = try LedgerFixture(); defer { b.clean() }
    let id = UUID()
    let first = try a.open(), second = try b.open()
    try await first.insert(a.record(id: id), as: a.principal)
    try await second.insert(b.record(id: id, content: "BETA-ZEBRA-9911"), as: b.principal)
    let mapping = try MemoryProviderMapping(memoryID: id, provider: "p", providerMemoryID: "same")
    try await first.setProviderMapping(mapping, as: a.principal)
    try await second.setProviderMapping(mapping, as: b.principal)
    let exportedA = try await first.export(as: a.principal)
    let exportedB = try await second.export(as: b.principal)
    #expect(!String(decoding: try JSONEncoder().encode(exportedA), as: UTF8.self).contains("BETA-ZEBRA-9911"))
    #expect(!String(decoding: try JSONEncoder().encode(exportedB), as: UTF8.self).contains("ALPHA-PINEAPPLE-7834"))
    try await first.forget(id: id, as: a.principal)
    #expect(try await second.memory(id: id, as: b.principal)?.content == .string("BETA-ZEBRA-9911"))
}

@Test func durableLedgerRejectsCrossPrincipalRecordAndForeignDerivation() async throws {
    let a = try LedgerFixture(); defer { a.clean() }
    let b = try LedgerFixture(); defer { b.clean() }
    let ledger = try a.open()
    let foreign = try b.record()
    await #expect(throws: MemoryLedgerError.ownershipMismatch) { try await ledger.insert(foreign, as: a.principal) }
    let derived = try a.record(derived: [foreign.id])
    await #expect(throws: MemoryLedgerError.derivedMemoryNotFound(foreign.id)) { try await ledger.insert(derived, as: a.principal) }
    #expect(try await ledger.query(MemoryLedgerQuery(), as: a.principal).isEmpty)
}

@Test func durableLedgerFailedSupersessionAndMappingAreAtomic() async throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let ledger = try f.open()
    let a = try f.record(), b = try f.record()
    try await ledger.insert(a, as: f.principal)
    try await ledger.insert(b, as: f.principal)
    try await ledger.setProviderMapping(MemoryProviderMapping(memoryID: a.id, provider: "p", providerMemoryID: "collision"), as: f.principal)
    let before = try Data(contentsOf: f.url)
    let missing = UUID()
    let replacement = try f.record(supersedes: [a.id, missing], time: 2_000)
    await #expect(throws: MemoryLedgerError.supersededMemoryNotFound(missing)) {
        try await ledger.supersede(with: replacement, as: f.principal, at: Date(timeIntervalSince1970: 2_001))
    }
    await #expect(throws: MemoryLedgerError.providerMappingConflict) {
        try await ledger.setProviderMapping(MemoryProviderMapping(memoryID: b.id, provider: "p", providerMemoryID: "collision"), as: f.principal)
    }
    #expect(try Data(contentsOf: f.url) == before)
    #expect(try await f.open().memory(id: a.id, as: f.principal)?.state == .active)
}

@Test func durableLedgerTwoOpenHandlesReloadBeforeWriting() async throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let first = try f.open(), second = try f.open()
    let a = try f.record(), b = try f.record()
    try await first.insert(a, as: f.principal)
    try await second.insert(b, as: f.principal)
    #expect(try await first.query(MemoryLedgerQuery(), as: f.principal).count == 2)
    #expect(try await second.memory(id: a.id, as: f.principal) == a)
}

@Test func durableLedgerConcurrentHandlesNeverLoseAcceptedWrites() async throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let first = try f.open(), second = try f.open()
    let records = try (0..<20).map { try f.record(content: "record-\($0)") }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for (index, record) in records.enumerated() {
            let ledger = index % 2 == 0 ? first : second
            group.addTask {
                for attempt in 0..<100 {
                    do { try await ledger.insert(record, as: f.principal); return }
                    catch MemoryPersistenceError.busy where attempt < 99 { try await Task.sleep(for: .milliseconds(2)) }
                }
            }
        }
        try await group.waitForAll()
    }
    #expect(try await first.query(MemoryLedgerQuery(), as: f.principal).count == records.count)
}

@Test func durableLedgerSizeFailureLeavesDiskUnchanged() async throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let ledger = try f.open(maxFileBytes: 2_048)
    let before = try Data(contentsOf: f.url)
    let huge = try f.record(content: String(repeating: "x", count: 3_000))
    await #expect(throws: MemoryPersistenceError.fileTooLarge) { try await ledger.insert(huge, as: f.principal) }
    #expect(try Data(contentsOf: f.url) == before)
    #expect(try await ledger.memory(id: huge.id, as: f.principal) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).sorted() == ["memory.json", "memory.json.lock"])
}

@Test func durableLedgerCorruptionAndDisappearanceThrowThroughProtocol() async throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let ledger: any MemoryLedgerStoring = try f.open()
    try Data("broken-json".utf8).write(to: f.url)
    await #expect(throws: MemoryPersistenceError.corruptFile) { _ = try await ledger.query(MemoryLedgerQuery(), as: f.principal) }
    #expect(throws: MemoryPersistenceError.corruptFile) { _ = try f.open() }
    try FileManager.default.removeItem(at: f.url)
    await #expect(throws: MemoryPersistenceError.missingFile) { _ = try await ledger.memory(id: UUID(), as: f.principal) }
    await #expect(throws: MemoryPersistenceError.missingFile) { try await ledger.insert(f.record(), as: f.principal) }
}

@Test func durableLedgerRefusesInsecureDirectoryAndFileModes() async throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let ledger = try f.open()
    let attributes = try FileManager.default.attributesOfItem(atPath: f.url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(chmod(f.url.path, 0o644) == 0)
    await #expect(throws: MemoryPersistenceError.unsafeFile) { _ = try await ledger.export(as: f.principal) }
    #expect(chmod(f.url.path, 0o600) == 0)
    #expect(chmod(f.directory.path, 0o755) == 0)
    #expect(throws: MemoryPersistenceError.insecureDirectory) { _ = try f.open() }
    await #expect(throws: MemoryPersistenceError.insecureDirectory) { _ = try await ledger.export(as: f.principal) }
}

@Test func durableLedgerRefusesSymlinkHardlinkFIFOAndLockSubstitution() async throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let ledger = try f.open()
    let original = f.directory.appendingPathComponent("original.json")
    try FileManager.default.moveItem(at: f.url, to: original)
    try FileManager.default.createSymbolicLink(at: f.url, withDestinationURL: original)
    await #expect(throws: MemoryPersistenceError.unsafeFile) { _ = try await ledger.export(as: f.principal) }
    try FileManager.default.removeItem(at: f.url)
    #expect(link(original.path, f.url.path) == 0)
    await #expect(throws: MemoryPersistenceError.unsafeFile) { _ = try await ledger.export(as: f.principal) }
    try FileManager.default.removeItem(at: f.url)
    #expect(mkfifo(f.url.path, 0o600) == 0)
    await #expect(throws: MemoryPersistenceError.unsafeFile) { _ = try await ledger.export(as: f.principal) }
    try FileManager.default.removeItem(at: f.url)
    try FileManager.default.moveItem(at: original, to: f.url)
    let lock = f.url.appendingPathExtension("lock")
    try FileManager.default.removeItem(at: lock)
    try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: f.url)
    await #expect(throws: MemoryPersistenceError.unsafeFile) { _ = try await ledger.export(as: f.principal) }
}

@Test func durableLedgerRefusesSymlinkAncestors() throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let target = f.directory.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let alias = f.directory.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    #expect(throws: MemoryPersistenceError.insecureDirectory) {
        _ = try FileBackedMemoryLedger(url: alias.appendingPathComponent("memory.json"), principal: f.principal)
    }
}

@Test func durableLedgerReportsBusyWithoutIgnoringOtherWriterLock() async throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let ledger = try f.open()
    let fd = open(f.url.appendingPathExtension("lock").path, O_RDWR)
    #expect(fd >= 0); defer { close(fd) }
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    await #expect(throws: MemoryPersistenceError.busy) { try await ledger.insert(f.record(), as: f.principal) }
    #expect(flock(fd, LOCK_UN) == 0)
    #expect(try await ledger.query(MemoryLedgerQuery(), as: f.principal).isEmpty)
}

@Test func durableForgetRemovesHistoryDerivedCopiesMappingsAndBlocksResurrection() async throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let ledger = try f.open()
    let original = try f.record(), independent = try f.record(content: "keep-me")
    try await ledger.insert(original, as: f.principal)
    try await ledger.insert(independent, as: f.principal)
    let derived = try f.record(content: "copy-of-secret", derived: [original.id])
    try await ledger.insert(derived, as: f.principal)
    let replacement = try f.record(content: "new-secret", supersedes: [original.id], time: 2_000)
    try await ledger.supersede(with: replacement, as: f.principal, at: Date(timeIntervalSince1970: 2_001))
    try await ledger.setProviderMapping(MemoryProviderMapping(memoryID: derived.id, provider: "p", providerMemoryID: "x"), as: f.principal)
    try await ledger.forget(id: replacement.id, as: f.principal, at: Date(timeIntervalSince1970: 3_000))
    let reopened = try f.open()
    let snapshot = try await reopened.export(as: f.principal)
    #expect(snapshot.memories == [independent])
    #expect(snapshot.providerMappings.isEmpty)
    #expect(Set(snapshot.tombstones.map(\.memoryID)) == Set([original.id, derived.id, replacement.id]))
    let raw = try String(contentsOf: f.url, encoding: .utf8)
    #expect(!raw.contains("ALPHA-PINEAPPLE-7834"))
    #expect(!raw.contains("copy-of-secret"))
    #expect(!raw.contains("new-secret"))
    await #expect(throws: MemoryLedgerError.deletedMemory(original.id)) { try await reopened.insert(original, as: f.principal) }
    let before = try await reopened.export(as: f.principal, at: Date(timeIntervalSince1970: 4_000))
    try await reopened.forget(id: replacement.id, as: f.principal)
    #expect(try await reopened.export(as: f.principal, at: Date(timeIntervalSince1970: 4_000)) == before)
}

@Test func forgettingDerivedMemoryKeepsSourceAndRejectsBackwardTimestamp() async throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let ledger = try f.open()
    let source = try f.record()
    try await ledger.insert(source, as: f.principal)
    let derived = try f.record(derived: [source.id])
    try await ledger.insert(derived, as: f.principal)
    await #expect(throws: MemoryLedgerError.invalidDeletionTimestamp) {
        try await ledger.forget(id: derived.id, as: f.principal, at: Date(timeIntervalSince1970: 1))
    }
    #expect(try await ledger.memory(id: derived.id, as: f.principal) != nil)
    try await ledger.forget(id: derived.id, as: f.principal)
    #expect(try await ledger.memory(id: source.id, as: f.principal) == source)
}

@Test func deletingUnknownIDPersistsTombstoneAndInMemoryLedgerHasSameSemantics() async throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let stores: [any MemoryLedgerStoring] = [try f.open(), InMemoryMemoryLedger()]
    let record = try f.record()
    for ledger in stores {
        try await ledger.forget(id: record.id, as: f.principal, at: Date(timeIntervalSince1970: 2_000))
        await #expect(throws: MemoryLedgerError.deletedMemory(record.id)) { try await ledger.insert(record, as: f.principal) }
        #expect(try await ledger.export(as: f.principal, at: Date()).tombstones.count == 1)
    }
}

@Test func durableLedgerRejectsTamperedSnapshotGraphsAndOwnership() async throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let ledger = try f.open()
    let record = try f.record()
    try await ledger.insert(record, as: f.principal)
    let original = try Data(contentsOf: f.url)
    func tamper(_ mutation: (inout [String: Any]) -> Void) throws {
        var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        mutation(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: f.url)
    }
    try tamper { $0["version"] = 999 }
    #expect(throws: MemoryPersistenceError.unsupportedVersion(999)) { _ = try f.open() }
    try tamper { object in
        var snapshot = object["snapshot"] as! [String: Any]
        let memories = snapshot["memories"] as! [[String: Any]]
        snapshot["memories"] = memories + memories
        object["snapshot"] = snapshot
    }
    #expect(throws: MemoryPersistenceError.corruptFile) { _ = try f.open() }
    try tamper { object in
        var snapshot = object["snapshot"] as! [String: Any]
        var memories = snapshot["memories"] as! [[String: Any]]
        var tenant = memories[0]["tenant"] as! [String: Any]
        tenant["userID"] = UUID().uuidString
        memories[0]["tenant"] = tenant
        snapshot["memories"] = memories
        object["snapshot"] = snapshot
    }
    #expect(throws: MemoryPersistenceError.corruptFile) { _ = try f.open() }
    try tamper { object in
        var snapshot = object["snapshot"] as! [String: Any]
        var memories = snapshot["memories"] as! [[String: Any]]
        memories[0]["derivedFromMemoryIDs"] = [UUID().uuidString]
        snapshot["memories"] = memories
        object["snapshot"] = snapshot
    }
    #expect(throws: MemoryPersistenceError.corruptFile) { _ = try f.open() }
    try original.write(to: f.url)
    #expect(try await ledger.memory(id: record.id, as: f.principal) == record)
}

@Test func durableLedgerRejectsCyclicHistoryAndTombstoneResurrectionOnDisk() async throws {
    let f = try LedgerFixture(); defer { f.clean() }
    let ledger = try f.open()
    let a = try f.record(), b = try f.record()
    try await ledger.insert(a, as: f.principal)
    try await ledger.insert(b, as: f.principal)
    let original = try Data(contentsOf: f.url)
    var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
    var snapshot = object["snapshot"] as! [String: Any]
    var records = snapshot["memories"] as! [[String: Any]]
    let firstID = records[0]["id"] as! String, secondID = records[1]["id"] as! String
    records[0]["derivedFromMemoryIDs"] = [secondID]
    records[1]["derivedFromMemoryIDs"] = [firstID]
    snapshot["memories"] = records
    object["snapshot"] = snapshot
    try JSONSerialization.data(withJSONObject: object).write(to: f.url)
    #expect(throws: MemoryPersistenceError.corruptFile) { _ = try f.open() }
    try original.write(to: f.url)
    try await ledger.forget(id: a.id, as: f.principal)
    object = try JSONSerialization.jsonObject(with: Data(contentsOf: f.url)) as! [String: Any]
    snapshot = object["snapshot"] as! [String: Any]
    records = snapshot["memories"] as! [[String: Any]]
    records.append(try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any])
    snapshot["memories"] = records
    object["snapshot"] = snapshot
    try JSONSerialization.data(withJSONObject: object).write(to: f.url)
    #expect(throws: MemoryPersistenceError.corruptFile) { _ = try f.open() }
}

@Test func memoryTimestampsCannotPoisonDurableSnapshots() throws {
    let f = try LedgerFixture(); defer { f.clean() }
    #expect(throws: MemoryValidationError.invalidTimestamp) { _ = try f.record(time: .infinity) }
    #expect(throws: MemoryValidationError.invalidTimestamp) {
        _ = try MemorySourceReference(type: .file, reference: "source", sourceTimestamp: Date(timeIntervalSince1970: .nan))
    }
    #expect(throws: MemoryValidationError.invalidTimestamp) {
        _ = try MemoryProviderMapping(memoryID: UUID(), provider: "p", providerMemoryID: "x", indexedAt: Date(timeIntervalSince1970: .infinity))
    }
}
