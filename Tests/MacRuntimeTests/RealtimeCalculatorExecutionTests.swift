@testable import AgentCore
import Foundation
import Testing
@testable import MacRuntime

// This stitches the real wire adapter to the real orchestration/native tool
// types. Only the network, human confirmation, and OS launch are replaced.
private actor CalculatorTransport: OpenAIRealtimeTransport {
    private var incoming: [String]
    private(set) var sent: [String] = []

    init(incoming: [String]) { self.incoming = incoming }
    func connect(_ request: URLRequest) {}
    func send(text: String) { sent.append(text) }
    func receive() -> String? {
        incoming.isEmpty ? nil : incoming.removeFirst()
    }
    func close() {}
}

private actor CalculatorAudit: AuditSink {
    func append(_ event: AuditEvent) throws {}
}

private struct CalculatorPermissions: PermissionChecking {
    func isGranted(_ permission: Permission) async -> Bool { true }
}

private struct CalculatorDecision: DecisionProvider {
    let providerID = "calculator-test"
    func decide(_ request: DecisionRequest) async throws -> ProviderDecision {
        ProviderDecision(selectedOptionID: request.options[0].id, confidence: 1)
    }
}

private actor CalculatorObservations {
    private(set) var approvals = 0
    private(set) var launches: [String] = []
    func confirm() { approvals += 1 }
    func launch(_ bundleID: String) { launches.append(bundleID) }
}

private final class CalculatorClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance() {
        lock.lock()
        defer { lock.unlock() }
        value = value.addingTimeInterval(31)
    }
}

private struct CalculatorExpiringApproval: RealtimeApprovalProviding {
    let broker: LocalApprovalBroker
    let clock: CalculatorClock

    func requestApproval(_ request: RealtimeApprovalRequest) async throws -> UUID? {
        let grant = try await broker.requestApproval(request)
        clock.advance()
        return grant
    }
}

private enum CalculatorApprovalMode: Sendable, Equatable { case allow, deny, expire }

private func calculatorWire(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func calculatorCall(bundleID: String = "com.apple.calculator") throws -> String {
    try calculatorWire([
        "type": "response.function_call_arguments.done",
        "event_id": "evt_calculator",
        "response_id": "resp_tool",
        "call_id": "call_calculator",
        "name": "cap_computer_open_app",
        "arguments": calculatorWire(["application_id": bundleID])
    ])
}

private struct CalculatorHarness: Sendable {
    let coordinator: RealtimeCoordinator
    let invocation: AgentInvocationContext
    let session: any RealtimeModelSession
    let transport: CalculatorTransport
    let observations: CalculatorObservations

    func run() async throws -> RealtimeTurnResult {
        try await coordinator.runTurn(
            RealtimeTurnRequest(text: "Open Calculator"),
            in: invocation,
            using: session
        )
    }

    func outputs() async throws -> [RealtimeToolResult] {
        var results: [RealtimeToolResult] = []
        for text in await transport.sent {
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            )
            guard let item = object["item"] as? [String: Any],
                  item["type"] as? String == "function_call_output" else { continue }
            #expect(item["call_id"] as? String == "call_calculator")
            let output = try #require(item["output"] as? String)
            let result = try JSONDecoder().decode(RealtimeToolResult.self, from: Data(output.utf8))
            #expect(result.tool == "computer.open_app")
            results.append(result)
        }
        return results
    }
}

