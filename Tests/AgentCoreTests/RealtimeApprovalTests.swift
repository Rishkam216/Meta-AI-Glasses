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

private struct RealtimeWriteProbe: Tool {
    let counter: RealtimeApprovalCounter

    let descriptor = ToolDescriptor(
        name: "test.write_action",
        summary: "Write action used to prove realtime approval binding.",
        risk: .reversibleWrite,
        inputSchema: EmptyInput.schema
    )

    func execute(_ input: EmptyInput) async throws -> String {
        await counter.increment()
        return "executed"
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

private func realtimeApprovalHarness(approvals: ApprovalStore) async throws -> (
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
    return (RealtimeCoordinator(orchestrator: orchestrator), invocation, counter)
}

@Test func realtimeWriteWithoutTrustedApprovalNeverReachesExecutor() async throws {
    let approvals = ApprovalStore()
    let harness = try await realtimeApprovalHarness(approvals: approvals)
    let turn = try RealtimeTurnRequest(text: "Do the write action")
    let intent = try RealtimeToolIntent(turnID: turn.id, tool: "test.write_action")
    let session = RealtimeApprovalSession(events: [
        .toolIntent(intent),
        .turnCompleted(RealtimeTurnCompleted(turnID: turn.id))
    ])

    let result = try await harness.coordinator.runTurn(
        turn,
        in: harness.invocation,
        using: session
    )

    #expect(result.toolResults.count == 1)
    #expect(result.toolResults[0].error?.code == .approvalRequired)
    #expect(await harness.counter.value == 0)
}

@Test func trustedLocalApprovalExecutesExactRealtimeActionOnce() async throws {
    let approvals = ApprovalStore()
    let base = try await realtimeApprovalHarness(approvals: approvals)
    let broker = LocalApprovalBroker(approvals: approvals) { request in
        #expect(request.descriptor.name == "test.write_action")
        #expect(request.descriptor.risk == .reversibleWrite)
        return true
    }

    // Reuse the exact same orchestrator/device harness by constructing an
    // equivalent coordinator is not possible from the returned base, so build
    // the approved harness directly here.
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
    let coordinator = RealtimeCoordinator(
        orchestrator: orchestrator,
        approvalProvider: broker
    )
    let invocation = AgentInvocationContext(
        principal: base.invocation.principal,
        session: AgentSession(activeDeviceID: identity.id),
        interfaceID: UUID()
    )

    let turn = try RealtimeTurnRequest(text: "Do the write action")
    let eventID = UUID()
    let intent = try RealtimeToolIntent(
        eventID: eventID,
        turnID: turn.id,
        tool: "test.write_action"
    )
    let session = RealtimeApprovalSession(events: [
        .toolIntent(intent),
        .toolIntent(intent),
        .turnCompleted(RealtimeTurnCompleted(turnID: turn.id))
    ])

    let result = try await coordinator.runTurn(turn, in: invocation, using: session)

    #expect(result.toolResults.count == 1)
    #expect(result.toolResults[0].status == "success")
    #expect(result.toolResults[0].requestID == eventID)
    #expect(await counter.value == 1)
}

@Test func declinedRealtimeApprovalDoesNotReachExecutor() async throws {
    let approvals = ApprovalStore()
    let counter = RealtimeApprovalCounter()
    let runtime = ToolRuntime(
        audit: RealtimeApprovalAudit(),
        permissions: RealtimeApprovalPermissions(),
        approvals: approvals
    )
    try await runtime.register(RealtimeWriteProbe(counter: counter))
    let identity = DeviceIdentity(displayName: "Mac", platform: "macOS")
    let router = DeviceRouter()
    try await router.register(RuntimeDeviceExecutor(identity: identity, runtime: runtime))
    let orchestrator = AgentOrchestrator(
        devices: router,
        decisions: DecisionEngine(boundedProvider: RealtimeApprovalDecisionProvider()),
        contextCompiler: ContextCompiler(store: InMemoryContextService())
    )
    let broker = LocalApprovalBroker(approvals: approvals) { _ in false }
    let coordinator = RealtimeCoordinator(
        orchestrator: orchestrator,
        approvalProvider: broker
    )
    let invocation = AgentInvocationContext(
        principal: TenantContext(tenantID: UUID(), userID: UUID()),
        session: AgentSession(activeDeviceID: identity.id)
    )
    let turn = try RealtimeTurnRequest(text: "Do it")
    let session = RealtimeApprovalSession(events: [
        .toolIntent(try RealtimeToolIntent(turnID: turn.id, tool: "test.write_action")),
        .turnCompleted(RealtimeTurnCompleted(turnID: turn.id))
    ])

    let result = try await coordinator.runTurn(turn, in: invocation, using: session)

    #expect(result.toolResults[0].error?.code == .approvalRequired)
    #expect(await counter.value == 0)
}
