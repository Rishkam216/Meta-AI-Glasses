import Foundation
import Testing
@testable import AgentCore

private actor RealtimeMemoryRetrieverProbe: MemoryContextRetrieving {
    private let itemID = UUID()
    private(set) var principals: [TenantContext] = []
    private(set) var queries: [MemoryContextQuery] = []

    func retrieve(_ query: MemoryContextQuery,
                  as principal: TenantContext,
                  now: Date) async throws -> [ContextItem] {
        principals.append(principal)
        queries.append(query)
        return [try ContextItem(
            id: itemID,
            tenant: principal,
            scope: .user,
            key: "memory",
            value: .object([
                "content": .string("The user's preferred editor is VS Code."),
                "retrieval_score": .number(0.95)
            ]),
            provenance: try ContextProvenance(
                origin: .memoryService,
                trust: .memory,
                sourceReference: "memory:\(itemID.uuidString.lowercased())"
            ),
            freshness: try ContextFreshness(
                classification: .longTerm,
                observedAt: now
            ),
            createdAt: now
        )]
    }
}

private actor RealtimeMemorySession: RealtimeModelSession {
    nonisolated let id = UUID()
    private let completion: RealtimeProviderEvent
    private var delivered = false
    private(set) var sent: [RealtimeClientEvent] = []

    init(turnID: UUID) {
        completion = .turnCompleted(RealtimeTurnCompleted(turnID: turnID))
    }

    func send(_ event: RealtimeClientEvent) {
        sent.append(event)
    }

    func nextEvent() -> RealtimeProviderEvent? {
        guard !delivered else { return nil }
        delivered = true
        return completion
    }

    func cancel(turnID: UUID) {}
    func close() {}
}

private actor RealtimeMemoryDecisionProvider: DecisionProvider {
    nonisolated let providerID = "realtime-memory-test"

    func decide(_ request: DecisionRequest) -> ProviderDecision {
        ProviderDecision(selectedOptionID: request.options[0].id, confidence: 1)
    }
}

private actor RealtimeMemoryDevice: DeviceExecuting {
    nonisolated let identity: DeviceIdentity

    init(identity: DeviceIdentity) {
        self.identity = identity
    }

    func capabilities() -> [ToolDescriptor] {
        [ToolDescriptor(
            name: "ui.get_frontmost_app",
            summary: "Read active app for capability discovery.",
            risk: .read,
            inputSchema: EmptyInput.schema
        )]
    }

    func execute(_ request: ToolRequest) -> ToolResult {
        ToolResult(request: request, data: .string("unused"))
    }
}

@Test func realtimeTurnCompilesOptInMemoryUnderTrustedPrincipal() async throws {
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let deviceIdentity = DeviceIdentity(displayName: "Memory Test Mac", platform: "macOS")
    let router = DeviceRouter()
    try await router.register(RealtimeMemoryDevice(identity: deviceIdentity))

    let memory = RealtimeMemoryRetrieverProbe()
    let compiler = ContextCompiler(
        store: InMemoryContextService(),
        memoryRetriever: memory
    )
    let orchestrator = AgentOrchestrator(
        devices: router,
        decisions: DecisionEngine(boundedProvider: RealtimeMemoryDecisionProvider()),
        contextCompiler: compiler
    )
    let coordinator = RealtimeCoordinator(orchestrator: orchestrator)
    let invocation = AgentInvocationContext(
        principal: principal,
        session: AgentSession(activeDeviceID: deviceIdentity.id),
        interfaceID: UUID()
    )
    let memoryQuery = try MemoryContextQuery(
        text: "Which editor does the user prefer?",
        scopes: [.user]
    )
    let turn = try RealtimeTurnRequest(
        text: "Which editor do I prefer?",
        memoryQuery: memoryQuery
    )
    let session = RealtimeMemorySession(turnID: turn.id)

    _ = try await coordinator.runTurn(turn, in: invocation, using: session)

    #expect(await memory.principals == [principal])
    #expect(await memory.queries == [memoryQuery])

    let sent = await session.sent
    guard case .turnContext(let providerContext)? = sent.first else {
        Issue.record("Expected compiled realtime context before user text")
        return
    }

    #expect(providerContext.context.consumer == .realtime)
    #expect(providerContext.context.memoryRetrievalSummary.requested)
    #expect(providerContext.context.memoryRetrievalSummary.retrieved == 1)
    #expect(providerContext.context.memoryRetrievalSummary.acceptedForRequestedScopes == 1)
    #expect(!providerContext.context.memoryRetrievalSummary.failed)
    #expect(providerContext.context.items.count == 1)
    #expect(providerContext.context.items[0].key == "memory")
    #expect(providerContext.context.items[0].scope == .user)
    #expect(providerContext.context.items[0].provenance.origin == .memoryService)
    #expect(providerContext.context.items[0].provenance.trust == .memory)
}
