import Foundation

public struct AgentSession: Codable, Sendable, Equatable {
    public let id: UUID
    public let activeDeviceID: UUID?
    public let allowBoundedReadDeviceSelection: Bool

    public init(id: UUID = UUID(), activeDeviceID: UUID? = nil,
                allowBoundedReadDeviceSelection: Bool = false) {
        self.id = id
        self.activeDeviceID = activeDeviceID
        self.allowBoundedReadDeviceSelection = allowBoundedReadDeviceSelection
    }
}

/// Trusted execution identity and live request bindings. `TenantContext` must be
/// supplied by authenticated backend/session code; it is never accepted from a
/// model-generated tool request or external content.
public struct AgentInvocationContext: Sendable, Equatable {
    public let principal: TenantContext
    public let session: AgentSession
    public let interfaceID: UUID?
    public let taskID: UUID?

    public init(principal: TenantContext,
                session: AgentSession,
                interfaceID: UUID? = nil,
                taskID: UUID? = nil) {
        self.principal = principal
        self.session = session
        self.interfaceID = interfaceID
        self.taskID = taskID
    }
}

public struct ToolIntent: Codable, Sendable, Equatable {
    public let tool: String
    public let arguments: JSONValue
    public let explicitDeviceID: UUID?
    public let approvalID: UUID?
    public let decisionState: JSONValue

    public init(tool: String, arguments: JSONValue = .object([:]),
                explicitDeviceID: UUID? = nil, approvalID: UUID? = nil,
                decisionState: JSONValue = .object([:])) {
        self.tool = tool
        self.arguments = arguments
        self.explicitDeviceID = explicitDeviceID
        self.approvalID = approvalID
        self.decisionState = decisionState
    }
}

public enum OrchestrationError: Error, Sendable, Equatable {
    case noCapableDevice(String)
    case deviceSelectionRequired(tool: String, candidateDeviceIDs: [UUID])
    case inconsistentCapabilityRisk(String)
    case invalidDeviceDecision(String)
}

/// Coordinates session context and device routing without knowing how a platform
/// implements any capability. Model/provider adapters remain outside this type.
public struct AgentOrchestrator: Sendable {
    private let devices: DeviceRouter
    private let decisions: DecisionEngine
    private let contextCompiler: ContextCompiler?

    public init(devices: DeviceRouter,
                decisions: DecisionEngine,
                contextCompiler: ContextCompiler? = nil) {
        self.devices = devices
        self.decisions = decisions
        self.contextCompiler = contextCompiler
    }

    /// Compatibility path for callers that have not yet been upgraded to carry
    /// authenticated tenant context. It intentionally does not compile stored
    /// context into model decisions.
    public func execute(_ intent: ToolIntent,
                        in session: AgentSession) async throws -> ToolResult {
        try await execute(intent, session: session, invocation: nil)
    }

    /// Preferred context-aware path. Tenant identity is supplied separately from
    /// model-generated intent and may be used only to retrieve that principal's
    /// context partition.
    public func execute(_ intent: ToolIntent,
                        in invocation: AgentInvocationContext) async throws -> ToolResult {
        try await execute(intent, session: invocation.session, invocation: invocation)
    }

    private func execute(_ intent: ToolIntent,
                         session: AgentSession,
                         invocation: AgentInvocationContext?) async throws -> ToolResult {
        if let explicitDeviceID = intent.explicitDeviceID {
            return try await devices.route(
                tool: intent.tool,
                arguments: intent.arguments,
                to: explicitDeviceID,
                sessionID: session.id,
                approvalID: intent.approvalID
            )
        }

        let candidates = await devices.candidates(for: intent.tool)
        guard !candidates.isEmpty else {
            throw OrchestrationError.noCapableDevice(intent.tool)
        }

        if let activeDeviceID = session.activeDeviceID,
           candidates.contains(where: { $0.identity.id == activeDeviceID }) {
            return try await devices.route(
                tool: intent.tool,
                arguments: intent.arguments,
                to: activeDeviceID,
                sessionID: session.id,
                approvalID: intent.approvalID
            )
        }

        if candidates.count == 1 {
            return try await devices.route(
                tool: intent.tool,
                arguments: intent.arguments,
                to: candidates[0].identity.id,
                sessionID: session.id,
                approvalID: intent.approvalID
            )
        }

        let risks = Set(candidates.compactMap { snapshot in
            snapshot.capabilities.first(where: { $0.name == intent.tool })?.risk
        })
        guard risks.count == 1, let risk = risks.first else {
            throw OrchestrationError.inconsistentCapabilityRisk(intent.tool)
        }

        let candidateIDs = candidates.map(\.identity.id)
            .sorted { $0.uuidString < $1.uuidString }

        guard risk == .read, session.allowBoundedReadDeviceSelection else {
            throw OrchestrationError.deviceSelectionRequired(
                tool: intent.tool,
                candidateDeviceIDs: candidateIDs
            )
        }

        let options = candidates.map { snapshot in
            DecisionOption(
                id: snapshot.identity.id.uuidString,
                summary: snapshot.identity.displayName,
                metadata: .object([
                    "platform": .string(snapshot.identity.platform)
                ])
            )
        }

        var state: [String: JSONValue] = [
            "tool": .string(intent.tool),
            "session_id": .string(session.id.uuidString),
            "intent_state": intent.decisionState
        ]

        if let invocation, let contextCompiler {
            let candidateScopes = Set(candidates.map { ContextScope.device($0.identity.id) })
            let request = try ContextCompilationRequest(
                consumer: .boundedDecision,
                sessionID: session.id,
                interfaceID: invocation.interfaceID,
                taskID: invocation.taskID,
                additionalScopes: candidateScopes,
                includeUserScope: false,
                includeExternalContent: false,
                includeMemory: false,
                includeModelGenerated: false,
                maxItems: 24,
                maxBytes: 16_384,
                refreshStaleEphemeral: true,
                maxRefreshItems: 8
            )
            let compiled = try await contextCompiler.compile(
                request,
                as: invocation.principal
            )
            state["compiled_context"] = try JSONValue.encoding(compiled)
        }

        let decision = try await decisions.decide(DecisionRequest(
            objective: "Choose the most appropriate device for this read-only capability.",
            state: .object(state),
            options: options
        ))

        guard let selectedID = UUID(uuidString: decision.decision.selectedOptionID) else {
            throw OrchestrationError.invalidDeviceDecision(decision.decision.selectedOptionID)
        }

        return try await devices.route(
            tool: intent.tool,
            arguments: intent.arguments,
            to: selectedID,
            sessionID: session.id,
            approvalID: intent.approvalID
        )
    }
}
