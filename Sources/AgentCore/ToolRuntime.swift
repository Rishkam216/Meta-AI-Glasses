import Foundation

public protocol PermissionChecking: Sendable {
    func isGranted(_ permission: Permission) async -> Bool
}

public enum RegistryError: Error { case duplicateTool(String) }

public actor ToolRuntime {
    private struct Entry: Sendable {
        let descriptor: ToolDescriptor
        let run: @Sendable (JSONValue) async throws -> JSONValue
    }
    private var tools: [String: Entry] = [:]
    private let audit: any AuditSink
    private let permissions: any PermissionChecking
    private let approvals: any ApprovalAuthorizing

    public init(audit: any AuditSink, permissions: any PermissionChecking,
                approvals: any ApprovalAuthorizing = DenyAllApprovals()) {
        self.audit = audit
        self.permissions = permissions
        self.approvals = approvals
    }

    public func register<T: Tool>(_ tool: T) throws {
        let descriptor = tool.descriptor
        guard tools[descriptor.name] == nil else { throw RegistryError.duplicateTool(descriptor.name) }
        tools[descriptor.name] = Entry(descriptor: descriptor, run: { arguments in
            let input: T.Input
            do { input = try arguments.decode(T.Input.self) }
            catch {
                throw ToolFailure(code: .invalidArguments, message: "Arguments do not match the tool's input contract.")
            }
            return try JSONValue.encoding(await tool.execute(input))
        })
    }

    public func catalog() -> [ToolDescriptor] {
        tools.values.map(\.descriptor).sorted { $0.name < $1.name }
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        let entry = tools[request.tool]
        do {
            try await audit.append(AuditEvent(request: request, risk: entry?.descriptor.risk, phase: .started))
        } catch {
            return auditFailure(request, mayHaveExecuted: false)
        }

        let result: ToolResult
        do {
            try Task.checkCancellation()
            guard let entry else {
                throw ToolFailure(code: .unknownTool, message: "The requested capability is not registered.")
            }
            if entry.descriptor.risk != .read {
                try await approvals.authorize(request, descriptor: entry.descriptor)
            }
            for permission in entry.descriptor.permissions {
                guard await permissions.isGranted(permission) else {
                    throw ToolFailure(code: .permissionRequired,
                                      message: "Grant the required permission in the Mac app, then retry.",
                                      details: ["permission": .string(permission.rawValue)])
                }
            }
            try Task.checkCancellation()
            result = ToolResult(request: request, data: try await entry.run(request.arguments))
        } catch let error as ToolFailure {
            result = ToolResult(request: request, error: error)
        } catch is CancellationError {
            result = ToolResult(request: request, error: ToolFailure(code: .cancelled, message: "The request was cancelled."))
        } catch {
            // Unexpected native errors can contain user data. Do not forward their descriptions.
            result = ToolResult(request: request, error: ToolFailure(code: .executionFailed, message: "The tool could not complete."))
        }

        do {
            try await audit.append(AuditEvent(request: request, risk: entry?.descriptor.risk,
                                              phase: .completed, result: result))
        } catch {
            return auditFailure(request, mayHaveExecuted: true)
        }
        return result
    }

    private func auditFailure(_ request: ToolRequest, mayHaveExecuted: Bool) -> ToolResult {
        ToolResult(request: request, error: ToolFailure(
            code: .auditUnavailable, message: "The audit log could not be written. Do not automatically retry.",
            details: ["may_have_executed": .bool(mayHaveExecuted)]
        ))
    }
}
