import AgentCore
import Foundation
import Testing
@testable import MacRuntime

private actor MemorySessionStore: AgentSessionCredentialStoring {
    private var value: AgentSessionCredential?
    func load() async throws -> AgentSessionCredential? { value }
    func save(_ credential: AgentSessionCredential) async throws { value = credential }
    func clear() async throws { value = nil }
}

private final class AuthURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let status: Int
        let body: Data
        if path == "/v1/auth/logout" {
            status = 200
            body = Data("{\"result\":{\"revoked\":true}}".utf8)
        } else if authorization == "Bearer unauthorized-external-token" {
            status = 401
            body = Data("{\"error\":\"unauthenticated\"}".utf8)
        } else if authorization == "Bearer malformed-response-token" {
            status = 200
            body = Data("{bad".utf8)
        } else {
            status = 200
            body = Data("""
            {"result":{"token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expiresAt":"2099-01-01T00:00:00.000Z","identity":{"tenantID":"11111111-1111-1111-1111-111111111111","userID":"22222222-2222-2222-2222-222222222222","accountID":null}}}
            """.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func testSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AuthURLProtocol.self]
    return URLSession(configuration: configuration)
}

private let authEndpoint = URL(string: "https://auth.example.test/v1/auth/exchange")!

@Test func authExchangeStoresOnlyOpaqueAgentCredential() async throws {
    let store = MemorySessionStore()
    let client = try AuthExchangeClient(endpoint: authEndpoint, credentialStore: store, session: testSession())
    let external = "valid-external-access-token"
    let credential = try await client.exchange(externalAccessToken: external)
    #expect(credential.token == String(repeating: "A", count: 43))
    #expect(credential.token != external)
    #expect(try await store.load() == credential)
    #expect(credential.identity.tenantID.uuidString == "11111111-1111-1111-1111-111111111111")
}

@Test func authExchangeFailsClosedOnUnauthorizedAndMalformedResponses() async throws {
    let store = MemorySessionStore()
    let client = try AuthExchangeClient(endpoint: authEndpoint, credentialStore: store, session: testSession())
    await #expect(throws: AuthExchangeError.unauthenticated) {
        try await client.exchange(externalAccessToken: "unauthorized-external-token")
    }
    #expect(try await store.load() == nil)
    await #expect(throws: AuthExchangeError.invalidResponse) {
        try await client.exchange(externalAccessToken: "malformed-response-token")
    }
    #expect(try await store.load() == nil)
}

@Test func authLogoutRevokesThenClearsLocalCredential() async throws {
    let store = MemorySessionStore()
    let client = try AuthExchangeClient(endpoint: authEndpoint, credentialStore: store, session: testSession())
    _ = try await client.exchange(externalAccessToken: "valid-external-access-token")
    #expect(try await store.load() != nil)
    try await client.logout()
    #expect(try await store.load() == nil)
}

@Test func authExchangeRejectsUnsafeEndpointsAndMalformedExternalTokens() async throws {
    let store = MemorySessionStore()
    #expect(throws: AuthExchangeError.invalidEndpoint) {
        try AuthExchangeClient(endpoint: URL(string: "http://example.com/v1/auth/exchange")!, credentialStore: store)
    }
    #expect(throws: AuthExchangeError.invalidEndpoint) {
        try AuthExchangeClient(endpoint: URL(string: "https://example.com/not-auth")!, credentialStore: store)
    }
    let client = try AuthExchangeClient(endpoint: authEndpoint, credentialStore: store, session: testSession())
    await #expect(throws: AuthExchangeError.invalidExternalToken) {
        try await client.exchange(externalAccessToken: "short")
    }
}
