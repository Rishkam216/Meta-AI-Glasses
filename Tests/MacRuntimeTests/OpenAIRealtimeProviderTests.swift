import AgentCore
import Foundation
import Testing
@testable import MacRuntime

private actor FakeOpenAIRealtimeTransport: OpenAIRealtimeTransport {
    private(set) var connectedRequest: URLRequest?
    private(set) var sent: [String] = []
    private var incoming: [String]
    private(set) var closeCount = 0

    init(incoming: [String]) {
        self.incoming = incoming
    }

    func connect(_ request: URLRequest) {
        connectedRequest = request
    }

    func send(text: String) {
        sent.append(text)
    }

    func receive() -> String? {
        guard !incoming.isEmpty else { return nil }
        return incoming.removeFirst()
    }

    func close() {
        closeCount += 1
    }
}

private func wire(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func decoded(_ text: String) throws -> [String: Any] {
    let data = Data(text.utf8)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func emptyCompiledContext() -> CompiledContext {
    CompiledContext(
        consumer: .realtime,
        items: [],
        consideredItemCount: 0,
        omittedByPolicyCount: 0,
        omittedByBudgetCount: 0,
        encodedBytes: 0,
        refreshSummary: .none,
        memoryRetrievalSummary: .none
    )
}

private func openProvider(transport: FakeOpenAIRealtimeTransport,
                          credential: String = "test-secret-not-live") throws -> OpenAIRealtimeProvider {
    try OpenAIRealtimeProvider(
        endpoint: URL(string: "wss://api.openai.com/v1/realtime")!,
        model: "gpt-realtime-2.1",
        credentialProvider: { credential },
        transportFactory: { transport }
    )
}

@Test func openAIRealtimeConnectsWithBearerAndWaitsForSessionCreated() async throws {
    let transport = FakeOpenAIRealtimeTransport(incoming: [
        try wire(["type": "session.created", "event_id": "evt_ready"])
    ])
    let provider = try openProvider(transport: transport)
    let agentSessionID = UUID()

    let session = try await provider.openSession(agentSessionID: agentSessionID)

    #expect(session.id == agentSessionID)
    let request = try #require(await transport.connectedRequest)
    #expect(request.url?.scheme == "wss")
    #expect(request.url?.host == "api.openai.com")
    #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "model" })?.value == "gpt-realtime-2.1")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret-not-live")
    #expect((await transport.sent).isEmpty)
}

@Test func openAIRealtimeSendsTextTurnWithProviderSafeSemanticTools() async throws {
    let transport = FakeOpenAIRealtimeTransport(incoming: [
        try wire(["type": "session.created"]),
        try wire([
            "type": "response.output_text.delta",
            "event_id": "evt_text_1",
            "response_id": "resp_text",
            "delta": "Done"
        ]),
        try wire([
            "type": "response.done",
            "event_id": "evt_done",
            "response": ["id": "resp_text", "status": "completed", "output": []]
        ])
    ])
    let provider = try openProvider(transport: transport)
    let session = try await provider.openSession(agentSessionID: UUID())
    let turnID = UUID()
    let capability = AgentCapabilityDescriptor(
        name: "computer.inspect",
        summary: "Inspect the selected computer.",
        effect: .read,
        inputSchema: EmptyInput.schema
    )

    try await session.send(.turnContext(RealtimeTurnContext(
        turnID: turnID,
        context: emptyCompiledContext(),
        capabilities: [capability]
    )))
    try await session.send(.userText(try RealtimeUserText(
        turnID: turnID,
        text: "What app is active?"
    )))

    let sent = await transport.sent
    #expect(sent.count == 2)
    let item = try decoded(sent[0])
    #expect(item["type"] as? String == "conversation.item.create")

    let create = try decoded(sent[1])
    #expect(create["type"] as? String == "response.create")
    let response = try #require(create["response"] as? [String: Any])
    let tools = try #require(response["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools[0]["name"] as? String == "cap_computer_inspect")
    #expect(sent[1].contains("computer.inspect") == false)
    #expect(sent.joined().contains("test-secret-not-live") == false)
    #expect(sent.joined().contains("ui.get_frontmost_app") == false)

    let first = try await session.nextEvent()
    guard case .assistantText(let text)? = first else {
        Issue.record("Expected assistant text")
        return
    }
    #expect(text.turnID == turnID)
    #expect(text.text == "Done")

    let second = try await session.nextEvent()
    guard case .turnCompleted(let completed)? = second else {
        Issue.record("Expected turn completion")
        return
    }
    #expect(completed.turnID == turnID)
}

@Test func openAIRealtimeFunctionCallRoundTripDoesNotPrematurelyComplete() async throws {
    let transport = FakeOpenAIRealtimeTransport(incoming: [
        try wire(["type": "session.created"]),
        try wire([
            "type": "response.function_call_arguments.done",
            "event_id": "evt_call",
            "response_id": "resp_tool",
            "call_id": "call_123",
            "name": "cap_computer_open_app",
            "arguments": "{\"application_id\":\"com.apple.TextEdit\"}"
        ]),
        try wire([
            "type": "response.done",
            "event_id": "evt_tool_done",
            "response": [
                "id": "resp_tool",
                "status": "completed",
                "output": [["type": "function_call"]]
            ]
        ]),
        try wire([
            "type": "response.output_text.delta",
            "event_id": "evt_after_tool",
            "response_id": "resp_after_tool",
            "delta": "TextEdit is open."
        ]),
        try wire([
            "type": "response.done",
            "event_id": "evt_final",
            "response": ["id": "resp_after_tool", "status": "completed", "output": []]
        ])
    ])
    let provider = try openProvider(transport: transport)
    let session = try await provider.openSession(agentSessionID: UUID())
    let turnID = UUID()
    let capability = AgentCapabilityDescriptor(
        name: "computer.open_app",
        summary: "Open an application.",
        effect: .action,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "application_id": .object(["type": .string("string")])
            ]),
            "required": .array([.string("application_id")]),
            "additionalProperties": .bool(false)
        ])
    )

    try await session.send(.turnContext(RealtimeTurnContext(
        turnID: turnID,
        context: emptyCompiledContext(),
        capabilities: [capability]
    )))
    try await session.send(.userText(try RealtimeUserText(turnID: turnID, text: "Open TextEdit")))

    let event = try await session.nextEvent()
    guard case .toolIntent(let intent)? = event else {
        Issue.record("Expected semantic tool intent")
        return
    }
    #expect(intent.tool == "computer.open_app")
    #expect(intent.arguments == .object([
        "application_id": .string("com.apple.TextEdit")
    ]))

    let nativeRequest = ToolRequest(
        id: intent.eventID,
        tool: "app.open",
        arguments: .object(["bundle_identifier": .string("com.apple.TextEdit")])
    )
    let nativeResult = ToolResult(request: nativeRequest, data: .bool(true))
    try await session.send(.toolResult(RealtimeToolResult(
        sourceEventID: intent.eventID,
        turnID: turnID,
        result: nativeResult,
        reportedTool: intent.tool
    )))

    let sent = await transport.sent
    #expect(sent.count == 4)
    let output = try decoded(sent[2])
    let outputItem = try #require(output["item"] as? [String: Any])
    #expect(outputItem["type"] as? String == "function_call_output")
    #expect(outputItem["call_id"] as? String == "call_123")

    let afterTool = try await session.nextEvent()
    guard case .assistantText(let text)? = afterTool else {
        Issue.record("Tool response.done must be ignored; expected next assistant text")
        return
    }
    #expect(text.text == "TextEdit is open.")

    let completed = try await session.nextEvent()
    guard case .turnCompleted? = completed else {
        Issue.record("Expected completion after post-tool response")
        return
    }
}

