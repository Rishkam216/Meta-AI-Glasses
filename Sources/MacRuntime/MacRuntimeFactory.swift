import AgentCore
import Foundation

public enum MacRuntimeFactory {
    public static var auditDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MetaAIGlasses", isDirectory: true)
    }

    public static func make() async throws -> ToolRuntime {
        let directory = auditDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ToolFailure(code: .auditUnavailable, message: "Audit directory is not a regular directory.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let log = try FileAuditLog(url: directory.appendingPathComponent("audit.jsonl"))
        let runtime = ToolRuntime(audit: log, permissions: MacPermissions())
        try await runtime.register(FrontmostAppTool())
        return runtime
    }
}
