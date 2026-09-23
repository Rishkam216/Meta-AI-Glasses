import Foundation

public enum AgentInterfaceKind: String, Codable, Sendable, Hashable {
    case macDesktop = "mac_desktop"
    case windowsDesktop = "windows_desktop"
    case iOSApp = "ios_app"
    case androidApp = "android_app"
    case metaGlassesViaPhone = "meta_glasses_via_phone"
    case web
}

public protocol ContextStateRecord: Codable, Sendable {
    var contextScope: ContextScope { get }
    var contextKey: String { get }
    var freshnessClass: ContextFreshnessClass { get }
    var observedAt: Date { get }
    var bindings: ContextBindings { get }
}

public extension ContextStateRecord {
    func contextItem(tenant: TenantContext,
                     provenance: ContextProvenance,
                     validUntil: Date? = nil) throws -> ContextItem {
        try ContextItem(
            tenant: tenant,
            scope: contextScope,
            key: contextKey,
            value: JSONValue.encoding(self),
            provenance: provenance,
            freshness: ContextFreshness(
                classification: freshnessClass,
                observedAt: observedAt,
                validUntil: validUntil
            ),
            bindings: bindings,
            createdAt: observedAt
        )
    }
}

public struct InterfaceContextState: ContextStateRecord, Equatable {
    public let interfaceID: UUID
    public let kind: AgentInterfaceKind
    public let originatingDeviceID: UUID?
    public let companionDeviceID: UUID?
    public let observedAt: Date

    public init(interfaceID: UUID = UUID(), kind: AgentInterfaceKind,
                originatingDeviceID: UUID? = nil,
                companionDeviceID: UUID? = nil,
                observedAt: Date = Date()) {
        self.interfaceID = interfaceID
        self.kind = kind
        self.originatingDeviceID = originatingDeviceID
        self.companionDeviceID = companionDeviceID
        self.observedAt = observedAt
    }

    public var contextScope: ContextScope {
        try! ContextScope(kind: .interface, referenceID: interfaceID.uuidString)
    }
    public var contextKey: String { "interface_state" }
    public var freshnessClass: ContextFreshnessClass { .session }
    public var bindings: ContextBindings {
        ContextBindings(deviceID: originatingDeviceID)
    }
}

public struct SessionContextState: ContextStateRecord, Equatable {
    public let sessionID: UUID
    public let activeDeviceID: UUID?
    public let currentGoal: String?
    public let currentTaskID: UUID?
    public let pendingApprovalID: UUID?
    public let activeJobIDs: [UUID]
    public let interfaceID: UUID?
    public let observedAt: Date

    public init(sessionID: UUID, activeDeviceID: UUID? = nil,
                currentGoal: String? = nil, currentTaskID: UUID? = nil,
                pendingApprovalID: UUID? = nil, activeJobIDs: [UUID] = [],
                interfaceID: UUID? = nil, observedAt: Date = Date()) {
        self.sessionID = sessionID
        self.activeDeviceID = activeDeviceID
        self.currentGoal = currentGoal
        self.currentTaskID = currentTaskID
        self.pendingApprovalID = pendingApprovalID
        self.activeJobIDs = activeJobIDs
        self.interfaceID = interfaceID
        self.observedAt = observedAt
    }

    public var contextScope: ContextScope { .session(sessionID) }
    public var contextKey: String { "session_state" }
    public var freshnessClass: ContextFreshnessClass { .session }
    public var bindings: ContextBindings {
        ContextBindings(sessionID: sessionID, deviceID: activeDeviceID, taskID: currentTaskID)
    }
}

public struct DeviceContextState: ContextStateRecord, Equatable {
    public let deviceID: UUID
    public let online: Bool
    public let lastSeenAt: Date
    public let advertisedCapabilities: [String]
    public let frontmostApp: String?
    public let focusedWindow: String?
    public let activeProject: String?
    public let workingDirectory: String?
    public let selectedFile: String?
    public let browserURL: String?
    public let observedAt: Date

    public init(deviceID: UUID, online: Bool, lastSeenAt: Date,
                advertisedCapabilities: [String] = [],
                frontmostApp: String? = nil, focusedWindow: String? = nil,
                activeProject: String? = nil, workingDirectory: String? = nil,
                selectedFile: String? = nil, browserURL: String? = nil,
                observedAt: Date = Date()) {
        self.deviceID = deviceID
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.advertisedCapabilities = advertisedCapabilities
        self.frontmostApp = frontmostApp
        self.focusedWindow = focusedWindow
        self.activeProject = activeProject
        self.workingDirectory = workingDirectory
        self.selectedFile = selectedFile
        self.browserURL = browserURL
        self.observedAt = observedAt
    }

    public var contextScope: ContextScope { .device(deviceID) }
    public var contextKey: String { "device_state" }
    public var freshnessClass: ContextFreshnessClass { .ephemeral }
    public var bindings: ContextBindings { ContextBindings(deviceID: deviceID) }
}

public enum TaskContextStatus: String, Codable, Sendable, Hashable {
    case pending
    case running
    case waitingForUser = "waiting_for_user"
    case completed
    case failed
    case cancelled
}

public struct TaskContextState: ContextStateRecord, Equatable {
    public let taskID: UUID
    public let sessionID: UUID
    public let goal: String
    public let status: TaskContextStatus
    public let knownFacts: [String: JSONValue]
    public let actionsTaken: [String]
    public let nextCandidates: [String]
    public let observedAt: Date

    public init(taskID: UUID, sessionID: UUID, goal: String,
                status: TaskContextStatus = .pending,
                knownFacts: [String: JSONValue] = [:],
                actionsTaken: [String] = [], nextCandidates: [String] = [],
                observedAt: Date = Date()) {
        self.taskID = taskID
        self.sessionID = sessionID
        self.goal = goal
        self.status = status
        self.knownFacts = knownFacts
        self.actionsTaken = actionsTaken
        self.nextCandidates = nextCandidates
        self.observedAt = observedAt
    }

    public var contextScope: ContextScope { .task(taskID) }
    public var contextKey: String { "task_state" }
    public var freshnessClass: ContextFreshnessClass { .session }
    public var bindings: ContextBindings {
        ContextBindings(sessionID: sessionID, taskID: taskID)
    }
}

public extension ContextStoring {
    func put<State: ContextStateRecord>(_ state: State,
                                        tenant: TenantContext,
                                        provenance: ContextProvenance,
                                        validUntil: Date? = nil) async throws {
        try await put(
            state.contextItem(
                tenant: tenant,
                provenance: provenance,
                validUntil: validUntil
            ),
            as: tenant
        )
    }
}

public extension AgentSession {
    func contextState(currentGoal: String? = nil,
                      currentTaskID: UUID? = nil,
                      pendingApprovalID: UUID? = nil,
                      activeJobIDs: [UUID] = [],
                      interfaceID: UUID? = nil,
                      observedAt: Date = Date()) -> SessionContextState {
        SessionContextState(
            sessionID: id,
            activeDeviceID: activeDeviceID,
            currentGoal: currentGoal,
            currentTaskID: currentTaskID,
            pendingApprovalID: pendingApprovalID,
            activeJobIDs: activeJobIDs,
            interfaceID: interfaceID,
            observedAt: observedAt
        )
    }
}
