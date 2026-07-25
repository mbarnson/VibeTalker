import Foundation

nonisolated protocol InteractionServing: Sendable {
    func interact(with utterance: CommittedUtterance) async throws -> ValidatedInteraction
}

nonisolated enum ResponsesTransport: Equatable, Sendable {
    case serverSentEvents
    case webSocket
}

nonisolated struct InteractorConfiguration: Sendable {
    let endpoint: URL
    let model: String
    let apiKey: String?
    let reasoningEffort: String?
    let timeout: Duration
    let transport: ResponsesTransport

    init(
        endpoint: URL,
        model: String,
        apiKey: String? = nil,
        reasoningEffort: String? = nil,
        timeout: Duration = .milliseconds(2_500),
        transport: ResponsesTransport = .serverSentEvents
    ) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.reasoningEffort = reasoningEffort
        self.timeout = timeout
        self.transport = transport
    }
}

private final class ResponsesWebSocketDelegate:
    NSObject,
    URLSessionWebSocketDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var openWaiters: [
        Int: CheckedContinuation<Void, any Error>
    ] = [:]

    func connect(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            openWaiters[task.taskIdentifier] = continuation
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        finish(webSocketTask, with: .success(()))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finish(
            webSocketTask,
            with: .failure(URLError(.networkConnectionLost))
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let webSocketTask = task as? URLSessionWebSocketTask else {
            return
        }
        finish(
            webSocketTask,
            with: .failure(error ?? URLError(.cannotConnectToHost))
        )
    }

    private func finish(
        _ task: URLSessionWebSocketTask,
        with result: Result<Void, any Error>
    ) {
        lock.lock()
        let continuation = openWaiters.removeValue(
            forKey: task.taskIdentifier
        )
        lock.unlock()
        continuation?.resume(with: result)
    }
}

