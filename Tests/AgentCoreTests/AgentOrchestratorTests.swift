import Foundation
import Testing
@testable import AgentCore

private actor OrchestratorRecorder {
    private(set) var requests: [ToolRequest] = []
    func record(_ request: ToolRequest) { requests.append(request) }
}

private struct OrchestratorDevice: DeviceExecuting {
    let identity: DeviceIdentity
    let tool: String
    let risk: RiskLevel
    let recorder: OrchestratorRecorder

    func capabilities() async -> [ToolDescriptor] {
        [ToolDescriptor(name: tool, summary: "Capability", risk: risk,
                        inputSchema: EmptyInput.schema)]
    }

    func execute(_ request: ToolRequest) async -> ToolResult {
        await recorder.record(request)
        return ToolResult(request: request, data: .string(identity.displayName))
    }
}

private actor OrchestratorDecisionProvider: DecisionProvider {
    nonisolated let providerID = "bounded-test"
    private let selectedOptionID: String
    private(set) var requests: [DecisionRequest] = []

    init(selectedOptionID: String) {
        self.selectedOptionID = selectedOptionID
    }

    func decide(_ request: DecisionRequest) -> ProviderDecision {
        requests.append(request)
        return ProviderDecision(selectedOptionID: selectedOptionID, confidence: 0.95)
    }

    var callCount: Int { requests.count }
}

private func orchestrator(router: DeviceRouter,
                          provider: OrchestratorDecisionProvider) -> AgentOrchestrator {
    AgentOrchestrator(devices: router,
                      decisions: DecisionEngine(boundedProvider: provider))
}

@Test func explicitDeviceBypassesDecisionEngine() async throws {
    let router = DeviceRouter()
    let firstRecorder = OrchestratorRecorder()
    let secondRecorder = OrchestratorRecorder()
    let first = OrchestratorDevice(identity: DeviceIdentity(displayName: "Mac", platform: "macOS"),
                                   tool: "ui.inspect", risk: .read, recorder: firstRecorder)
    let second = OrchestratorDevice(identity: DeviceIdentity(displayName: "PC", platform: "Windows"),
                                    tool: "ui.inspect", risk: .read, recorder: secondRecorder)
    try await router.register(first)
    try await router.register(second)
    let provider = OrchestratorDecisionProvider(selectedOptionID: first.identity.id.uuidString)
    let agent = orchestrator(router: router, provider: provider)
    let session = AgentSession()

    let result = try await agent.execute(
        ToolIntent(tool: "ui.inspect", explicitDeviceID: second.identity.id),
        in: session
    )

    #expect(result.data == .string("PC"))
    #expect(await firstRecorder.requests.isEmpty)
    #expect(await secondRecorder.requests.count == 1)
    #expect(await provider.callCount == 0)
}

@Test func activeDeviceBypassesDecisionEngine() async throws {
    let router = DeviceRouter()
    let first = OrchestratorDevice(identity: DeviceIdentity(displayName: "Mac", platform: "macOS"),
                                   tool: "ui.inspect", risk: .read, recorder: OrchestratorRecorder())
    let secondRecorder = OrchestratorRecorder()
    let second = OrchestratorDevice(identity: DeviceIdentity(displayName: "PC", platform: "Windows"),
                                    tool: "ui.inspect", risk: .read, recorder: secondRecorder)
    try await router.register(first)
    try await router.register(second)
    let provider = OrchestratorDecisionProvider(selectedOptionID: first.identity.id.uuidString)
    let agent = orchestrator(router: router, provider: provider)

    let result = try await agent.execute(
        ToolIntent(tool: "ui.inspect"),
        in: AgentSession(activeDeviceID: second.identity.id)
    )

    #expect(result.data == .string("PC"))
    #expect(await secondRecorder.requests.count == 1)
    #expect(await provider.callCount == 0)
}

@Test func singleCandidateBypassesDecisionEngine() async throws {
    let router = DeviceRouter()
    let recorder = OrchestratorRecorder()
    let device = OrchestratorDevice(identity: DeviceIdentity(displayName: "Mac", platform: "macOS"),
                                    tool: "ui.inspect", risk: .read, recorder: recorder)
    try await router.register(device)
    let provider = OrchestratorDecisionProvider(selectedOptionID: device.identity.id.uuidString)
    let agent = orchestrator(router: router, provider: provider)

    let result = try await agent.execute(ToolIntent(tool: "ui.inspect"), in: AgentSession())
    #expect(result.data == .string("Mac"))
    #expect(await recorder.requests.count == 1)
    #expect(await provider.callCount == 0)
}

