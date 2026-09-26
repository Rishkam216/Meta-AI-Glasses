import Foundation
import Testing
@testable import AgentCore

private actor RealtimeDeviceRecorder {
    private(set) var requests: [ToolRequest] = []
    func record(_ request: ToolRequest) { requests.append(request) }
}

private struct RealtimeTestDevice: DeviceExecuting {
    let identity: DeviceIdentity
    let tool: String
    let recorder: RealtimeDeviceRecorder

    func capabilities() async -> [ToolDescriptor] {
        [ToolDescriptor(
            name: tool,
            summary: "Test read capability",
            risk: .read,
            inputSchema: EmptyInput.schema
        )]
    }

    func execute(_ request: ToolRequest) async -> ToolResult {
        await recorder.record(request)
        return ToolResult(request: request, data: .string(identity.displayName))
    }
}

private actor RealtimeDecisionProvider: DecisionProvider {
    nonisolated let providerID = "realtime-test-bounded"

    func decide(_ request: DecisionRequest) -> ProviderDecision {
        ProviderDecision(selectedOptionID: request.options[0].id, confidence: 1)
    }
}

private actor FakeRealtimeSession: RealtimeModelSession {
    nonisolated let id = UUID()
    private var incoming: [RealtimeProviderEvent]
    private(set) var sent: [RealtimeClientEvent] = []
    private(set) var cancelledTurns: [UUID] = []
    private(set) var closeCount = 0

    init(events: [RealtimeProviderEvent]) {
        incoming = events
    }

    func send(_ event: RealtimeClientEvent) {
        sent.append(event)
    }

    func nextEvent() -> RealtimeProviderEvent? {
        guard !incoming.isEmpty else { return nil }
        return incoming.removeFirst()
    }

    func cancel(turnID: UUID) {
        cancelledTurns.append(turnID)
    }

    func close() {
        closeCount += 1
    }

    func sentEvents() -> [RealtimeClientEvent] { sent }
    func cancelled() -> [UUID] { cancelledTurns }
}

private func makeRealtimeCoordinator(devices: [RealtimeTestDevice]) async throws -> RealtimeCoordinator {
    let router = DeviceRouter()
    for device in devices {
        try await router.register(device)
    }
    let provider = RealtimeDecisionProvider()
    let compiler = ContextCompiler(store: InMemoryContextService())
    let orchestrator = AgentOrchestrator(
        devices: router,
        decisions: DecisionEngine(boundedProvider: provider),
        contextCompiler: compiler
    )
    return RealtimeCoordinator(orchestrator: orchestrator)
}

private func principal() -> TenantContext {
    TenantContext(tenantID: UUID(), userID: UUID())
}

@Test func realtimeTurnRoutesToolThroughOrchestratorAndReturnsResult() async throws {
    let recorder = RealtimeDeviceRecorder()
    let device = RealtimeTestDevice(
        identity: DeviceIdentity(displayName: "Local Mac", platform: "macOS"),
        tool: "ui.get_frontmost_app",
        recorder: recorder
    )
    let coordinator = try await makeRealtimeCoordinator(devices: [device])
    let invocation = AgentInvocationContext(
        principal: principal(),
        session: AgentSession(activeDeviceID: device.identity.id),
        interfaceID: UUID()
    )
    let turn = try RealtimeTurnRequest(text: "What app am I using?")
    let intent = try RealtimeToolIntent(
        turnID: turn.id,
        tool: "ui.get_frontmost_app"
    )
    let session = FakeRealtimeSession(events: [
        .toolIntent(intent),
        .assistantText(try RealtimeAssistantText(turnID: turn.id, text: "You are using the local Mac app.")),
        .turnCompleted(RealtimeTurnCompleted(turnID: turn.id))
    ])

    let result = try await coordinator.runTurn(turn, in: invocation, using: session)

    #expect(result.assistantText == ["You are using the local Mac app."])
    #expect(result.toolResults.count == 1)
    #expect(result.toolResults[0].status == "success")
    #expect(result.toolResults[0].data == .string("Local Mac"))
    #expect(await recorder.requests.count == 1)

    let sent = await session.sentEvents()
    #expect(sent.count == 3)
    guard case .turnContext(let contextEvent) = sent[0] else {
        Issue.record("First event must be compiled context")
        return
    }
    #expect(contextEvent.turnID == turn.id)
    #expect(contextEvent.context.consumer == .realtime)
    guard case .userText(let userEvent) = sent[1] else {
        Issue.record("Second event must be user text")
        return
    }
    #expect(userEvent.text == "What app am I using?")
    guard case .toolResult(let toolResult) = sent[2] else {
        Issue.record("Third event must be tool result")
        return
    }
    #expect(toolResult.sourceEventID == intent.eventID)
}

