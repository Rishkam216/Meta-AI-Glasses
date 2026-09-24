import Foundation

/// Identity for exactly one immutable remote upload. The random upload ID must
/// be unique in the provider deployment. Drivers must bind every operation and
/// observation to ALL these fields and to the authenticated namespace.
public struct MemoryIndexAttempt: Sendable, Equatable {
    public let namespace: MemoryProviderNamespace
    public let canonicalID: UUID
    public let uploadID: UUID
    public let operationID: UUID
    public let revision: UInt64
}

public enum MemoryRemoteObservation: Sendable, Equatable {
    /// Includes missing data whose absence is not conclusive, failed processing,
    /// unknown status, and timeouts. Never permission to repeat a mutation.
    case unknown
    case processing(providerID: String)
    /// All work from this upload is complete. No delayed job/retry can create or
    /// change data from it after deletion. "Searchable" alone is insufficient.
    case settled(providerID: String)
    /// All indexed and derived data from this upload is removed, and no queued
    /// task can restore it. An ordinary eventually-consistent 404 is insufficient.
    case deleted
}

/// Lower-level backend for the durable coordinator. This is NOT a general retry
/// client. create/delete must each send at most one application-level mutation;
/// never retry internally. observe is read-only and can be repeated.
/// Every call must enforce transport deadlines, cancellation and response limits.
///
/// A production driver may declare verifiedLifecycle only after demonstrating
/// the strong settled/deleted semantics above, identity binding, and no hidden
/// mutation retries. A configuration flag or status-string guess is not proof.
public protocol MemoryMutationDriver: Sendable {
    var providerID: String { get }
    var verifiedLifecycle: Bool { get }
    func create(_ attempt: MemoryIndexAttempt, document: MemoryProviderDocument) async throws -> MemoryRemoteObservation
    func observe(_ attempt: MemoryIndexAttempt) async throws -> MemoryRemoteObservation
    func delete(_ attempt: MemoryIndexAttempt, providerID: String) async throws -> MemoryRemoteObservation
}

