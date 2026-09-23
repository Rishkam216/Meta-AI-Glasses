import Foundation
import Testing
@testable import AgentCore

@Test func interfaceStateProducesInterfaceScopedSessionContext() throws {
    let interfaceID = UUID()
    let phoneID = UUID()
    let observed = Date(timeIntervalSince1970: 1_000)
    let state = try InterfaceContextState(
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

@Test func glassesViaPhoneRequiresExplicitCompanionDevice() throws {
    #expect(throws: ContextStateValidationError.missingGlassesCompanion) {
        _ = try InterfaceContextState(kind: .metaGlassesViaPhone)
    }

    let companion = UUID()
    let state = try InterfaceContextState(
        kind: .metaGlassesViaPhone,
        companionDeviceID: companion
    )
    #expect(state.companionDeviceID == companion)
}

@Test func deviceStateNormalizesAndBoundsCapabilities() throws {
    let deviceID = UUID()
    let observed = Date(timeIntervalSince1970: 2_000)
    let state = try DeviceContextState(
        deviceID: deviceID,
        online: true,
        lastSeenAt: observed,
        advertisedCapabilities: [" ui.get_windows ", "ui.get_windows", "ui.get_frontmost_app"],
        frontmostApp: "VS Code",
        activeProject: "SECND",
        observedAt: observed
    )

    #expect(state.advertisedCapabilities == ["ui.get_frontmost_app", "ui.get_windows"])
    #expect(state.contextScope == .device(deviceID))
    #expect(state.freshnessClass == .ephemeral)

    #expect(throws: ContextStateValidationError.invalidCapabilityName) {
        _ = try DeviceContextState(
            deviceID: deviceID,
            online: true,
            lastSeenAt: observed,
            advertisedCapabilities: ["   "]
        )
    }
}

@Test func taskStateRemainsStructuredAndBounded() throws {
    let taskID = UUID()
    let sessionID = UUID()
    let observed = Date(timeIntervalSince1970: 3_000)
    let state = try TaskContextState(
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
    #expect(state.knownFacts["backend_running"] == .bool(false))

    #expect(throws: ContextStateValidationError.invalidFactKey) {
        _ = try TaskContextState(
            taskID: taskID,
            sessionID: sessionID,
            goal: "valid",
            knownFacts: ["   ": .string("bad")]
        )
    }
}

@Test func typedStateCanBeStoredOnlyInsideItsTenantPartition() async throws {
    let owner = TenantContext(tenantID: UUID(), userID: UUID())
    let other = TenantContext(tenantID: owner.tenantID, userID: UUID())
    let observed = Date(timeIntervalSince1970: 4_000)
    let store = InMemoryContextService()
    let state = try SessionContextState(
        sessionID: UUID(),
        currentGoal: "Debug SECND",
        summary: "Backend investigation in progress",
        observedAt: observed
    )
    let provenance = try ContextProvenance(origin: .system, trust: .systemState)

    try await store.put(state, tenant: owner, provenance: provenance)

    let ownerItems = await store.query(
        try ContextQuery(scopeKinds: [.session], keys: ["session_state"], includeStale: true),
        as: owner,
        now: observed
    )
    let otherItems = await store.query(
        try ContextQuery(scopeKinds: [.session], keys: ["session_state"], includeStale: true),
        as: other,
        now: observed
    )

    #expect(ownerItems.count == 1)
    #expect(otherItems.isEmpty)
    #expect(try ownerItems[0].value.decode(SessionContextState.self) == state)
}

@Test func agentSessionBuildsValidatedSessionContextWithoutChangingRoutingState() throws {
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

    let state = try session.contextState(
        currentGoal: "Inspect current project",
        summary: "Working in SECND",
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

@Test func sessionContextRejectsOversizedAndDuplicateState() throws {
    #expect(throws: ContextStateValidationError.textTooLong("currentGoal")) {
        _ = try SessionContextState(
            sessionID: UUID(),
            currentGoal: String(repeating: "x", count: 4_097)
        )
    }
    let job = UUID()
    #expect(throws: ContextStateValidationError.duplicateJobID) {
        _ = try SessionContextState(sessionID: UUID(), activeJobIDs: [job, job])
    }
}

@Test func typedWireDecodingReRunsValidation() throws {
    let invalidDevice = Data(#"{"deviceID":"00000000-0000-0000-0000-000000000001","online":true,"lastSeenAt":0,"advertisedCapabilities":["   "],"observedAt":0}"#.utf8)
    #expect(throws: ContextStateValidationError.invalidCapabilityName) {
        _ = try JSONDecoder().decode(DeviceContextState.self, from: invalidDevice)
    }

    let invalidSession = Data(#"{"sessionID":"00000000-0000-0000-0000-000000000001","activeJobIDs":[],"currentGoal":"   ","observedAt":0}"#.utf8)
    #expect(throws: ContextStateValidationError.emptyText("currentGoal")) {
        _ = try JSONDecoder().decode(SessionContextState.self, from: invalidSession)
    }
}
