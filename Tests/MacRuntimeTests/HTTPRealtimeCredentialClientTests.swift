import Foundation
import Testing
@testable import MacRuntime

private final class RealtimeCredentialURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        let status: Int
        let responseBody: Data

        // URLProtocol may expose a streamed request body instead of request.httpBody,
        // so this transport mock validates method/path/content type and leaves the
        // exact `{}` body contract to the backend HTTP tests.
        if request.url?.path != "/v1/realtime/credential" ||
            request.httpMethod != "POST" || contentType != "application/json" {
            status = 400
            responseBody = Data("{\"error\":\"invalid_request\"}".utf8)
        } else if authorization == "Bearer \(String(repeating: "B", count: 43))" {
            status = 401
            responseBody = Data("{\"error\":\"unauthenticated\"}".utf8)
        } else if authorization == "Bearer \(String(repeating: "C", count: 43))" {
            status = 200
            responseBody = Data("{\"result\":{\"credential\":\"ek_test_ephemeral_value\",\"model\":\"different-model\"}}".utf8)
        } else if authorization == "Bearer \(String(repeating: "D", count: 43))" {
            status = 200
            responseBody = Data("{\"result\":{\"credential\":\" bad credential \",\"model\":\"gpt-realtime-2.1\"}}".utf8)
        } else if authorization == "Bearer \(String(repeating: "E", count: 43))" {
            status = 503
            responseBody = Data("{\"error\":\"realtime_unavailable\"}".utf8)
        } else {
            status = 200
            responseBody = Data("{\"result\":{\"credential\":\"ek_test_ephemeral_value\",\"model\":\"gpt-realtime-2.1\",\"expiresAt\":2000000000}}".utf8)
        }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func realtimeCredentialTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RealtimeCredentialURLProtocol.self]
    return URLSession(configuration: configuration)
}

private let realtimeCredentialEndpoint = URL(string: "https://agent.example.test/v1/realtime/credential")!

@Test func realtimeCredentialClientUsesOnlyOpaqueAgentSessionAndReturnsEphemeralCredential() async throws {
    let agentToken = String(repeating: "A", count: 43)
    let client = try HTTPRealtimeCredentialClient(
        endpoint: realtimeCredentialEndpoint,
        bearerTokenProvider: { agentToken },
        session: realtimeCredentialTestSession()
    )

    let credential = try await client.credential()
    #expect(credential == "ek_test_ephemeral_value")
    #expect(credential != agentToken)
}

@Test func realtimeCredentialClientFailsClosedOnAuthModelCredentialAndServiceErrors() async throws {
    let unauthorized = try HTTPRealtimeCredentialClient(
        endpoint: realtimeCredentialEndpoint,
        bearerTokenProvider: { String(repeating: "B", count: 43) },
        session: realtimeCredentialTestSession()
    )
    await #expect(throws: RealtimeCredentialClientError.unauthenticated) {
        try await unauthorized.credential()
    }

    let mismatch = try HTTPRealtimeCredentialClient(
        endpoint: realtimeCredentialEndpoint,
        bearerTokenProvider: { String(repeating: "C", count: 43) },
        session: realtimeCredentialTestSession()
    )
    await #expect(throws: RealtimeCredentialClientError.invalidResponse) {
        try await mismatch.credential()
    }

    let malformed = try HTTPRealtimeCredentialClient(
        endpoint: realtimeCredentialEndpoint,
        bearerTokenProvider: { String(repeating: "D", count: 43) },
        session: realtimeCredentialTestSession()
    )
    await #expect(throws: RealtimeCredentialClientError.invalidResponse) {
        try await malformed.credential()
    }

    let unavailable = try HTTPRealtimeCredentialClient(
        endpoint: realtimeCredentialEndpoint,
        bearerTokenProvider: { String(repeating: "E", count: 43) },
        session: realtimeCredentialTestSession()
    )
    await #expect(throws: RealtimeCredentialClientError.unavailable) {
        try await unavailable.credential()
    }
}

@Test func realtimeCredentialClientRejectsMalformedAgentTokenBeforeRequest() async throws {
    let client = try HTTPRealtimeCredentialClient(
        endpoint: realtimeCredentialEndpoint,
        bearerTokenProvider: { "not-an-agent-session" },
        session: realtimeCredentialTestSession()
    )
    await #expect(throws: RealtimeCredentialClientError.unauthenticated) {
        try await client.credential()
    }
}

@Test func realtimeCredentialClientRejectsUnsafeEndpoints() {
    #expect(throws: RealtimeCredentialClientError.invalidEndpoint) {
        try HTTPRealtimeCredentialClient(
            endpoint: URL(string: "http://example.com/v1/realtime/credential")!,
            bearerTokenProvider: { String(repeating: "A", count: 43) }
        )
    }
    #expect(throws: RealtimeCredentialClientError.invalidEndpoint) {
        try HTTPRealtimeCredentialClient(
            endpoint: URL(string: "https://example.com/other")!,
            bearerTokenProvider: { String(repeating: "A", count: 43) }
        )
    }
    #expect(throws: RealtimeCredentialClientError.invalidEndpoint) {
        try HTTPRealtimeCredentialClient(
            endpoint: URL(string: "https://user:password@example.com/v1/realtime/credential")!,
            bearerTokenProvider: { String(repeating: "A", count: 43) }
        )
    }
}
