import Foundation

public enum RealtimeValidationError: Error, Sendable, Equatable {
    case invalidText
    case textTooLarge
    case invalidToolName
    case argumentsTooLarge
    case invalidFailureCode
}

public enum RealtimeProtocolError: Error, Sendable, Equatable {
    case providerClosed
    case wrongTurn
    case duplicateEventMismatch
    case toolCallLimitExceeded
    case providerEventLimitExceeded
    case assistantTextLimitExceeded
    case providerFailure(String)
}

public enum RealtimeLimits {
    public static let maxTextBytes = 64 * 1_024
    public static let maxToolArgumentBytes = 256 * 1_024
    public static let maxToolCallsPerTurn = 8
    public static let maxCapabilities = 32
    public static let maxProviderEventsPerTurn = 256
    public static let maxAssistantTextBytesPerTurn = 64 * 1_024
}

/// Trusted application-origin turn request. Identity is intentionally absent:
/// TenantContext comes from AgentInvocationContext, never provider/model payloads.
public struct RealtimeTurnRequest: Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let explicitDeviceID: UUID?
    public let memoryQuery: MemoryContextQuery?

    public init(id: UUID = UUID(),
                text: String,
                explicitDeviceID: UUID? = nil,
                memoryQuery: MemoryContextQuery? = nil) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RealtimeValidationError.invalidText }
        guard text.utf8.count <= RealtimeLimits.maxTextBytes else {
            throw RealtimeValidationError.textTooLarge
        }
        self.id = id
        self.text = text
        self.explicitDeviceID = explicitDeviceID
        self.memoryQuery = memoryQuery
    }
}

/// Provider-facing context deliberately contains no tenant/user/account identity
/// and advertises semantic capabilities rather than native executor tool names.
public struct RealtimeTurnContext: Codable, Sendable, Equatable {
    public let turnID: UUID
    public let context: CompiledContext
    public let capabilities: [AgentCapabilityDescriptor]

    public init(turnID: UUID,
                context: CompiledContext,
                capabilities: [AgentCapabilityDescriptor] = []) {
        self.turnID = turnID
        self.context = context
        self.capabilities = Array(capabilities.prefix(RealtimeLimits.maxCapabilities))
    }
}

public struct RealtimeUserText: Codable, Sendable, Equatable {
    public let turnID: UUID
    public let text: String

    public init(turnID: UUID, text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RealtimeValidationError.invalidText }
        guard text.utf8.count <= RealtimeLimits.maxTextBytes else {
            throw RealtimeValidationError.textTooLarge
        }
        self.turnID = turnID
        self.text = text
    }
}

/// Model/provider-generated semantic capability intent. It cannot carry tenant
/// identity, approval IDs, session IDs, or authoritative device identity.
public struct RealtimeToolIntent: Codable, Sendable, Equatable {
    public let eventID: UUID
    public let turnID: UUID
    public let tool: String
    public let arguments: JSONValue

    public init(eventID: UUID = UUID(),
                turnID: UUID,
                tool: String,
                arguments: JSONValue = .object([:])) throws {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, tool.utf8.count <= 256 else {
            throw RealtimeValidationError.invalidToolName
        }
        let encoded = try JSONEncoder().encode(arguments)
        guard encoded.count <= RealtimeLimits.maxToolArgumentBytes else {
            throw RealtimeValidationError.argumentsTooLarge
        }
        self.eventID = eventID
        self.turnID = turnID
        self.tool = tool
        self.arguments = arguments
    }
}

public struct RealtimeAssistantText: Codable, Sendable, Equatable {
    public let eventID: UUID
    public let turnID: UUID
    public let text: String

    public init(eventID: UUID = UUID(), turnID: UUID, text: String) throws {
        guard text.utf8.count <= RealtimeLimits.maxTextBytes else {
            throw RealtimeValidationError.textTooLarge
        }
        self.eventID = eventID
        self.turnID = turnID
        self.text = text
    }
}

public struct RealtimeToolResult: Codable, Sendable, Equatable {
    public let sourceEventID: UUID
    public let turnID: UUID
    public let requestID: UUID
    /// Semantic capability name exposed to the provider, not the native tool name.
    public let tool: String
    public let status: String
    public let data: JSONValue?
    public let error: ToolFailure?

    public init(sourceEventID: UUID,
                turnID: UUID,
                result: ToolResult,
                reportedTool: String? = nil) {
        self.sourceEventID = sourceEventID
        self.turnID = turnID
        self.requestID = result.requestID
        self.tool = reportedTool ?? result.tool
        self.status = result.status.rawValue
        self.data = result.data
        self.error = result.error
    }
}

public struct RealtimeTurnCompleted: Codable, Sendable, Equatable {
    public let eventID: UUID
    public let turnID: UUID

    public init(eventID: UUID = UUID(), turnID: UUID) {
        self.eventID = eventID
        self.turnID = turnID
    }
}

public struct RealtimeProviderFailure: Codable, Sendable, Equatable {
    public let eventID: UUID
    public let turnID: UUID?
    public let code: String
    public let retryable: Bool

    public init(eventID: UUID = UUID(), turnID: UUID? = nil,
                code: String, retryable: Bool = false) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, code.utf8.count <= 128 else {
            throw RealtimeValidationError.invalidFailureCode
        }
        self.eventID = eventID
        self.turnID = turnID
        self.code = code
        self.retryable = retryable
    }
}

public enum RealtimeClientEvent: Codable, Sendable, Equatable {
    case turnContext(RealtimeTurnContext)
    case userText(RealtimeUserText)
    case toolResult(RealtimeToolResult)
    case cancel(turnID: UUID)
}

public enum RealtimeProviderEvent: Codable, Sendable, Equatable {
    case assistantText(RealtimeAssistantText)
    case toolIntent(RealtimeToolIntent)
    case turnCompleted(RealtimeTurnCompleted)
    case failure(RealtimeProviderFailure)
}

/// Provider-specific websocket/audio event types remain behind this contract.
public protocol RealtimeModelSession: Sendable {
    var id: UUID { get }
    func send(_ event: RealtimeClientEvent) async throws
    func nextEvent() async throws -> RealtimeProviderEvent?
    func cancel(turnID: UUID) async
    func close() async
}

public protocol RealtimeModelProvider: Sendable {
    func openSession(agentSessionID: UUID) async throws -> any RealtimeModelSession
}

public struct RealtimeTurnResult: Sendable, Equatable {
    public let turnID: UUID
    public let assistantText: [String]
    public let toolResults: [RealtimeToolResult]

    public init(turnID: UUID,
                assistantText: [String],
                toolResults: [RealtimeToolResult]) {
        self.turnID = turnID
        self.assistantText = assistantText
        self.toolResults = toolResults
    }
}
