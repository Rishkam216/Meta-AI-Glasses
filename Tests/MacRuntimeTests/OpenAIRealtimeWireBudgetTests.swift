import Foundation
import Testing
@testable import AgentCore
@testable import MacRuntime

private actor WireBudgetTransport: OpenAIRealtimeTransport {
    private let incoming: [String]
    private var index = 0
    private(set) var closeCount = 0
    private(set) var receiveCount = 0

    init(_ incoming: [String]) { self.incoming = incoming }
    func connect(_ request: URLRequest) {}
    func send(text: String) {}
    func receive() -> String? {
        receiveCount += 1
        guard index < incoming.count else { return nil }
        defer { index += 1 }
        return incoming[index]
    }
    func close() { closeCount += 1 }
}

private let wireBudgetIgnored = #"{"type":"ignored.test.event"}"#
private let wireBudgetText = #"{"type":"response.output_text.delta","event_id":"same-text-id","delta":"OK"}"#
private let wireBudgetDone = #"{"type":"response.done","response":{"id":"resp_final","status":"completed","output":[]}}"#
private let wireBudgetCall = #"{"type":"response.function_call_arguments.done","response_id":"resp_tool","call_id":"same-call-id","name":"cap_computer_open_app","arguments":"{\"application_id\":\"com.apple.calculator\"}"}"#
private let wireBudgetToolDone = #"{"type":"response.done","response":{"id":"resp_tool","status":"completed","output":[{"type":"function_call"}]}}"#

private func wireBudgetSession(_ frames: [String]) async throws -> (
    session: any RealtimeModelSession, transport: WireBudgetTransport
) {
    let transport = WireBudgetTransport([#"{"type":"session.created"}"#] + frames)
    let provider = try OpenAIRealtimeProvider(
        endpoint: URL(string: "wss://api.openai.com/v1/realtime")!,
        model: "gpt-realtime-2.1",
        credentialProvider: { "offline-wire-budget" },
        transportFactory: { transport }
    )
    return (try await provider.openSession(agentSessionID: UUID()), transport)
}

private func wireBudgetBegin(_ session: any RealtimeModelSession) async throws -> UUID {
    let turnID = UUID()
    let context = CompiledContext(
        consumer: .realtime, items: [], consideredItemCount: 0,
        omittedByPolicyCount: 0, omittedByBudgetCount: 0, encodedBytes: 0,
        refreshSummary: .none, memoryRetrievalSummary: .none
    )
    try await session.send(.turnContext(RealtimeTurnContext(
        turnID: turnID, context: context,
        capabilities: [AgentCapabilityDescriptor(
            name: "computer.open_app", summary: "Open an application.",
            effect: .action, inputSchema: EmptyInput.schema
        )]
    )))
    try await session.send(.userText(RealtimeUserText(turnID: turnID, text: "Budget test")))
    return turnID
}

private func wireBudgetResult(_ intent: RealtimeToolIntent) -> RealtimeToolResult {
    RealtimeToolResult(
        sourceEventID: intent.eventID, turnID: intent.turnID,
        result: ToolResult(request: ToolRequest(id: intent.eventID, tool: "app.open"), data: .bool(true)),
        reportedTool: intent.tool
    )
}

@Test func realtimeIgnoredWireFrameFloodClosesAtPerTurnLimit() async throws {
    let harness = try await wireBudgetSession(Array(
        repeating: wireBudgetIgnored, count: OpenAIRealtimeLimits.maxWireEventsPerTurn
    ))
    _ = try await wireBudgetBegin(harness.session)
    await #expect(throws: OpenAIRealtimeError.responseTooLarge) {
        _ = try await harness.session.nextEvent()
    }
    #expect(await harness.transport.closeCount == 1)
    #expect(await harness.transport.receiveCount == OpenAIRealtimeLimits.maxWireEventsPerTurn + 1)
}

@Test func realtimeIncomingWireByteBudgetCountsUTF8AndIgnoredFrames() async throws {
    let frame = "{\"type\":\"ignored\",\"padding\":\"" + String(repeating: "é", count: 450_000) + "\"}"
    #expect(frame.utf8.count < OpenAIRealtimeLimits.maxInboundBytes)
    #expect(frame.utf8.count * 4 <= OpenAIRealtimeLimits.maxWireBytesPerTurn)
    #expect(frame.utf8.count * 5 > OpenAIRealtimeLimits.maxWireBytesPerTurn)
    let harness = try await wireBudgetSession(Array(repeating: frame, count: 5))
    _ = try await wireBudgetBegin(harness.session)
    await #expect(throws: OpenAIRealtimeError.responseTooLarge) {
        _ = try await harness.session.nextEvent()
    }
    #expect(await harness.transport.closeCount == 1)
    #expect(await harness.transport.receiveCount == 6) // Handshake plus five frames.
}

