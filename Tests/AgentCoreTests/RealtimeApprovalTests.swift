import Foundation
import Testing
@testable import AgentCore

private actor RealtimeApprovalAudit: AuditSink {
    func append(_ event: AuditEvent) throws {}
}

private struct RealtimeApprovalPermissions: PermissionChecking {
    func isGranted(_ permission: Permission) async -> Bool { true }
}

private actor RealtimeApprovalCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct RealtimeProbeOpenInput: Codable, Sendable {
    let bundleIdentifier: String

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier = "bundle_identifier"
    }
}

private struct RealtimeWriteProbe: Tool {
    let counter: RealtimeApprovalCounter

    let descriptor = ToolDescriptor(
        name: "app.open",
        summary: "Probe native app-open action.",
        risk: .reversibleWrite,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "bundle_identifier": .object(["type": .string("string")])
            ]),
            "required": .array([.string("bundle_identifier")]),
            "additionalProperties": .bool(false)
        ])
    )

    func execute(_ input: RealtimeProbeOpenInput) async throws -> String {
        await counter.increment()
        return input.bundleIdentifier
    }
}

private actor RealtimeApprovalDecisionProvider: DecisionProvider {
    nonisolated let providerID = "realtime-approval-test"

    func decide(_ request: DecisionRequest) -> ProviderDecision {
        ProviderDecision(selectedOptionID: request.options[0].id, confidence: 1)
    }
}

private actor RealtimeApprovalSession: RealtimeModelSession {
    nonisolated let id = UUID()
    private var incoming: [RealtimeProviderEvent]
    private(set) var sent: [RealtimeClientEvent] = []

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

    func cancel(turnID: UUID) {}
    func close() {}
}

private func realtimeApprovalHarness(
    approvals: ApprovalStore,
    approvalProvider: (any RealtimeApprovalProviding)? = nil
) async throws -> (
    coordinator: RealtimeCoordinator,
    invocation: AgentInvocationContext,
    counter: RealtimeApprovalCounter
) {
    let counter = RealtimeApprovalCounter()
    let runtime = ToolRuntime(
        audit: RealtimeApprovalAudit(),
        permissions: RealtimeApprovalPermissions(),
        approvals: approvals
    )
    try await runtime.register(RealtimeWriteProbe(counter: counter))

    let identity = DeviceIdentity(displayName: "Approved Mac", platform: "macOS")
    let router = DeviceRouter()
    try await router.register(RuntimeDeviceExecutor(identity: identity, runtime: runtime))

    let orchestrator = AgentOrchestrator(
        devices: router,
        decisions: DecisionEngine(boundedProvider: RealtimeApprovalDecisionProvider()),
        contextCompiler: ContextCompiler(store: InMemoryContextService())
    )
    let invocation = AgentInvocationContext(
        principal: TenantContext(tenantID: UUID(), userID: UUID()),
        session: AgentSession(activeDeviceID: identity.id),
        interfaceID: UUID()
    )
    return (
        RealtimeCoordinator(
            orchestrator: orchestrator,
            approvalProvider: approvalProvider
        ),
        invocation,
        counter
    )
}

private func openIntent(turnID: UUID, eventID: UUID = UUID()) throws -> RealtimeToolIntent {
    try RealtimeToolIntent(
        eventID: eventID,
        turnID: turnID,
        tool: "computer.open_app",
        arguments: .object([
            "application_id": .string("com.apple.TextEdit")
        ])
    )
}

@Test func realtimeWriteWithoutTrustedApprovalNeverReachesExecutor() async throws {
    let approvals = ApprovalStore()
    let harness = try await realtimeApprovalHarness(approvals: approvals)
    let turn = try RealtimeTurnRequest(text: "Open TextEdit")
    let session = RealtimeApprovalSession(events: [
        .toolIntent(try openIntent(turnID: turn.id)),
        .turnCompleted(RealtimeTurnCompleted(turnID: turn.id))
    ])

    let result = try await harness.coordinator.runTurn(
        turn,
        in: harness.invocation,
        using: session
    )

    #expect(result.toolResults.count == 1)
    #expect(result.toolResults[0].tool == "computer.open_app")
    #expect(result.toolResults[0].error?.code == .approvalRequired)
    #expect(await harness.counter.value == 0)
}

@Test func trustedLocalApprovalExecutesExactRealtimeActionOnce() async throws {
    let approvals = ApprovalStore()
    let broker = LocalApprovalBroker(approvals: approvals) { request in
        #expect(request.descriptor.name == "app.open")
        #expect(request.descriptor.risk == .reversibleWrite)
        #expect(request.arguments == .object([
            "bundle_identifier": .string("com.apple.TextEdit")
        ]))
        return true
    }
    let harness = try await realtimeApprovalHarness(
        approvals: approvals,
        approvalProvider: broker
    )

    let turn = try RealtimeTurnRequest(text: "Open TextEdit")
    let eventID = UUID()
    let intent = try openIntent(turnID: turn.id, eventID: eventID)
    let session = RealtimeApprovalSession(events: [
        .toolIntent(intent),
        .toolIntent(intent),
        .turnCompleted(RealtimeTurnCompleted(turnID: turn.id))
    ])

    let result = try await harness.coordinator.runTurn(
        turn,
        in: harness.invocation,
        using: session
    )

    #expect(result.toolResults.count == 1)
    #expect(result.toolResults[0].tool == "computer.open_app")
    #expect(result.toolResults[0].status == "success")
    #expect(result.toolResults[0].requestID == eventID)
    #expect(await harness.counter.value == 1)
}

@Test func declinedRealtimeApprovalDoesNotReachExecutor() async throws {
    let approvals = ApprovalStore()
    let broker = LocalApprovalBroker(approvals: approvals) { _ in false }
    let harness = try await realtimeApprovalHarness(
        approvals: approvals,
        approvalProvider: broker
    )
    let turn = try RealtimeTurnRequest(text: "Open TextEdit")
    let session = RealtimeApprovalSession(events: [
        .toolIntent(try openIntent(turnID: turn.id)),
        .turnCompleted(RealtimeTurnCompleted(turnID: turn.id))
    ])

    let result = try await harness.coordinator.runTurn(
        turn,
        in: harness.invocation,
        using: session
    )

    #expect(result.toolResults[0].error?.code == .approvalRequired)
    #expect(await harness.counter.value == 0)
}
