import Foundation
import Testing
@testable import AgentCore

private actor ApprovalAudit: AuditSink {
    func append(_ event: AuditEvent) throws {}
}

private struct ApprovalPermissions: PermissionChecking {
    func isGranted(_ permission: Permission) async -> Bool { true }
}

private actor ApprovalCounter {
    var value = 0
    func increment() { value += 1 }
}

private struct ApprovalProbe: Tool {
    let counter: ApprovalCounter
    var risk: RiskLevel = .reversibleWrite

    var descriptor: ToolDescriptor {
        ToolDescriptor(name: "test.approved_probe", summary: "Approval probe", risk: risk,
                       inputSchema: EmptyInput.schema)
    }

    func execute(_ input: EmptyInput) async throws -> String {
        await counter.increment()
        return "executed"
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = value.addingTimeInterval(seconds)
    }
}

@Test func exactApprovalExecutesOnceAndCannotReplay() async throws {
    let counter = ApprovalCounter()
    let probe = ApprovalProbe(counter: counter)
    let approvals = ApprovalStore()
    let runtime = ToolRuntime(audit: ApprovalAudit(), permissions: ApprovalPermissions(), approvals: approvals)
    try await runtime.register(probe)

    let context = RequestContext(deviceID: UUID(), sessionID: UUID())
    let grant = try await approvals.issue(descriptor: probe.descriptor,
                                          arguments: .object([:]), context: context)
    let request = ToolRequest(tool: probe.descriptor.name, context: context, approvalID: grant.id)

    #expect((await runtime.execute(request)).status == .success)
    #expect(await counter.value == 1)
    #expect((await runtime.execute(request)).error?.code == .approvalRequired)
    #expect(await counter.value == 1)
}

@Test func argumentMismatchConsumesGrant() async throws {
    let counter = ApprovalCounter()
    let probe = ApprovalProbe(counter: counter, risk: .externalEffect)
    let approvals = ApprovalStore()
    let runtime = ToolRuntime(audit: ApprovalAudit(), permissions: ApprovalPermissions(), approvals: approvals)
    try await runtime.register(probe)

    let context = RequestContext(deviceID: UUID(), sessionID: UUID())
    let grant = try await approvals.issue(descriptor: probe.descriptor,
                                          arguments: .object([:]), context: context)
    let mismatched = ToolRequest(tool: probe.descriptor.name,
                                 arguments: .object(["changed": .bool(true)]),
                                 context: context, approvalID: grant.id)

    #expect((await runtime.execute(mismatched)).error?.code == .approvalRequired)
    #expect((await runtime.execute(ToolRequest(tool: probe.descriptor.name,
                                              context: context, approvalID: grant.id))).error?.code == .approvalRequired)
    #expect(await counter.value == 0)
}

@Test func approvalIsBoundToDeviceAndSession() async throws {
    let counter = ApprovalCounter()
    let probe = ApprovalProbe(counter: counter, risk: .highRisk)
    let approvals = ApprovalStore()
    let runtime = ToolRuntime(audit: ApprovalAudit(), permissions: ApprovalPermissions(), approvals: approvals)
    try await runtime.register(probe)

    let approved = RequestContext(deviceID: UUID(), sessionID: UUID())
    let wrongSession = RequestContext(deviceID: approved.deviceID, sessionID: UUID())
    let grant = try await approvals.issue(descriptor: probe.descriptor,
                                          arguments: .object([:]), context: approved)

    let result = await runtime.execute(ToolRequest(tool: probe.descriptor.name,
                                                   context: wrongSession, approvalID: grant.id))
    #expect(result.error?.code == .approvalRequired)
    #expect(await counter.value == 0)
}

@Test func expiredApprovalFailsClosed() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let approvals = ApprovalStore(maxTTL: 60, now: { clock.now() })
    let counter = ApprovalCounter()
    let probe = ApprovalProbe(counter: counter)
    let runtime = ToolRuntime(audit: ApprovalAudit(), permissions: ApprovalPermissions(), approvals: approvals)
    try await runtime.register(probe)

    let context = RequestContext(deviceID: UUID(), sessionID: UUID())
    let grant = try await approvals.issue(descriptor: probe.descriptor,
                                          arguments: .object([:]), context: context, ttl: 10)
    clock.advance(11)

    let result = await runtime.execute(ToolRequest(tool: probe.descriptor.name,
                                                   context: context, approvalID: grant.id))
    #expect(result.error?.code == .approvalRequired)
    #expect(await counter.value == 0)
}

@Test func approvalTTLIsBoundedAndReadToolsCannotBeApproved() async throws {
    let approvals = ApprovalStore(maxTTL: 60)
    let context = RequestContext(deviceID: UUID(), sessionID: UUID())
    let read = ApprovalProbe(counter: ApprovalCounter(), risk: .read).descriptor
    let write = ApprovalProbe(counter: ApprovalCounter()).descriptor

    do {
        _ = try await approvals.issue(descriptor: read, arguments: .object([:]), context: context)
        Issue.record("Read-only tool unexpectedly received an approval")
    } catch let error as ApprovalIssueError {
        #expect(error == .readOnlyTool)
    }

    do {
        _ = try await approvals.issue(descriptor: write, arguments: .object([:]), context: context, ttl: 61)
        Issue.record("Oversized approval TTL was accepted")
    } catch let error as ApprovalIssueError {
        #expect(error == .invalidTTL)
    }
}
