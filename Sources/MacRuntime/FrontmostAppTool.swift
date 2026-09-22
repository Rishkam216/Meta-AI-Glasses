import AgentCore
import AppKit

public struct FrontmostApp: Codable, Sendable, Equatable {
    public let processID: Int32
    public let bundleIdentifier: String?
    public let name: String?

    public init(processID: Int32, bundleIdentifier: String?, name: String?) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}

public struct FrontmostAppTool: Tool {
    public typealias Input = EmptyInput
    public let descriptor = ToolDescriptor(
        name: "ui.get_frontmost_app",
        summary: "Identify the application currently receiving keyboard events.",
        risk: .read,
        inputSchema: .object([
            "type": .string("object"), "properties": .object([:]),
            "additionalProperties": .bool(false)
        ])
    )
    private let read: @MainActor @Sendable () -> FrontmostApp?

    public init() {
        read = {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return FrontmostApp(processID: app.processIdentifier,
                                bundleIdentifier: app.bundleIdentifier,
                                name: app.localizedName)
        }
    }

    // Internal seam for deterministic tests; production always uses NSWorkspace.
    init(read: @escaping @MainActor @Sendable () -> FrontmostApp?) { self.read = read }

    public func execute(_ input: EmptyInput) async throws -> FrontmostApp {
        guard let app = await read() else {
            throw ToolFailure(code: .unavailable, message: "No foreground application is available.", retryable: true)
        }
        return app
    }
}
