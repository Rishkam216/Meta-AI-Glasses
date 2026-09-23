import Foundation

public enum ContextLayerError: Error, Sendable, Equatable {
    case emptyText
    case textTooLong
    case tooManyCapabilities
    case invalidCapabilityName
    case decodeFailed
}

private func validateOptionalText(_ value: String?, maxBytes: Int) throws {
    guard let value else { return }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ContextLayerError.emptyText }
    guard value.utf8.count <= maxBytes else { throw ContextLayerError.textTooLong }
}

public enum AgentInterfaceKind: String, Codable, Sendable, Hashable {
    case macDesktop = "mac_desktop"
    case windowsDesktop = "windows_desktop"
    case iOSApp = "ios_app"
    case androidApp = "android_app"
    case metaGlassesViaPhone = "meta_glasses_via_phone"
    case web
}

public struct SessionContextState: Codable, Sendable, Equatable {
    public let activeDeviceID: UUID?
    public let activeTaskID: UUID?
    public let currentGoal: String?
    public let summary: String?

    public init(activeDeviceID: UUID? = nil, activeTaskID: UUID? = nil,
                currentGoal: String? = nil, summary: String? = nil) throws {
        try validateOptionalText(currentGoal, maxBytes: 4_096)
        try validateOptionalText(summary, maxBytes: 8_192)
        self.activeDeviceID = activeDeviceID
        self.activeTaskID = activeTaskID
        self.currentGoal = currentGoal
        self.summary = summary
    }
}

public struct InterfaceContextState: Codable, Sendable, Equatable {
    public let interfaceID: UUID
    public let kind: AgentInterfaceKind
    public let deviceID: UUID?
    public let companionDeviceID: UUID?

    public init(interfaceID: UUID = UUID(), kind: AgentInterfaceKind,
                deviceID: UUID? = nil, companionDeviceID: UUID? = nil) {
        self.interfaceID = interfaceID
        self.kind = kind
        self.deviceID = deviceID
        self.companionDeviceID = companionDeviceID
    }
}

public struct DeviceContextState: Codable, Sendable, Equatable {
    public let online: Bool
    public let lastSeen: Date
    public let capabilityNames: [String]
    public let frontmostApp: String?
    public let activeProject: String?

    public init(online: Bool, lastSeen: Date, capabilityNames: [String],
                frontmostApp: String? = nil, activeProject: String? = nil) throws {
        guard capabilityNames.count <= 512 else { throw ContextLayerError.tooManyCapabilities }
        let normalized = Array(Set(capabilityNames)).sorted()
        for name in normalized {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, name.utf8.count <= 256 else {
                throw ContextLayerError.invalidCapabilityName
            }
        }
        try validateOptionalText(frontmostApp, maxBytes: 512)
        try validateOptionalText(activeProject, maxBytes: 1_024)

        self.online = online
        self.lastSeen = lastSeen
        self.capabilityNames = normalized
        self.frontmostApp = frontmostApp
        self.activeProject = activeProject
    }
}

public enum TaskContextStatus: String, Codable, Sendable, Hashable {
    case pending
    case running
    case waitingForApproval = "waiting_for_approval"
    case completed
    case failed
    case cancelled
}

public struct TaskContextState: Codable, Sendable, Equatable {
    public let status: TaskContextStatus
    public let goalSummary: String
    public let updatedAt: Date

    public init(status: TaskContextStatus, goalSummary: String, updatedAt: Date) throws {
        let trimmed = goalSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ContextLayerError.emptyText }
        guard goalSummary.utf8.count <= 4_096 else { throw ContextLayerError.textTooLong }
        self.status = status
        self.goalSummary = goalSummary
        self.updatedAt = updatedAt
    }
}

/// Typed adapters over ContextServing. They establish canonical scope/key/trust/
/// freshness conventions so callers do not hand-roll semantically different JSON
/// records for the same context layer.
public struct ContextLayerStore: Sendable {
    private let service: any ContextServing

    public init(service: any ContextServing) {
        self.service = service
    }

    @discardableResult
    public func recordSession(_ state: SessionContextState, principal: TenantContext,
                              sessionID: UUID, observedAt: Date = Date()) async throws -> ContextItem {
        let item = try ContextItem(
            tenant: principal,
            scope: .session(sessionID),
            key: "session_state",
            value: JSONValue.encoding(state),
            provenance: ContextProvenance(
                origin: .system,
                trust: .systemState,
                sourceReference: "context.session_state"
            ),
            freshness: ContextFreshness(classification: .session, observedAt: observedAt),
            bindings: ContextBindings(sessionID: sessionID),
            createdAt: observedAt
        )
        try await service.store(item, for: principal)
        return item
    }

