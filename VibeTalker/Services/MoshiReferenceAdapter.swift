import Foundation

nonisolated enum MoshiReferenceAdapterError: LocalizedError, Equatable {
    case inactiveSession
    case invalidRequest
    case missingTranscript
    case referenceNotDelivered
    case moshiRejectedReference

    var errorDescription: String? {
        switch self {
        case .inactiveSession:
            "No Moshi voice session is active."
        case .invalidRequest:
            "Moshi sent an invalid chat-completions request."
        case .missingTranscript:
            "Moshi's retrieval request did not contain a committed user transcript."
        case .referenceNotDelivered:
            "The Coordinator completed without delivering the matching Reference."
        case .moshiRejectedReference:
            "The MLX Moshi runtime rejected the encoded Reference."
        }
    }
}

nonisolated protocol MoshiReferenceAccepting: Sendable {
    func accept(_ delivery: ReferenceDelivery) async throws
}

actor MoshiReferenceHTTPClient: MoshiReferenceAccepting {
    private struct Request: Encodable {
        let text: String
    }

    private let endpoint: URL
    private let session: URLSession

    init(
        endpoint: URL = URL(string: "http://127.0.0.1:8999/api/reference")!,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    func accept(_ delivery: ReferenceDelivery) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(text: delivery.text))
        let (_, response) = try await session.data(for: request)
        guard let HTTPResponse = response as? HTTPURLResponse,
              (200..<300).contains(HTTPResponse.statusCode) else {
            throw MoshiReferenceAdapterError.moshiRejectedReference
        }
    }
}

nonisolated struct MoshiChatCompletionResult: Equatable, Sendable {
    let statusCode: Int
    let body: Data
}

actor MoshiReferenceBridge: ReferenceDelivering {
    typealias CommitHandler = @Sendable (CommittedUtterance) async throws -> CoordinatedTurn
    typealias EventSink = @Sendable (LedgerEventKind, String) async -> Void

    private var events: EventSink
    private var voiceSessionID: UUID?
    private var commitHandler: CommitHandler?
    private var deliveredByUtterance: [UUID: ReferenceDelivery] = [:]
    private var deliverySink: @Sendable (ReferenceDelivery) async throws -> Void = { _ in }

    init(events: @escaping EventSink = { _, _ in }) {
        self.events = events
    }

    func setEventSink(_ events: @escaping EventSink) {
        self.events = events
    }

    func setDeliverySink(
        _ deliverySink: @escaping @Sendable (ReferenceDelivery) async throws -> Void
    ) {
        self.deliverySink = deliverySink
    }

    func beginSession(
        _ voiceSessionID: UUID,
        commit: @escaping CommitHandler
    ) {
        self.voiceSessionID = voiceSessionID
        commitHandler = commit
        deliveredByUtterance.removeAll()
    }

    func endSession() {
        voiceSessionID = nil
        commitHandler = nil
        deliveredByUtterance.removeAll()
    }

    func deliver(_ delivery: ReferenceDelivery) async throws {
        guard delivery.voiceSessionID == voiceSessionID else {
            throw MoshiReferenceAdapterError.inactiveSession
        }
        try await deliverySink(delivery)
        deliveredByUtterance[delivery.utteranceID] = delivery
        await events(.reference, "Reference: \(delivery.text)")
    }

    func commit(
        utteranceID: UUID,
        revision: UInt64,
        transcript: String
    ) async throws -> ReferenceDelivery {
        guard let voiceSessionID, let commitHandler else {
            throw MoshiReferenceAdapterError.inactiveSession
        }
        let utterance = CommittedUtterance(
            voiceSessionID: voiceSessionID,
            utteranceID: utteranceID,
            revision: revision,
            transcript: transcript
        )
        await events(.transcript, "Committed ASR: \(transcript)")
        let turn = try await commitHandler(utterance)
        guard deliveredByUtterance.removeValue(forKey: utterance.utteranceID)
                == turn.reference else {
            throw MoshiReferenceAdapterError.referenceNotDelivered
        }
        return turn.reference
    }

    func resolve(_ transcript: String) async throws -> ReferenceDelivery {
        try await commit(
            utteranceID: UUID(),
            revision: 1,
            transcript: transcript
        )
    }
}

actor MoshiChatCompletionsAdapter {
    private struct Request: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String
        }

        let model: String?
        let messages: [Message]
    }

    private struct Response: Encodable {
        struct Choice: Encodable {
            struct Message: Encodable {
                let role: String
                let content: String
            }

            let index: Int
            let message: Message
            let finishReason: String

            enum CodingKeys: String, CodingKey {
                case index
                case message
                case finishReason = "finish_reason"
            }
        }

        struct Usage: Encodable {
            let promptTokens = 0
            let completionTokens = 0
            let totalTokens = 0

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case totalTokens = "total_tokens"
            }
        }

        let id: String
        let object = "chat.completion"
        let created: Int
        let model: String
        let choices: [Choice]
        let usage = Usage()
    }

    private struct CachedRequest {
        let source: String
        let task: Task<MoshiChatCompletionResult, Error>
    }

    private let bridge: MoshiReferenceBridge
    private var cachedRequest: CachedRequest?

    init(bridge: MoshiReferenceBridge) {
        self.bridge = bridge
    }

    func reset() {
        cachedRequest?.task.cancel()
        cachedRequest = nil
    }

    func respond(to data: Data) async throws -> MoshiChatCompletionResult {
        let request: Request
        do {
            request = try JSONDecoder().decode(Request.self, from: data)
        } catch {
            throw MoshiReferenceAdapterError.invalidRequest
        }
        guard let source = request.messages.last(where: { $0.role == "user" })?.content else {
            throw MoshiReferenceAdapterError.missingTranscript
        }
        if let cachedRequest, cachedRequest.source == source {
            return try await cachedRequest.task.value
        }
        guard let transcript = Self.latestHumanTranscript(in: source) else {
            throw MoshiReferenceAdapterError.missingTranscript
        }

        let model = request.model ?? "vibetalker-coordinator"
        let task = Task {
            let reference = try await self.bridge.resolve(transcript)
            let response = Response(
                id: "chatcmpl-\(reference.interactionRequestID.uuidString)",
                created: Int(Date().timeIntervalSince1970),
                model: model,
                choices: [
                    .init(
                        index: 0,
                        message: .init(role: "assistant", content: reference.text),
                        finishReason: "stop"
                    )
                ]
            )
            return MoshiChatCompletionResult(
                statusCode: 200,
                body: try JSONEncoder().encode(response)
            )
        }
        cachedRequest = CachedRequest(source: source, task: task)
        return try await task.value
    }

    static func latestHumanTranscript(in prompt: String) -> String? {
        for line in prompt.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("Human:") else { continue }
            let transcript = value.dropFirst("Human:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                return transcript
            }
        }
        return nil
    }
}
