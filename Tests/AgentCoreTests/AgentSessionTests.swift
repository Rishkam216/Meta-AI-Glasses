import Foundation
import Testing
@testable import AgentCore

private let sessionPrincipal = TenantContext(
    tenantID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    userID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
)
private let validAgentToken = String(repeating: "A", count: 43)

@Test func agentSessionValidatesOpaqueTokenAndExpiry() throws {
    let future = Date(timeIntervalSince1970: 4_000_000_000)
    let credential = try AgentSessionCredential(token: validAgentToken, expiresAt: future,
                                                identity: sessionPrincipal)
    #expect(try credential.bearerToken(at: Date(timeIntervalSince1970: 1_000)) == validAgentToken)
    #expect(!credential.isExpired(at: Date(timeIntervalSince1970: 1_000)))
    #expect(credential.isExpired(at: future))
    #expect(throws: AgentSessionCredentialError.expired) {
        try credential.bearerToken(at: future)
    }
}

@Test func agentSessionRejectsMalformedTokens() {
    #expect(throws: AgentSessionCredentialError.invalidToken) {
        try AgentSessionCredential(token: "short", expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
                                   identity: sessionPrincipal)
    }
    #expect(throws: AgentSessionCredentialError.invalidToken) {
        try AgentSessionCredential(token: String(repeating: "+", count: 43),
                                   expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
                                   identity: sessionPrincipal)
    }
}

@Test func agentSessionRoundTripsWithISO8601Encoding() throws {
    let credential = try AgentSessionCredential(token: validAgentToken,
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000), identity: sessionPrincipal)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(AgentSessionCredential.self, from: encoder.encode(credential))
    #expect(decoded == credential)
}
