import Foundation

public enum AgentCapabilityEffect: String, Codable, Sendable, Equatable {
    case read
    case action
}

public struct AgentCapabilityDescriptor: Codable, Sendable, Equatable {
    public let name: String
    public let summary: String
    public let effect: AgentCapabilityEffect
    public let inputSchema: JSONValue

    public init(name: String,
                summary: String,
                effect: AgentCapabilityEffect,
                inputSchema: JSONValue) {
        self.name = name
        self.summary = summary
        self.effect = effect
        self.inputSchema = inputSchema
    }
}

public struct ResolvedAgentCapability: Sendable, Equatable {
    public let executorTool: String
    public let arguments: JSONValue

    public init(executorTool: String, arguments: JSONValue) {
        self.executorTool = executorTool
        self.arguments = arguments
    }
}

public enum AgentCapabilityResolutionError: Error, Sendable, Equatable {
    case unknownCapability(String)
    case invalidArguments(String)
}

public protocol AgentCapabilityResolving: Sendable {
    func catalog() -> [AgentCapabilityDescriptor]
    func executorTool(for capability: String) throws -> String
    func resolve(name: String, arguments: JSONValue) throws -> ResolvedAgentCapability
}

/// Small provider-neutral semantic capability surface for the first Mac control
/// milestone. Native tool names remain behind this resolver.
public struct DefaultAgentCapabilityRegistry: AgentCapabilityResolving {
    public init() {}

    public func catalog() -> [AgentCapabilityDescriptor] {
        [
            AgentCapabilityDescriptor(
                name: "computer.inspect",
                summary: "Inspect the currently active application on the selected computer.",
                effect: .read,
                inputSchema: EmptyInput.schema
            ),
            AgentCapabilityDescriptor(
                name: "computer.open_app",
                summary: "Open an installed application on the selected computer.",
                effect: .action,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "application_id": .object([
                            "type": .string("string"),
                            "maxLength": .integer(512)
                        ])
                    ]),
                    "required": .array([.string("application_id")]),
                    "additionalProperties": .bool(false)
                ])
            )
        ]
    }

    public func executorTool(for capability: String) throws -> String {
        switch capability {
        case "computer.inspect":
            return "ui.get_frontmost_app"
        case "computer.open_app":
            return "app.open"
        default:
            throw AgentCapabilityResolutionError.unknownCapability(capability)
        }
    }

    public func resolve(name: String, arguments: JSONValue) throws -> ResolvedAgentCapability {
        switch name {
        case "computer.inspect":
            guard case .object(let object) = arguments, object.isEmpty else {
                throw AgentCapabilityResolutionError.invalidArguments(name)
            }
            return ResolvedAgentCapability(
                executorTool: "ui.get_frontmost_app",
                arguments: .object([:])
            )

        case "computer.open_app":
            guard case .object(let object) = arguments,
                  object.count == 1,
                  case .string(let applicationID)? = object["application_id"] else {
                throw AgentCapabilityResolutionError.invalidArguments(name)
            }
            let trimmed = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  applicationID.utf8.count <= 512,
                  !applicationID.contains("\n"),
                  !applicationID.contains("\r") else {
                throw AgentCapabilityResolutionError.invalidArguments(name)
            }
            return ResolvedAgentCapability(
                executorTool: "app.open",
                arguments: .object([
                    "bundle_identifier": .string(applicationID)
                ])
            )

        default:
            throw AgentCapabilityResolutionError.unknownCapability(name)
        }
    }
}
