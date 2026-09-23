import Foundation
import Testing
@testable import AgentCore

@Test func interfaceStateProducesInterfaceScopedSessionContext() throws {
    let interfaceID = UUID()
    let phoneID = UUID()
    let observed = Date(timeIntervalSince1970: 1_000)
    let state = InterfaceContextState(
        interfaceID: interfaceID,
        kind: .iOSApp,
        originatingDeviceID: phoneID,
        observedAt: observed
    )

    #expect(state.contextScope.kind == .interface)
    #expect(state.contextScope.referenceID == interfaceID.uuidString)
    #expect(state.contextKey == "interface_state")
    #expect(state.freshnessClass == .session)
    #expect(state.bindings.deviceID == phoneID)
}

@Test func deviceStateIsEphemeralAndDeviceBound() throws {
    let tenant = TenantContext(tenantID: UUID(), userID: UUID())
    let deviceID = UUID()
    let observed = Date(timeIntervalSince1970: 2_000)
    let state = DeviceContextState(
        deviceID: deviceID,
        online: true,
        lastSeenAt: observed,
        advertisedCapabilities: ["ui.get_frontmost_app", "ui.get_windows"],
        frontmostApp: "VS Code",
        activeProject: "SECND",
        observedAt: observed
    )
    let provenance = try ContextProvenance(origin: .applicationAdapter, trust: .systemState)
    let item = try state.contextItem(tenant: tenant, provenance: provenance)

    #expect(item.scope == .device(deviceID))
    #expect(item.freshness.classification == .ephemeral)
    #expect(item.bindings.deviceID == deviceID)
    #expect(item.provenance.trust == .systemState)

    let decoded = try item.value.decode(DeviceContextState.self)
    #expect(decoded == state)
}

@Test func taskStateRemainsStructuredInsteadOfConversationText() throws {
    let taskID = UUID()
    let sessionID = UUID()
    let observed = Date(timeIntervalSince1970: 3_000)
    let state = TaskContextState(
        taskID: taskID,
        sessionID: sessionID,
        goal: "Diagnose backend",
        status: .running,
        knownFacts: [
            "backend_running": .bool(false),
            "latest_error": .string("DATABASE_URL missing")
        ],
        actionsTaken: ["checked process", "inspected logs"],
        nextCandidates: ["inspect_env", "inspect_config", "ask_user"],
        observedAt: observed
    )

    #expect(state.contextScope == .task(taskID))
    #expect(state.bindings.sessionID == sessionID)
    #expect(state.bindings.taskID == taskID)
    #expect(state.knownFacts["backend_running"] == .bool(false))
    #expect(state.nextCandidates == ["inspect_env", "inspect_config", "ask_user"])
}

@Test func typedStateCanBeStoredOnlyInsideItsTenantPartition() async throws {
    let owner = TenantContext(tenantID: UUID(), userID: UUID())
    let other = TenantContext(tenantID: owner.tenantID, userID: UUID())
    let observed = Date(timeIntervalSince1970: 4_000)
    let store = InMemoryContextService()
    let state = SessionContextState(
        sessionID: UUID(),
        currentGoal: "Debug SECND",
        observedAt: observed
    )
    let provenance = try ContextProvenance(origin: .system, trust: .systemState)

    try await store.put(state, tenant: owner, provenance: provenance)

    let ownerItems = await store.query(
        ContextQuery(scopeKinds: [.session], keys: ["session_state"], includeStale: true),
        as: owner,
        now: observed
    )
    let otherItems = await store.query(
        ContextQuery(scopeKinds: [.session], keys: ["session_state"], includeStale: true),
        as: other,
        now: observed
    )

    #expect(ownerItems.count == 1)
    #expect(otherItems.isEmpty)
    #expect(try ownerItems[0].value.decode(SessionContextState.self) == state)
}

@Test func agentSessionBuildsSessionContextWithoutChangingRoutingState() throws {
    let sessionID = UUID()
    let activeDevice = UUID()
    let taskID = UUID()
    let interfaceID = UUID()
    let observed = Date(timeIntervalSince1970: 5_000)
    let session = AgentSession(
        id: sessionID,
        activeDeviceID: activeDevice,
        allowBoundedReadDeviceSelection: true
    )

    let state = session.contextState(
        currentGoal: "Inspect current project",
        currentTaskID: taskID,
        interfaceID: interfaceID,
        observedAt: observed
    )

    #expect(state.sessionID == sessionID)
    #expect(state.activeDeviceID == activeDevice)
    #expect(state.currentTaskID == taskID)
    #expect(state.interfaceID == interfaceID)
    #expect(state.bindings.sessionID == sessionID)
    #expect(state.bindings.deviceID == activeDevice)
}
