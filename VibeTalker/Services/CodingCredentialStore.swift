import Foundation
import Security

nonisolated enum CodingProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openAI
    case openRouter
    case openAICompatible
    case responsesCompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .openAICompatible: "OpenAI-compatible"
        case .responsesCompatible: "Responses-compatible"
        }
    }

    var environmentKey: String {
        switch self {
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openAI: "OPENAI_API_KEY"
        case .openRouter: "OPENROUTER_API_KEY"
        case .openAICompatible, .responsesCompatible: "OMLX_API_KEY"
        }
    }

    var piProviderID: String {
        switch self {
        case .anthropic: "anthropic"
        case .openAI: "openai"
        case .openRouter: "openrouter"
        case .openAICompatible: "omlx-openai-compatible"
        case .responsesCompatible: "omlx-responses-compatible"
        }
    }

    var customPiAPI: String? {
        switch self {
        case .openAICompatible: "openai-completions"
        case .responsesCompatible: "openai-responses"
        case .anthropic, .openAI, .openRouter: nil
        }
    }

    var defaultPiModelID: String? {
        switch self {
        case .anthropic: "claude-opus-4-8"
        case .openAI: "gpt-5.5"
        case .openRouter: "moonshotai/kimi-k2.6"
        case .openAICompatible, .responsesCompatible: nil
        }
    }
}

nonisolated enum InteractionProvider: String, CaseIterable, Identifiable, Sendable {
    case openAIResponses
    case responsesCompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAIResponses: "OpenAI Responses"
        case .responsesCompatible: "Responses-compatible"
        }
    }

    var credentialProvider: CodingProvider {
        switch self {
        case .openAIResponses: .openAI
        case .responsesCompatible: .responsesCompatible
        }
    }

    var reasoningEffort: String? {
        switch self {
        case .openAIResponses: "none"
        case .responsesCompatible: nil
        }
    }
}

nonisolated struct CodingProviderCredential: Sendable {
    let provider: CodingProvider
    let value: String
}

nonisolated struct PiCustomProviderConfiguration: Equatable, Sendable {
    static let providerID = "vibetalker-omlx"

    let api: String
    let baseURL: URL
    let modelID: String
    let environmentKey: String

    init?(
        provider: CodingProvider,
        baseURL: String,
        modelID: String
    ) {
        guard let api = provider.customPiAPI,
              let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        let normalizedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else { return nil }

        self.api = api
        self.baseURL = url
        self.modelID = normalizedModel
        self.environmentKey = provider.environmentKey
    }
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
