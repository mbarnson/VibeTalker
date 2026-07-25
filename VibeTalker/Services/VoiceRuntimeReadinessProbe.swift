import Foundation

nonisolated enum VoiceRuntimeReadinessProbe {
    static func isReady(
        service: RuntimeService,
        data: Data,
        response: URLResponse
    ) -> Bool {
        guard let HTTPResponse = response as? HTTPURLResponse,
              (200..<300).contains(HTTPResponse.statusCode) else {
            return false
        }

        guard service == .moshi else {
            return true
        }

        guard let page = String(data: data, encoding: .utf8) else {
            return false
        }
        return page.localizedCaseInsensitiveContains("moshi.chat")
    }
}
