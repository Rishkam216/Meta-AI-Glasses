import Foundation
import Testing
@testable import AgentCore

@Test func sessionLayerUsesCanonicalScopeTrustFreshnessAndTypedReadback() async throws {
    let service = ContextService(freshnessPolicy: try ContextFreshnessPolicy(sessionMaxAge: 3_600))
    let layers = ContextLayerStore(service: service)
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let sessionID = UUID()
    let activeDeviceID = UUID()
    let activeTaskID = UUID()
    let observed = Date(timeIntervalSince1970: 1_000)
    let state = try SessionContextState(
        activeDeviceID: activeDeviceID,
        activeTaskID: activeTaskID,
        currentGoal: "Diagnose backend",
        summary: "Backend exits during startup."
    )

    let item = try await layers.recordSession(state, principal: principal, sessionID: sessionID, observedAt: observed)

    #expect(item.scope == .session(sessionID))
    #expect(item.key == "session_state")
    #expect(item.provenance.trust == .systemState)
    #expect(item.provenance.origin == .system)
    #expect(item.freshness.classification == .session)
    #expect(item.bindings.sessionID == sessionID)
    #expect(try await layers.latestSession(principal: principal, sessionID: sessionID, at: observed) == state)
}

@Test func interfaceLayerPreservesOriginDeviceAndCompanionRelationships() async throws {
    let service = ContextService(freshnessPolicy: try ContextFreshnessPolicy(ephemeralMaxAge: 60))
    let layers = ContextLayerStore(service: service)
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let sessionID = UUID()
    let phoneID = UUID()
    let interfaceID = UUID()
    let state = InterfaceContextState(
        interfaceID: interfaceID,
        kind: .metaGlassesViaPhone,
        deviceID: nil,
        companionDeviceID: phoneID
    )
    let now = Date(timeIntervalSince1970: 1_000)

    let item = try await layers.recordInterface(state, principal: principal, sessionID: sessionID, observedAt: now)
    #expect(item.scope.kind == .interface)
    #expect(item.scope.referenceID == interfaceID.uuidString)
    #expect(item.bindings.sessionID == sessionID)
    #expect(item.freshness.classification == .ephemeral)
    #expect(try await layers.latestInterface(principal: principal, interfaceID: interfaceID, at: now) == state)
}

@Test func deviceLayerNormalizesCapabilitiesAndBindsDevice() async throws {
    let service = ContextService(freshnessPolicy: try ContextFreshnessPolicy(ephemeralMaxAge: 60))
    let layers = ContextLayerStore(service: service)
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let sessionID = UUID()
    let deviceID = UUID()
    let now = Date(timeIntervalSince1970: 1_000)
    let state = try DeviceContextState(
        online: true,
        lastSeen: now,
        capabilityNames: ["ui.get_tree", "app.open", "ui.get_tree"],
        frontmostApp: "VS Code",
        activeProject: "SECND"
    )

    let item = try await layers.recordDevice(
        state,
        principal: principal,
        deviceID: deviceID,
        sessionID: sessionID,
        observedAt: now
    )
    let decoded = try await layers.latestDevice(principal: principal, deviceID: deviceID, at: now)

    #expect(item.scope == .device(deviceID))
    #expect(item.bindings.deviceID == deviceID)
    #expect(item.bindings.sessionID == sessionID)
    #expect(item.provenance.origin == .applicationAdapter)
    #expect(decoded?.capabilityNames == ["app.open", "ui.get_tree"])
    #expect(decoded?.frontmostApp == "VS Code")
}

@Test func taskLayerReturnsNewestTypedState() async throws {
    let service = ContextService(freshnessPolicy: try ContextFreshnessPolicy(sessionMaxAge: 3_600))
    let layers = ContextLayerStore(service: service)
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let sessionID = UUID()
    let taskID = UUID()
    let firstTime = Date(timeIntervalSince1970: 1_000)
    let secondTime = firstTime.addingTimeInterval(5)

    try await layers.recordTask(
        TaskContextState(status: .running, goalSummary: "Debug backend", updatedAt: firstTime),
        principal: principal,
        taskID: taskID,
        sessionID: sessionID,
        observedAt: firstTime
    )
    let completed = try TaskContextState(status: .completed, goalSummary: "Debug backend", updatedAt: secondTime)
    try await layers.recordTask(
        completed,
        principal: principal,
        taskID: taskID,
        sessionID: sessionID,
        observedAt: secondTime
    )

    #expect(try await layers.latestTask(principal: principal, taskID: taskID, sessionID: sessionID, at: secondTime) == completed)
}

@Test func typedLayerReadsCannotCrossPrincipalPartition() async throws {
    let service = ContextService(freshnessPolicy: try ContextFreshnessPolicy(sessionMaxAge: 3_600))
    let layers = ContextLayerStore(service: service)
    let owner = TenantContext(tenantID: UUID(), userID: UUID())
    let attacker = TenantContext(tenantID: owner.tenantID, userID: UUID())
    let sessionID = UUID()
    let now = Date(timeIntervalSince1970: 1_000)

    try await layers.recordSession(
        SessionContextState(currentGoal: "Owner-only goal"),
        principal: owner,
        sessionID: sessionID,
        observedAt: now
    )

    #expect(try await layers.latestSession(principal: owner, sessionID: sessionID, at: now) != nil)
    #expect(try await layers.latestSession(principal: attacker, sessionID: sessionID, at: now) == nil)
}

@Test func typedStateValidationBoundsUserControlledStringsAndCapabilities() throws {
    #expect(throws: ContextLayerError.emptyText) {
        _ = try SessionContextState(currentGoal: "   ")
    }
    #expect(throws: ContextLayerError.textTooLong) {
        _ = try TaskContextState(
            status: .running,
            goalSummary: String(repeating: "x", count: 4_097),
            updatedAt: Date()
        )
    }
    #expect(throws: ContextLayerError.tooManyCapabilities) {
        _ = try DeviceContextState(
            online: true,
            lastSeen: Date(),
            capabilityNames: Array(repeating: "tool", count: 513)
        )
    }
    #expect(throws: ContextLayerError.invalidCapabilityName) {
        _ = try DeviceContextState(online: true, lastSeen: Date(), capabilityNames: ["   "])
    }
}

@Test func typedReadFailsClosedWhenStoredValueHasWrongShape() async throws {
    let service = ContextService(freshnessPolicy: try ContextFreshnessPolicy(ephemeralMaxAge: 60))
    let layers = ContextLayerStore(service: service)
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let deviceID = UUID()
    let now = Date(timeIntervalSince1970: 1_000)

    let malformed = try ContextItem(
        tenant: principal,
        scope: .device(deviceID),
        key: "device_state",
        value: .string("not-a-device-state"),
        provenance: ContextProvenance(origin: .applicationAdapter, trust: .systemState),
        freshness: ContextFreshness(classification: .ephemeral, observedAt: now),
        bindings: ContextBindings(deviceID: deviceID),
        createdAt: now
    )
    try await service.store(malformed, for: principal)

    do {
        _ = try await layers.latestDevice(principal: principal, deviceID: deviceID, at: now)
        Issue.record("Malformed typed context unexpectedly decoded")
    } catch let error as ContextLayerError {
        #expect(error == .decodeFailed)
    }
}
