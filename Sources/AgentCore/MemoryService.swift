import Foundation

public struct MemoryWriteReceipt: Sendable, Equatable {
    public let memoryID: UUID
    public let pendingProviderOperations: Int
}

public struct MemorySyncFailure: Sendable, Equatable {
    public let providerID: String
    public let memoryID: UUID
    public let reason: MemoryProviderError
}

public struct MemorySyncReport: Sendable, Equatable {
    public let attempted: Int
    public let acknowledged: Int
    public let superseded: Int
    public let remaining: Int
    public let failures: [MemorySyncFailure]
}

public struct RetrievedMemory: Sendable, Equatable {
    public let record: MemoryRecord
    public let score: Double
    /// Fixed by the service, never by provider/model output.
    public var trust: ContextTrustClass { .memory }
}

/// One authenticated principal per service. The application must explicitly
/// enable provider processing after its consent/data-minimization policy passes.
/// The ledger remains usable with processing disabled or no provider configured.
public actor MemoryService {
    private let principal: TenantContext
    private let ledger: any MemoryServiceLedger
    private let providers: [String: any MemoryProvider]
    private let descriptors: [String: MemoryProviderDescriptor]
    private let providerProcessingEnabled: Bool
    private var synchronizing = false

    public init(principal: TenantContext, ledger: any MemoryServiceLedger,
                providers: [any MemoryProvider] = [], providerProcessingEnabled: Bool = false) throws {
        guard providers.count <= 8 else { throw MemoryProviderError.invalidConfiguration }
        var byID: [String: any MemoryProvider] = [:]
        var descriptors: [String: MemoryProviderDescriptor] = [:]
        for provider in providers {
            let descriptor = provider.descriptor
            let capabilities = descriptor.capabilities
            guard byID[descriptor.id] == nil,
                  capabilities.namespaceIsolation, capabilities.scopeFiltering,
                  capabilities.idempotentRevisionFencing else { throw MemoryProviderError.invalidConfiguration }
            byID[descriptor.id] = provider
            descriptors[descriptor.id] = descriptor
        }
        self.principal = principal; self.ledger = ledger; self.providers = byID
        self.descriptors = descriptors; self.providerProcessingEnabled = providerProcessingEnabled
    }

    public func capabilities(as caller: TenantContext) throws -> [MemoryProviderDescriptor] {
        try requireOwner(caller)
        return descriptors.values.sorted { $0.id < $1.id }
    }

    /// Returns after canonical data AND desired provider work are durably saved.
    /// Network synchronization is explicit, so a provider outage cannot hide the
    /// successful canonical save or block the realtime turn on remote indexing.
    public func remember(_ record: MemoryRecord, as caller: TenantContext,
                         at timestamp: Date = Date()) async throws -> MemoryWriteReceipt {
        try requireOwner(caller)
        guard record.tenant == principal else { throw MemoryLedgerError.ownershipMismatch }
        if providerProcessingEnabled {
            let size = try JSONEncoder().encode(MemoryProviderDocument(record)).count
            guard descriptors.values.allSatisfy({ size <= $0.maxDocumentBytes }) else {
                throw MemoryProviderError.documentTooLarge
            }
        }
        try await ledger.remember(record, replacing: !record.supersedes.isEmpty,
                                  providers: configuredIDs, as: principal, at: timestamp)
        let snapshot = try await ledger.export(as: principal, at: timestamp)
        return MemoryWriteReceipt(memoryID: record.id, pendingProviderOperations: snapshot.synchronization.entries.filter { !$0.acknowledged }.count)
    }

    public func forget(id: UUID, as caller: TenantContext, at timestamp: Date = Date()) async throws -> MemoryWriteReceipt {
        try requireOwner(caller)
        try await ledger.forget(id: id, providers: configuredIDs, as: principal, at: timestamp)
        let snapshot = try await ledger.export(as: principal, at: timestamp)
        return MemoryWriteReceipt(memoryID: id, pendingProviderOperations: snapshot.synchronization.entries.filter { !$0.acknowledged }.count)
    }

    public func export(as caller: TenantContext, at timestamp: Date = Date()) async throws -> PortableMemoryExport {
        try requireOwner(caller)
        return try await ledger.export(as: principal, at: timestamp)
    }

    /// Bounded, restart-safe reconciliation. Failed and unconfigured-provider work
    /// remains durable. Every adapter must support the fencing contract before use.
    public func synchronize(as caller: TenantContext, maxOperations: Int = 32) async throws -> MemorySyncReport {
        try requireOwner(caller)
        guard providerProcessingEnabled else { throw MemoryProviderError.unsupportedFeature }
        guard (1...100).contains(maxOperations) else { throw MemoryProviderError.invalidQuery }
        guard !synchronizing else { throw MemoryProviderError.synchronizationBusy }
        synchronizing = true
        defer { synchronizing = false }
        try await ledger.enrollProviders(configuredIDs, as: principal)
        let snapshot = try await ledger.export(as: principal, at: Date())
        let pending = snapshot.synchronization.entries.filter { !$0.acknowledged }.sorted {
            let left = snapshot.synchronization.attemptTimes[$0.operationID] ?? .distantPast
            let right = snapshot.synchronization.attemptTimes[$1.operationID] ?? .distantPast
            if left != right { return left < right }
            if $0.action != $1.action { return $0.action == .delete }
            return $0.revision < $1.revision
        }
        var attempted = 0, acknowledged = 0, superseded = 0
        var failures: [MemorySyncFailure] = []
        for entry in pending.prefix(maxOperations) {
            try Task.checkCancellation()
            guard try await ledger.markAttempt(entry, as: principal, at: Date()) else { superseded += 1; continue }
            attempted += 1
            guard let provider = providers[entry.providerID], let descriptor = descriptors[entry.providerID] else {
                failures.append(MemorySyncFailure(providerID: entry.providerID, memoryID: entry.memoryID, reason: .unavailable))
                continue
            }
            do {
                let document: MemoryProviderDocument?
                if entry.action == .upsert {
                    guard let record = try await ledger.memory(id: entry.memoryID, as: principal), record.state == .active else {
                        superseded += 1; continue
                    }
                    document = MemoryProviderDocument(record)
                    guard try JSONEncoder().encode(document).count <= descriptor.maxDocumentBytes else {
                        throw MemoryProviderError.documentTooLarge
                    }
                } else { document = nil }
                let mutation = MemoryProviderMutation(namespace: namespace, canonicalID: entry.memoryID,
                                                       revision: entry.revision, operationID: entry.operationID,
                                                       action: entry.action, document: document)
                let receipt: MemoryProviderReceipt
                do { receipt = try await provider.apply(mutation) }
                catch is CancellationError { throw CancellationError() }
                catch let error as MemoryProviderError { throw error }
                catch { throw MemoryProviderError.unavailable }
                guard receipt.namespace == namespace, receipt.canonicalID == entry.memoryID,
                      receipt.revision == entry.revision, receipt.operationID == entry.operationID,
                      receipt.action == entry.action else { throw MemoryProviderError.invalidResponse }
                if entry.action == .upsert {
                    guard let externalID = receipt.providerMemoryID, !externalID.isEmpty,
                          externalID.utf8.count <= 1_024, externalID == externalID.trimmingCharacters(in: .whitespacesAndNewlines) else {
                        throw MemoryProviderError.invalidResponse
                    }
                } else if receipt.providerMemoryID != nil { throw MemoryProviderError.invalidResponse }
                if try await ledger.acknowledge(entry, providerMemoryID: receipt.providerMemoryID, as: principal, at: Date()) {
                    acknowledged += 1
                } else { superseded += 1 }
            } catch is CancellationError { throw CancellationError() }
            catch let error as MemoryProviderError {
                failures.append(MemorySyncFailure(providerID: entry.providerID, memoryID: entry.memoryID, reason: error))
            }
            // Ledger I/O/validation errors deliberately propagate. An adapter
            // error never marks work complete; a crash between remote success and
            // acknowledgement safely retries the same operation/revision.
        }
        let latest = try await ledger.export(as: principal, at: Date())
        return MemorySyncReport(attempted: attempted, acknowledged: acknowledged, superseded: superseded,
                                remaining: latest.synchronization.entries.filter { !$0.acknowledged }.count, failures: failures)
    }

    /// Selective retrieval for model context. Canonical mode works with provider
    /// processing disabled. Provider mode still resolves every hit back through
    /// canonical state, so a provider can rank memories but cannot authoritatively
    /// inject forgotten, historical, cross-scope, or foreign-principal content.
    public func retrieveForContext(_ query: MemoryContextQuery,
                                   as caller: TenantContext) async throws -> [RetrievedMemory] {
        try requireOwner(caller)
        switch query.strategy {
        case .canonical:
            return try await canonicalContextSearch(query)
        case .provider(let providerID):
            let providerQuery = try MemorySearchQuery(
                text: query.text,
                scopes: query.scopes,
                limit: query.limit
            )
            return try await search(providerQuery, providerID: providerID, as: caller)
        }
    }

    public func search(_ query: MemorySearchQuery, providerID: String,
                       as caller: TenantContext) async throws -> [RetrievedMemory] {
        try requireOwner(caller)
        let (provider, descriptor) = try providerForRetrieval(providerID)
        guard descriptor.capabilities.search, query.limit <= descriptor.maxResults else { throw MemoryProviderError.unsupportedFeature }
        let response: MemoryProviderResults
        do { response = try await provider.search(query, in: namespace) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MemoryProviderError.unavailable }
        return try await resolve(response, providerID: providerID, scopes: query.scopes, limit: query.limit)
    }

    public func profile(scopes: Set<MemoryScope>, limit: Int = 10, providerID: String,
                        as caller: TenantContext) async throws -> [RetrievedMemory] {
        try requireOwner(caller)
        let (provider, descriptor) = try providerForRetrieval(providerID)
        guard (1...16).contains(scopes.count), (1...descriptor.maxResults).contains(limit) else { throw MemoryProviderError.invalidQuery }
        guard descriptor.capabilities.profile else { throw MemoryProviderError.unsupportedFeature }
        let response: MemoryProviderResults
        do { response = try await provider.profile(scopes: scopes, limit: limit, in: namespace) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MemoryProviderError.unavailable }
        return try await resolve(response, providerID: providerID, scopes: scopes, limit: limit)
    }

    private func canonicalContextSearch(_ query: MemoryContextQuery) async throws -> [RetrievedMemory] {
        let candidateLimit = min(100, max(query.limit * 4, 24))
        let scopes = query.scopes.sorted {
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return ($0.referenceID ?? "") < ($1.referenceID ?? "")
        }

        var records: [UUID: MemoryRecord] = [:]
        for scope in scopes {
            let ledgerQuery = try MemoryLedgerQuery(
                scope: scope,
                includeSuperseded: false,
                limit: candidateLimit
            )
            for record in try await ledger.query(ledgerQuery, as: principal) {
                guard record.tenant == principal,
                      record.state == .active,
                      query.scopes.contains(record.scope) else {
                    throw MemoryContextError.invalidResponse
                }
                records[record.id] = record
            }
        }

        let queryTokens = memorySearchTokens(query.text)
        guard !queryTokens.isEmpty else { throw MemoryContextError.invalidQuery }
        let normalizedQuery = query.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let ranked = try records.values.compactMap { record -> RetrievedMemory? in
            let contentData = try JSONEncoder().encode(record.content)
            guard let contentText = String(data: contentData, encoding: .utf8)?.lowercased() else {
                throw MemoryContextError.invalidResponse
            }
            let contentTokens = memorySearchTokens(contentText)
            let overlap = queryTokens.intersection(contentTokens)
            let exactPhrase = contentText.contains(normalizedQuery)
            guard exactPhrase || !overlap.isEmpty else { return nil }

            let coverage = Double(overlap.count) / Double(queryTokens.count)
            let specificity = contentTokens.isEmpty ? 0 : Double(overlap.count) / Double(contentTokens.count)
            let confidence = record.confidence ?? 0.5
            let score = min(1.0,
                            (coverage * 0.72) +
                            (specificity * 0.13) +
                            (exactPhrase ? 0.10 : 0.0) +
                            (confidence * 0.05))
            return RetrievedMemory(record: record, score: score)
        }

        return ranked.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.record.updatedAt != $1.record.updatedAt {
                return $0.record.updatedAt > $1.record.updatedAt
            }
            return $0.record.id.uuidString < $1.record.id.uuidString
        }
        .prefix(query.limit)
        .map { $0 }
    }

    private func memorySearchTokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 }
            .prefix(128))
    }

    private func resolve(_ response: MemoryProviderResults, providerID: String,
                         scopes: Set<MemoryScope>, limit: Int) async throws -> [RetrievedMemory] {
        guard response.namespace == namespace, response.hits.count <= limit else { throw MemoryProviderError.invalidResponse }
        var seen: Set<UUID> = []
        for hit in response.hits {
            guard hit.score.isFinite, (0...1).contains(hit.score), !hit.providerMemoryID.isEmpty,
                  hit.providerMemoryID.utf8.count <= 1_024, seen.insert(hit.canonicalID).inserted else { throw MemoryProviderError.invalidResponse }
        }
        // Resolve against a single canonical snapshot after provider I/O. Provider
        // results cannot reintroduce forgotten, historical or other-user content.
        let snapshot = try await ledger.export(as: principal, at: Date())
        let records = Dictionary(uniqueKeysWithValues: snapshot.memories.map { ($0.id, $0) })
        let mappings = Dictionary(uniqueKeysWithValues: snapshot.providerMappings.filter { $0.provider == providerID }.map { ($0.memoryID, $0) })
        return response.hits.compactMap { hit in
            guard let record = records[hit.canonicalID], record.tenant == principal,
                  record.state == .active, scopes.contains(record.scope),
                  mappings[hit.canonicalID]?.providerMemoryID == hit.providerMemoryID else { return nil }
            return RetrievedMemory(record: record, score: hit.score)
        }
    }

    private var namespace: MemoryProviderNamespace { MemoryProviderNamespace(principal: principal) }
    private var configuredIDs: Set<String> { providerProcessingEnabled ? Set(providers.keys) : [] }
    private func requireOwner(_ caller: TenantContext) throws {
        guard caller == principal else { throw MemoryLedgerError.ownershipMismatch }
    }
    private func providerForRetrieval(_ id: String) throws -> (any MemoryProvider, MemoryProviderDescriptor) {
        guard providerProcessingEnabled else { throw MemoryProviderError.unsupportedFeature }
        guard let provider = providers[id], let descriptor = descriptors[id] else { throw MemoryProviderError.invalidConfiguration }
        return (provider, descriptor)
    }
}
