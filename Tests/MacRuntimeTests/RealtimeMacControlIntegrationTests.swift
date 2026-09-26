@testable import AgentCore
import Foundation
import Testing
@testable import MacRuntime

private actor RealtimeMacAudit: AuditSink {
    func append(_ event: AuditEvent) throws {}
}

private struct RealtimeMacPermissions: PermissionChecking {
    func isGranted(_ permission: Permission) async -> Bool { true }
}

private actor RealtimeMacDecisionProvider: DecisionProvider {
    nonisolated let providerID = "native-realtime-test"

    func decide(_ request: DecisionRequest) -> ProviderDecision {
        ProviderDecision(selectedOptionID: request.options[0].id, confidence: 1)
    }
}

private actor RealtimeMacSession: RealtimeModelSession {
    nonisolated let id = UUID()
    private var incoming: [RealtimeProviderEvent]
    private(set) var sent: [RealtimeClientEvent] = []

    init(incoming: [RealtimeProviderEvent]) {
        self.incoming = incoming
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

private actor NativeOpenCounter {
    private(set) var bundleIdentifiers: [String] = []
    func record(_ value: String) { bundleIdentifiers.append(value) }
}

@Test func semanticRealtimeTurnUsesActualMacRuntimeReadAndApprovedActionTools() async throws {
    let approvals = ApprovalStore()
    let openCounter = NativeOpenCounter()
    let runtime = ToolRuntime(
        audit: RealtimeMacAudit(),
        permissions: RealtimeMacPermissions(),
        approvals: approvals
    )

    try await runtime.register(FrontmostAppTool(read: {
        FrontmostApp(
            processID: 321,
            bundleIdentifier: "com.apple.finder",
            name: "Finder"
        )
    }))
    try await runtime.register(AppOpenTool(open: { bundleIdentifier in
        await openCounter.record(bundleIdentifier)
        return true
    }))

    let identity = DeviceIdentity(displayName: "Native Test Mac", platform: "macOS")
    let router = DeviceRouter()
    try await router.register(RuntimeDeviceExecutor(identity: identity, runtime: runtime))

    let orchestrator = AgentOrchestrator(
        devices: router,
        decisions: DecisionEngine(boundedProvider: RealtimeMacDecisionProvider()),
        contextCompiler: ContextCompiler(store: InMemoryContextService())
    )

    let approvalBroker = LocalApprovalBroker(approvals: approvals) { request in
        #expect(request.descriptor.name == "app.open")
        #expect(request.arguments == .object([
            "bundle_identifier": .string("com.apple.TextEdit")
        ]))
        return true
    }
    let coordinator = RealtimeCoordinator(
        orchestrator: orchestrator,
        approvalProvider: approvalBroker
    )
    let invocation = AgentInvocationContext(
        principal: TenantContext(tenantID: UUID(), userID: UUID()),
        session: AgentSession(activeDeviceID: identity.id),
        interfaceID: UUID()
    )
    let turn = try RealtimeTurnRequest(text: "Tell me the active app, then open TextEdit")
    let readEventID = UUID()
    let actionEventID = UUID()
    let providerSession = RealtimeMacSession(incoming: [
        .toolIntent(try RealtimeToolIntent(
            eventID: readEventID,
            turnID: turn.id,
            tool: "computer.inspect",
            arguments: .object([:])
        )),
        .toolIntent(try RealtimeToolIntent(
            eventID: actionEventID,
            turnID: turn.id,
            tool: "computer.open_app",
            arguments: .object([
                "application_id": .string("com.apple.TextEdit")
            ])
        )),
        .assistantText(try RealtimeAssistantText(
            turnID: turn.id,
            text: "Finder was active and TextEdit was opened."
        )),
        .turnCompleted(RealtimeTurnCompleted(turnID: turn.id))
    ])

    let result = try await coordinator.runTurn(
        turn,
        in: invocation,
        using: providerSession
    )

    #expect(result.toolResults.count == 2)
    #expect(result.toolResults.contains {
        $0.sourceEventID == readEventID &&
        $0.tool == "computer.inspect" &&
        $0.status == "success"
    })
    #expect(result.toolResults.contains {
        $0.sourceEventID == actionEventID &&
        $0.tool == "computer.open_app" &&
        $0.status == "success"
    })
    #expect(await openCounter.bundleIdentifiers == ["com.apple.TextEdit"])
    #expect(result.assistantText == ["Finder was active and TextEdit was opened."])

    let sent = await providerSession.sent
    guard case .turnContext(let context)? = sent.first else {
        Issue.record("Expected provider turn context")
        return
    }
    #expect(Set(context.capabilities.map(\.name)) == ["computer.inspect", "computer.open_app"])
    #expect(context.capabilities.allSatisfy { !$0.name.contains("ui.") && !$0.name.contains("app.") })
}
