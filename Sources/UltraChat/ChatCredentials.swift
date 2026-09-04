import Foundation
import Security

/// API keys, in the keychain — and the base URLs that go with some of them, in defaults.
///
/// A key is a secret and goes where secrets go. A base URL is not, and putting it beside
/// the key would make "where is my local server" a keychain prompt away.
public enum ChatCredentials {
    static let service = "com.ultra.chat"
    static let baseURLPrefix = "chat.baseURL."

    // MARK: Keys

    public static func apiKey(for provider: ChatProviderID) -> String {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Store a key, or remove it when handed an empty one.
    public static func setAPIKey(_ key: String, for provider: ChatProviderID) {
        let query = baseQuery(for: provider)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(trimmed.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public static func hasAPIKey(for provider: ChatProviderID) -> Bool {
        !apiKey(for: provider).isEmpty
    }

    private static func baseQuery(for provider: ChatProviderID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }

    // MARK: Base URLs

    public static func baseURL(for provider: ChatProviderID) -> URL? {
        UserDefaults.standard.string(forKey: baseURLPrefix + provider.rawValue)
            .flatMap { URL(string: $0) }
    }

    public static func setBaseURL(_ url: String, for provider: ChatProviderID) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: baseURLPrefix + provider.rawValue)
        } else {
            UserDefaults.standard.set(trimmed, forKey: baseURLPrefix + provider.rawValue)
        }
    }

    /// The whole credential a provider is built from.
    public static func credential(for provider: ChatProviderID) -> ChatCredential {
        ChatCredential(apiKey: apiKey(for: provider), baseURL: baseURL(for: provider))
    }

    /// Whether a conversation on this provider can be sent right now.
    public static func isConfigured(_ provider: ChatProviderID) -> Bool {
        !provider.requiresCredential || hasAPIKey(for: provider)
    }

    // MARK: Providers

    /// A provider, built from what is stored.
    public static func provider(for id: ChatProviderID) -> any ChatProvider {
        switch id {
        case .apple: AppleProvider()
        case .anthropic: AnthropicProvider(credential: credential(for: id))
        case .openAI: OpenAIProvider(id: .openAI, credential: credential(for: id))
        case .gemini: GeminiProvider(credential: credential(for: id))
        case .compatible: OpenAIProvider(id: .compatible, credential: credential(for: id))
        }
    }
}

/// Choices that are not secrets: which provider a new conversation starts on.
public enum ChatDefaults {
    static let providerKey = "chat.defaultProvider"

    /// The on-device model until someone chooses otherwise — it is the one that works
    /// before a key has been pasted anywhere.
    public static var provider: ChatProviderID {
        get {
            UserDefaults.standard.string(forKey: providerKey)
                .flatMap(ChatProviderID.init(rawValue:)) ?? .apple
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    /// What a fresh conversation should be sent with: the default provider if it can be
    /// used, else the on-device model, which always can.
    public static var startingProvider: ChatProviderID {
        ChatCredentials.isConfigured(provider) ? provider : .apple
    }
}
