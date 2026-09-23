import Foundation

public enum ContextStateValidationError: Error, Sendable, Equatable {
    case emptyText(String)
    case textTooLong(String)
    case tooManyCapabilities
    case invalidCapabilityName
    case tooManyJobs
    case duplicateJobID
    case tooManyFacts
    case invalidFactKey
    case tooManyActions
    case tooManyCandidates
    case invalidCandidate
    case missingGlassesCompanion
}

private func validateOptionalContextText(_ value: String?, field: String,
                                         maxBytes: Int) throws {
    guard let value else { return }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ContextStateValidationError.emptyText(field) }
    guard value.utf8.count <= maxBytes else {
        throw ContextStateValidationError.textTooLong(field)
    }
}

private func validateRequiredContextText(_ value: String, field: String,
                                         maxBytes: Int) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ContextStateValidationError.emptyText(field) }
    guard value.utf8.count <= maxBytes else {
        throw ContextStateValidationError.textTooLong(field)
    }
}

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

    private enum CodingKeys: String, CodingKey {
        case interfaceID, kind, originatingDeviceID, companionDeviceID, observedAt
    }

    public init(interfaceID: UUID = UUID(), kind: AgentInterfaceKind,
                originatingDeviceID: UUID? = nil,
                companionDeviceID: UUID? = nil,
                observedAt: Date = Date()) throws {
        if kind == .metaGlassesViaPhone, companionDeviceID == nil {
            throw ContextStateValidationError.missingGlassesCompanion
        }
        self.interfaceID = interfaceID
        self.kind = kind
        self.originatingDeviceID = originatingDeviceID
        self.companionDeviceID = companionDeviceID
        self.observedAt = observedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            interfaceID: values.decode(UUID.self, forKey: .interfaceID),
            kind: values.decode(AgentInterfaceKind.self, forKey: .kind),
            originatingDeviceID: values.decodeIfPresent(UUID.self, forKey: .originatingDeviceID),
            companionDeviceID: values.decodeIfPresent(UUID.self, forKey: .companionDeviceID),
            observedAt: values.decode(Date.self, forKey: .observedAt)
        )
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
    public let summary: String?
    public let currentTaskID: UUID?
    public let pendingApprovalID: UUID?
    public let activeJobIDs: [UUID]
    public let interfaceID: UUID?
    public let observedAt: Date

    private enum CodingKeys: String, CodingKey {
        case sessionID, activeDeviceID, currentGoal, summary, currentTaskID,
             pendingApprovalID, activeJobIDs, interfaceID, observedAt
    }

    public init(sessionID: UUID, activeDeviceID: UUID? = nil,
                currentGoal: String? = nil, summary: String? = nil,
                currentTaskID: UUID? = nil,
                pendingApprovalID: UUID? = nil, activeJobIDs: [UUID] = [],
                interfaceID: UUID? = nil, observedAt: Date = Date()) throws {
        try validateOptionalContextText(currentGoal, field: "currentGoal", maxBytes: 4_096)
        try validateOptionalContextText(summary, field: "summary", maxBytes: 8_192)
        guard activeJobIDs.count <= 256 else { throw ContextStateValidationError.tooManyJobs }
        guard Set(activeJobIDs).count == activeJobIDs.count else {
            throw ContextStateValidationError.duplicateJobID
        }
        self.sessionID = sessionID
        self.activeDeviceID = activeDeviceID
        self.currentGoal = currentGoal
        self.summary = summary
        self.currentTaskID = currentTaskID
        self.pendingApprovalID = pendingApprovalID
        self.activeJobIDs = activeJobIDs
        self.interfaceID = interfaceID
        self.observedAt = observedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionID: values.decode(UUID.self, forKey: .sessionID),
            activeDeviceID: values.decodeIfPresent(UUID.self, forKey: .activeDeviceID),
            currentGoal: values.decodeIfPresent(String.self, forKey: .currentGoal),
            summary: values.decodeIfPresent(String.self, forKey: .summary),
            currentTaskID: values.decodeIfPresent(UUID.self, forKey: .currentTaskID),
            pendingApprovalID: values.decodeIfPresent(UUID.self, forKey: .pendingApprovalID),
            activeJobIDs: values.decode([UUID].self, forKey: .activeJobIDs),
            interfaceID: values.decodeIfPresent(UUID.self, forKey: .interfaceID),
            observedAt: values.decode(Date.self, forKey: .observedAt)
        )
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

    private enum CodingKeys: String, CodingKey {
        case deviceID, online, lastSeenAt, advertisedCapabilities, frontmostApp,
             focusedWindow, activeProject, workingDirectory, selectedFile,
             browserURL, observedAt
    }

    public init(deviceID: UUID, online: Bool, lastSeenAt: Date,
                advertisedCapabilities: [String] = [],
                frontmostApp: String? = nil, focusedWindow: String? = nil,
                activeProject: String? = nil, workingDirectory: String? = nil,
                selectedFile: String? = nil, browserURL: String? = nil,
                observedAt: Date = Date()) throws {
        guard advertisedCapabilities.count <= 512 else {
            throw ContextStateValidationError.tooManyCapabilities
        }
        var normalizedCapabilities: Set<String> = []
        for raw in advertisedCapabilities {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 256 else {
                throw ContextStateValidationError.invalidCapabilityName
            }
            normalizedCapabilities.insert(name)
        }
        try validateOptionalContextText(frontmostApp, field: "frontmostApp", maxBytes: 512)
        try validateOptionalContextText(focusedWindow, field: "focusedWindow", maxBytes: 2_048)
        try validateOptionalContextText(activeProject, field: "activeProject", maxBytes: 1_024)
        try validateOptionalContextText(workingDirectory, field: "workingDirectory", maxBytes: 4_096)
        try validateOptionalContextText(selectedFile, field: "selectedFile", maxBytes: 4_096)
        try validateOptionalContextText(browserURL, field: "browserURL", maxBytes: 8_192)

        self.deviceID = deviceID
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.advertisedCapabilities = normalizedCapabilities.sorted()
        self.frontmostApp = frontmostApp
        self.focusedWindow = focusedWindow
        self.activeProject = activeProject
        self.workingDirectory = workingDirectory
        self.selectedFile = selectedFile
        self.browserURL = browserURL
        self.observedAt = observedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            deviceID: values.decode(UUID.self, forKey: .deviceID),
            online: values.decode(Bool.self, forKey: .online),
            lastSeenAt: values.decode(Date.self, forKey: .lastSeenAt),
            advertisedCapabilities: values.decode([String].self, forKey: .advertisedCapabilities),
            frontmostApp: values.decodeIfPresent(String.self, forKey: .frontmostApp),
            focusedWindow: values.decodeIfPresent(String.self, forKey: .focusedWindow),
            activeProject: values.decodeIfPresent(String.self, forKey: .activeProject),
            workingDirectory: values.decodeIfPresent(String.self, forKey: .workingDirectory),
            selectedFile: values.decodeIfPresent(String.self, forKey: .selectedFile),
            browserURL: values.decodeIfPresent(String.self, forKey: .browserURL),
            observedAt: values.decode(Date.self, forKey: .observedAt)
        )
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
    case waitingForApproval = "waiting_for_approval"
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

    private enum CodingKeys: String, CodingKey {
        case taskID, sessionID, goal, status, knownFacts, actionsTaken,
             nextCandidates, observedAt
    }

    public init(taskID: UUID, sessionID: UUID, goal: String,
                status: TaskContextStatus = .pending,
                knownFacts: [String: JSONValue] = [:],
                actionsTaken: [String] = [], nextCandidates: [String] = [],
                observedAt: Date = Date()) throws {
        try validateRequiredContextText(goal, field: "goal", maxBytes: 4_096)
        guard knownFacts.count <= 128 else { throw ContextStateValidationError.tooManyFacts }
        for key in knownFacts.keys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, key.utf8.count <= 256 else {
                throw ContextStateValidationError.invalidFactKey
            }
        }
        guard actionsTaken.count <= 128 else { throw ContextStateValidationError.tooManyActions }
        for action in actionsTaken {
            try validateRequiredContextText(action, field: "action", maxBytes: 2_048)
        }
        guard nextCandidates.count <= 64 else { throw ContextStateValidationError.tooManyCandidates }
        for candidate in nextCandidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, candidate.utf8.count <= 256 else {
                throw ContextStateValidationError.invalidCandidate
            }
        }

        self.taskID = taskID
        self.sessionID = sessionID
        self.goal = goal
        self.status = status
        self.knownFacts = knownFacts
        self.actionsTaken = actionsTaken
        self.nextCandidates = nextCandidates
        self.observedAt = observedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            taskID: values.decode(UUID.self, forKey: .taskID),
            sessionID: values.decode(UUID.self, forKey: .sessionID),
            goal: values.decode(String.self, forKey: .goal),
            status: values.decode(TaskContextStatus.self, forKey: .status),
            knownFacts: values.decode([String: JSONValue].self, forKey: .knownFacts),
            actionsTaken: values.decode([String].self, forKey: .actionsTaken),
            nextCandidates: values.decode([String].self, forKey: .nextCandidates),
            observedAt: values.decode(Date.self, forKey: .observedAt)
        )
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
                      summary: String? = nil,
                      currentTaskID: UUID? = nil,
                      pendingApprovalID: UUID? = nil,
                      activeJobIDs: [UUID] = [],
                      interfaceID: UUID? = nil,
                      observedAt: Date = Date()) throws -> SessionContextState {
        try SessionContextState(
            sessionID: id,
            activeDeviceID: activeDeviceID,
            currentGoal: currentGoal,
            summary: summary,
            currentTaskID: currentTaskID,
            pendingApprovalID: pendingApprovalID,
            activeJobIDs: activeJobIDs,
            interfaceID: interfaceID,
            observedAt: observedAt
        )
    }
}
