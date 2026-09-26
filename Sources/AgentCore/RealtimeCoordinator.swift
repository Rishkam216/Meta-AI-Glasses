import Foundation

/// Portable orchestration loop between a realtime provider session and the
/// existing authenticated context/device/tool runtime. Provider/model payloads
/// never carry authoritative tenant identity, session identity or approval IDs.
public struct RealtimeCoordinator: Sendable {
    private struct ProcessedToolEvent: Sendable {
        let capability: String
        let arguments: JSONValue
        let result: RealtimeToolResult
    }

    private let orchestrator: AgentOrchestrator
    private let approvalProvider: (any RealtimeApprovalProviding)?
    private let capabilities: any AgentCapabilityResolving

    public init(orchestrator: AgentOrchestrator,
                approvalProvider: (any RealtimeApprovalProviding)? = nil,
                capabilities: any AgentCapabilityResolving = DefaultAgentCapabilityRegistry()) {
        self.orchestrator = orchestrator
        self.approvalProvider = approvalProvider
        self.capabilities = capabilities
    }

    public func runTurn(_ request: RealtimeTurnRequest,
                        in invocation: AgentInvocationContext,
                        using session: any RealtimeModelSession) async throws -> RealtimeTurnResult {
        let deviceID = request.explicitDeviceID ?? invocation.session.activeDeviceID
        var additionalScopes: Set<ContextScope> = []
        if let deviceID {
            additionalScopes.insert(.device(deviceID))
        }

        let compilationRequest = try ContextCompilationRequest(
            consumer: .realtime,
            sessionID: invocation.session.id,
            interfaceID: invocation.interfaceID,
            deviceID: deviceID,
            taskID: invocation.taskID,
            additionalScopes: additionalScopes,
            includeUserScope: true,
            includeExternalContent: false,
            includeMemory: request.memoryQuery != nil,
            includeModelGenerated: false,
            maxItems: 48,
            maxBytes: 64 * 1_024,
            refreshStaleEphemeral: true,
            maxRefreshItems: 8,
            memoryQuery: request.memoryQuery
        )
        let compiled = try await orchestrator.compileContext(
            compilationRequest,
            in: invocation
        )

        let availableExecutorTools = try await orchestrator.availableExecutorTools(
            in: invocation,
            explicitDeviceID: request.explicitDeviceID
        )
        let capabilityCatalog = capabilities.catalog().filter { capability in
            guard let executorTool = try? capabilities.executorTool(for: capability.name) else {
                return false
            }
            return availableExecutorTools.contains(executorTool)
        }
        let allowedCapabilities = Set(capabilityCatalog.map(\.name))

        try await session.send(.turnContext(RealtimeTurnContext(
            turnID: request.id,
            context: compiled,
            capabilities: capabilityCatalog
        )))
        try await session.send(.userText(try RealtimeUserText(
            turnID: request.id,
            text: request.text
        )))

        var assistantText: [String] = []
        var seenAssistantEvents: Set<UUID> = []
        var processedTools: [UUID: ProcessedToolEvent] = [:]

        while let event = try await session.nextEvent() {
            try Task.checkCancellation()

            switch event {
            case .assistantText(let message):
                guard message.turnID == request.id else {
                    throw RealtimeProtocolError.wrongTurn
                }
                if seenAssistantEvents.insert(message.eventID).inserted {
                    assistantText.append(message.text)
                }

            case .toolIntent(let toolIntent):
                guard toolIntent.turnID == request.id else {
                    throw RealtimeProtocolError.wrongTurn
                }

                if let previous = processedTools[toolIntent.eventID] {
                    guard previous.capability == toolIntent.tool,
                          previous.arguments == toolIntent.arguments else {
                        throw RealtimeProtocolError.duplicateEventMismatch
                    }
                    // Re-send the prior result after a provider replay/reconnect;
                    // never execute a committed action twice.
                    try await session.send(.toolResult(previous.result))
                    continue
                }

                guard processedTools.count < RealtimeLimits.maxToolCallsPerTurn else {
                    throw RealtimeProtocolError.toolCallLimitExceeded
                }

                let result = try await executeToolIntent(
                    toolIntent,
                    turnID: request.id,
                    trustedDeviceID: request.explicitDeviceID,
                    invocation: invocation,
                    allowedCapabilities: allowedCapabilities
                )
                let providerResult = RealtimeToolResult(
                    sourceEventID: toolIntent.eventID,
                    turnID: request.id,
                    result: result,
                    reportedTool: toolIntent.tool
                )
                processedTools[toolIntent.eventID] = ProcessedToolEvent(
                    capability: toolIntent.tool,
                    arguments: toolIntent.arguments,
                    result: providerResult
                )
                try await session.send(.toolResult(providerResult))

            case .turnCompleted(let completed):
                guard completed.turnID == request.id else {
                    throw RealtimeProtocolError.wrongTurn
                }
                let orderedResults = processedTools
                    .sorted { $0.key.uuidString < $1.key.uuidString }
                    .map(\.value.result)
                return RealtimeTurnResult(
                    turnID: request.id,
                    assistantText: assistantText,
                    toolResults: orderedResults
                )

            case .failure(let failure):
                if let turnID = failure.turnID, turnID != request.id {
                    throw RealtimeProtocolError.wrongTurn
                }
                // Provider details can contain remote/internal data. Surface only
                // the bounded provider code through the portable error.
                throw RealtimeProtocolError.providerFailure(failure.code)
            }
        }

        throw RealtimeProtocolError.providerClosed
    }

