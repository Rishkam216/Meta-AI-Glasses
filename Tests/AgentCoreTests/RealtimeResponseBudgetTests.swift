import Foundation
import Testing
@testable import AgentCore

private actor BudgetSession: RealtimeModelSession {
    nonisolated let id = UUID()
    private var events: [RealtimeProviderEvent]
    private(set) var closeCount = 0
    private(set) var readCount = 0
    private(set) var sent: [RealtimeClientEvent] = []
    init(_ events: [RealtimeProviderEvent]) { self.events = events }
    func send(_ event: RealtimeClientEvent) { sent.append(event) }
    func nextEvent() -> RealtimeProviderEvent? {
        readCount += 1
        return events.isEmpty ? nil : events.removeFirst()
    }
    func cancel(turnID: UUID) {}
    func close() { closeCount += 1 }
    func replace(_ events: [RealtimeProviderEvent]) { self.events = events }
}

private actor BudgetDevice: DeviceExecuting {
    nonisolated let identity = DeviceIdentity(displayName: "Budget test", platform: "test")
    private(set) var executions = 0
    func capabilities() -> [ToolDescriptor] {
        [ToolDescriptor(name: "app.open", summary: "Test action", risk: .reversibleWrite,
                        inputSchema: .object([:]))]
    }
    func execute(_ request: ToolRequest) -> ToolResult {
        executions += 1
        return ToolResult(request: request, data: .bool(true))
    }
}

private actor BudgetApproval: RealtimeApprovalProviding {
    private(set) var requests = 0
    func requestApproval(_ request: RealtimeApprovalRequest) -> UUID? {
        requests += 1
        return UUID() // Test executor; no native runtime involved.
    }
}

private struct BudgetDecision: DecisionProvider {
    let providerID = "budget-test"
    func decide(_ request: DecisionRequest) throws -> ProviderDecision { throw DecisionError.noOptions }
}

private struct BudgetFixture {
    let coordinator: RealtimeCoordinator
    let invocation: AgentInvocationContext
    let device: BudgetDevice
    let approval: BudgetApproval
    static func make() async throws -> Self {
        let device = BudgetDevice()
        let router = DeviceRouter()
        try await router.register(device)
        let approval = BudgetApproval()
        let orchestrator = AgentOrchestrator(devices: router,
            decisions: DecisionEngine(boundedProvider: BudgetDecision()),
            contextCompiler: ContextCompiler(store: InMemoryContextService()))
        return Self(coordinator: RealtimeCoordinator(orchestrator: orchestrator, approvalProvider: approval),
            invocation: AgentInvocationContext(principal: TenantContext(tenantID: UUID(), userID: UUID()),
                                               session: AgentSession(activeDeviceID: device.identity.id)),
            device: device, approval: approval)
    }
}

private func textEvent(_ text: String, turn: RealtimeTurnRequest) throws -> RealtimeProviderEvent {
    .assistantText(try RealtimeAssistantText(turnID: turn.id, text: text))
}
private func completion(_ turn: RealtimeTurnRequest) -> RealtimeProviderEvent {
    .turnCompleted(RealtimeTurnCompleted(turnID: turn.id))
}
private func action(_ turn: RealtimeTurnRequest) throws -> RealtimeProviderEvent {
    .toolIntent(try RealtimeToolIntent(turnID: turn.id, tool: "computer.open_app",
        arguments: .object(["application_id": .string("com.apple.calculator")])))
}

@Test func aggregateTextAcceptsExactUTF8BoundaryAndDoesNotChargeDuplicates() async throws {
    let fixture = try await BudgetFixture.make()
    let turn = try RealtimeTurnRequest(text: "Text boundary")
    let half = String(repeating: "a", count: RealtimeLimits.maxAssistantTextBytesPerTurn / 2)
    let repeated = try textEvent(half, turn: turn)
    let session = BudgetSession([repeated, repeated, try textEvent(half, turn: turn), completion(turn)])
    let result = try await fixture.coordinator.runTurn(turn, in: fixture.invocation, using: session)
    #expect(result.assistantText.count == 2)
    #expect(result.assistantText.joined().utf8.count == RealtimeLimits.maxAssistantTextBytesPerTurn)
    #expect(await session.closeCount == 0)
}

