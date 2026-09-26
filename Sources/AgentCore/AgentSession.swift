import Foundation

public enum AgentSessionCredentialError: Error, Sendable, Equatable {
    case invalidToken
    case invalidExpiry
    case expired
    case unavailable
}

/// Provider-neutral credential returned by our authentication service after an
/// external identity (currently Supabase) has been verified. Downstream agent
/// systems use this opaque token and our own principal, never the provider token.
public struct AgentSessionCredential: Codable, Sendable, Equatable {
    public let token: String
    public let expiresAt: Date
    public let identity: TenantContext

    public init(token: String, expiresAt: Date, identity: TenantContext) throws {
        guard Self.validToken(token) else { throw AgentSessionCredentialError.invalidToken }
        guard expiresAt.timeIntervalSince1970.isFinite else { throw AgentSessionCredentialError.invalidExpiry }
        self.token = token
        self.expiresAt = expiresAt
        self.identity = identity
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        expiresAt <= date
    }

    public func bearerToken(at date: Date = Date()) throws -> String {
        guard !isExpired(at: date) else { throw AgentSessionCredentialError.expired }
        return token
    }

    private enum CodingKeys: String, CodingKey { case token, expiresAt, identity }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            token: values.decode(String.self, forKey: .token),
            expiresAt: values.decode(Date.self, forKey: .expiresAt),
            identity: values.decode(TenantContext.self, forKey: .identity)
        )
    }

    private static func validToken(_ token: String) -> Bool {
        guard token.utf8.count == 43 else { return false }
        return token.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) ||
            (97...122).contains(byte) || byte == 45 || byte == 95
        }
    }
}

public protocol AgentSessionCredentialStoring: Sendable {
    func load() async throws -> AgentSessionCredential?
    func save(_ credential: AgentSessionCredential) async throws
    func clear() async throws
}
