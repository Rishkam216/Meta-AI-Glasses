import AgentCore
import Foundation
import Security

/// Stores only our opaque agent session. Supabase access/refresh tokens are not
/// persisted here; the external access token is used only during auth exchange.
public actor KeychainAgentSessionStore: AgentSessionCredentialStoring {
    private let service: String
    private let account: String

    public init(service: String = "com.rishkam.metaai.macagent.agent-session",
                account: String = "current") {
        self.service = service
        self.account = account
    }

    public func load() async throws -> AgentSessionCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AgentSessionCredentialError.unavailable
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let credential: AgentSessionCredential
        do { credential = try decoder.decode(AgentSessionCredential.self, from: data) }
        catch { throw AgentSessionCredentialError.unavailable }

        if credential.isExpired() {
            try deleteItem()
            throw AgentSessionCredentialError.expired
        }
        return credential
    }

    public func save(_ credential: AgentSessionCredential) async throws {
        guard !credential.isExpired() else { throw AgentSessionCredentialError.expired }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try encoder.encode(credential) }
        catch { throw AgentSessionCredentialError.unavailable }

        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AgentSessionCredentialError.unavailable }

        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw AgentSessionCredentialError.unavailable
        }
    }

    public func clear() async throws {
        try deleteItem()
    }

    public func bearerToken() async throws -> String {
        guard let credential = try await load() else { throw AgentSessionCredentialError.expired }
        return try credential.bearerToken()
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func deleteItem() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentSessionCredentialError.unavailable
        }
    }
}