nonisolated enum InteractorError: LocalizedError {
    case invalidConfiguration
    case invalidHTTPResponse
    case providerFailure(Int, String)
    case providerStreamFailure(String)
    case timedOut
    case streamEndedBeforeCompletion
    case missingStructuredOutput
    case malformedStructuredOutput(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Interactor endpoint and model ID are required."
        case .invalidHTTPResponse:
            "Interactor returned a non-HTTP response."
        case .providerFailure(let status, let message):
            "Interactor failed with HTTP \(status): \(message)"
        case .providerStreamFailure(let message):
            "Interactor stream failed: \(message)"
        case .timedOut:
            "Interactor exceeded its response deadline."
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
    private let webSocketDelegate: ResponsesWebSocketDelegate
    private let webSocketSession: URLSession
    private var previousResponseID: String?
    private var webSocketTask: URLSessionWebSocketTask?

    init(
        configuration: InteractorConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
        let webSocketDelegate = ResponsesWebSocketDelegate()
        self.webSocketDelegate = webSocketDelegate
        self.webSocketSession = URLSession(
            configuration: .ephemeral,
            delegate: webSocketDelegate,
            delegateQueue: nil
        )
    }

    func interact(with utterance: CommittedUtterance) async throws -> ValidatedInteraction {
        let requestID = UUID()
        let clock = ContinuousClock()
        let started = clock.now
        let chainedResponseID = previousResponseID

        let providerResult = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(
                of: ProviderResult.self
            ) { group in
                group.addTask {
                    try await self.performRequest(
                        utterance: utterance,
                        previousResponseID: chainedResponseID
                    )
                }
                group.addTask {
                    try await Task.sleep(for: self.configuration.timeout)
                    throw InteractorError.timedOut
                }
                do {
                    guard let first = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return first
                } catch {
                    group.cancelAll()
                    self.cancelActiveWebSocket()
                    throw error
                }
            }
        } onCancel: {
            Task {
                await self.cancelActiveWebSocket()
            }
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
        let boundOutput = InteractionOutput(
            utteranceID: utterance.utteranceID,
            referenceResponse: decoded.referenceResponse,
            piRequest: decoded.piRequest
        )
        let reconciled = InteractionIntentPolicy.reconcile(
            boundOutput,
            transcript: utterance.transcript
        )
        let validated = try InteractionValidator.validate(reconciled, for: utterance)
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
        switch configuration.transport {
        case .serverSentEvents:
            return try await performSSERequest(
                utterance: utterance,
                previousResponseID: previousResponseID
            )
        case .webSocket:
            do {
                return try await performWebSocketRequest(
                    utterance: utterance,
                    previousResponseID: previousResponseID
                )
            } catch ResponsesWebSocketError.restartChain {
                cancelActiveWebSocket()
                self.previousResponseID = nil
                return try await performWebSocketRequest(
                    utterance: utterance,
                    previousResponseID: nil
                )
            } catch InteractorError.providerStreamFailure {
                guard !Task.isCancelled else {
                    throw CancellationError()
                }
                cancelActiveWebSocket()
                self.previousResponseID = nil
                return try await performWebSocketRequest(
                    utterance: utterance,
                    previousResponseID: nil
                )
            }
        }
    }

    private func performSSERequest(
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
            previousResponseID: previousResponseID,
            streaming: true
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

    private func performWebSocketRequest(
        utterance: CommittedUtterance,
        previousResponseID: String?
    ) async throws -> ProviderResult {
        let task = try await webSocket()
        var event = requestBody(
            utterance: utterance,
            previousResponseID: previousResponseID,
            streaming: false
        )
        event["type"] = "response.create"
        let data = try JSONSerialization.data(withJSONObject: event)
        guard let text = String(data: data, encoding: .utf8) else {
            throw InteractorError.invalidConfiguration
        }

        do {
            do {
                try await task.send(.string(text))
            } catch {
                throw InteractorError.providerStreamFailure(
                    "WebSocket send failed: \(error.localizedDescription)"
                )
            }
            let decoder = ResponsesEventDecoder()
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    throw InteractorError.providerStreamFailure(
                        "WebSocket receive failed: \(error.localizedDescription)"
                    )
                }
                let payload: Data
                switch message {
                case .data(let data):
                    payload = data
                case .string(let string):
                    payload = Data(string.utf8)
                @unknown default:
                    continue
                }
                if let result = try decoder.consume(payload) {
                    return result
                }
            }
            throw CancellationError()
        } catch {
            cancelActiveWebSocket()
            throw error
        }
    }

    private func webSocket() async throws -> URLSessionWebSocketTask {
        if let webSocketTask {
            return webSocketTask
        }
        guard var components = URLComponents(
            url: configuration.endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw InteractorError.invalidConfiguration
        }
        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "wss", "ws":
            break
        default:
            throw InteractorError.invalidConfiguration
        }
        guard let URL = components.url else {
            throw InteractorError.invalidConfiguration
        }
        var request = URLRequest(url: URL)
        if let apiKey = configuration.apiKey {
            request.setValue(
                "Bearer \(apiKey)",
                forHTTPHeaderField: "Authorization"
            )
        }
        let task = webSocketSession.webSocketTask(with: request)
        webSocketTask = task
        do {
            try await webSocketDelegate.connect(task)
        } catch {
            webSocketTask = nil
            throw error
        }
        return task
    }

    private func cancelActiveWebSocket() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func requestBody(
        utterance: CommittedUtterance,
        previousResponseID: String?,
        streaming: Bool
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": configuration.model,
            "store": false,
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
        if streaming {
            body["stream"] = true
        }
        if let previousResponseID {
            body["previous_response_id"] = previousResponseID
        }
        if let reasoningEffort = configuration.reasoningEffort {
            body["reasoning"] = ["effort": reasoningEffort]
        }
        return body
    }

    private static let developerInstructions = """
    You are VibeTalker's conversational Interactor. Echo the utterance UUID \
    from the newest input exactly; never reuse an earlier UUID. Return one \
    factual Reference of at most 180 characters for the voice model.

    Apply these rules in order:
    1. A transcript mentioning pi, a coding job, coding task, current task, \
    agent, or sandbox work and asking about doing, status, state, running, \
    finished, completed, active, or progress MUST set operation to "status" with a null \
    instruction. Do not answer or guess the job state yourself; the Coordinator \
    will supply grounded evidence. A direct request to stop, cancel, or abort \
    that job MUST set operation to "cancel" with a null instruction.
    2. Questions not matched by rule 1 and beginning Who, What, When, Where, \
    Why, How, Is, Does, \
    Explain, Tell, Define, Give, or Summarize MUST set pi_request to null, even \
    when they mention code, tests, files, or action verbs.
    3. A direct imperative whose first word is Add, Create, Fix, Implement, \
    Improve, Refactor, Rename, Update, Run, Test, Write, or Document MUST set \
    operation to "start". Also use "start" for another unambiguous direct \
    request to change code, documentation, tests, or files. Copy the complete \
    request verbatim into pi_request.instruction.
    4. Quoted, conditional, or hypothetical requests set pi_request to null.
    Otherwise set pi_request to null. Never claim that work started, finished, \
    or changed a file; only the Coordinator has that evidence.

    Examples:
    - "What does actor isolation protect?" -> pi_request: null
    - "Add a test for empty input." -> pi_request: {"operation":"start",\
    "instruction":"Add a test for empty input."}
    - "What is pi doing right now?" -> pi_request: {"operation":"status",\
    "instruction":null}
    """

    private static let outputSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["utterance_id", "reference_response", "pi_request"],
        "properties": [
            "utterance_id": ["type": "string", "format": "uuid"],
            "reference_response": ["type": "string", "minLength": 1, "maxLength": 220],
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

private nonisolated enum ResponsesWebSocketError: Error {
    case restartChain
}

nonisolated struct ResponsesEnvelope: Decodable {
    struct ProviderError: Decodable {
        let code: String?
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
    private let eventDecoder = ResponsesEventDecoder()

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
        return try eventDecoder.consume(
            Data(payload.utf8),
            fallbackType: eventName
        )
    }
}

nonisolated struct ResponsesEventDecoder {
    func consume(
        _ data: Data,
        fallbackType: String? = nil
    ) throws -> ProviderResult? {
        let event = try JSONDecoder().decode(ResponsesStreamEvent.self, from: data)
        let type = event.type ?? fallbackType

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
            let code = event.error?.code ?? event.response?.error?.code
            if code == "previous_response_not_found"
                || code == "websocket_connection_limit_reached" {
                throw ResponsesWebSocketError.restartChain
            }
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
        let code: String?
        let message: String?
    }

    let type: String?
    let response: ResponsesEnvelope?
    let error: ProviderError?
}