private func calculatorHarness(
    mode: CalculatorApprovalMode = .allow,
    replayBundleID: String? = nil
) async throws -> CalculatorHarness {
    let clock = CalculatorClock()
    let approvals = ApprovalStore(now: { clock.now() })
    let observations = CalculatorObservations()
    let runtime = ToolRuntime(
        audit: CalculatorAudit(), permissions: CalculatorPermissions(), approvals: approvals
    )
    try await runtime.register(AppOpenTool(open: { bundleID in
        #expect(await observations.approvals == 1)
        await observations.launch(bundleID)
        return true
    }))
    let device = DeviceIdentity(displayName: "Calculator Test Mac", platform: "macOS")
    let router = DeviceRouter()
    try await router.register(RuntimeDeviceExecutor(identity: device, runtime: runtime))
    let invocation = AgentInvocationContext(
        principal: TenantContext(tenantID: UUID(), userID: UUID()),
        session: AgentSession(activeDeviceID: device.id), interfaceID: UUID()
    )
    let broker = LocalApprovalBroker(approvals: approvals) { request in
        // The launcher must not run until the exact native action is confirmed.
        #expect(await observations.launches.isEmpty)
        #expect(request.descriptor.name == "app.open")
        #expect(request.descriptor.risk == .reversibleWrite)
        #expect(request.arguments == .object([
            "bundle_identifier": .string("com.apple.calculator")
        ]))
        #expect(request.context.deviceID == device.id)
        #expect(request.context.sessionID == invocation.session.id)
        await observations.confirm()
        return mode != .deny
    }
    let approvalProvider: any RealtimeApprovalProviding
    if mode == .expire {
        approvalProvider = CalculatorExpiringApproval(broker: broker, clock: clock)
    } else {
        approvalProvider = broker
    }
    let coordinator = RealtimeCoordinator(
        orchestrator: AgentOrchestrator(
            devices: router,
            decisions: DecisionEngine(boundedProvider: CalculatorDecision()),
            contextCompiler: ContextCompiler(store: InMemoryContextService())
        ),
        approvalProvider: approvalProvider
    )
    var incoming = [try calculatorWire(["type": "session.created"]), try calculatorCall()]
    if let replayBundleID { incoming.append(try calculatorCall(bundleID: replayBundleID)) }
    incoming += [
        try calculatorWire([
            "type": "response.done",
            "response": ["id": "resp_tool", "status": "completed", "output": [["type": "function_call"]]]
        ]),
        try calculatorWire([
            "type": "response.output_text.delta", "event_id": "evt_final_text",
            "response_id": "resp_final", "delta": "Action result received."
        ]),
        try calculatorWire([
            "type": "response.done",
            "response": ["id": "resp_final", "status": "completed", "output": []]
        ])
    ]
    let transport = CalculatorTransport(incoming: incoming)
    let provider = try OpenAIRealtimeProvider(
        endpoint: URL(string: "wss://api.openai.com/v1/realtime")!,
        model: "gpt-realtime-2.1",
        credentialProvider: { "offline-test-credential" },
        transportFactory: { transport }
    )
    let session = try await provider.openSession(agentSessionID: invocation.session.id)
    return CalculatorHarness(
        coordinator: coordinator, invocation: invocation, session: session,
        transport: transport, observations: observations
    )
}

@Test func calculatorWireCallExecutesOnlyAfterExactApprovalAndReturnsOutput() async throws {
    let harness = try await calculatorHarness()
    let result = try await harness.run()
    #expect(await harness.observations.launches == ["com.apple.calculator"])
    #expect(await harness.observations.approvals == 1)
    #expect(result.assistantText == ["Action result received."])
    let outputs = try await harness.outputs()
    #expect(outputs.count == 1)
    #expect(outputs == result.toolResults)
    #expect(outputs.first?.status == "success")
    let data = try #require(outputs.first?.data)
    let opened = try JSONDecoder().decode(AppOpenOutput.self, from: JSONEncoder().encode(data))
    #expect(opened == AppOpenOutput(bundleIdentifier: "com.apple.calculator", opened: true))
}

@Test func calculatorWireDeniedApprovalReturnsErrorWithoutLaunching() async throws {
    let harness = try await calculatorHarness(mode: .deny)
    let result = try await harness.run()
    #expect(await harness.observations.launches.isEmpty)
    #expect(await harness.observations.approvals == 1)
    let outputs = try await harness.outputs()
    #expect(outputs.count == 1)
    #expect(outputs == result.toolResults)
    #expect(outputs.first?.error?.code == .approvalRequired)
}

@Test func calculatorWireExpiredApprovalReturnsErrorWithoutLaunching() async throws {
    let harness = try await calculatorHarness(mode: .expire)
    let result = try await harness.run()
    #expect(await harness.observations.launches.isEmpty)
    #expect(await harness.observations.approvals == 1)
    let outputs = try await harness.outputs()
    #expect(outputs.count == 1)
    #expect(outputs == result.toolResults)
    #expect(outputs.first?.error?.code == .approvalRequired)
}

@Test func calculatorWireReplayReturnsCachedOutputWithoutSecondApprovalOrLaunch() async throws {
    let harness = try await calculatorHarness(replayBundleID: "com.apple.calculator")
    let result = try await harness.run()
    #expect(await harness.observations.launches == ["com.apple.calculator"])
    #expect(await harness.observations.approvals == 1)
    #expect(result.toolResults.count == 1)
    let outputs = try await harness.outputs()
    #expect(outputs.count == 2)
    #expect(outputs.first == outputs.last)
    #expect(outputs.first?.status == "success")
}

@Test func calculatorWireMutatedReplayFailsClosedBeforeSecondApprovalOrLaunch() async throws {
    let harness = try await calculatorHarness(replayBundleID: "com.apple.TextEdit")
    await #expect(throws: RealtimeProtocolError.duplicateEventMismatch) {
        _ = try await harness.run()
    }
    #expect(await harness.observations.launches == ["com.apple.calculator"])
    #expect(await harness.observations.approvals == 1)
    let outputs = try await harness.outputs()
    #expect(outputs.count == 1)
    #expect(outputs.first?.status == "success")
}
