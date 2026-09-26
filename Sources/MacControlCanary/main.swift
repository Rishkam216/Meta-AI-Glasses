import AgentCore
import Darwin
import Foundation
import MacRuntime

private enum CanaryError: Error { case stopped }

/// This diagnostic never loads user memory or impersonates a backend account.
/// Its random principal is confined to a fresh in-memory context store.
@main
private struct MacControlCanary {
    static func main() async {
        guard CommandLine.arguments == [CommandLine.arguments[0], "--allow-live-calculator"] else {
            print("Manual macOS diagnostic. Run with --allow-live-calculator to opt into one paid text turn and a separately approved Calculator launch.")
            return
        }
        do {
            print("No network until confirmation. No retries. Calculator only. After connection, a 90-second turn deadline includes local approval.")
            let consent = try await terminalLine(prompt: "Type START to connect to OpenAI: ", secret: false)
            guard consent == "START" else { throw CanaryError.stopped }
            let credential = try await terminalLine(prompt: "Paste short-lived Realtime client secret (hidden; not an API key): ", secret: true)
            guard credential.hasPrefix("ek_"), credential.utf8.count <= 8_192,
                  !credential.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 || $0.value == 127 }) else {
                throw CanaryError.stopped
            }
            try await run(credential: credential)
        } catch {
            // Never print provider errors, model text, credentials, or arguments.
            print("MAC_CONTROL_CANARY_STOPPED: no automatic retry; if Calculator opened, it remains open.")
            exit(1)
        }
    }

    private static func run(credential: String) async throws {
        let approvals = ApprovalStore()
        let native = OneShotCalculator()
        let runtime = ToolRuntime(audit: CanaryAudit(), permissions: NoPermissions(), approvals: approvals)
        try await runtime.register(native)
        let device = DeviceIdentity(displayName: "Local Calculator diagnostic", platform: "macOS")
        let router = DeviceRouter()
        try await router.register(RuntimeDeviceExecutor(identity: device, runtime: runtime))
        let orchestrator = AgentOrchestrator(
            devices: router,
            decisions: DecisionEngine(boundedProvider: NoDeviceSelection()),
            contextCompiler: ContextCompiler(store: InMemoryContextService())
        )
        let broker = LocalApprovalBroker(approvals: approvals) { request in
            guard request.descriptor.name == "app.open",
                  request.arguments == .object(["bundle_identifier": .string("com.apple.calculator")]),
                  request.context.deviceID == device.id else { return false }
            print("LOCAL APPROVAL: app.open; bundle_identifier=com.apple.calculator; this Mac; once.")
            return (try? await terminalLine(prompt: "Type ALLOW CALCULATOR to approve; anything else denies: ", secret: false)) == "ALLOW CALCULATOR"
        }
        let coordinator = RealtimeCoordinator(orchestrator: orchestrator, approvalProvider: broker)
        let invocation = AgentInvocationContext(
            principal: TenantContext(tenantID: UUID(), userID: UUID()),
            session: AgentSession(activeDeviceID: device.id)
        )
        let provider = try OpenAIRealtimeProvider(credentialProvider: { credential })
        // Connection has its own production handshake timeout. The deadline below
        // closes an already-open socket to unblock a stalled provider read.
        let session = BoundedSession(underlying: try await provider.openSession(agentSessionID: invocation.session.id))
        do {
            let result = try await withThrowingTaskGroup(of: RealtimeTurnResult.self) { group in
                group.addTask {
                    try await coordinator.runTurn(
                        try RealtimeTurnRequest(text: "Open Calculator (application_id com.apple.calculator) exactly once using computer.open_app. Do not retry. After the tool result, reply in at most five words."),
                        in: invocation, using: session
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(90))
                    await native.stop()
                    await session.close()
                    throw CanaryError.stopped
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CanaryError.stopped }
                return result
            }
            await native.stop()
            await session.close()
            guard result.toolResults.count == 1, let tool = result.toolResults.first else {
                throw CanaryError.stopped
            }
            if tool.status == "success", await native.succeeded {
                print("MAC_CONTROL_CANARY_OK: native Calculator launch succeeded and its result was sent to the model; turn completed.")
            } else if tool.error?.code == .approvalRequired, await native.attempts == 0 {
                print("MAC_CONTROL_CANARY_DENIED: no native launch; denial sent to the model; turn completed.")
            } else {
                throw CanaryError.stopped
            }
        } catch {
            await native.stop()
            await session.close()
            throw error
        }
    }
}

