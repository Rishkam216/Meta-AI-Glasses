import Foundation

/// Durable latest desired provider operation, with a monotonically increasing
/// fence. Acknowledgements remain to distinguish completed work from a new index.
public struct MemorySyncEntry: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let tenant: TenantContext
    public let providerID: String
    public let memoryID: UUID
    public let revision: UInt64
    public let action: MemorySyncAction
    public let acknowledged: Bool

    func acknowledging() -> Self {
        Self(operationID: operationID, tenant: tenant, providerID: providerID,
             memoryID: memoryID, revision: revision, action: action, acknowledged: true)
    }
}

public struct MemorySyncInventory: Codable, Sendable, Equatable {
    public internal(set) var providers: Set<String> = []
    public internal(set) var sequence: UInt64 = 0
    public internal(set) var entries: [MemorySyncEntry] = []
    public internal(set) var attemptTimes: [UUID: Date] = [:]
    public init() {}
}

/// Ledger extensions make canonical changes and desired provider work one atomic
/// transaction. Implementations must not emulate these as separate async writes.
public protocol MemoryServiceLedger: MemoryLedgerStoring {
    func enrollProviders(_ providers: Set<String>, as principal: TenantContext) async throws
    func remember(_ record: MemoryRecord, replacing: Bool, providers: Set<String>,
                  as principal: TenantContext, at timestamp: Date) async throws
    func forget(id: UUID, providers: Set<String>, as principal: TenantContext, at timestamp: Date) async throws
    @discardableResult
    func markAttempt(_ entry: MemorySyncEntry, as principal: TenantContext, at timestamp: Date) async throws -> Bool
    @discardableResult
    func acknowledge(_ entry: MemorySyncEntry, providerMemoryID: String?,
                     as principal: TenantContext, at timestamp: Date) async throws -> Bool
}
