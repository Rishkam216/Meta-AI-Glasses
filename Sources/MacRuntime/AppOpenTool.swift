import AgentCore
import AppKit
import Foundation

public struct AppOpenInput: Codable, Sendable, Equatable {
    public let bundleIdentifier: String

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier = "bundle_identifier"
    }

    public init(bundleIdentifier: String) throws {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              bundleIdentifier.utf8.count <= 512,
              !bundleIdentifier.contains("\n"),
              !bundleIdentifier.contains("\r") else {
            throw ToolFailure(
                code: .invalidArguments,
                message: "A valid application bundle identifier is required."
            )
        }
        self.bundleIdentifier = bundleIdentifier
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let object = try container.decode([String: JSONValue].self)
        guard object.count == 1,
              case .string(let bundleIdentifier)? = object["bundle_identifier"] else {
            throw ToolFailure(
                code: .invalidArguments,
                message: "Only bundle_identifier is accepted."
            )
        }
        try self.init(bundleIdentifier: bundleIdentifier)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
    }
}

public struct AppOpenOutput: Codable, Sendable, Equatable {
    public let bundleIdentifier: String
    public let opened: Bool

    public init(bundleIdentifier: String, opened: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.opened = opened
    }
}

public struct AppOpenTool: Tool {
    public let descriptor = ToolDescriptor(
        name: "app.open",
        summary: "Open an installed macOS application by bundle identifier.",
        risk: .reversibleWrite,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "bundle_identifier": .object([
                    "type": .string("string"),
                    "maxLength": .integer(512)
                ])
            ]),
            "required": .array([.string("bundle_identifier")]),
            "additionalProperties": .bool(false)
        ])
    )

    private let open: @MainActor @Sendable (String) async -> Bool

    public init() {
        open = { bundleIdentifier in
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ) else {
                return false
            }

            let configuration = NSWorkspace.OpenConfiguration()
            return await withCheckedContinuation { continuation in
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: configuration
                ) { application, error in
                    continuation.resume(returning: application != nil && error == nil)
                }
            }
        }
    }

    // Internal deterministic seam: native CI never needs to launch a real app.
    init(open: @escaping @MainActor @Sendable (String) async -> Bool) {
        self.open = open
    }

    public func execute(_ input: AppOpenInput) async throws -> AppOpenOutput {
        guard await open(input.bundleIdentifier) else {
            throw ToolFailure(
                code: .unavailable,
                message: "The requested application could not be opened.",
                retryable: false
            )
        }
        return AppOpenOutput(bundleIdentifier: input.bundleIdentifier, opened: true)
    }
}