@Test func openAIRealtimeCancellationUsesCurrentGAEvent() async throws {
    let transport = FakeOpenAIRealtimeTransport(incoming: [
        try wire(["type": "session.created"])
    ])
    let provider = try openProvider(transport: transport)
    let session = try await provider.openSession(agentSessionID: UUID())
    let turnID = UUID()

    try await session.send(.turnContext(RealtimeTurnContext(
        turnID: turnID,
        context: emptyCompiledContext(),
        capabilities: []
    )))
    try await session.send(.userText(try RealtimeUserText(turnID: turnID, text: "Stop test")))
    await session.cancel(turnID: turnID)

    let sent = await transport.sent
    #expect(sent.count == 3)
    let cancel = try decoded(sent[2])
    #expect(cancel["type"] as? String == "response.cancel")
}

@Test func openAIRealtimeSanitizesProviderErrorsAndRejectsInvalidCredentials() async throws {
    let invalidProvider = try openProvider(
        transport: FakeOpenAIRealtimeTransport(incoming: []),
        credential: " bad secret "
    )
    await #expect(throws: OpenAIRealtimeError.invalidCredential) {
        _ = try await invalidProvider.openSession(agentSessionID: UUID())
    }

    let transport = FakeOpenAIRealtimeTransport(incoming: [
        try wire(["type": "session.created"]),
        try wire([
            "type": "error",
            "event_id": "evt_error",
            "error": ["code": "bad code / secret-looking detail"]
        ])
    ])
    let provider = try openProvider(transport: transport)
    let session = try await provider.openSession(agentSessionID: UUID())
    let turnID = UUID()
    try await session.send(.turnContext(RealtimeTurnContext(
        turnID: turnID,
        context: emptyCompiledContext(),
        capabilities: []
    )))
    try await session.send(.userText(try RealtimeUserText(turnID: turnID, text: "Hello")))

    let event = try await session.nextEvent()
    guard case .failure(let failure)? = event else {
        Issue.record("Expected sanitized provider failure")
        return
    }
    #expect(failure.code == "bad_code___secret-looking_detail")
    #expect(failure.code.contains(" ") == false)
    #expect(failure.code.count <= 96)
}