@Test func duplicateRealtimeToolEventResendsResultWithoutReexecution() async throws {
    let recorder = RealtimeDeviceRecorder()
    let device = RealtimeTestDevice(
        identity: DeviceIdentity(displayName: "Mac", platform: "macOS"),
        tool: "ui.inspect",
        recorder: recorder
    )
    let coordinator = try await makeRealtimeCoordinator(devices: [device])
    let invocation = AgentInvocationContext(
        principal: principal(),
        session: AgentSession(activeDeviceID: device.identity.id)
    )
    let turn = try RealtimeTurnRequest(text: "Inspect")
    let eventID = UUID()
    let intent = try RealtimeToolIntent(eventID: eventID, turnID: turn.id, tool: "ui.inspect")
    let session = FakeRealtimeSession(events: [
        .toolIntent(intent),
        .toolIntent(intent),
        .turnCompleted(RealtimeTurnCompleted(turnID: turn.id))
    ])

    let result = try await coordinator.runTurn(turn, in: invocation, using: session)

    #expect(await recorder.requests.count == 1)
    #expect(result.toolResults.count == 1)
    let sentToolResults = await session.sentEvents().filter {
        if case .toolResult = $0 { return true }
        return false
    }
    #expect(sentToolResults.count == 2)
}

@Test func mismatchedReplayWithSameEventIDFailsClosed() async throws {
    let recorder = RealtimeDeviceRecorder()
    let device = RealtimeTestDevice(
        identity: DeviceIdentity(displayName: "Mac", platform: "macOS"),
        tool: "ui.inspect",
        recorder: recorder
    )
    let coordinator = try await makeRealtimeCoordinator(devices: [device])
    let invocation = AgentInvocationContext(
        principal: principal(),
        session: AgentSession(activeDeviceID: device.identity.id)
    )
    let turn = try RealtimeTurnRequest(text: "Inspect")
    let eventID = UUID()
    let first = try RealtimeToolIntent(eventID: eventID, turnID: turn.id, tool: "ui.inspect")
    let changed = try RealtimeToolIntent(
        eventID: eventID,
        turnID: turn.id,
        tool: "ui.inspect",
        arguments: .object(["changed": .bool(true)])
    )
    let session = FakeRealtimeSession(events: [.toolIntent(first), .toolIntent(changed)])

    await #expect(throws: RealtimeProtocolError.duplicateEventMismatch) {
        try await coordinator.runTurn(turn, in: invocation, using: session)
    }
    #expect(await recorder.requests.count == 1)
}

