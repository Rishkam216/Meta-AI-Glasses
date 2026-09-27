import Foundation
import Testing
@testable import AgentCore

private actor CancellationGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor CancellationCounter {
    private(set) var executions = 0
    func increment() { executions += 1 }
}

private struct CancellationWriteTool: Tool {
    let counter: CancellationCounter
    let descriptor = ToolDescriptor(name: "app.open", summary: "Test action", risk: .reversibleWrite,
                                    permissions: [.accessibility],
                                    inputSchema: .object([:]))
    func execute(_ input: JSONValue) async throws -> JSONValue {
        await counter.increment()
        return .bool(true)
    }
}

private struct CancellationAudit: AuditSink { func append(_ event: AuditEvent) {} }
private struct CancellationPermissions: PermissionChecking {
    func isGranted(_ permission: Permission) -> Bool { true }
}
private struct SuspendedCancellationPermissions: PermissionChecking {
    let checking: CancellationGate
    let resume: CancellationGate
    func isGranted(_ permission: Permission) async -> Bool {
        await checking.release()
        await resume.wait()
        return true
    }
}
private struct CancellationDecision: DecisionProvider {
    let providerID = "cancellation-test"
    func decide(_ request: DecisionRequest) throws -> ProviderDecision { throw DecisionError.noOptions }
}

private actor CancellationSession: RealtimeModelSession {
    nonisolated let id: UUID
    let reading = CancellationGate()
    let closed = CancellationGate()
    let cancelling = CancellationGate()
    let releaseCancel = CancellationGate()
    private var events: [RealtimeProviderEvent]
    private let blockCancel: Bool
    private var readWaiter: CheckedContinuation<RealtimeProviderEvent?, Never>?
    private var isClosed = false
    private(set) var closeCount = 0
    private(set) var cancelledTurns: [UUID] = []
    private(set) var sent: [RealtimeClientEvent] = []

    init(id: UUID = UUID(), events: [RealtimeProviderEvent], blockCancel: Bool = false) {
        self.id = id; self.events = events; self.blockCancel = blockCancel
    }
    func send(_ event: RealtimeClientEvent) { sent.append(event) }
    func nextEvent() async -> RealtimeProviderEvent? {
        if isClosed { return nil }
        if !events.isEmpty { return events.removeFirst() }
        await reading.release()
        // close() can run while the gate is being signalled.
        if isClosed { return nil }
        return await withCheckedContinuation { readWaiter = $0 }
    }
    func cancel(turnID: UUID) async {
        cancelledTurns.append(turnID)
        await cancelling.release()
        if blockCancel { await releaseCancel.wait() }
    }
    func close() async {
        closeCount += 1
        isClosed = true
        let waiter = readWaiter
        readWaiter = nil
        waiter?.resume(returning: nil)
        await closed.release()
    }
    func replaceEvents(_ values: [RealtimeProviderEvent]) { events = values }
}

private struct CancellationFixture: Sendable {
    let coordinator: RealtimeCoordinator
    let invocation: AgentInvocationContext
    let counter: CancellationCounter
    let confirming: CancellationGate
    let allow: CancellationGate

    static func make(permissions: any PermissionChecking = CancellationPermissions()) async throws -> Self {
        let counter = CancellationCounter()
        let approvals = ApprovalStore()
        let runtime = ToolRuntime(audit: CancellationAudit(), permissions: permissions, approvals: approvals)
        try await runtime.register(CancellationWriteTool(counter: counter))
        let device = DeviceIdentity(displayName: "Cancellation test", platform: "test")
        let devices = DeviceRouter()
        try await devices.register(RuntimeDeviceExecutor(identity: device, runtime: runtime))
        let confirming = CancellationGate()
        let allow = CancellationGate()
        let broker = LocalApprovalBroker(approvals: approvals) { _ in
            await confirming.release()
            await allow.wait() // Deliberately noncooperative confirmation UI.
            return true
        }
        let orchestrator = AgentOrchestrator(devices: devices,
            decisions: DecisionEngine(boundedProvider: CancellationDecision()),
            contextCompiler: ContextCompiler(store: InMemoryContextService()))
        return Self(coordinator: RealtimeCoordinator(orchestrator: orchestrator, approvalProvider: broker),
                    invocation: AgentInvocationContext(principal: TenantContext(tenantID: UUID(), userID: UUID()),
                                                       session: AgentSession(activeDeviceID: device.id)),
                    counter: counter, confirming: confirming, allow: allow)
    }

    func session(for turn: RealtimeTurnRequest, blockCancel: Bool = false) throws -> CancellationSession {
        CancellationSession(events: [
            .toolIntent(try RealtimeToolIntent(turnID: turn.id, tool: "computer.open_app",
                                             arguments: .object(["application_id": .string("com.apple.calculator")]))),
            .turnCompleted(RealtimeTurnCompleted(turnID: turn.id))
        ], blockCancel: blockCancel)
    }
}

private func expectCancelled(_ task: Task<RealtimeTurnResult, Error>) async {
    switch await task.result {
    case .success: Issue.record("Cancelled turn unexpectedly succeeded")
    case .failure(let error): #expect(error is CancellationError)
    }
}

@Test func cancelSuspendedApprovalThroughCoordinatorCopyNeverExecutes() async throws {
    let fixture = try await CancellationFixture.make()
    let turn = try RealtimeTurnRequest(text: "Open Calculator")
    let session = try fixture.session(for: turn)
    let task = Task { try await fixture.coordinator.runTurn(turn, in: fixture.invocation, using: session) }
    await fixture.confirming.wait()
    let copy = fixture.coordinator
    await copy.cancel(turnID: turn.id, using: session)
    await session.closed.wait()
    await fixture.allow.release()
    await expectCancelled(task)
    #expect(await fixture.counter.executions == 0)
    #expect(await session.closeCount == 1)
    #expect(await session.sent.count == 2) // Context/text only, no tool result.
}

