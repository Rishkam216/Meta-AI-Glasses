import Foundation
import Testing
@testable import AgentCore

private actor MemoryAudit: AuditSink {
    var events: [AuditEvent] = []
    let failAt: Int?
    init(failAt: Int? = nil) { self.failAt = failAt }
    func append(_ event: AuditEvent) throws {
        if events.count == failAt { throw TestError.failure }
        events.append(event)
    }
}
private enum TestError: Error { case failure }
private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
private struct Permissions: PermissionChecking {
    var allowed = true
    func isGranted(_ permission: Permission) async -> Bool { allowed }
}
private struct Probe: Tool {
    let counter: Counter
    var risk: RiskLevel = .read
    var permissions: [Permission] = []
    var fail = false
    var descriptor: ToolDescriptor {
        ToolDescriptor(name: "test.probe", summary: "Test probe", risk: risk,
                       permissions: permissions, inputSchema: .object([:]))
    }
    func execute(_ input: EmptyInput) async throws -> String {
        await counter.increment()
        if fail { throw TestError.failure }
        return "payload-not-for-audit"
    }
}

@Test func successfulReadHasMatchingAuditAndResult() async throws {
    let audit = MemoryAudit()
    let counter = Counter()
    let runtime = ToolRuntime(audit: audit, permissions: Permissions())
    try await runtime.register(Probe(counter: counter))
    let request = ToolRequest(tool: "test.probe")
    let result = await runtime.execute(request)
    #expect(result.status == .success)
    #expect(result.data == .string("payload-not-for-audit"))
    #expect(result.error == nil)
    #expect(result.requestID == request.id)
    #expect(await counter.value == 1)
    let events = await audit.events
    #expect(events.map(\.phase) == [.started, .completed])
    #expect(events.allSatisfy { $0.requestID == request.id })
    #expect(!String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains("payload-not-for-audit"))
    let json = try JSONSerialization.jsonObject(with: result.json()) as! [String: Any]
    #expect(json["status"] as? String == "success")
    #expect(json["error"] == nil)
}

@Test(arguments: [RiskLevel.reversibleWrite, .externalEffect, .highRisk])
func nonReadActionsNeverExecute(risk: RiskLevel) async throws {
    let counter = Counter()
    let runtime = ToolRuntime(audit: MemoryAudit(), permissions: Permissions())
    try await runtime.register(Probe(counter: counter, risk: risk))
    let result = await runtime.execute(ToolRequest(tool: "test.probe"))
    #expect(result.error?.code == .approvalRequired)
    #expect(await counter.value == 0)
}

@Test func deniedPermissionNeverExecutes() async throws {
    let counter = Counter()
    let runtime = ToolRuntime(audit: MemoryAudit(), permissions: Permissions(allowed: false))
    try await runtime.register(Probe(counter: counter, permissions: [.accessibility]))
    let result = await runtime.execute(ToolRequest(tool: "test.probe"))
    #expect(result.error?.code == .permissionRequired)
    #expect(result.error?.details["permission"] == .string("accessibility"))
    #expect(await counter.value == 0)
}

@Test func unknownToolIsAudited() async {
    let audit = MemoryAudit()
    let runtime = ToolRuntime(audit: audit, permissions: Permissions())
    let result = await runtime.execute(ToolRequest(tool: "shell.run"))
    #expect(result.error?.code == .unknownTool)
    #expect(await audit.events.count == 2)
}

@Test(arguments: [JSONValue.null, .array([]), .object(["unexpected": .bool(true)])])
func invalidInputNeverExecutes(arguments: JSONValue) async throws {
    let counter = Counter()
    let runtime = ToolRuntime(audit: MemoryAudit(), permissions: Permissions())
    try await runtime.register(Probe(counter: counter))
    let result = await runtime.execute(ToolRequest(tool: "test.probe", arguments: arguments))
    #expect(result.error?.code == .invalidArguments)
    #expect(await counter.value == 0)
}

@Test(arguments: [0, 1])
func auditFailureIsExplicit(failAt: Int) async throws {
    let counter = Counter()
    let runtime = ToolRuntime(audit: MemoryAudit(failAt: failAt), permissions: Permissions())
    try await runtime.register(Probe(counter: counter))
    let result = await runtime.execute(ToolRequest(tool: "test.probe"))
    #expect(result.error?.code == .auditUnavailable)
    #expect(result.error?.details["may_have_executed"] == .bool(failAt == 1))
    #expect(await counter.value == failAt)
    #expect(result.data == nil)
}

@Test func unexpectedErrorsDoNotLeakDetails() async throws {
    let runtime = ToolRuntime(audit: MemoryAudit(), permissions: Permissions())
    try await runtime.register(Probe(counter: Counter(), fail: true))
    let result = await runtime.execute(ToolRequest(tool: "test.probe"))
    #expect(result.error?.code == .executionFailed)
    #expect(result.data == nil)
}

@Test func duplicateRegistrationDoesNotReplaceTool() async throws {
    let runtime = ToolRuntime(audit: MemoryAudit(), permissions: Permissions())
    try await runtime.register(Probe(counter: Counter()))
    do {
        try await runtime.register(Probe(counter: Counter(), risk: .highRisk))
        Issue.record("Duplicate tool was allowed")
    } catch RegistryError.duplicateTool(let name) { #expect(name == "test.probe") }
    #expect(await runtime.catalog().count == 1)
    #expect(await runtime.catalog().first?.risk == .read)
}

@Test func jsonRoundTripPreservesTypesAndLargeIntegers() throws {
    let original = JSONValue.object([
        "integer": .integer(9_007_199_254_740_993), "bool": .bool(true),
        "null": .null, "array": .array([.string("value"), .number(1.5)])
    ])
    let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(original))
    #expect(decoded == original)
}

@Test func auditFileIsAppendOnlyPrivateAndRefusesSymlink() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("audit.jsonl")
    let request = ToolRequest(tool: "test.probe")
    let event = AuditEvent(request: request, risk: .read, phase: .started)
    let firstLog = try FileAuditLog(url: path)
    try await firstLog.append(event)
    let secondLog = try FileAuditLog(url: path)
    try await secondLog.append(event)
    let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let link = directory.appendingPathComponent("link.jsonl")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
    #expect(throws: (any Error).self) { _ = try FileAuditLog(url: link) }
}
