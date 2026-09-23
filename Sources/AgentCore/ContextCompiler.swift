import Foundation

public enum ContextConsumerKind: String, Codable, Sendable, Hashable {
    case realtime
    case boundedDecision = "bounded_decision"
    case reasoning
}

public enum ContextCompilationError: Error, Sendable, Equatable {
    case invalidMaxItems
    case invalidMaxBytes
    case invalidMaxRefreshItems
}

public struct ContextCompilationRequest: Sendable, Equatable {
    public let consumer: ContextConsumerKind
    public let sessionID: UUID?
    public let deviceID: UUID?
    public let taskID: UUID?
    public let requestedKeys: Set<String>?
    public let maxItems: Int
    public let maxBytes: Int
    public let refreshStaleEphemeral: Bool
    public let maxRefreshItems: Int

    public init(consumer: ContextConsumerKind,
                sessionID: UUID? = nil,
                deviceID: UUID? = nil,
                taskID: UUID? = nil,
                requestedKeys: Set<String>? = nil,
                maxItems: Int = 32,
                maxBytes: Int = 32_768,
                refreshStaleEphemeral: Bool = true,
                maxRefreshItems: Int = 8) throws {
        guard maxItems > 0 else { throw ContextCompilationError.invalidMaxItems }
        guard maxBytes > 0 else { throw ContextCompilationError.invalidMaxBytes }
        guard (0...32).contains(maxRefreshItems) else {
            throw ContextCompilationError.invalidMaxRefreshItems
        }
        self.consumer = consumer
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.taskID = taskID
        self.requestedKeys = requestedKeys
        self.maxItems = maxItems
        self.maxBytes = maxBytes
        self.refreshStaleEphemeral = refreshStaleEphemeral
        self.maxRefreshItems = maxRefreshItems
    }
}

/// Provider-facing representation deliberately omits tenant/account/user IDs.
/// Provenance is preserved so downstream prompts can distinguish instructions
/// from external/untrusted content.
public struct CompiledContextItem: Codable, Sendable, Equatable {
    public let id: UUID
    public let scope: ContextScope
    public let key: String
    public let value: JSONValue
    public let provenance: ContextProvenance
    public let freshness: ContextFreshness
    public let bindings: ContextBindings

    init(_ item: ContextItem) {
        id = item.id
        scope = item.scope
        key = item.key
        value = item.value
        provenance = item.provenance
        freshness = item.freshness
        bindings = item.bindings
    }
}

public struct ContextRefreshSummary: Codable, Sendable, Equatable {
    public let attempted: Int
    public let refreshed: Int
    public let unsupported: Int
    public let failed: Int

    public static let none = ContextRefreshSummary(
        attempted: 0,
        refreshed: 0,
        unsupported: 0,
        failed: 0
    )
}

public struct CompiledContext: Codable, Sendable, Equatable {
    public let consumer: ContextConsumerKind
    public let items: [CompiledContextItem]
    public let omittedItemCount: Int
    public let encodedBytes: Int
    public let refreshSummary: ContextRefreshSummary
}

public struct ContextCompiler: Sendable {
    private let store: any ContextStoring
    private let refresher: (any ContextRefreshing)?

    public init(store: any ContextStoring,
                refresher: (any ContextRefreshing)? = nil) {
        self.store = store
        self.refresher = refresher
    }

