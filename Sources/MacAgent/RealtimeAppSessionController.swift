import AgentCore
import AppKit
import Foundation
import MacRuntime

private enum RealtimeAppSessionError: Error, LocalizedError {
    case notReady
    case missingAgentSession
    case invalidBackendEndpoint

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "The realtime agent runtime is not ready yet."
        case .missingAgentSession:
            return "Sign in first. No valid agent session is available in Keychain."
        case .invalidBackendEndpoint:
            return "The configured Realtime credential endpoint is invalid."
        }
    }
}

private struct LocalSingleDeviceDecisionProvider: DecisionProvider {
    let providerID = "mac-local-single-device"

    func decide(_ request: DecisionRequest) async throws -> ProviderDecision {
        guard let first = request.options.first else {
            throw DecisionError.noOptions
        }
        return ProviderDecision(selectedOptionID: first.id, confidence: 1)
    }
}

/// Composition root for the first user-visible text realtime loop.
///
/// Identity is loaded from our Keychain-backed opaque agent session. The Mac
/// never stores or accepts the standard OpenAI API key; it retrieves a short-lived
/// Realtime credential from our authenticated backend when a provider session opens.
actor RealtimeAppSessionController {
    private let approvals = ApprovalStore()
    private let credentialStore = MacRuntimeFactory.makeAgentSessionStore()
    private let devices = DeviceRouter()
    private let contextStore = InMemoryContextService()
    private let deviceIdentity: DeviceIdentity
    private let agentSessionID = UUID()
    private let interfaceID = UUID()

    private var runtime: ToolRuntime?
    private var coordinator: RealtimeCoordinator?
    private var provider: OpenAIRealtimeProvider?
    private var liveProviderSession: (any RealtimeModelSession)?
    private var livePrincipal: TenantContext?

    init() {
        deviceIdentity = DeviceIdentity(displayName: "This Mac", platform: "macOS")
    }

    func start() async throws {
        guard runtime == nil else { return }

        let runtime = try await MacRuntimeFactory.make(approvals: approvals)
        try await devices.register(RuntimeDeviceExecutor(identity: deviceIdentity, runtime: runtime))

        let orchestrator = AgentOrchestrator(
            devices: devices,
            decisions: DecisionEngine(boundedProvider: LocalSingleDeviceDecisionProvider()),
            contextCompiler: ContextCompiler(store: contextStore)
        )

        let approvalBroker = LocalApprovalBroker(approvals: approvals) { request in
            await MainActor.run {
                LocalRealtimeApprovalUI.confirm(request)
            }
        }

        coordinator = RealtimeCoordinator(
            orchestrator: orchestrator,
            approvalProvider: approvalBroker
        )

        guard let endpoint = Self.realtimeCredentialEndpoint() else {
            throw RealtimeAppSessionError.invalidBackendEndpoint
        }
        provider = try MacRuntimeFactory.makeAuthenticatedOpenAIRealtimeProvider(
            credentialEndpoint: endpoint,
            credentialStore: credentialStore
        )
        self.runtime = runtime
    }

    func hasAgentSession() async -> Bool {
        (try? await credentialStore.load()) != nil
    }

    func run(text: String) async throws -> RealtimeTurnResult {
        guard let coordinator, let provider else {
            throw RealtimeAppSessionError.notReady
        }

        let credential: AgentSessionCredential
        do {
            guard let loaded = try await credentialStore.load() else {
                throw RealtimeAppSessionError.missingAgentSession
            }
            credential = loaded
        } catch is AgentSessionCredentialError {
            throw RealtimeAppSessionError.missingAgentSession
        }

        if livePrincipal != nil, livePrincipal != credential.identity {
            if let liveProviderSession {
                await liveProviderSession.close()
            }
            liveProviderSession = nil
            livePrincipal = nil
        }

        let invocation = AgentInvocationContext(
            principal: credential.identity,
            session: AgentSession(id: agentSessionID, activeDeviceID: deviceIdentity.id),
            interfaceID: interfaceID
        )

        let session: any RealtimeModelSession
        if let liveProviderSession {
            session = liveProviderSession
        } else {
            session = try await provider.openSession(agentSessionID: agentSessionID)
            liveProviderSession = session
            livePrincipal = credential.identity
        }

        do {
            return try await coordinator.runTurn(
                try RealtimeTurnRequest(text: text),
                in: invocation,
                using: session
            )
        } catch {
            await session.close()
            liveProviderSession = nil
            livePrincipal = nil
            throw error
        }
    }

    func inspectFrontmost() async -> ToolResult? {
        guard let runtime else { return nil }
        return await runtime.execute(ToolRequest(tool: "ui.get_frontmost_app"))
    }

    func close() async {
        if let liveProviderSession {
            await liveProviderSession.close()
        }
        liveProviderSession = nil
        livePrincipal = nil
    }

    private static func realtimeCredentialEndpoint() -> URL? {
        let configured = ProcessInfo.processInfo.environment["AGENT_REALTIME_CREDENTIAL_ENDPOINT"]
            ?? "http://127.0.0.1:8787/v1/realtime/credential"
        return URL(string: configured)
    }
}

@MainActor
private enum LocalRealtimeApprovalUI {
    static func confirm(_ request: RealtimeApprovalRequest) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow this Mac action once?"
        alert.informativeText = "Tool: \(request.descriptor.name)\n\nArguments:\n\(formatted(request.arguments))"
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Deny")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func formatted(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return "(unavailable)"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
