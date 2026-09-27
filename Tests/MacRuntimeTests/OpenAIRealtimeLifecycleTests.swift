import Foundation
import Testing
@testable import AgentCore
@testable import MacRuntime

private enum LifecycleConnectError: Error { case failed }

/// Blocked operations deliberately ignore Task cancellation. Only close()
/// releases them, matching transports that need explicit socket shutdown.
private actor LifecycleTransport: OpenAIRealtimeTransport {
    enum Mode: Sendable {
        case immediate(String?)
        case failedConnect
        case blockedConnect
        case blockedReceive(replyOnClose: String?)
    }

    private let mode: Mode
    private var closed = false
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectWaiter: CheckedContinuation<Void, Never>?
    private var receiveWaiter: CheckedContinuation<String?, Never>?
    private(set) var closeCount = 0
    private(set) var receiveCount = 0

    init(_ mode: Mode) { self.mode = mode }

    func connect(_ request: URLRequest) async throws {
        switch mode {
        case .failedConnect:
            throw LifecycleConnectError.failed
        case .blockedConnect:
            guard !closed else { return }
            await withCheckedContinuation { continuation in
                connectWaiter = continuation
                signalSuspension()
            }
        default: break
        }
    }

    func send(text: String) {}

    func receive() async -> String? {
        receiveCount += 1
        switch mode {
        case .immediate(let reply): return reply
        case .blockedReceive(let reply):
            if closed { return reply }
            return await withCheckedContinuation { continuation in
                receiveWaiter = continuation
                signalSuspension()
            }
        default: return nil
        }
    }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    private func signalSuspension() {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func close() {
        closeCount += 1
        closed = true
        connectWaiter?.resume()
        connectWaiter = nil
        if case .blockedReceive(let reply) = mode {
            receiveWaiter?.resume(returning: reply)
            receiveWaiter = nil
        }
    }
}

private func lifecycleProvider(_ transport: LifecycleTransport) throws -> OpenAIRealtimeProvider {
    try OpenAIRealtimeProvider(
        endpoint: URL(string: "wss://api.openai.com/v1/realtime")!,
        model: "gpt-realtime-2.1",
        credentialProvider: { "offline-lifecycle-test" },
        transportFactory: { transport }
    )
}

@Test func realtimeStartupConnectFailureClosesTransport() async throws {
    let transport = LifecycleTransport(.failedConnect)
    let provider = try lifecycleProvider(transport)
    await #expect(throws: LifecycleConnectError.self) {
        _ = try await provider.openSession(agentSessionID: UUID())
    }
    #expect(await transport.closeCount >= 1)
    #expect(await transport.receiveCount == 0)
}

@Test func realtimeStartupMalformedHandshakeClosesTransport() async throws {
    let transport = LifecycleTransport(.immediate("{}"))
    let provider = try lifecycleProvider(transport)
    await #expect(throws: OpenAIRealtimeError.invalidResponse) {
        _ = try await provider.openSession(agentSessionID: UUID())
    }
    #expect(await transport.closeCount >= 1)
}

@Test func realtimeStartupProviderFailureClosesTransport() async throws {
    let transport = LifecycleTransport(.immediate(
        #"{"type":"error","error":{"code":"test_failure"}}"#
    ))
    let provider = try lifecycleProvider(transport)
    await #expect(throws: OpenAIRealtimeError.providerFailure("test_failure")) {
        _ = try await provider.openSession(agentSessionID: UUID())
    }
    #expect(await transport.closeCount >= 1)
}

@Test func realtimeStartupEOFClosesTransport() async throws {
    let transport = LifecycleTransport(.immediate(nil))
    let provider = try lifecycleProvider(transport)
    await #expect(throws: OpenAIRealtimeError.handshakeFailed) {
        _ = try await provider.openSession(agentSessionID: UUID())
    }
    #expect(await transport.closeCount >= 1)
}

@Test(arguments: [false, true])
func realtimeStartupCancellationClosesUncooperativeReceive(readyOnClose: Bool) async throws {
    // Even a racing session.created response must not return a cancelled session.
    let transport = LifecycleTransport(.blockedReceive(
        replyOnClose: readyOnClose ? #"{"type":"session.created"}"# : nil
    ))
    let provider = try lifecycleProvider(transport)
    let startup = Task { try await provider.openSession(agentSessionID: UUID()) }
    await transport.waitUntilSuspended()
    startup.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await startup.value
    }
    #expect(await transport.closeCount >= 1)
}

@Test func realtimeStartupCancellationClosesUncooperativeConnect() async throws {
    let transport = LifecycleTransport(.blockedConnect)
    let provider = try lifecycleProvider(transport)
    let startup = Task { try await provider.openSession(agentSessionID: UUID()) }
    await transport.waitUntilSuspended()
    startup.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await startup.value
    }
    #expect(await transport.closeCount >= 1)
    #expect(await transport.receiveCount == 0)
}

@Test func realtimeSuccessfulStartupLeavesTransportOpenUntilExplicitClose() async throws {
    let transport = LifecycleTransport(.immediate(#"{"type":"session.created"}"#))
    let provider = try lifecycleProvider(transport)
    let session = try await provider.openSession(agentSessionID: UUID())
    #expect(await transport.closeCount == 0)
    await session.close()
    #expect(await transport.closeCount == 1)
}