@Test func aggregateTextCountsUTF8BytesAndBlocksPendingAction() async throws {
    let fixture = try await BudgetFixture.make()
    let turn = try RealtimeTurnRequest(text: "Multibyte boundary")
    let almostFull = String(repeating: "a", count: RealtimeLimits.maxAssistantTextBytesPerTurn - 3)
    let session = BudgetSession([try textEvent(almostFull, turn: turn), try textEvent("😀", turn: turn),
                                 try action(turn), completion(turn)])
    do {
        _ = try await fixture.coordinator.runTurn(turn, in: fixture.invocation, using: session)
        Issue.record("UTF8 byte overflow accepted")
    } catch {
        #expect(error as? RealtimeProtocolError == .assistantTextLimitExceeded)
    }
    #expect(await fixture.device.executions == 0)
    #expect(await fixture.approval.requests == 0)
    #expect(await session.closeCount == 1)
    #expect(await session.sent.count == 2)
}

@Test func semanticEventBudgetIncludesCompletionAndAcceptsExactBoundary() async throws {
    let fixture = try await BudgetFixture.make()
    let turn = try RealtimeTurnRequest(text: "Event boundary")
    let events = try (0..<(RealtimeLimits.maxProviderEventsPerTurn - 1)).map { _ in
        try textEvent("x", turn: turn)
    } + [completion(turn)]
    let session = BudgetSession(events)
    let result = try await fixture.coordinator.runTurn(turn, in: fixture.invocation, using: session)
    #expect(result.assistantText.count == RealtimeLimits.maxProviderEventsPerTurn - 1)
    #expect(await session.closeCount == 0)
}

@Test func semanticEventBudgetRejectsCompletionBeyondBoundary() async throws {
    let fixture = try await BudgetFixture.make()
    let turn = try RealtimeTurnRequest(text: "Completion overflow")
    let repeated = try textEvent("x", turn: turn)
    let session = BudgetSession(Array(repeating: repeated, count: RealtimeLimits.maxProviderEventsPerTurn) + [completion(turn)])
    do {
        _ = try await fixture.coordinator.runTurn(turn, in: fixture.invocation, using: session)
        Issue.record("Completion overflow accepted")
    } catch {
        #expect(error as? RealtimeProtocolError == .providerEventLimitExceeded)
    }
    #expect(await session.closeCount == 1)
}

@Test func duplicateFloodCannotTriggerActionBeyondEventBudget() async throws {
    let fixture = try await BudgetFixture.make()
    let turn = try RealtimeTurnRequest(text: "Duplicate flood")
    let repeated = try textEvent("x", turn: turn)
    let session = BudgetSession(Array(repeating: repeated, count: RealtimeLimits.maxProviderEventsPerTurn)
                                + [try action(turn), completion(turn)])
    do {
        _ = try await fixture.coordinator.runTurn(turn, in: fixture.invocation, using: session)
        Issue.record("Duplicate flood accepted")
    } catch {
        #expect(error as? RealtimeProtocolError == .providerEventLimitExceeded)
    }
    #expect(await fixture.device.executions == 0)
    #expect(await fixture.approval.requests == 0)
    #expect(await session.closeCount == 1)
    #expect(await session.sent.count == 2)
    #expect(await session.readCount == RealtimeLimits.maxProviderEventsPerTurn)
}

@Test func exhaustedSemanticBudgetClosesWithoutReadingAnotherEvent() async throws {
    let fixture = try await BudgetFixture.make()
    let turn = try RealtimeTurnRequest(text: "Exhausted events")
    let repeated = try textEvent("x", turn: turn)
    let session = BudgetSession(Array(repeating: repeated, count: RealtimeLimits.maxProviderEventsPerTurn))
    do {
        _ = try await fixture.coordinator.runTurn(turn, in: fixture.invocation, using: session)
        Issue.record("Exhausted semantic budget accepted")
    } catch {
        #expect(error as? RealtimeProtocolError == .providerEventLimitExceeded)
    }
    #expect(await session.readCount == RealtimeLimits.maxProviderEventsPerTurn)
    #expect(await session.closeCount == 1)
}

@Test func responseBudgetsResetBetweenNormalTurnsOnSameSession() async throws {
    let fixture = try await BudgetFixture.make()
    let first = try RealtimeTurnRequest(text: "First")
    let second = try RealtimeTurnRequest(text: "Second")
    let full = String(repeating: "a", count: RealtimeLimits.maxAssistantTextBytesPerTurn)
    let session = BudgetSession([try textEvent(full, turn: first), completion(first)])
    _ = try await fixture.coordinator.runTurn(first, in: fixture.invocation, using: session)
    await session.replace([try textEvent(full, turn: second), try action(second), completion(second)])
    let result = try await fixture.coordinator.runTurn(second, in: fixture.invocation, using: session)
    #expect(result.assistantText == [full])
    #expect(result.toolResults.first?.status == "success")
    #expect(await fixture.device.executions == 1)
    #expect(await session.closeCount == 0)
}