@Test func realtimeExactWireByteExhaustionClosesWithoutAnotherReceive() async throws {
    let prefix = "{\"type\":\"ignored\",\"padding\":\""
    let suffix = "\"}"
    let frame = prefix + String(
        repeating: "x", count: OpenAIRealtimeLimits.maxInboundBytes - prefix.utf8.count - suffix.utf8.count
    ) + suffix
    #expect(frame.utf8.count * 4 == OpenAIRealtimeLimits.maxWireBytesPerTurn)
    let harness = try await wireBudgetSession(Array(repeating: frame, count: 4))
    _ = try await wireBudgetBegin(harness.session)
    await #expect(throws: OpenAIRealtimeError.responseTooLarge) {
        _ = try await harness.session.nextEvent()
    }
    #expect(await harness.transport.closeCount == 1)
    #expect(await harness.transport.receiveCount == 5) // No fifth post-handshake receive.
}

@Test func realtimeToolContinuationAndRepeatedUserTextCannotResetWireBudget() async throws {
    let harness = try await wireBudgetSession(
        Array(repeating: wireBudgetIgnored, count: OpenAIRealtimeLimits.maxWireEventsPerTurn - 2)
        + [wireBudgetCall, wireBudgetToolDone, wireBudgetText]
    )
    let turnID = try await wireBudgetBegin(harness.session)
    guard case .toolIntent(let intent)? = try await harness.session.nextEvent() else {
        Issue.record("Expected tool call before budget exhaustion")
        return
    }
    await #expect(throws: OpenAIRealtimeError.invalidState) {
        try await harness.session.send(.userText(RealtimeUserText(turnID: turnID, text: "Reset attempt")))
    }
    try await harness.session.send(.toolResult(wireBudgetResult(intent)))
    await #expect(throws: OpenAIRealtimeError.responseTooLarge) {
        _ = try await harness.session.nextEvent()
    }
    #expect(await harness.transport.closeCount == 1)
}

@Test(arguments: [false, true])
func realtimeNextTurnHasFreshWireBudgetAndTextEventIdentity(cancelled: Bool) async throws {
    let ending = cancelled ? #"{"type":"response.cancelled"}"# : wireBudgetDone
    let frames = Array(repeating: wireBudgetIgnored, count: OpenAIRealtimeLimits.maxWireEventsPerTurn - 2)
        + [wireBudgetText, ending]
    let harness = try await wireBudgetSession(frames + frames)
    var eventIDs: [UUID] = []
    for _ in 0..<2 {
        let turnID = try await wireBudgetBegin(harness.session)
        guard case .assistantText(let text)? = try await harness.session.nextEvent() else {
            Issue.record("Expected text within the fresh budget")
            return
        }
        #expect(text.turnID == turnID)
        eventIDs.append(text.eventID)
        let terminal = try await harness.session.nextEvent()
        if cancelled {
            guard case .failure(let failure)? = terminal else {
                Issue.record("Expected cancellation at the exact event limit")
                return
            }
            #expect(failure.code == "cancelled")
        } else {
            guard case .turnCompleted? = terminal else {
                Issue.record("Expected completion at the exact event limit")
                return
            }
        }
    }
    #expect(eventIDs.count == 2)
    #expect(eventIDs.first != eventIDs.last)
    #expect(await harness.transport.closeCount == 0)
    await harness.session.close()
}

@Test func realtimeCompletedTurnClearsFunctionCallIdentity() async throws {
    let frames = [wireBudgetCall, wireBudgetToolDone, wireBudgetDone]
    let harness = try await wireBudgetSession(frames + frames)
    var eventIDs: [UUID] = []
    for _ in 0..<2 {
        _ = try await wireBudgetBegin(harness.session)
        guard case .toolIntent(let intent)? = try await harness.session.nextEvent() else {
            Issue.record("Expected tool call")
            return
        }
        eventIDs.append(intent.eventID)
        try await harness.session.send(.toolResult(wireBudgetResult(intent)))
        guard case .turnCompleted? = try await harness.session.nextEvent() else {
            Issue.record("Expected completion after tool response")
            return
        }
    }
    #expect(eventIDs.count == 2)
    #expect(eventIDs.first != eventIDs.last)
    #expect(await harness.transport.closeCount == 0)
    await harness.session.close()
}
