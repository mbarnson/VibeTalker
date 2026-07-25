import Foundation

nonisolated protocol InteractionServing: Sendable {
    func interact(with utterance: CommittedUtterance) async throws -> ValidatedInteraction
}

nonisolated struct InteractorConfiguration: Sendable {
    let endpoint: URL
    let model: String
    let apiKey: String?
    let timeout: Duration

    init(
        endpoint: URL,
        model: String,
        apiKey: String? = nil,
        timeout: Duration = .seconds(2)
    ) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
    }
}

nonisolated enum InteractorError: LocalizedError {
    case invalidHTTPResponse
    case providerFailure(Int, String)
    case providerStreamFailure(String)
    case streamEndedBeforeCompletion
    case missingStructuredOutput
    case malformedStructuredOutput(String)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            "Interactor returned a non-HTTP response."
        case .providerFailure(let status, let message):
            "Interactor failed with HTTP \(status): \(message)"
        case .providerStreamFailure(let message):
            "Interactor stream failed: \(message)"
        case .streamEndedBeforeCompletion:
            "Interactor stream ended before response.completed."
        case .missingStructuredOutput:
            "Interactor response did not contain structured output."
        case .malformedStructuredOutput(let message):
            "Interactor structured output is invalid: \(message)"
        }
    }
}

actor ResponsesInteractor: InteractionServing {
    private let configuration: InteractorConfiguration
    private let session: URLSession
    private var previousResponseID: String?

    init(
        configuration: InteractorConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    func interact(with utterance: CommittedUtterance) async throws -> ValidatedInteraction {
        let requestID = UUID()
        let clock = ContinuousClock()
        let started = clock.now
        let previousID = previousResponseID

        let providerResult = try await withThrowingTaskGroup(
            of: ProviderResult.self
        ) { group in
            group.addTask {
                try await self.performRequest(
                    utterance: utterance,
                    previousResponseID: previousID
                )
            }
            group.addTask {
                try await Task.sleep(for: self.configuration.timeout)
                throw CancellationError()
            }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return first
        }

        let decoded: InteractionOutput
        do {
            decoded = try JSONDecoder().decode(
                InteractionOutput.self,
                from: Data(providerResult.structuredText.utf8)
            )
        } catch {
            throw InteractorError.malformedStructuredOutput(error.localizedDescription)
        }
        let validated = try InteractionValidator.validate(decoded, for: utterance)
        previousResponseID = providerResult.responseID

        return ValidatedInteraction(
            requestID: requestID,
            utterance: utterance,
            referenceResponse: validated.referenceResponse,
            piRequest: validated.piRequest,
            providerResponseID: providerResult.responseID,
            latency: started.duration(to: clock.now)
        )
    }

    private func performRequest(
        utterance: CommittedUtterance,
        previousResponseID: String?
    ) async throws -> ProviderResult {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey = configuration.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(
            utterance: utterance,
            previousResponseID: previousResponseID
        ))

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw InteractorError.invalidHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body.append(line)
                body.append("\n")
            }
            throw InteractorError.providerFailure(
                httpResponse.statusCode,
                body.isEmpty ? "no response body" : body
            )
        }

        var decoder = ResponsesSSEDecoder()
        for try await line in bytes.lines {
            if let result = try decoder.consume(line) {
                return result
            }
        }
        throw InteractorError.streamEndedBeforeCompletion
    }

    private func requestBody(
        utterance: CommittedUtterance,
        previousResponseID: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": configuration.model,
            "store": true,
            "stream": true,
            "instructions": Self.developerInstructions,
            "input": [[
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": """
                    utterance_id: \(utterance.utteranceID.uuidString)
                    transcript: \(utterance.transcript)
                    """
                ]]
            ]],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "vibetalker_interaction",
                    "strict": true,
                    "schema": Self.outputSchema
                ]
            ]
        ]
        if let previousResponseID {
            body["previous_response_id"] = previousResponseID
        }
        return body
    }

    private static let developerInstructions = """
    You are VibeTalker's conversational Interactor. Return one short factual \
    Reference for the voice model. Include a Pi Request only when the user \
    clearly requests coding work, cancellation, or grounded job status. Never \
    claim that work started. Echo the supplied utterance UUID exactly.
    """

    private static let outputSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["utterance_id", "reference_response", "pi_request"],
        "properties": [
            "utterance_id": ["type": "string", "format": "uuid"],
            "reference_response": ["type": "string", "minLength": 1, "maxLength": 400],
            "pi_request": [
                "anyOf": [
                    ["type": "null"],
                    [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["operation", "instruction"],
                        "properties": [
                            "operation": [
                                "type": "string",
                                "enum": ["start", "cancel", "status"]
                            ],
                            "instruction": [
                                "anyOf": [
                                    ["type": "string", "maxLength": 4_000],
                                    ["type": "null"]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    ]
}

nonisolated struct ProviderResult: Equatable, Sendable {
    let responseID: String?
    let structuredText: String
}

nonisolated struct ResponsesEnvelope: Decodable {
    struct ProviderError: Decodable {
        let message: String?
    }

    struct Output: Decodable {
        struct Content: Decodable {
            let type: String?
            let text: String?
        }

        let content: [Content]?
    }

    let id: String?
    let output: [Output]?
    let outputText: String?
    let error: ProviderError?

    enum CodingKeys: String, CodingKey {
        case id
        case output
        case outputText = "output_text"
        case error
    }

    var structuredText: String? {
        if let outputText, !outputText.isEmpty {
            return outputText
        }
        return output?
            .flatMap { $0.content ?? [] }
            .first { $0.type == "output_text" && $0.text != nil }?
            .text
    }
}

nonisolated struct ResponsesSSEDecoder {
    private var eventName: String?

    mutating func consume(_ line: String) throws -> ProviderResult? {
        if line.hasPrefix("event:") {
            eventName = String(line.dropFirst("event:".count))
                .trimmingCharacters(in: .whitespaces)
            return nil
        }
        guard line.hasPrefix("data:") else {
            if line.isEmpty {
                eventName = nil
            }
            return nil
        }

        let payload = String(line.dropFirst("data:".count))
            .trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", !payload.isEmpty else { return nil }
        let data = Data(payload.utf8)
        let event = try JSONDecoder().decode(ResponsesStreamEvent.self, from: data)
        let type = event.type ?? eventName

        switch type {
        case "response.completed":
            guard let response = event.response,
                  let structuredText = response.structuredText else {
                throw InteractorError.missingStructuredOutput
            }
            return ProviderResult(
                responseID: response.id,
                structuredText: structuredText
            )
        case "response.failed", "error":
            throw InteractorError.providerStreamFailure(
                event.error?.message
                    ?? event.response?.error?.message
                    ?? "unknown provider stream error"
            )
        default:
            return nil
        }
    }
}

private nonisolated struct ResponsesStreamEvent: Decodable {
    struct ProviderError: Decodable {
        let message: String?
    }

    let type: String?
    let response: ResponsesEnvelope?
    let error: ProviderError?
}
