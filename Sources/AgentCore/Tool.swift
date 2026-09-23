import Foundation

public enum RiskLevel: String, Codable, Sendable {
    case read
    case reversibleWrite = "reversible_write"
    case externalEffect = "external_effect"
    case highRisk = "high_risk"
}

public enum Permission: String, Codable, Sendable {
    case accessibility
    case screenRecording = "screen_recording"
}

public struct ToolDescriptor: Codable, Sendable {
    public let name: String
    public let summary: String
    public let risk: RiskLevel
    public let permissions: [Permission]
    public let inputSchema: JSONValue

    public init(name: String, summary: String, risk: RiskLevel,
                permissions: [Permission] = [], inputSchema: JSONValue) {
        self.name = name
        self.summary = summary
        self.risk = risk
        self.permissions = permissions
        self.inputSchema = inputSchema
    }
}

public protocol Tool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable
    var descriptor: ToolDescriptor { get }
    func execute(_ input: Input) async throws -> Output
}

public struct RequestContext: Codable, Sendable, Equatable {
    public let deviceID: UUID
    public let sessionID: UUID

    public init(deviceID: UUID, sessionID: UUID) {
        self.deviceID = deviceID
        self.sessionID = sessionID
    }
}

public struct ToolRequest: Codable, Sendable {
    public let id: UUID
    public let tool: String
    public let arguments: JSONValue
    public let context: RequestContext?
    public let approvalID: UUID?

    public init(id: UUID = UUID(), tool: String, arguments: JSONValue = .object([:]),
                context: RequestContext? = nil, approvalID: UUID? = nil) {
        self.id = id
        self.tool = tool
        self.arguments = arguments
        self.context = context
        self.approvalID = approvalID
    }
}

/// Empty input rejects unexpected arguments instead of silently ignoring them.
public struct EmptyInput: Codable, Sendable {
    public init() {}
    public init(from decoder: any Decoder) throws {
        let values = try decoder.singleValueContainer().decode([String: JSONValue].self)
        guard values.isEmpty else {
            throw ToolFailure(code: .invalidArguments, message: "This tool accepts no arguments.")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode([String: JSONValue]())
    }
    public static let schema: JSONValue = .object([
        "type": .string("object"), "properties": .object([:]),
        "additionalProperties": .bool(false)
    ])
}

public enum ErrorCode: String, Codable, Sendable {
    case unknownTool = "unknown_tool"
    case invalidArguments = "invalid_arguments"
    case permissionRequired = "permission_required"
    case approvalRequired = "approval_required"
    case unavailable
    case cancelled
    case executionFailed = "execution_failed"
    case auditUnavailable = "audit_unavailable"
}

public struct ToolFailure: Error, Codable, Sendable, Equatable {
    public let code: ErrorCode
    public let message: String
    public let retryable: Bool
    public let details: [String: JSONValue]

    public init(code: ErrorCode, message: String, retryable: Bool = false,
                details: [String: JSONValue] = [:]) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }
}

/// Built internally so success/error payload combinations cannot be forged by callers.
public struct ToolResult: Encodable, Sendable {
    public enum Status: String, Codable, Sendable { case success, error }
    public let protocolVersion = 1
    public let requestID: UUID
    public let tool: String
    public let status: Status
    public let data: JSONValue?
    public let error: ToolFailure?

    init(request: ToolRequest, data: JSONValue) {
        requestID = request.id; tool = request.tool
        status = .success; self.data = data; error = nil
    }
    init(request: ToolRequest, error: ToolFailure) {
        requestID = request.id; tool = request.tool
        status = .error; data = nil; self.error = error
    }

    public func json(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }
}