/// One authoritative local journal per principal AND deployment, shared by every
/// worker for that partition. This is not a multi-host/distributed gateway.
/// Never copy/roll back/delete the journal while retaining the remote index.
/// Lost journals require a NEW deployment ID and index, not automatic recreation.
public actor RevisionFencedMemoryProvider: MemoryProvider {
    public nonisolated let descriptor: MemoryProviderDescriptor
    private let namespace: MemoryProviderNamespace
    private let journal: MemoryMutationJournal
    private let driver: any MemoryMutationDriver
    private let reader: any MemoryProvider

    /// Explicit provisioning is required, so a missing runtime journal cannot
    /// silently reset revision/deletion fences. Use only for a fresh remote index.
    public static func provision(url: URL, principal: TenantContext, providerID: String) throws {
        try MemoryMutationJournal.provision(url: url, principal: principal, providerID: providerID)
    }

    public init(url: URL, principal: TenantContext, driver: any MemoryMutationDriver,
                reader: any MemoryProvider) throws {
        let source = reader.descriptor
        guard driver.verifiedLifecycle, driver.providerID == source.id,
              source.capabilities.namespaceIsolation, source.capabilities.scopeFiltering else {
            throw MemoryProviderError.invalidConfiguration
        }
        descriptor = try MemoryProviderDescriptor(id: source.id, capabilities: .init(
            namespaceIsolation: true, scopeFiltering: true, idempotentRevisionFencing: true,
            search: source.capabilities.search, profile: source.capabilities.profile),
            maxDocumentBytes: source.maxDocumentBytes, maxResults: source.maxResults)
        namespace = MemoryProviderNamespace(principal: principal)
        journal = try MemoryMutationJournal(url: url, principal: principal, providerID: source.id)
        self.driver = driver; self.reader = reader
    }

    /// At most one remote call per invocation. Pending work is retained and the
    /// service may call again. A crash after claiming dispatch never causes replay.
    public func apply(_ mutation: MemoryProviderMutation) async throws -> MemoryProviderReceipt {
        guard mutation.namespace == namespace else { throw MemoryProviderError.invalidQuery }
        try Task.checkCancellation()
        let work = try journal.acceptAndClaim(mutation, maxDocumentBytes: descriptor.maxDocumentBytes)
        if let work {
            let observation: MemoryRemoteObservation
            do {
                // Cancellation after claim leaves an uncertain dispatch on disk.
                // Deliberately do not put it back into the ready state.
                try Task.checkCancellation()
                switch work.kind {
                case .create:
                    guard let document = work.document else { throw MemoryProviderError.invalidResponse }
                    observation = try await driver.create(work.attempt, document: document)
                case .observe:
                    observation = try await driver.observe(work.attempt)
                case .delete:
                    guard let id = work.providerID else { throw MemoryProviderError.invalidResponse }
                    observation = try await driver.delete(work.attempt, providerID: id)
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as MemoryProviderError { throw error }
            catch { throw MemoryProviderError.unavailable }
            // Persist even if cancellation arrived after the remote result. This
            // records useful evidence without resending the request next time.
            try journal.record(observation, for: work)
            try Task.checkCancellation()
        }
        return try journal.receipt(for: mutation)
    }

    public func search(_ query: MemorySearchQuery, in namespace: MemoryProviderNamespace) async throws -> MemoryProviderResults {
        guard namespace == self.namespace else { throw MemoryProviderError.invalidQuery }
        guard descriptor.capabilities.search, query.limit <= descriptor.maxResults else { throw MemoryProviderError.unsupportedFeature }
        let response: MemoryProviderResults
        do { response = try await reader.search(query, in: namespace) }
        catch is CancellationError { throw CancellationError() }
        catch let error as MemoryProviderError { throw error }
        catch { throw MemoryProviderError.unavailable }
        return try journal.filter(response, scopes: query.scopes, limit: query.limit)
    }

    public func profile(scopes: Set<MemoryScope>, limit: Int, in namespace: MemoryProviderNamespace) async throws -> MemoryProviderResults {
        guard namespace == self.namespace, (1...16).contains(scopes.count),
              (1...descriptor.maxResults).contains(limit) else { throw MemoryProviderError.invalidQuery }
        guard descriptor.capabilities.profile else { throw MemoryProviderError.unsupportedFeature }
        let response: MemoryProviderResults
        do { response = try await reader.profile(scopes: scopes, limit: limit, in: namespace) }
        catch is CancellationError { throw CancellationError() }
        catch let error as MemoryProviderError { throw error }
        catch { throw MemoryProviderError.unavailable }
        return try journal.filter(response, scopes: scopes, limit: limit)
    }
}

/// Synchronous filesystem transactions; never hold flock across an await.
/// Reload under lock every time so separate actors/processes share the fence.
struct MemoryMutationJournal: Sendable {
    enum Phase: String, Codable { case ready, creating, processing, settled, deleting, deleted }
    enum Kind: Sendable { case create, observe, delete }
    struct Work: Sendable {
        let attempt: MemoryIndexAttempt
        let kind: Kind
        let phase: Phase
        let document: MemoryProviderDocument?
        let providerID: String?
    }
    private struct Entry: Codable {
        let canonicalID: UUID
        let uploadID: UUID
        let initialRevision: UInt64
        let initialOperationID: UUID
        var revision: UInt64
        var operationID: UUID
        var action: MemorySyncAction
        var document: MemoryProviderDocument?
        var phase: Phase
        var providerID: String?
    }
    private struct State: Codable {
        let version: Int
        let principal: TenantContext
        let providerID: String
        var entries: [Entry]
    }
    private let file: LockedMemoryFile
    private let principal: TenantContext
    private let providerID: String
    private var namespace: MemoryProviderNamespace { .init(principal: principal) }
    private static let maxBytes = 64 * 1_024 * 1_024

    static func provision(url: URL, principal: TenantContext, providerID: String) throws {
        guard validMemoryProviderID(providerID) else { throw MemoryProviderError.invalidConfiguration }
        let file = try LockedMemoryFile(url: url, maxFileBytes: maxBytes)
        try file.withLock {
            guard try file.read() == nil else { throw MemoryProviderError.invalidConfiguration }
            try file.replace(with: JSONEncoder().encode(State(version: 1, principal: principal, providerID: providerID, entries: [])))
        }
    }

    init(url: URL, principal: TenantContext, providerID: String) throws {
        file = try LockedMemoryFile(url: url, maxFileBytes: Self.maxBytes)
        self.principal = principal; self.providerID = providerID
        _ = try file.withLock { try load() }
    }

    private func load() throws -> State {
        guard let bytes = try file.read() else { throw MemoryPersistenceError.missingFile }
        let state: State
        do { state = try JSONDecoder().decode(State.self, from: bytes) }
        catch { throw MemoryPersistenceError.corruptFile }
        guard state.version == 1 else { throw MemoryPersistenceError.unsupportedVersion(state.version) }
        guard state.principal == principal else { throw MemoryLedgerError.ownershipMismatch }
        guard state.providerID == providerID else { throw MemoryProviderError.invalidConfiguration }
        var ids = Set<UUID>(), uploads = Set<UUID>(), remoteIDs = Set<String>()
        for e in state.entries {
            guard ids.insert(e.canonicalID).inserted, uploads.insert(e.uploadID).inserted,
                  e.initialRevision > 0, e.revision >= e.initialRevision,
                  (e.action == .upsert ? e.document?.canonicalID == e.canonicalID : e.document == nil),
                  !(e.action == .upsert && (e.phase == .deleting || e.phase == .deleted)),
                  !(e.action == .delete && e.phase == .ready),
                  !(e.phase == .ready && e.providerID != nil),
                  !([Phase.processing, .settled, .deleting].contains(e.phase) && e.providerID == nil) else {
                throw MemoryPersistenceError.corruptFile
            }
            if let id = e.providerID {
                guard Self.validRemoteID(id), remoteIDs.insert(id).inserted else { throw MemoryPersistenceError.corruptFile }
            }
        }
        return state
    }

    private func mutate<T>(_ body: (inout State) throws -> T) throws -> T {
        try file.withLock {
            var state = try load()
            let result = try body(&state)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try file.replace(with: encoder.encode(state))
            return result
        }
    }

    func acceptAndClaim(_ mutation: MemoryProviderMutation, maxDocumentBytes: Int) throws -> Work? {
        guard mutation.namespace == namespace, mutation.revision > 0 else { throw MemoryProviderError.invalidQuery }
        if mutation.action == .upsert {
            guard let document = mutation.document, document.canonicalID == mutation.canonicalID else { throw MemoryProviderError.invalidQuery }
            guard try JSONEncoder().encode(document).count <= maxDocumentBytes else { throw MemoryProviderError.documentTooLarge }
        } else if mutation.document != nil { throw MemoryProviderError.invalidQuery }
        return try mutate { state in
            let index: Int
            if let existing = state.entries.firstIndex(where: { $0.canonicalID == mutation.canonicalID }) {
                index = existing
                let prior = state.entries[index]
                guard mutation.revision >= prior.revision else { throw MemoryProviderError.staleRevision }
                if mutation.revision == prior.revision {
                    guard mutation.operationID == prior.operationID, mutation.action == prior.action,
                          mutation.document == prior.document else { throw MemoryProviderError.mutationConflict }
                } else {
                    // Canonical IDs are immutable. Corrections use a new canonical
                    // ID and delete the old one, matching ledger supersession.
                    guard !(prior.action == .delete && mutation.action == .upsert),
                          mutation.action == .delete || mutation.document == prior.document else {
                        throw MemoryProviderError.mutationConflict
                    }
                    state.entries[index].revision = mutation.revision
                    state.entries[index].operationID = mutation.operationID
                    state.entries[index].action = mutation.action
                    if mutation.action == .delete {
                        state.entries[index].document = nil
                        if prior.phase == .ready { state.entries[index].phase = .deleted }
                    }
                }
            } else {
                index = state.entries.count
                state.entries.append(Entry(canonicalID: mutation.canonicalID, uploadID: UUID(),
                    initialRevision: mutation.revision, initialOperationID: mutation.operationID,
                    revision: mutation.revision, operationID: mutation.operationID, action: mutation.action,
                    document: mutation.document, phase: mutation.action == .delete ? .deleted : .ready))
            }
            var entry = state.entries[index]
            let kind: Kind
            switch entry.phase {
            case .ready: entry.phase = .creating; kind = .create
            case .creating, .processing, .deleting: kind = .observe
            case .settled:
                guard entry.action == .delete else { return nil }
                entry.phase = .deleting; kind = .delete
            case .deleted: return nil
            }
            state.entries[index] = entry
            return Work(attempt: attempt(entry), kind: kind, phase: entry.phase,
                        document: kind == .create ? entry.document : nil, providerID: entry.providerID)
        }
    }

    func record(_ observation: MemoryRemoteObservation, for work: Work) throws {
        try mutate { state in
            guard let index = state.entries.firstIndex(where: { $0.canonicalID == work.attempt.canonicalID }),
                  attempt(state.entries[index]) == work.attempt else { throw MemoryProviderError.invalidResponse }
            var entry = state.entries[index]
            // A later worker may already have settled/deleted this attempt. A
            // late create/poll response must never move its phase backwards.
            guard entry.phase == work.phase else { return }
            switch observation {
            case .unknown: return
            case .processing(let id), .settled(let id):
                guard Self.validRemoteID(id), entry.providerID == nil || entry.providerID == id,
                      !state.entries.contains(where: { $0.canonicalID != entry.canonicalID && $0.providerID == id }) else {
                    throw MemoryProviderError.invalidResponse
                }
                if entry.phase == .deleting { return }
                guard entry.phase == .creating || entry.phase == .processing else { throw MemoryProviderError.invalidResponse }
                entry.providerID = id
                if case .settled = observation { entry.phase = .settled }
                else { entry.phase = .processing }
            case .deleted:
                guard entry.phase == .deleting, entry.action == .delete else { throw MemoryProviderError.invalidResponse }
                entry.phase = .deleted
            }
            state.entries[index] = entry
        }
    }

    func receipt(for mutation: MemoryProviderMutation) throws -> MemoryProviderReceipt {
        try file.withLock {
            let state = try load()
            guard let e = state.entries.first(where: { $0.canonicalID == mutation.canonicalID }),
                  e.revision == mutation.revision, e.operationID == mutation.operationID,
                  e.action == mutation.action else { throw MemoryProviderError.staleRevision }
            guard (e.action == .upsert && e.phase == .settled) || (e.action == .delete && e.phase == .deleted) else {
                throw MemoryProviderError.operationPending
            }
            return MemoryProviderReceipt(namespace: namespace, canonicalID: e.canonicalID, revision: e.revision,
                operationID: e.operationID, action: e.action, providerMemoryID: e.action == .upsert ? e.providerID : nil)
        }
    }

    func filter(_ response: MemoryProviderResults, scopes: Set<MemoryScope>, limit: Int) throws -> MemoryProviderResults {
        guard response.namespace == namespace, response.hits.count <= limit else { throw MemoryProviderError.invalidResponse }
        var seen = Set<UUID>()
        guard response.hits.allSatisfy({ seen.insert($0.canonicalID).inserted && Self.validRemoteID($0.providerMemoryID)
            && $0.score.isFinite && (0...1).contains($0.score) }) else { throw MemoryProviderError.invalidResponse }
        return try file.withLock {
            let state = try load()
            let entries = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.canonicalID, $0) })
            let hits = response.hits.filter { hit in
                guard let e = entries[hit.canonicalID], e.action == .upsert, e.phase == .settled,
                      e.providerID == hit.providerMemoryID, let scope = e.document?.scope else { return false }
                return scopes.contains(scope)
            }
            return MemoryProviderResults(namespace: namespace, hits: hits)
        }
    }

    private func attempt(_ e: Entry) -> MemoryIndexAttempt {
        MemoryIndexAttempt(namespace: namespace, canonicalID: e.canonicalID, uploadID: e.uploadID,
                           operationID: e.initialOperationID, revision: e.initialRevision)
    }
    private static func validRemoteID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 1_024 && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