    @discardableResult
    public func recordInterface(_ state: InterfaceContextState, principal: TenantContext,
                                sessionID: UUID, observedAt: Date = Date()) async throws -> ContextItem {
        let scope = try ContextScope(kind: .interface, referenceID: state.interfaceID.uuidString)
        let item = try ContextItem(
            tenant: principal,
            scope: scope,
            key: "interface_state",
            value: JSONValue.encoding(state),
            provenance: ContextProvenance(
                origin: .system,
                trust: .systemState,
                sourceReference: "context.interface_state"
            ),
            freshness: ContextFreshness(classification: .ephemeral, observedAt: observedAt),
            bindings: ContextBindings(sessionID: sessionID, deviceID: state.deviceID),
            createdAt: observedAt
        )
        try await service.store(item, for: principal)
        return item
    }

    @discardableResult
    public func recordDevice(_ state: DeviceContextState, principal: TenantContext,
                             deviceID: UUID, sessionID: UUID? = nil,
                             observedAt: Date = Date()) async throws -> ContextItem {
        let item = try ContextItem(
            tenant: principal,
            scope: .device(deviceID),
            key: "device_state",
            value: JSONValue.encoding(state),
            provenance: ContextProvenance(
                origin: .applicationAdapter,
                trust: .systemState,
                sourceReference: "context.device_state"
            ),
            freshness: ContextFreshness(classification: .ephemeral, observedAt: observedAt),
            bindings: ContextBindings(sessionID: sessionID, deviceID: deviceID),
            createdAt: observedAt
        )
        try await service.store(item, for: principal)
        return item
    }

    @discardableResult
    public func recordTask(_ state: TaskContextState, principal: TenantContext,
                           taskID: UUID, sessionID: UUID,
                           observedAt: Date = Date()) async throws -> ContextItem {
        let item = try ContextItem(
            tenant: principal,
            scope: .task(taskID),
            key: "task_state",
            value: JSONValue.encoding(state),
            provenance: ContextProvenance(
                origin: .system,
                trust: .systemState,
                sourceReference: "context.task_state"
            ),
            freshness: ContextFreshness(classification: .session, observedAt: observedAt),
            bindings: ContextBindings(sessionID: sessionID, taskID: taskID),
            createdAt: observedAt
        )
        try await service.store(item, for: principal)
        return item
    }

    public func latestSession(principal: TenantContext, sessionID: UUID,
                              at now: Date = Date()) async throws -> SessionContextState? {
        try await latest(
            type: SessionContextState.self,
            query: ContextQuery(scope: .session(sessionID), key: "session_state", sessionID: sessionID, limit: 1),
            principal: principal,
            at: now
        )
    }

    public func latestInterface(principal: TenantContext, interfaceID: UUID,
                                at now: Date = Date()) async throws -> InterfaceContextState? {
        try await latest(
            type: InterfaceContextState.self,
            query: ContextQuery(
                scope: try ContextScope(kind: .interface, referenceID: interfaceID.uuidString),
                key: "interface_state",
                limit: 1
            ),
            principal: principal,
            at: now
        )
    }

    public func latestDevice(principal: TenantContext, deviceID: UUID,
                             at now: Date = Date()) async throws -> DeviceContextState? {
        try await latest(
            type: DeviceContextState.self,
            query: ContextQuery(scope: .device(deviceID), key: "device_state", deviceID: deviceID, limit: 1),
            principal: principal,
            at: now
        )
    }

    public func latestTask(principal: TenantContext, taskID: UUID, sessionID: UUID,
                           at now: Date = Date()) async throws -> TaskContextState? {
        try await latest(
            type: TaskContextState.self,
            query: ContextQuery(scope: .task(taskID), key: "task_state", sessionID: sessionID, taskID: taskID, limit: 1),
            principal: principal,
            at: now
        )
    }

    private func latest<T: Decodable & Sendable>(type: T.Type, query: ContextQuery,
                                                  principal: TenantContext, at now: Date) async throws -> T? {
        guard let item = await service.search(query, for: principal, at: now).first else { return nil }
        do {
            return try item.value.decode(T.self)
        } catch {
            throw ContextLayerError.decodeFailed
        }
    }
}