    public func cancel(turnID: UUID,
                       using session: any RealtimeModelSession) async {
        await session.cancel(turnID: turnID)
    }

    private func executeToolIntent(_ intent: RealtimeToolIntent,
                                   turnID: UUID,
                                   trustedDeviceID: UUID?,
                                   invocation: AgentInvocationContext,
                                   allowedCapabilities: Set<String>) async throws -> ToolResult {
        guard allowedCapabilities.contains(intent.tool) else {
            return providerCapabilityFailure(
                intent,
                code: .unknownTool,
                message: "The requested capability is not available for this turn."
            )
        }

        let resolved: ResolvedAgentCapability
        do {
            resolved = try capabilities.resolve(name: intent.tool, arguments: intent.arguments)
        } catch AgentCapabilityResolutionError.invalidArguments {
            return providerCapabilityFailure(
                intent,
                code: .invalidArguments,
                message: "The capability arguments are invalid."
            )
        } catch {
            return providerCapabilityFailure(
                intent,
                code: .unknownTool,
                message: "The requested capability is not available for this turn."
            )
        }

        do {
            // Device identity comes from trusted turn/session state. Semantic
            // capability resolution happens locally and yields the native tool.
            let prepared = try await orchestrator.prepare(
                ToolIntent(
                    tool: resolved.executorTool,
                    arguments: resolved.arguments,
                    explicitDeviceID: trustedDeviceID,
                    approvalID: nil,
                    decisionState: .object([:])
                ),
                in: invocation,
                requestID: intent.eventID
            )

            var approvalID: UUID?
            if prepared.descriptor.risk != .read {
                guard let approvalProvider else {
                    return approvalRequiredResult(for: prepared)
                }
                try Task.checkCancellation()
                approvalID = try await approvalProvider.requestApproval(
                    RealtimeApprovalRequest(
                        sourceEventID: intent.eventID,
                        turnID: turnID,
                        descriptor: prepared.descriptor,
                        arguments: prepared.arguments,
                        context: prepared.context
                    )
                )
                try Task.checkCancellation()
                guard approvalID != nil else {
                    return approvalRequiredResult(for: prepared)
                }
            }

            return try await orchestrator.execute(
                prepared,
                approvalID: approvalID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return providerCapabilityFailure(
                intent,
                code: .unavailable,
                message: "The requested capability is not available for this turn."
            )
        }
    }

    private func providerCapabilityFailure(_ intent: RealtimeToolIntent,
                                           code: ErrorCode,
                                           message: String) -> ToolResult {
        ToolResult(
            request: ToolRequest(
                id: intent.eventID,
                tool: intent.tool,
                arguments: intent.arguments
            ),
            error: ToolFailure(code: code, message: message)
        )
    }

    private func approvalRequiredResult(for prepared: PreparedToolExecution) -> ToolResult {
        ToolResult(
            request: prepared.request(),
            error: ToolFailure(
                code: .approvalRequired,
                message: "This action requires a fresh local approval."
            )
        )
    }
}