@Test func ambiguousReadRequiresOptInBeforeBoundedSelection() async throws {
    let router = DeviceRouter()
    let first = OrchestratorDevice(identity: DeviceIdentity(displayName: "Mac", platform: "macOS"),
                                   tool: "ui.inspect", risk: .read, recorder: OrchestratorRecorder())
    let second = OrchestratorDevice(identity: DeviceIdentity(displayName: "PC", platform: "Windows"),
                                    tool: "ui.inspect", risk: .read, recorder: OrchestratorRecorder())
    try await router.register(first)
    try await router.register(second)
    let provider = OrchestratorDecisionProvider(selectedOptionID: first.identity.id.uuidString)
    let agent = orchestrator(router: router, provider: provider)

    do {
        _ = try await agent.execute(ToolIntent(tool: "ui.inspect"), in: AgentSession())
        Issue.record("Ambiguous device was chosen without opt-in")
    } catch let error as OrchestrationError {
        guard case .deviceSelectionRequired(let tool, let ids) = error else {
            Issue.record("Unexpected orchestration error")
            return
        }
        #expect(tool == "ui.inspect")
        #expect(Set(ids) == Set([first.identity.id, second.identity.id]))
    }
    #expect(await provider.callCount == 0)
}

@Test func boundedDecisionCanChooseAmongReadOnlyCandidates() async throws {
    let router = DeviceRouter()
    let firstRecorder = OrchestratorRecorder()
    let secondRecorder = OrchestratorRecorder()
    let first = OrchestratorDevice(identity: DeviceIdentity(displayName: "Mac", platform: "macOS"),
                                   tool: "ui.inspect", risk: .read, recorder: firstRecorder)
    let second = OrchestratorDevice(identity: DeviceIdentity(displayName: "PC", platform: "Windows"),
                                    tool: "ui.inspect", risk: .read, recorder: secondRecorder)
    try await router.register(first)
    try await router.register(second)
    let provider = OrchestratorDecisionProvider(selectedOptionID: second.identity.id.uuidString)
    let agent = orchestrator(router: router, provider: provider)
    let session = AgentSession(allowBoundedReadDeviceSelection: true)

    let result = try await agent.execute(
        ToolIntent(tool: "ui.inspect",
                   decisionState: .object(["user_hint": .string("office PC")])),
        in: session
    )

    #expect(result.data == .string("PC"))
    #expect(await firstRecorder.requests.isEmpty)
    #expect(await secondRecorder.requests.count == 1)
    #expect(await provider.callCount == 1)
    let requests = await provider.requests
    #expect(requests[0].state == .object([
        "tool": .string("ui.inspect"),
        "session_id": .string(session.id.uuidString),
        "intent_state": .object(["user_hint": .string("office PC")])
    ]))
}

@Test func boundedDecisionNeverChoosesAmbiguousNonReadDevice() async throws {
    let router = DeviceRouter()
    let first = OrchestratorDevice(identity: DeviceIdentity(displayName: "Mac", platform: "macOS"),
                                   tool: "ui.click", risk: .externalEffect, recorder: OrchestratorRecorder())
    let second = OrchestratorDevice(identity: DeviceIdentity(displayName: "PC", platform: "Windows"),
                                    tool: "ui.click", risk: .externalEffect, recorder: OrchestratorRecorder())
    try await router.register(first)
    try await router.register(second)
    let provider = OrchestratorDecisionProvider(selectedOptionID: first.identity.id.uuidString)
    let agent = orchestrator(router: router, provider: provider)

    do {
        _ = try await agent.execute(ToolIntent(tool: "ui.click"),
                                    in: AgentSession(allowBoundedReadDeviceSelection: true))
        Issue.record("AI selected a device for a non-read action")
    } catch let error as OrchestrationError {
        guard case .deviceSelectionRequired(let tool, _) = error else {
            Issue.record("Unexpected orchestration error")
            return
        }
        #expect(tool == "ui.click")
    }
    #expect(await provider.callCount == 0)
}

@Test func inconsistentCapabilityRiskFailsClosed() async throws {
    let router = DeviceRouter()
    let first = OrchestratorDevice(identity: DeviceIdentity(displayName: "Mac", platform: "macOS"),
                                   tool: "shared.tool", risk: .read, recorder: OrchestratorRecorder())
    let second = OrchestratorDevice(identity: DeviceIdentity(displayName: "PC", platform: "Windows"),
                                    tool: "shared.tool", risk: .externalEffect, recorder: OrchestratorRecorder())
    try await router.register(first)
    try await router.register(second)
    let provider = OrchestratorDecisionProvider(selectedOptionID: first.identity.id.uuidString)
    let agent = orchestrator(router: router, provider: provider)

    do {
        _ = try await agent.execute(ToolIntent(tool: "shared.tool"),
                                    in: AgentSession(allowBoundedReadDeviceSelection: true))
        Issue.record("Conflicting capability risk was ignored")
    } catch let error as OrchestrationError {
        #expect(error == .inconsistentCapabilityRisk("shared.tool"))
    }
    #expect(await provider.callCount == 0)
}

@Test func missingCapabilityFailsBeforeDecision() async throws {
    let router = DeviceRouter()
    let provider = OrchestratorDecisionProvider(selectedOptionID: UUID().uuidString)
    let agent = orchestrator(router: router, provider: provider)

    do {
        _ = try await agent.execute(ToolIntent(tool: "ui.inspect"), in: AgentSession())
        Issue.record("Missing capability did not fail")
    } catch let error as OrchestrationError {
        #expect(error == .noCapableDevice("ui.inspect"))
    }
    #expect(await provider.callCount == 0)
}
