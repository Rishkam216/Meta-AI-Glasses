import AgentCore
import Foundation

public enum MacRuntimeFactory {
    public static var auditDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MetaAIGlasses", isDirectory: true)
    }

    public static func makeAgentSessionStore() -> KeychainAgentSessionStore {
        KeychainAgentSessionStore()
    }

    public static func makeAuthExchangeClient(endpoint: URL,
                                              credentialStore: KeychainAgentSessionStore) throws -> AuthExchangeClient {
        try AuthExchangeClient(endpoint: endpoint, credentialStore: credentialStore)
    }

    /// Memory uses only our opaque agent session loaded from Keychain. It never
    /// receives a Supabase access token.
    public static func makeAuthenticatedMemoryStore(endpoint: URL,
                                                    credentialStore: KeychainAgentSessionStore) throws -> HTTPMemorySnapshotStore {
        try HTTPMemorySnapshotStore(endpoint: endpoint) {
            try await credentialStore.bearerToken()
        }
    }

    /// Provider credentials are supplied just-in-time by trusted app/backend
    /// composition. The realtime adapter never writes them to disk or Keychain.
    public static func makeOpenAIRealtimeProvider(
        model: String = "gpt-realtime-2.1",
        credentialProvider: @escaping OpenAIRealtimeProvider.CredentialProvider
    ) throws -> OpenAIRealtimeProvider {
        try OpenAIRealtimeProvider(
            model: model,
            credentialProvider: credentialProvider
        )
    }

    /// Production remains deny-by-default until a trusted local approval UI is
    /// wired. Tests or the future app composition root may inject ApprovalStore.
    public static func make(approvals: any ApprovalAuthorizing = DenyAllApprovals()) async throws -> ToolRuntime {
        let directory = auditDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ToolFailure(code: .auditUnavailable, message: "Audit directory is not a regular directory.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let log = try FileAuditLog(url: directory.appendingPathComponent("audit.jsonl"))
        let runtime = ToolRuntime(audit: log, permissions: MacPermissions(), approvals: approvals)
        try await runtime.register(FrontmostAppTool())
        try await runtime.register(AppOpenTool())
        return runtime
    }
}
