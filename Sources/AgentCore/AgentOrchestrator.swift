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

/// Immutable, trusted result of device/capability resolution. Approval UI can
/// inspect this exact binding, but cannot change it after a grant is issued.
public struct PreparedToolExecution: Sendable {
    public let requestID: UUID
    public let tool: String
    public let arguments: JSONValue
    public let descriptor: ToolDescriptor
    public let context: RequestContext

    init(requestID: UUID,
         tool: String,
         arguments: JSONValue,
         descriptor: ToolDescriptor,
         context: RequestContext) {
        self.requestID = requestID
        self.tool = tool
        self.arguments = arguments
        self.descriptor = descriptor
        self.context = context
    }

    public func request(approvalID: UUID? = nil) -> ToolRequest {
        ToolRequest(
            id: requestID,
            tool: tool,
            arguments: arguments,
            context: context,
            approvalID: approvalID
        )
    }
}

public enum OrchestrationError: Error, Sendable, Equatable {
    case noCapableDevice(String)
    case deviceSelectionRequired(tool: String, candidateDeviceIDs: [UUID])
    case inconsistentCapabilityRisk(String)
    case invalidDeviceDecision(String)
    case contextCompilerUnavailable
}

/// Coordinates authenticated context compilation, session state and device
/// routing without knowing how a platform or model provider implements them.
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

    /// Single authenticated model-context boundary. Future realtime/reasoning
    /// adapters call the orchestrator, which delegates to the configured compiler.
    /// Tenant identity remains outside model-generated requests.
    public func compileContext(_ request: ContextCompilationRequest,
                               in invocation: AgentInvocationContext,
                               now: Date = Date()) async throws -> CompiledContext {
        guard let contextCompiler else {
            throw OrchestrationError.contextCompilerUnavailable
        }
        return try await contextCompiler.compile(
            request,
            as: invocation.principal,
            now: now
        )
    }

    /// Returns executor tools actually advertised by trusted device state. A
    /// realtime provider receives semantic capabilities filtered through this set,
    /// never an invented model-side tool list.
    public func availableExecutorTools(in invocation: AgentInvocationContext,
                                       explicitDeviceID: UUID? = nil) async throws -> Set<String> {
        if let deviceID = explicitDeviceID ?? invocation.session.activeDeviceID {
            let snapshot = try await devices.snapshot(for: deviceID)
            return Set(snapshot.capabilities.map(\.name))
        }
        let snapshots = await devices.snapshots()
        return Set(snapshots.flatMap { $0.capabilities.map(\.name) })
    }

    /// Resolves one exact device/capability binding without executing it. This is
    /// the handoff point for a trusted approval UI on non-read actions.
    public func prepare(_ intent: ToolIntent,
                        in invocation: AgentInvocationContext,
                        requestID: UUID = UUID()) async throws -> PreparedToolExecution {
        try await prepare(
            intent,
            session: invocation.session,
            invocation: invocation,
            requestID: requestID
        )
    }

    /// Executes only the already-resolved immutable request. The device runtime
    /// still validates the approval against its live descriptor before execution.
    public func execute(_ prepared: PreparedToolExecution,
                        approvalID: UUID? = nil) async throws -> ToolResult {
        try await devices.route(prepared.request(approvalID: approvalID))
    }

    /// Compatibility path for callers that have not yet been upgraded to carry
    /// authenticated tenant context. It intentionally does not compile stored
    /// context into model decisions.
    public func execute(_ intent: ToolIntent,
                        in session: AgentSession) async throws -> ToolResult {
        let prepared = try await prepare(
            intent,
            session: session,
            invocation: nil,
            requestID: UUID()
        )
        return try await execute(prepared, approvalID: intent.approvalID)
    }

    /// Preferred context-aware path. Tenant identity is supplied separately from
    /// model-generated intent and may be used only to retrieve that principal's
    /// context partition.
    public func execute(_ intent: ToolIntent,
                        in invocation: AgentInvocationContext) async throws -> ToolResult {
        let prepared = try await prepare(intent, in: invocation)
        return try await execute(prepared, approvalID: intent.approvalID)
    }

    private func prepare(_ intent: ToolIntent,
                         session: AgentSession,
                         invocation: AgentInvocationContext?,
                         requestID: UUID) async throws -> PreparedToolExecution {
        let deviceID = try await resolveDeviceID(
            for: intent,
            session: session,
            invocation: invocation
        )
        let descriptor = try await devices.descriptor(for: intent.tool, on: deviceID)
        return PreparedToolExecution(
            requestID: requestID,
            tool: intent.tool,
            arguments: intent.arguments,
            descriptor: descriptor,
            context: RequestContext(deviceID: deviceID, sessionID: session.id)
        )
    }

    private func resolveDeviceID(for intent: ToolIntent,
                                 session: AgentSession,
                                 invocation: AgentInvocationContext?) async throws -> UUID {
        if let explicitDeviceID = intent.explicitDeviceID {
            // descriptor(for:on:) in prepare() performs the authoritative
            // capability check for explicit devices.
            return explicitDeviceID
        }

        let candidates = await devices.candidates(for: intent.tool)
        guard !candidates.isEmpty else {
            throw OrchestrationError.noCapableDevice(intent.tool)
        }

        if let activeDeviceID = session.activeDeviceID,
           candidates.contains(where: { $0.identity.id == activeDeviceID }) {
            return activeDeviceID
        }

        if candidates.count == 1 {
            return candidates[0].identity.id
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
        guard candidateIDs.contains(selectedID) else {
            throw OrchestrationError.invalidDeviceDecision(decision.decision.selectedOptionID)
        }
        return selectedID
    }
}
