import Foundation

@main
enum ResponsesWebSocketSmoke {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        let endpointValue = environment["VIBETALKER_INTERACTION_ENDPOINT"]
            ?? "https://api.openai.com/v1/responses"
        let model = environment["VIBETALKER_INTERACTION_MODEL"]
            ?? "gpt-5.6-luna"
        guard let endpoint = URL(string: endpointValue),
              let apiKey = environment["OPENAI_API_KEY"],
              !apiKey.isEmpty else {
            throw InteractorError.invalidConfiguration
        }

        let interactor = ResponsesInteractor(configuration: .init(
            endpoint: endpoint,
            model: model,
            apiKey: apiKey,
            reasoningEffort: "none",
            timeout: .seconds(15),
            transport: .webSocket
        ))
        let sessionID = UUID()
        let first = try await measure {
            try await interactor.interact(with: CommittedUtterance(
                voiceSessionID: sessionID,
                utteranceID: UUID(),
                revision: 1,
                transcript: "What is one benefit of a persistent WebSocket?"
            ))
        }
        let second = try await measure {
            try await interactor.interact(with: CommittedUtterance(
                voiceSessionID: sessionID,
                utteranceID: UUID(),
                revision: 1,
                transcript: "Summarize that answer in five words."
            ))
        }

        let output: [String: Any] = [
            "schema_version": 1,
            "endpoint": endpoint.absoluteString,
            "model": model,
            "transport": "websocket",
            "turns": [
                result(first),
                result(second),
            ],
            "passed": first.value.providerResponseID != nil
                && second.value.providerResponseID != nil
                && first.value.providerResponseID
                    != second.value.providerResponseID,
        ]
        let encoded = try JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private struct TimedResult {
        let value: ValidatedInteraction
        let seconds: Double
    }

    private static func measure(
        _ operation: () async throws -> ValidatedInteraction
    ) async throws -> TimedResult {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await operation()
        return TimedResult(
            value: value,
            seconds: seconds(start.duration(to: clock.now))
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func result(_ measured: TimedResult) -> [String: Any] {
        [
            "response_id": measured.value.providerResponseID ?? "",
            "reference": measured.value.referenceResponse,
            "pi_request": measured.value.piRequest == nil
                ? NSNull()
                : measured.value.piRequest!.operation.rawValue,
            "elapsed_seconds": measured.seconds,
        ]
    }
}
