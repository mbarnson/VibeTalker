import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.path == "/v1/responses" {
            respondToInteraction(url)
        } else if url.path == "/api/reference" {
            respond(status: 204, data: Data(), contentType: nil)
        } else {
            respond(status: 404, data: Data(), contentType: "text/plain")
        }
    }

    override func stopLoading() {}

    private func respondToInteraction(_ url: URL) {
        guard let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body)
                as? [String: Any],
              let input = object["input"] as? [[String: Any]],
              let content = input.first?["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              let utteranceLine = text.split(separator: "\n").first,
              let utteranceID = utteranceLine.split(separator: " ").last
        else {
            respond(status: 400, data: Data(), contentType: "text/plain")
            return
        }

        let output: [String: Any] = [
            "utterance_id": String(utteranceID),
            "reference_response": "Fixture Reference",
            "pi_request": NSNull()
        ]
        let outputData = try! JSONSerialization.data(withJSONObject: output)
        let outputText = String(decoding: outputData, as: UTF8.self)
        let event: [String: Any] = [
            "type": "response.completed",
            "response": [
                "id": "fixture-response",
                "output_text": outputText
            ]
        ]
        let eventData = try! JSONSerialization.data(withJSONObject: event)
        var data = Data("event: response.completed\ndata: ".utf8)
        data.append(eventData)
        data.append(Data("\n\n".utf8))
        respond(status: 200, data: data, contentType: "text/event-stream")
    }

    private func respond(
        status: Int,
        data: Data,
        contentType: String?
    ) {
        var headers: [String: String] = [:]
        if let contentType {
            headers["Content-Type"] = contentType
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        if !data.isEmpty {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor FixturePiDispatcher: PiRequestDispatching {
    func dispatch(_ request: PiRequest) async throws -> PiDispatchReceipt {
        switch request.operation {
        case .start:
            .started(projectName: "Workspace")
        case .cancel:
            .cancellationRequested(projectName: "Workspace")
        case .status:
            .status(projectName: "Workspace", summary: "No coding job is active.")
        }
    }
}

private struct Corpus: Decodable {
    let ordinary: [String]
    let dispatch: [String]
    let status: [String]

    var turns: [String] {
        ordinary + dispatch + status
    }
}

private func percentile(_ values: [Double], fraction: Double) -> Double {
    let ordered = values.sorted()
    let rank = max(1, Int(ceil(Double(ordered.count) * fraction)))
    return ordered[min(ordered.count - 1, rank - 1)]
}

@main
private enum Gate4NativeOverhead {
    static func main() async throws {
        let corpusURL = URL(fileURLWithPath:
            "Fixtures/Gate4/latency-corpus.json")
        let corpus = try JSONDecoder().decode(
            Corpus.self,
            from: Data(contentsOf: corpusURL)
        )
        guard corpus.turns.count == 100 else {
            throw NSError(
                domain: "Gate4NativeOverhead",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected 100 turns"]
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let interactor = ResponsesInteractor(
            configuration: .init(
                endpoint: URL(string: "http://127.0.0.1:47831/v1/responses")!,
                model: "fixture",
                timeout: .seconds(1)
            ),
            session: session
        )
        let bridge = MoshiReferenceBridge()
        let referenceClient = MoshiReferenceHTTPClient(
            endpoint: URL(string: "http://127.0.0.1:47831/api/reference")!,
            session: session
        )
        await bridge.setDeliverySink { delivery in
            try await referenceClient.accept(delivery)
        }
        let coordinator = ConversationCoordinator(
            interactor: interactor,
            piDispatcher: FixturePiDispatcher(),
            referenceDelivery: bridge,
            policy: PiRequestPolicy(projectName: "Workspace")
        )
        let voiceSessionID = UUID()
        await coordinator.beginVoiceSession(voiceSessionID)
        await bridge.beginSession(voiceSessionID) { utterance in
            try await coordinator.commit(utterance)
        }

        for transcript in corpus.ordinary.prefix(10) {
            _ = try await bridge.resolve(transcript)
        }

        var durations: [Double] = []
        for transcript in corpus.turns {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try await bridge.resolve(transcript)
            let ended = DispatchTime.now().uptimeNanoseconds
            durations.append(Double(ended - started) / 1_000_000_000)
        }

        let summary: [String: Any] = [
            "schema_version": 1,
            "turn_count": durations.count,
            "median_seconds": percentile(durations, fraction: 0.5),
            "p95_seconds": percentile(durations, fraction: 0.95),
            "maximum_seconds": durations.max()!,
            "measured_path": [
                "Responses URLSession transport",
                "SSE decoding",
                "structured-output decoding",
                "local utterance binding",
                "intent reconciliation",
                "Interaction validation",
                "Coordinator policy",
                "Moshi Reference bridge",
                "Reference HTTP encoding and transport"
            ]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: summary,
            options: [.prettyPrinted, .sortedKeys]
        )
        print(String(decoding: data, as: UTF8.self))

        if percentile(durations, fraction: 0.95) > 0.050 {
            throw NSError(
                domain: "Gate4NativeOverhead",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Native p95 overhead exceeded 50 milliseconds"
                ]
            )
        }
    }
}
