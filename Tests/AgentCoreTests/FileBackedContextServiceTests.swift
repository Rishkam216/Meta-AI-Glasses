import Foundation
import Testing
@testable import AgentCore

private func temporaryContextURL() throws -> (directory: URL, file: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("meta-ai-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    return (directory, directory.appendingPathComponent("context.json"))
}

private func durableItem(id: UUID = UUID(),
                         tenant: TenantContext,
                         key: String,
                         value: String,
                         observedAt: Date = Date(timeIntervalSince1970: 20_000)) throws -> ContextItem {
    try ContextItem(
        id: id,
        tenant: tenant,
        scope: .user,
        key: key,
        value: .string(value),
        provenance: ContextProvenance(origin: .user, trust: .userInstruction),
        freshness: ContextFreshness(classification: .longTerm, observedAt: observedAt),
        createdAt: observedAt
    )
}

@Test func fileBackedContextSurvivesRestart() async throws {
    let paths = try temporaryContextURL()
    defer { try? FileManager.default.removeItem(at: paths.directory) }

    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let item = try durableItem(tenant: tenant, key: "preferred_language", value: "en")

    let first = try FileBackedContextService(url: paths.file)
    try await first.put(item, as: tenant)

    let reopened = try FileBackedContextService(url: paths.file)
    #expect(await reopened.count(as: tenant) == 1)
    #expect(await reopened.get(item.id, as: tenant) == item)
}

@Test func sameItemIDRemainsPartitionedAcrossTenantsAfterRestart() async throws {
    let paths = try temporaryContextURL()
    defer { try? FileManager.default.removeItem(at: paths.directory) }

    let sharedID = UUID()
    let tenantA = TenantContext(tenantID: UUID(), userID: UUID())
    let tenantB = TenantContext(tenantID: UUID(), userID: UUID())
    let a = try durableItem(
        id: sharedID,
        tenant: tenantA,
        key: "canary",
        value: "ALPHA-PINEAPPLE-7834"
    )
    let b = try durableItem(
        id: sharedID,
        tenant: tenantB,
        key: "canary",
        value: "BETA-ZEBRA-9911"
    )

    let store = try FileBackedContextService(url: paths.file)
    try await store.put(a, as: tenantA)
    try await store.put(b, as: tenantB)

    let reopened = try FileBackedContextService(url: paths.file)
    #expect(await reopened.get(sharedID, as: tenantA)?.value == .string("ALPHA-PINEAPPLE-7834"))
    #expect(await reopened.get(sharedID, as: tenantB)?.value == .string("BETA-ZEBRA-9911"))
}

@Test func durableRemoveDoesNotResurrectAfterRestart() async throws {
    let paths = try temporaryContextURL()
    defer { try? FileManager.default.removeItem(at: paths.directory) }

    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let item = try durableItem(tenant: tenant, key: "temporary_fact", value: "delete-me")
    let store = try FileBackedContextService(url: paths.file)
    try await store.put(item, as: tenant)

    #expect(try await store.remove(item.id, as: tenant))

    let reopened = try FileBackedContextService(url: paths.file)
    #expect(await reopened.get(item.id, as: tenant) == nil)
    #expect(await reopened.count(as: tenant) == 0)
}

@Test func durableRemoveAllDeletesOnlyAuthenticatedPrincipalPartition() async throws {
    let paths = try temporaryContextURL()
    defer { try? FileManager.default.removeItem(at: paths.directory) }

    let tenantA = TenantContext(tenantID: UUID(), userID: UUID())
    let tenantB = TenantContext(tenantID: UUID(), userID: UUID())
    let a = try durableItem(tenant: tenantA, key: "private_a", value: "A")
    let b = try durableItem(tenant: tenantB, key: "private_b", value: "B")
    let store = try FileBackedContextService(url: paths.file)
    try await store.put(a, as: tenantA)
    try await store.put(b, as: tenantB)

    try await store.removeAll(as: tenantA)

    let reopened = try FileBackedContextService(url: paths.file)
    #expect(await reopened.count(as: tenantA) == 0)
    #expect(await reopened.count(as: tenantB) == 1)
    #expect(await reopened.get(b.id, as: tenantB) == b)
}

@Test func durableStoreRejectsCrossPrincipalWriteWithoutCreatingFile() async throws {
    let paths = try temporaryContextURL()
    defer { try? FileManager.default.removeItem(at: paths.directory) }

    let owner = TenantContext(tenantID: UUID(), userID: UUID())
    let other = TenantContext(tenantID: UUID(), userID: UUID())
    let item = try durableItem(tenant: owner, key: "secret", value: "owned")
    let store = try FileBackedContextService(url: paths.file)

    await #expect(throws: ContextServiceError.ownershipMismatch) {
        try await store.put(item, as: other)
    }
    #expect(!FileManager.default.fileExists(atPath: paths.file.path))
}

@Test func durableStoreRefusesSymlinkStateFile() throws {
    let paths = try temporaryContextURL()
    defer { try? FileManager.default.removeItem(at: paths.directory) }

    let target = paths.directory.appendingPathComponent("real.json")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
        at: paths.file,
        withDestinationURL: target
    )

    #expect(throws: ContextPersistenceError.pathIsSymlink) {
        _ = try FileBackedContextService(url: paths.file)
    }
}

@Test func durableStoreRejectsCorruptState() throws {
    let paths = try temporaryContextURL()
    defer { try? FileManager.default.removeItem(at: paths.directory) }

    try Data("not-json".utf8).write(to: paths.file)
    #expect(throws: ContextPersistenceError.corruptFile) {
        _ = try FileBackedContextService(url: paths.file)
    }
}

@Test func durableStoreUsesOwnerOnlyFilePermissions() async throws {
    let paths = try temporaryContextURL()
    defer { try? FileManager.default.removeItem(at: paths.directory) }

    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let store = try FileBackedContextService(url: paths.file)
    try await store.put(
        durableItem(tenant: tenant, key: "permission_test", value: "private"),
        as: tenant
    )

    let attributes = try FileManager.default.attributesOfItem(atPath: paths.file.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue == 0o600)
}
