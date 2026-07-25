import Foundation

nonisolated struct AppPreferences {
    static let defaultCodingBaseURL = "http://127.0.0.1:8000/v1"
    static let defaultInteractionEndpoint = "http://127.0.0.1:8000/v1/responses"

    private enum Key {
        static let codingProvider = "codingProvider"
        static let codingBaseURL = "codingBaseURL"
        static let codingModelID = "codingModelID"
        static let interactionProvider = "interactionProvider"
        static let interactionEndpoint = "interactionEndpoint"
        static let interactionModelID = "interactionModelID"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var codingProvider: CodingProvider {
        get {
            guard let rawValue = defaults.string(forKey: Key.codingProvider),
                  let provider = CodingProvider(rawValue: rawValue) else {
                return .anthropic
            }
            return provider
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Key.codingProvider)
        }
    }

    var codingBaseURL: String {
        get {
            defaults.string(forKey: Key.codingBaseURL)
                ?? Self.defaultCodingBaseURL
        }
        nonmutating set {
            defaults.set(newValue, forKey: Key.codingBaseURL)
        }
    }

    var codingModelID: String {
        get { defaults.string(forKey: Key.codingModelID) ?? "" }
        nonmutating set {
            defaults.set(newValue, forKey: Key.codingModelID)
        }
    }

    var interactionEndpoint: String {
        get {
            defaults.string(forKey: Key.interactionEndpoint)
                ?? Self.defaultInteractionEndpoint
        }
        nonmutating set {
            defaults.set(newValue, forKey: Key.interactionEndpoint)
        }
    }

    var interactionProvider: InteractionProvider {
        get {
            guard let rawValue = defaults.string(forKey: Key.interactionProvider),
                  let provider = InteractionProvider(rawValue: rawValue) else {
                return .responsesCompatible
            }
            return provider
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Key.interactionProvider)
        }
    }

    var interactionModelID: String {
        get { defaults.string(forKey: Key.interactionModelID) ?? "" }
        nonmutating set {
            defaults.set(newValue, forKey: Key.interactionModelID)
        }
    }
}
