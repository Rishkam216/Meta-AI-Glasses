import Foundation
import Testing
@testable import AgentCore

private actor RouteRecorder {
    var requests: [ToolRequest] = []
    func record(_ request: ToolRequest) { requests.append(request) }
}

private struct FakeDevice: DeviceExecuting {
    let identity: DeviceIdentity
    let toolNames: [String]
    let recorder: RouteRecorder

    func capabilities() async -> [ToolDescriptor] {
        toolNames.map {
            ToolDescriptor(name: $0, summary: "Fake capability", risk: .read,
                           inputSchema: EmptyInput.schema)
        }
    }

    func execute(_ request: ToolRequest) async -> ToolResult {
        await recorder.record(request)
        return ToolResult(request: request, data: .string("ok"))
    }
}

private actor RouteAudit: AuditSink {
    func append(_ event: AuditEvent) throws {}
}

private struct RoutePermissions: PermissionChecking {
    func isGranted(_ permission: Permission) async -> Bool { true }
}

private struct RouteProbe: Tool {
    let descriptor = ToolDescriptor(name: "ui.inspect", summary: "Inspect", risk: .read,
                                    inputSchema: EmptyInput.schema)
    func execute(_ input: EmptyInput) async throws -> String { "runtime-ok" }
}

@Test func candidatesAreSelectedByCapabilityNotPlatform() async throws {
    let router = DeviceRouter()
    let mac = FakeDevice(identity: DeviceIdentity(displayName: "Mac", platform: "macOS"),
                         toolNames: ["ui.inspect"], recorder: RouteRecorder())
    let windows = FakeDevice(identity: DeviceIdentity(displayName: "PC", platform: "Windows"),
                             toolNames: ["ui.inspect"], recorder: RouteRecorder())
    let linux = FakeDevice(identity: DeviceIdentity(displayName: "Server", platform: "Linux"),
                           toolNames: ["process.status"], recorder: RouteRecorder())
    try await router.register(mac)
    try await router.register(windows)
    try await router.register(linux)

    let candidates = await router.candidates(for: "ui.inspect")
    #expect(Set(candidates.map(\.identity.id)) == Set([mac.identity.id, windows.identity.id]))
}

@Test func routeCreatesBoundContextAndForwardsApproval() async throws {
    let router = DeviceRouter()
    let recorder = RouteRecorder()
    let device = FakeDevice(identity: DeviceIdentity(displayName: "Mac", platform: "macOS"),
                            toolNames: ["ui.inspect"], recorder: recorder)
    try await router.register(device)

    let sessionID = UUID()
    let approvalID = UUID()
    let result = try await router.route(tool: "ui.inspect",
                                        arguments: .object(["depth": .integer(2)]),
                                        to: device.identity.id,
                                        sessionID: sessionID,
                                        approvalID: approvalID)
    #expect(result.status == .success)

    let requests = await recorder.requests
    #expect(requests.count == 1)
    #expect(requests[0].context == RequestContext(deviceID: device.identity.id, sessionID: sessionID))
    #expect(requests[0].approvalID == approvalID)
    #expect(requests[0].arguments == .object(["depth": .integer(2)]))
}

@Test func unavailableCapabilityNeverExecutes() async throws {
    let router = DeviceRouter()
    let recorder = RouteRecorder()
    let device = FakeDevice(identity: DeviceIdentity(displayName: "Mac", platform: "macOS"),
                            toolNames: ["ui.inspect"], recorder: recorder)
    try await router.register(device)

    do {
        _ = try await router.route(tool: "shell.run", to: device.identity.id, sessionID: UUID())
        Issue.record("Unadvertised capability was routed")
    } catch let error as DeviceRoutingError {
        #expect(error == .capabilityUnavailable(deviceID: device.identity.id, tool: "shell.run"))
    }
    #expect(await recorder.requests.isEmpty)
}

@Test func unknownDeviceIsRejected() async throws {
    let router = DeviceRouter()
    let missing = UUID()
    do {
        _ = try await router.route(tool: "ui.inspect", to: missing, sessionID: UUID())
        Issue.record("Unknown device was routed")
    } catch let error as DeviceRoutingError {
        #expect(error == .unknownDevice(missing))
    }
}

@Test func duplicateDeviceRegistrationIsRejected() async throws {
    let router = DeviceRouter()
    let identity = DeviceIdentity(displayName: "Mac", platform: "macOS")
    try await router.register(FakeDevice(identity: identity, toolNames: ["ui.inspect"], recorder: RouteRecorder()))
    do {
        try await router.register(FakeDevice(identity: identity, toolNames: ["process.status"], recorder: RouteRecorder()))
        Issue.record("Duplicate device ID was accepted")
    } catch let error as DeviceRoutingError {
        #expect(error == .duplicateDevice(identity.id))
    }
}

@Test func runtimeAdapterRoutesIntoToolRuntime() async throws {
    let runtime = ToolRuntime(audit: RouteAudit(), permissions: RoutePermissions())
    try await runtime.register(RouteProbe())
    let identity = DeviceIdentity(displayName: "Local", platform: "macOS")
    let router = DeviceRouter()
    try await router.register(RuntimeDeviceExecutor(identity: identity, runtime: runtime))

    let result = try await router.route(tool: "ui.inspect", to: identity.id, sessionID: UUID())
    #expect(result.status == .success)
    #expect(result.data == .string("runtime-ok"))
}