/// Defense in depth after exact approval: no other bundle and never a second
/// native launch, even if the model changes event IDs or the adapter replays.
private actor OneShotCalculator: Tool {
    nonisolated let descriptor = AppOpenTool().descriptor
    private(set) var attempts = 0
    private(set) var succeeded = false
    private var stopped = false

    func stop() { stopped = true }

    func execute(_ input: AppOpenInput) async throws -> AppOpenOutput {
        try Task.checkCancellation()
        guard !stopped, attempts == 0, input.bundleIdentifier == "com.apple.calculator" else {
            throw ToolFailure(code: .unavailable, message: "Calculator diagnostic is closed.")
        }
        attempts += 1
        let output = try await AppOpenTool().execute(input)
        succeeded = output.opened
        return output
    }
}

private actor BoundedSession: RealtimeModelSession {
    nonisolated let id: UUID
    private let underlying: any RealtimeModelSession
    private var events = 0
    private var tools = 0
    private var textBytes = 0
    private var results = 0
    private var turns = 0
    private var contexts = 0

    init(underlying: any RealtimeModelSession) { self.underlying = underlying; id = underlying.id }
    func send(_ event: RealtimeClientEvent) async throws {
        switch event {
        case .userText:
            guard turns == 0 else { throw CanaryError.stopped }
            turns += 1
        case .turnContext:
            guard contexts == 0 else { throw CanaryError.stopped }
            contexts += 1
        case .toolResult:
            guard results == 0 else { throw CanaryError.stopped }
            results += 1
        case .cancel: break
        }
        try await underlying.send(event)
    }
    func nextEvent() async throws -> RealtimeProviderEvent? {
        guard events < 32 else { throw CanaryError.stopped }
        events += 1
        guard let event = try await underlying.nextEvent() else { return nil }
        switch event {
        case .toolIntent(let intent):
            guard tools == 0, intent.tool == "computer.open_app",
                  intent.arguments == .object(["application_id": .string("com.apple.calculator")]) else {
                throw CanaryError.stopped
            }
            tools += 1
        case .assistantText(let message):
            textBytes += message.text.utf8.count
            guard textBytes <= 2_048 else { throw CanaryError.stopped }
        default: break
        }
        return event
    }
    func cancel(turnID: UUID) async { await underlying.cancel(turnID: turnID) }
    func close() async { await underlying.close() }
}

private struct NoPermissions: PermissionChecking {
    func isGranted(_ permission: Permission) async -> Bool { false }
}

private struct NoDeviceSelection: DecisionProvider {
    let providerID = "diagnostic-explicit-device-only"
    func decide(_ request: DecisionRequest) async throws -> ProviderDecision { throw CanaryError.stopped }
}

/// Ephemeral metadata only; no user data, model text or credentials are persisted.
private struct CanaryAudit: AuditSink {
    func append(_ event: AuditEvent) async throws {
        print(event.phase == .started ? "MAC_CONTROL_ACTION_STARTED" : "MAC_CONTROL_ACTION_FINISHED")
    }
}

/// Require a controlling terminal (no pipe / CI autoapproval). Polling makes the
/// local approval cancellation-aware; echo is restored on every ordinary exit.
private func terminalLine(prompt: String, secret: Bool) async throws -> String {
    let fd = open("/dev/tty", O_RDWR | O_CLOEXEC)
    guard fd >= 0 else { throw CanaryError.stopped }
    defer { close(fd) }
    var original = termios()
    guard tcgetattr(fd, &original) == 0 else { throw CanaryError.stopped }
    if secret {
        var hidden = original
        hidden.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(fd, TCSAFLUSH, &hidden) == 0 else { throw CanaryError.stopped }
    }
    defer {
        if secret { _ = tcsetattr(fd, TCSAFLUSH, &original); _ = write(fd, "\n", 1) }
    }
    // Drop queued input so a previous paste cannot pre-approve a model action.
    _ = tcflush(fd, TCIFLUSH)
    _ = prompt.withCString { write(fd, $0, prompt.utf8.count) }
    var bytes: [UInt8] = []
    while bytes.count <= 8_192 {
        try Task.checkCancellation()
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 0)
        if ready < 0 {
            if errno == EINTR { continue }
            throw CanaryError.stopped
        }
        if ready == 0 {
            try await Task.sleep(for: .milliseconds(100))
            continue
        }
        guard descriptor.revents & Int16(POLLIN) != 0 else { throw CanaryError.stopped }
        var byte: UInt8 = 0
        guard read(fd, &byte, 1) == 1 else { throw CanaryError.stopped }
        if byte == 10 || byte == 13 { return String(decoding: bytes, as: UTF8.self) }
        bytes.append(byte)
    }
    throw CanaryError.stopped
}