    public func compile(_ request: ContextCompilationRequest,
                        as principal: TenantContext,
                        now: Date = Date()) async throws -> CompiledContext {
        var refreshSummary = ContextRefreshSummary.none

        if request.refreshStaleEphemeral,
           request.maxRefreshItems > 0,
           let refresher {
            let staleQuery = try ContextQuery(
                keys: request.requestedKeys,
                freshnessClasses: [.ephemeral],
                includeStale: true,
                onlyStale: true,
                limit: 100
            )
            let staleCandidates = await store.query(
                staleQuery,
                as: principal,
                now: now
            )
            let relevantStale = staleCandidates
                .filter { isRelevant($0, to: request) }
                .prefix(request.maxRefreshItems)

            var attempted = 0
            var refreshed = 0
            var unsupported = 0
            var failed = 0

            for item in relevantStale {
                attempted += 1
                do {
                    switch try await refresher.refresh(item, as: principal, now: now) {
                    case .refreshed:
                        refreshed += 1
                    case .unsupported:
                        unsupported += 1
                    }
                } catch ContextRefreshError.ownershipMismatch {
                    // A tenant boundary violation is not a recoverable refresh
                    // failure and must never be hidden by best-effort behavior.
                    throw ContextRefreshError.ownershipMismatch
                } catch {
                    // Refresh is best-effort. Failed stale items remain excluded
                    // by the fresh query below rather than being trusted anyway.
                    failed += 1
                }
            }

            refreshSummary = ContextRefreshSummary(
                attempted: attempted,
                refreshed: refreshed,
                unsupported: unsupported,
                failed: failed
            )
        }

        let query = try ContextQuery(
            keys: request.requestedKeys,
            includeStale: false,
            limit: 100
        )
        let candidates = await store.query(query, as: principal, now: now)

        let relevant = candidates
            .filter { isRelevant($0, to: request) }
            .filter { allowedTrust(for: request.consumer).contains($0.provenance.trust) }
            .sorted { lhs, rhs in
                let left = specificity(of: lhs, for: request)
                let right = specificity(of: rhs, for: request)
                if left != right { return left > right }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        var compiled: [CompiledContextItem] = []
        compiled.reserveCapacity(min(request.maxItems, relevant.count))
        var encodedBytes = 0
        var omitted = 0
        let encoder = JSONEncoder()

        for item in relevant {
            guard compiled.count < request.maxItems else {
                omitted += 1
                continue
            }

            let candidate = CompiledContextItem(item)
            let size = try encoder.encode(candidate).count
            guard encodedBytes + size <= request.maxBytes else {
                omitted += 1
                continue
            }

            compiled.append(candidate)
            encodedBytes += size
        }

        return CompiledContext(
            consumer: request.consumer,
            items: compiled,
            omittedItemCount: omitted,
            encodedBytes: encodedBytes,
            refreshSummary: refreshSummary
        )
    }

    private func allowedTrust(for consumer: ContextConsumerKind) -> Set<ContextTrustClass> {
        switch consumer {
        case .boundedDecision:
            return [.userInstruction, .systemState, .toolResult]
        case .realtime:
            return [.userInstruction, .systemState, .toolResult, .memory, .modelGenerated]
        case .reasoning:
            return [
                .userInstruction, .systemState, .toolResult,
                .externalContent, .memory, .modelGenerated
            ]
        }
    }

    private func isRelevant(_ item: ContextItem,
                            to request: ContextCompilationRequest) -> Bool {
        if let sessionID = request.sessionID {
            if let bound = item.bindings.sessionID, bound != sessionID { return false }
            if item.scope.kind == .session,
               item.scope.referenceID != sessionID.uuidString { return false }
        } else if item.scope.kind == .session || item.bindings.sessionID != nil {
            return false
        }

        if let deviceID = request.deviceID {
            if let bound = item.bindings.deviceID, bound != deviceID { return false }
            if item.scope.kind == .device,
               item.scope.referenceID != deviceID.uuidString { return false }
        } else if item.scope.kind == .device || item.bindings.deviceID != nil {
            return false
        }

        if let taskID = request.taskID {
            if let bound = item.bindings.taskID, bound != taskID { return false }
            if item.scope.kind == .task,
               item.scope.referenceID != taskID.uuidString { return false }
        } else if item.scope.kind == .task || item.bindings.taskID != nil {
            return false
        }

        return true
    }

    private func specificity(of item: ContextItem,
                             for request: ContextCompilationRequest) -> Int {
        var score = 0
        if let taskID = request.taskID,
           item.bindings.taskID == taskID || item.scope.referenceID == taskID.uuidString {
            score += 4
        }
        if let deviceID = request.deviceID,
           item.bindings.deviceID == deviceID || item.scope.referenceID == deviceID.uuidString {
            score += 2
        }
        if let sessionID = request.sessionID,
           item.bindings.sessionID == sessionID || item.scope.referenceID == sessionID.uuidString {
            score += 1
        }
        return score
    }
}
