import Foundation
import Network

nonisolated enum LoopbackReferenceServerError: LocalizedError {
    case invalidPort
    case invalidRequest
    case requestTooLarge
    case incompleteRequest
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "The Coordinator adapter port is invalid."
        case .invalidRequest:
            "The Coordinator adapter received an invalid HTTP request."
        case .requestTooLarge:
            "The Coordinator adapter request exceeded 1 MiB."
        case .incompleteRequest:
            "The Coordinator adapter connection closed before the request completed."
        case .listenerFailed(let message):
            "The Coordinator adapter listener failed: \(message)"
        }
    }
}

nonisolated final class LoopbackReferenceServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 8_173

    private struct HTTPRequest {
        let method: String
        let path: String
        let body: Data
    }

    private let adapter: MoshiChatCompletionsAdapter
    private let bridge: MoshiReferenceBridge
    private let queue = DispatchQueue(
        label: "org.barnson.VibeTalker.reference-adapter",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var listener: NWListener?

    init(
        adapter: MoshiChatCompletionsAdapter,
        bridge: MoshiReferenceBridge
    ) {
        self.adapter = adapter
        self.bridge = bridge
    }

    func start(port rawPort: UInt16 = defaultPort) async throws -> URL {
        guard let port = NWEndpoint.Port(rawValue: rawPort) else {
            throw LoopbackReferenceServerError.invalidPort
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: port
        )
        let listener = try NWListener(using: parameters)
        let start = ListenerStart()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                start.succeed()
            case .failed(let error):
                start.fail(LoopbackReferenceServerError.listenerFailed(
                    error.localizedDescription
                ))
            case .cancelled:
                start.fail(LoopbackReferenceServerError.listenerFailed(
                    "listener cancelled before becoming ready"
                ))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        lock.withLock {
            self.listener?.cancel()
            self.listener = listener
        }
        listener.start(queue: queue)
        try await start.wait()
        guard let boundPort = listener.port?.rawValue else {
            listener.cancel()
            throw LoopbackReferenceServerError.invalidPort
        }
        return URL(string: "http://127.0.0.1:\(boundPort)/v1")!
    }

    func stop() {
        let listener = lock.withLock {
            let current = self.listener
            self.listener = nil
            return current
        }
        listener?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task {
            do {
                let request = try await Self.receiveRequest(from: connection)
                let response = try await response(for: request)
                await Self.send(
                    status: response.statusCode,
                    body: response.body,
                    over: connection
                )
            } catch {
                let body = (try? JSONSerialization.data(withJSONObject: [
                    "error": [
                        "message": error.localizedDescription,
                        "type": "invalid_request_error"
                    ]
                ])) ?? Data()
                await Self.send(status: 422, body: body, over: connection)
            }
        }
    }

    private func response(for request: HTTPRequest) async throws -> MoshiChatCompletionResult {
        if request.method == "GET", request.path == "/health" {
            return MoshiChatCompletionResult(
                statusCode: 200,
                body: Data(#"{"status":"ready"}"#.utf8)
            )
        }
        if request.method == "POST", request.path == "/v1/transcripts" {
            return try await commitTranscript(request.body)
        }
        guard request.method == "POST",
              request.path == "/v1/chat/completions" else {
            throw LoopbackReferenceServerError.invalidRequest
        }
        return try await adapter.respond(to: request.body)
    }

    private func commitTranscript(_ body: Data) async throws -> MoshiChatCompletionResult {
        struct TranscriptRequest: Decodable {
            let utteranceID: UUID
            let revision: UInt64
            let transcript: String
            let committed: Bool

            enum CodingKeys: String, CodingKey {
                case utteranceID = "utterance_id"
                case revision
                case transcript
                case committed
            }
        }

        struct TranscriptResponse: Encodable {
            let accepted: Bool
            let utteranceID: UUID
            let interactionRequestID: UUID

            enum CodingKeys: String, CodingKey {
                case accepted
                case utteranceID = "utterance_id"
                case interactionRequestID = "interaction_request_id"
            }
        }

        let request: TranscriptRequest
        do {
            request = try JSONDecoder().decode(TranscriptRequest.self, from: body)
        } catch {
            throw LoopbackReferenceServerError.invalidRequest
        }
        guard request.committed,
              request.revision > 0,
              !request.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
            throw LoopbackReferenceServerError.invalidRequest
        }
        let reference = try await bridge.commit(
            utteranceID: request.utteranceID,
            revision: request.revision,
            transcript: request.transcript
        )
        return MoshiChatCompletionResult(
            statusCode: 200,
            body: try JSONEncoder().encode(TranscriptResponse(
                accepted: true,
                utteranceID: reference.utteranceID,
                interactionRequestID: reference.interactionRequestID
            ))
        )
    }

    private static func receiveRequest(from connection: NWConnection) async throws -> HTTPRequest {
        let maximumSize = 1_048_576
        var buffer = Data()
        var bodyOffset: Int?
        var contentLength: Int?

        while buffer.count <= maximumSize {
            if let bodyOffset, let contentLength,
               buffer.count >= bodyOffset + contentLength {
                return try parseRequest(
                    Data(buffer.prefix(bodyOffset + contentLength)),
                    bodyOffset: bodyOffset,
                    contentLength: contentLength
                )
            }

            let chunk = try await receiveChunk(from: connection)
            if let data = chunk.data {
                buffer.append(data)
            }
            if bodyOffset == nil,
               let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                bodyOffset = headerRange.upperBound
                contentLength = try parseContentLength(
                    Data(buffer[..<headerRange.lowerBound])
                )
            }
            if chunk.complete {
                break
            }
        }
        if buffer.count > maximumSize {
            throw LoopbackReferenceServerError.requestTooLarge
        }
        throw LoopbackReferenceServerError.incompleteRequest
    }

    private static func receiveChunk(
        from connection: NWConnection
    ) async throws -> (data: Data?, complete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 65_536
            ) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, complete))
                }
            }
        }
    }

    private static func parseContentLength(_ headerData: Data) throws -> Int {
        guard let headers = String(data: headerData, encoding: .utf8) else {
            throw LoopbackReferenceServerError.invalidRequest
        }
        for line in headers.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "content-length",
               let length = Int(parts[1].trimmingCharacters(
                in: .whitespacesAndNewlines
               )),
               length >= 0 {
                return length
            }
        }
        return 0
    }

    private static func parseRequest(
        _ data: Data,
        bodyOffset: Int,
        contentLength: Int
    ) throws -> HTTPRequest {
        guard let header = String(
            data: data.prefix(bodyOffset - 4),
            encoding: .utf8
        ) else {
            throw LoopbackReferenceServerError.invalidRequest
        }
        let requestLine = header.components(separatedBy: "\r\n")[0]
            .split(separator: " ")
        guard requestLine.count == 3 else {
            throw LoopbackReferenceServerError.invalidRequest
        }
        return HTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            body: Data(data[bodyOffset..<(bodyOffset + contentLength)])
        )
    }

    private static func send(
        status: Int,
        body: Data,
        over connection: NWConnection
    ) async {
        let reason = status == 200 ? "OK" : "Unprocessable Content"
        var response = Data(
            """
            HTTP/1.1 \(status) \(reason)\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """.utf8
        )
        response.append(body)
        await withCheckedContinuation { continuation in
            connection.send(
                content: response,
                completion: .contentProcessed { _ in
                    connection.cancel()
                    continuation.resume()
                }
            )
        }
    }
}

private nonisolated final class ListenerStart: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<Void, Error>? = lock.withLock {
                if let result {
                    return result
                }
                self.continuation = continuation
                return nil
            }
            if let immediate {
                continuation.resume(with: immediate)
            }
        }
    }

    func succeed() {
        finish(.success(()))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.resume(with: result)
    }
}