@Test func providerCannotOverrideTrustedExplicitDevice() async throws {
    let firstRecorder = RealtimeDeviceRecorder()
    let secondRecorder = RealtimeDeviceRecorder()
    let first = RealtimeTestDevice(
        identity: DeviceIdentity(displayName: "First", platform: "macOS"),
        tool: "ui.inspect",
        recorder: firstRecorder
    )
    let second = RealtimeTestDevice(
        identity: DeviceIdentity(displayName: "Second", platform: "macOS"),
        tool: "ui.inspect",
        recorder: secondRecorder
    )
    let coordinator = try await makeRealtimeCoordinator(devices: [first, second])
    let invocation = AgentInvocationContext(
        principal: principal(),
        session: AgentSession(activeDeviceID: first.identity.id)
    )
    let turn = try RealtimeTurnRequest(
        text: "Inspect the second Mac",
        explicitDeviceID: second.identity.id
    )
    let intent = try RealtimeToolIntent(turnID: turn.id, tool: "ui.inspect")
    let session = FakeRealtimeSession(events: [
        .toolIntent(intent),
        .turnCompleted(RealtimeTurnCompleted(turnID: turn.id))
    ])

    _ = try await coordinator.runTurn(turn, in: invocation, using: session)

    #expect(await firstRecorder.requests.isEmpty)
    #expect(await secondRecorder.requests.count == 1)
}

@Test func unavailableProviderToolReturnsSanitizedToolFailureAndTurnContinues() async throws {
    let recorder = RealtimeDeviceRecorder()
    let device = RealtimeTestDevice(
        identity: DeviceIdentity(displayName: "Mac", platform: "macOS"),
        tool: "ui.inspect",
        recorder: recorder
    )
    let coordinator = try await makeRealtimeCoordinator(devices: [device])
    let invocation = AgentInvocationContext(
        principal: principal(),
        session: AgentSession(activeDeviceID: device.identity.id)
    )
    let turn = try RealtimeTurnRequest(text: "Do an unknown thing")
    let intent = try RealtimeToolIntent(turnID: turn.id, tool: "dangerous.unknown")
    let session = FakeRealtimeSession(events: [
        .toolIntent(intent),
        .assistantText(try RealtimeAssistantText(turnID: turn.id, text: "That capability is unavailable.")),
        .turnCompleted(RealtimeTurnCompleted(turnID: turn.id))
    ])

    let result = try await coordinator.runTurn(turn, in: invocation, using: session)

    #expect(result.toolResults.count == 1)
    #expect(result.toolResults[0].status == "error")
    #expect(result.toolResults[0].error?.code == .unavailable)
    #expect(result.assistantText == ["That capability is unavailable."])
    #expect(await recorder.requests.isEmpty)
}

@Test func wrongTurnProviderEventFailsClosed() async throws {
    let recorder = RealtimeDeviceRecorder()
    let device = RealtimeTestDevice(
        identity: DeviceIdentity(displayName: "Mac", platform: "macOS"),
        tool: "ui.inspect",
        recorder: recorder
    )
    let coordinator = try await makeRealtimeCoordinator(devices: [device])
    let invocation = AgentInvocationContext(
        principal: principal(),
        session: AgentSession(activeDeviceID: device.identity.id)
    )
    let turn = try RealtimeTurnRequest(text: "Inspect")
    let session = FakeRealtimeSession(events: [
        .assistantText(try RealtimeAssistantText(turnID: UUID(), text: "foreign turn"))
    ])

    await #expect(throws: RealtimeProtocolError.wrongTurn) {
        try await coordinator.runTurn(turn, in: invocation, using: session)
    }
}

@Test func explicitCancellationIsForwardedToProviderSession() async throws {
    let coordinator = try await makeRealtimeCoordinator(devices: [])
    let session = FakeRealtimeSession(events: [])
    let turnID = UUID()

    await coordinator.cancel(turnID: turnID, using: session)

    #expect(await session.cancelled() == [turnID])
}

@Test func realtimePayloadValidationIsBounded() throws {
    #expect(throws: RealtimeValidationError.invalidText) {
        _ = try RealtimeTurnRequest(text: "   ")
    }
    #expect(throws: RealtimeValidationError.textTooLarge) {
        _ = try RealtimeTurnRequest(text: String(repeating: "x", count: RealtimeLimits.maxTextBytes + 1))
    }
    #expect(throws: RealtimeValidationError.invalidToolName) {
        _ = try RealtimeToolIntent(turnID: UUID(), tool: "")
    }
}
