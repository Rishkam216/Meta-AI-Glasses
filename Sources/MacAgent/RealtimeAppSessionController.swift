import AgentCore
import AppKit
import Foundation
import MacRuntime

private enum RealtimeAppSessionError: Error, LocalizedError {
    case notReady
    case missingCredential
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "The realtime agent runtime is not ready yet."
        case .missingCredential:
            return "Enter an OpenAI API key for this app session first."
        case .invalidCredential:
            return "The API key is empty or contains whitespace/control characters."
        }
    }
}

private actor EphemeralRealtimeCredentialVault {
    private var credential: String?

    func replace(with value: String) throws {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 8 * 1_024,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 0x20
              }) else {
            throw RealtimeAppSessionError.invalidCredential
        }
        credential = value
    }

    func bearerToken() throws -> String {
        guard let credential else {
            throw RealtimeAppSessionError.missingCredential
        }
        return credential
    }

    func hasCredential() -> Bool {
        credential != nil
    }

    func clear() {
        credential = nil
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
/// The principal/session/device identity are trusted application state and never
/// accepted from provider/model events. The OpenAI credential is intentionally
/// ephemeral for this development slice: it stays only in this process and is
/// cleared when the app exits or the user replaces it.
actor RealtimeAppSessionController {
    private let approvals = ApprovalStore()
    private let credentialVault = EphemeralRealtimeCredentialVault()
    private let devices = DeviceRouter()
    private let contextStore = InMemoryContextService()
    private let deviceIdentity: DeviceIdentity
    private let invocation: AgentInvocationContext

    private var runtime: ToolRuntime?
    private var coordinator: RealtimeCoordinator?
    private var provider: OpenAIRealtimeProvider?
    private var liveProviderSession: (any RealtimeModelSession)?

    init() {
        let identity = DeviceIdentity(displayName: "This Mac", platform: "macOS")
        deviceIdentity = identity
        invocation = AgentInvocationContext(
            principal: TenantContext(tenantID: UUID(), userID: UUID()),
            session: AgentSession(activeDeviceID: identity.id),
            interfaceID: UUID()
        )
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
        provider = try MacRuntimeFactory.makeOpenAIRealtimeProvider {
            try await self.credentialVault.bearerToken()
        }
        self.runtime = runtime
    }

    func setCredential(_ value: String) async throws {
        try await credentialVault.replace(with: value)
        if let liveProviderSession {
            await liveProviderSession.close()
            self.liveProviderSession = nil
        }
    }

    func hasCredential() async -> Bool {
        await credentialVault.hasCredential()
    }

    func run(text: String) async throws -> RealtimeTurnResult {
        guard let coordinator, let provider else {
            throw RealtimeAppSessionError.notReady
        }
        guard await credentialVault.hasCredential() else {
            throw RealtimeAppSessionError.missingCredential
        }

        let session: any RealtimeModelSession
        if let liveProviderSession {
            session = liveProviderSession
        } else {
            session = try await provider.openSession(agentSessionID: invocation.session.id)
            liveProviderSession = session
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
        await credentialVault.clear()
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
