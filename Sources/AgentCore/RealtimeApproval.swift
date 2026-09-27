import Foundation

/// Exact, trusted action binding presented to local approval UI. The realtime
/// provider/model never constructs this value and never receives the grant ID.
public struct RealtimeApprovalRequest: Sendable {
    public let sourceEventID: UUID
    public let turnID: UUID
    public let descriptor: ToolDescriptor
    public let arguments: JSONValue
    public let context: RequestContext

    public init(sourceEventID: UUID,
                turnID: UUID,
                descriptor: ToolDescriptor,
                arguments: JSONValue,
                context: RequestContext) {
        self.sourceEventID = sourceEventID
        self.turnID = turnID
        self.descriptor = descriptor
        self.arguments = arguments
        self.context = context
    }
}

public protocol RealtimeApprovalProviding: Sendable {
    /// Returns a grant minted by trusted local/application code, or nil when the
    /// user declines/unavailable. Provider/model events cannot supply this ID.
    func requestApproval(_ request: RealtimeApprovalRequest) async throws -> UUID?
}

/// Bridges a trusted confirmation UI to the existing exact single-use
/// ApprovalStore. Confirmation is intentionally outside the model/provider path.
public struct LocalApprovalBroker: RealtimeApprovalProviding {
    private let approvals: ApprovalStore
    private let confirm: @Sendable (RealtimeApprovalRequest) async -> Bool
    private let ttl: TimeInterval

    public init(approvals: ApprovalStore,
                ttl: TimeInterval = 30,
                confirm: @escaping @Sendable (RealtimeApprovalRequest) async -> Bool) {
        self.approvals = approvals
        self.ttl = ttl
        self.confirm = confirm
    }

    public func requestApproval(_ request: RealtimeApprovalRequest) async throws -> UUID? {
        try Task.checkCancellation()
        guard request.descriptor.risk != .read else { return nil }
        let confirmed = await confirm(request)
        try Task.checkCancellation()
        guard confirmed else { return nil }
        let grant = try await approvals.issue(
            descriptor: request.descriptor,
            arguments: request.arguments,
            context: request.context,
            ttl: ttl
        )
        return grant.id
    }
}