@Test func parentTaskCancellationStopsApprovalAndClosesSession() async throws {
    let fixture = try await CancellationFixture.make()
    let turn = try RealtimeTurnRequest(text: "Open Calculator")
    let session = try fixture.session(for: turn)
    let task = Task { try await fixture.coordinator.runTurn(turn, in: fixture.invocation, using: session) }
    await fixture.confirming.wait()
    task.cancel()
    await session.closed.wait()
    await fixture.allow.release()
    await expectCancelled(task)
    #expect(await fixture.counter.executions == 0)
}

@Test func wrongTurnAndWrongSessionCancellationDoNotCloseActiveSession() async throws {
    let fixture = try await CancellationFixture.make()
    let turn = try RealtimeTurnRequest(text: "Open Calculator")
    let session = try fixture.session(for: turn)
    let otherSession = CancellationSession(events: [])
    let task = Task { try await fixture.coordinator.runTurn(turn, in: fixture.invocation, using: session) }
    await fixture.confirming.wait()
    let wrongTurn = UUID()
    await fixture.coordinator.cancel(turnID: wrongTurn, using: session)
    await fixture.coordinator.cancel(turnID: turn.id, using: otherSession)
    #expect(await session.closeCount == 0)
    #expect(await otherSession.closeCount == 0)
    #expect(await session.cancelledTurns == [wrongTurn])
    await fixture.allow.release()
    let result = try await task.value
    #expect(result.toolResults.first?.status == "success")
    #expect(await fixture.counter.executions == 1)
}

@Test func concurrentSameSessionRejectedAndFinishedTurnRegistrationRemoved() async throws {
    let fixture = try await CancellationFixture.make()
    let turn = try RealtimeTurnRequest(text: "Open Calculator")
    let session = try fixture.session(for: turn)
    let task = Task { try await fixture.coordinator.runTurn(turn, in: fixture.invocation, using: session) }
    await fixture.confirming.wait()
    let second = try RealtimeTurnRequest(text: "Another turn")
    do {
        _ = try await fixture.coordinator.runTurn(second, in: fixture.invocation, using: session)
        Issue.record("Overlapping session was accepted")
    } catch {
        #expect(error as? RealtimeTurnLifecycleError == .sessionAlreadyActive)
    }
    await fixture.allow.release()
    _ = try await task.value
    await session.replaceEvents([.turnCompleted(RealtimeTurnCompleted(turnID: second.id))])
    let result = try await fixture.coordinator.runTurn(second, in: fixture.invocation, using: session)
    #expect(result.turnID == second.id)
    #expect(await fixture.counter.executions == 1)
}

@Test func localCancellationDoesNotWaitForRemoteCancelAndClosesBlockedRead() async throws {
    let fixture = try await CancellationFixture.make()
    let turn = try RealtimeTurnRequest(text: "Wait")
    let session = CancellationSession(events: [], blockCancel: true)
    let task = Task { try await fixture.coordinator.runTurn(turn, in: fixture.invocation, using: session) }
    await session.reading.wait()
    let cancel = Task { await fixture.coordinator.cancel(turnID: turn.id, using: session) }
    await session.cancelling.wait()
    await session.closed.wait()
    await expectCancelled(task) // Remote cancel is still suspended here.
    #expect(await fixture.counter.executions == 0)
    await session.releaseCancel.release()
    await cancel.value
}

@Test func alreadyCancelledParentDoesNotStartProviderTurn() async throws {
    let fixture = try await CancellationFixture.make()
    let turn = try RealtimeTurnRequest(text: "Wait")
    let session = CancellationSession(events: [])
    let start = CancellationGate()
    let task = Task {
        await start.wait()
        return try await fixture.coordinator.runTurn(turn, in: fixture.invocation, using: session)
    }
    task.cancel()
    await start.release()
    await expectCancelled(task)
    #expect(await session.sent.isEmpty)
}

@Test func runtimeSwallowedCancellationDoesNotBecomeProviderToolResult() async throws {
    let checking = CancellationGate()
    let resume = CancellationGate()
    let fixture = try await CancellationFixture.make(
        permissions: SuspendedCancellationPermissions(checking: checking, resume: resume))
    let turn = try RealtimeTurnRequest(text: "Open Calculator")
    let session = try fixture.session(for: turn)
    let task = Task { try await fixture.coordinator.runTurn(turn, in: fixture.invocation, using: session) }
    await fixture.confirming.wait()
    await fixture.allow.release()
    await checking.wait() // Approval was consumed, but native action not dispatched.
    await fixture.coordinator.cancel(turnID: turn.id, using: session)
    await resume.release()
    await expectCancelled(task)
    #expect(await fixture.counter.executions == 0)
    #expect(await session.sent.count == 2)
    // Cleanup drops the registration even after cancellation. A closed session
    // fails as providerClosed, rather than retaining a stale active-turn entry.
    do {
        _ = try await fixture.coordinator.runTurn(turn, in: fixture.invocation, using: session)
        Issue.record("Closed session unexpectedly completed")
    } catch {
        #expect(error as? RealtimeProtocolError == .providerClosed)
    }
    let next = try RealtimeTurnRequest(text: "Replacement transport")
    let replacement = CancellationSession(id: session.id, events: [
        .turnCompleted(RealtimeTurnCompleted(turnID: next.id))
    ])
    let result = try await fixture.coordinator.runTurn(next, in: fixture.invocation, using: replacement)
    #expect(result.turnID == next.id)
    #expect(await replacement.closeCount == 0)
}
