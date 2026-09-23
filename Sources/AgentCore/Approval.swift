import Foundation

public struct ApprovalGrant: Sendable, Equatable {
    public let id: UUID
    public let expiresAt: Date

    init(id: UUID, expiresAt: Date) {
        self.id = id
        self.expiresAt = expiresAt
    }
}

public enum ApprovalIssueError: Error, Equatable {
    case readOnlyTool
    case invalidTTL
}

public protocol ApprovalAuthorizing: Sendable {
    func authorize(_ request: ToolRequest, descriptor: ToolDescriptor) async throws
}

/// Default policy when no trusted local approval issuer has been wired in.
public struct DenyAllApprovals: ApprovalAuthorizing {
    public init() {}

    public func authorize(_ request: ToolRequest, descriptor: ToolDescriptor) async throws {
        throw ToolFailure(
            code: .approvalRequired,
            message: "This action requires a fresh local approval."
        )
    }
}

/// Ephemeral bearer approvals issued only by trusted local UI code.
/// Grants are bound to one device/session, exact tool, risk, and immutable JSON arguments.
/// Presenting a grant consumes it even if the binding is wrong, preventing replay/probing.
public actor ApprovalStore: ApprovalAuthorizing {
    private struct Record: Sendable {
        let tool: String
        let risk: RiskLevel
        let arguments: JSONValue
        let context: RequestContext
        let expiresAt: Date
    }

    private var records: [UUID: Record] = [:]
    private let maxTTL: TimeInterval
    private let now: @Sendable () -> Date

    public init(maxTTL: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.maxTTL = maxTTL
        self.now = now
    }

    public func issue(descriptor: ToolDescriptor, arguments: JSONValue,
                      context: RequestContext, ttl: TimeInterval = 30) throws -> ApprovalGrant {
        guard descriptor.risk != .read else { throw ApprovalIssueError.readOnlyTool }
        guard ttl > 0, ttl <= maxTTL else { throw ApprovalIssueError.invalidTTL }

        let id = UUID()
        let expiresAt = now().addingTimeInterval(ttl)
        records[id] = Record(tool: descriptor.name, risk: descriptor.risk,
                             arguments: arguments, context: context, expiresAt: expiresAt)
        return ApprovalGrant(id: id, expiresAt: expiresAt)
    }

    public func revoke(_ id: UUID) {
        records.removeValue(forKey: id)
    }

    public func authorize(_ request: ToolRequest, descriptor: ToolDescriptor) async throws {
        guard descriptor.risk != .read else { return }
        guard let approvalID = request.approvalID, let context = request.context else {
            throw approvalRequired()
        }
        guard let record = records.removeValue(forKey: approvalID) else {
            throw approvalRequired()
        }
        guard record.expiresAt > now(),
              record.tool == descriptor.name,
              record.risk == descriptor.risk,
              record.arguments == request.arguments,
              record.context == context else {
            throw approvalRequired()
        }
    }

    private func approvalRequired() -> ToolFailure {
        ToolFailure(code: .approvalRequired,
                    message: "This action requires a fresh local approval.")
    }
}
