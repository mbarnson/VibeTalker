import Foundation
import Security

nonisolated enum CodingProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openAI
    case openRouter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        }
    }

    var environmentKey: String {
        switch self {
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openAI: "OPENAI_API_KEY"
        case .openRouter: "OPENROUTER_API_KEY"
        }
    }

    var piProviderID: String {
        switch self {
        case .anthropic: "anthropic"
        case .openAI: "openai"
        case .openRouter: "openrouter"
        }
    }
}

nonisolated struct CodingProviderCredential: Sendable {
    let provider: CodingProvider
    let value: String
}

nonisolated enum CodingCredentialError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain operation failed: \(detail ?? String(status))"
        }
    }
}

actor CodingCredentialStore {
    static let service = "org.barnson.VibeTalker.pi"

    func contains(_ provider: CodingProvider) throws -> Bool {
        var query = lookupQuery(provider)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            throw CodingCredentialError.keychain(status)
        }
        return true
    }

    func credential(for provider: CodingProvider) throws -> CodingProviderCredential? {
        var query = lookupQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw CodingCredentialError.keychain(status)
        }
        return .init(provider: provider, value: value)
    }

    func save(_ value: String, for provider: CodingProvider) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let encoded = Data(normalized.utf8)
        let query = lookupQuery(provider)
        let update = [kSecValueData as String: encoded]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            update as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CodingCredentialError.keychain(updateStatus)
        }

        var item = query
        item[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = encoded
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CodingCredentialError.keychain(addStatus)
        }
    }

    func delete(_ provider: CodingProvider) throws {
        let status = SecItemDelete(lookupQuery(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodingCredentialError.keychain(status)
        }
    }

    private func lookupQuery(_ provider: CodingProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.piProviderID,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}
