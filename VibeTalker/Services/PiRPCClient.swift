import Foundation

nonisolated enum PiRPCClientError: LocalizedError {
    case notRunning
    case duplicateRequest(String)
    case malformedRecord(String)
    case requestFailed(String)
    case processEnded

    var errorDescription: String? {
        switch self {
        case .notRunning:
            "The pi RPC session is not running."
        case .duplicateRequest(let id):
            "Duplicate pi RPC request identifier: \(id)"
        case .malformedRecord(let record):
            "Malformed pi RPC record: \(record)"
        case .requestFailed(let message):
            "Pi RPC request failed: \(message)"
        case .processEnded:
            "The pi RPC process ended."
        }
    }
}

actor PiRPCClient {
    typealias EventSink = @Sendable (PiRPCEvent) async -> Void

    private let processes: ProcessCoordinator
    private var pending: [String: CheckedContinuation<PiRPCResponse, Error>] = [:]
    private var eventSink: EventSink?
    private var running = false

    init(processes: ProcessCoordinator) {
        self.processes = processes
    }

    func start(
        spec: RuntimeProcessSpec,
        events: @escaping EventSink
    ) async throws {
        guard spec.service == .pi else {
            throw ProcessCoordinatorError.launchFailed(.pi, "spec is not for pi")
        }
        eventSink = events
        try await processes.start(spec) { [weak self] event in
            await self?.receive(event)
        }
        running = true
    }

    func request(_ command: PiRPCCommand) async throws -> PiRPCResponse {
        guard running else { throw PiRPCClientError.notRunning }
        let id = command.id
        guard pending[id] == nil else {
            throw PiRPCClientError.duplicateRequest(id)
        }
        let line = String(
            data: try JSONEncoder().encode(command),
            encoding: .utf8
        )!

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await processes.writeLine(line, to: .pi)
                } catch {
                    failPendingRequest(id: id, error: error)
                }
            }
        }
    }

    func stop() async {
        await processes.stop(.pi)
        finishPending(with: PiRPCClientError.processEnded)
        running = false
    }

    private func receive(_ processEvent: RuntimeProcessEvent) async {
        if processEvent.stream == .lifecycle {
            if processEvent.message.hasPrefix("exited") {
                running = false
                finishPending(with: PiRPCClientError.processEnded)
                let ended = PiRPCEventFallback(
                    type: "process_ended",
                    record: processEvent.message
                )
                await eventSink?(ended.event)
            }
            return
        }
        if processEvent.stream == .standardError {
            let diagnostic = PiRPCEventFallback(
                type: "process_stderr",
                record: processEvent.message
            )
            await eventSink?(diagnostic.event)
            return
        }
        guard processEvent.stream == .standardOutput else { return }

        let data = Data(processEvent.message.utf8)
        do {
            let response = try JSONDecoder().decode(PiRPCResponse.self, from: data)
            if response.type == "response", let id = response.id,
               let continuation = pending.removeValue(forKey: id) {
                if response.success == false {
                    continuation.resume(
                        throwing: PiRPCClientError.requestFailed(
                            response.error ?? "unknown failure"
                        )
                    )
                } else {
                    continuation.resume(returning: response)
                }
                return
            }
            let event = try JSONDecoder().decode(PiRPCEvent.self, from: data)
            await eventSink?(event)
        } catch {
            let malformed = PiRPCEventFallback(
                type: "protocol_error",
                record: processEvent.message
            )
            await eventSink?(malformed.event)
        }
    }

    private func finishPending(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func failPendingRequest(id: String, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }
}

private nonisolated struct PiRPCEventFallback {
    let type: String
    let record: String

    var event: PiRPCEvent {
        let data = try! JSONEncoder().encode([
            "type": JSONValue.string(type),
            "record": JSONValue.string(record)
        ])
        return try! JSONDecoder().decode(PiRPCEvent.self, from: data)
    }
}
