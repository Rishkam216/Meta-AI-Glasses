import Foundation

/// Portable orchestration loop between a realtime provider session and the
/// existing authenticated context/device/tool runtime. Provider/model payloads
/// never carry authoritative tenant identity, session identity or approval IDs.
public struct RealtimeCoordinator: Sendable {
    private struct ProcessedToolEvent: Sendable {
        let tool: String
        let arguments: JSONValue
        let result: RealtimeToolResult
    }

    private let orchestrator: AgentOrchestrator
    private let approvalProvider: (any RealtimeApprovalProviding)?

    public init(orchestrator: AgentOrchestrator,
                approvalProvider: (any RealtimeApprovalProviding)? = nil) {
        self.orchestrator = orchestrator
        self.approvalProvider = approvalProvider
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

        try await session.send(.turnContext(RealtimeTurnContext(
            turnID: request.id,
            context: compiled
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
                    guard previous.tool == toolIntent.tool,
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
                    invocation: invocation
                )
                let providerResult = RealtimeToolResult(
                    sourceEventID: toolIntent.eventID,
                    turnID: request.id,
                    result: result
                )
                processedTools[toolIntent.eventID] = ProcessedToolEvent(
                    tool: toolIntent.tool,
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
                                   invocation: AgentInvocationContext) async throws -> ToolResult {
        do {
            // Device identity comes from trusted turn/session state. The provider
            // supplies only tool + JSON arguments and cannot carry approval IDs.
            let prepared = try await orchestrator.prepare(
                ToolIntent(
                    tool: intent.tool,
                    arguments: intent.arguments,
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
            let fallbackRequest = ToolRequest(
                id: intent.eventID,
                tool: intent.tool,
                arguments: intent.arguments,
                context: nil,
                approvalID: nil
            )
            return ToolResult(
                request: fallbackRequest,
                error: ToolFailure(
                    code: .unavailable,
                    message: "The requested capability is not available for this turn."
                )
            )
        }
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
