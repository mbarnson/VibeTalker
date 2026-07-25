import Foundation

nonisolated protocol PiRPCRequesting: Sendable {
    func request(_ command: PiRPCCommand) async throws -> PiRPCResponse
}

extension PiRPCClient: PiRPCRequesting {}

nonisolated enum PiGroundedJobState: Equatable, Sendable {
    case unavailable
    case idle
    case starting
    case running
    case cancelling
    case completed(String?)
    case failed(String)
    case aborted

    var isRunning: Bool {
        switch self {
        case .starting, .running, .cancelling: true
        case .unavailable, .idle, .completed, .failed, .aborted: false
        }
    }

    var summary: String {
        switch self {
        case .unavailable: "Pi RPC is unavailable."
        case .idle: "No coding job is active."
        case .starting: "The coding job is being admitted."
        case .running: "The coding job is running."
        case .cancelling: "Cancellation is pending."
        case .completed(let summary):
            summary.map { "Completed. \($0)" } ?? "The coding job completed."
        case .failed(let message): "Failed. \(message)"
        case .aborted: "The coding job was cancelled."
        }
    }
}

nonisolated enum PiJobControllerError: LocalizedError, Equatable {
    case runtimeUnavailable
    case jobAlreadyActive
    case noActiveJob
    case missingInstruction

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            "Pi RPC is unavailable."
        case .jobAlreadyActive:
            "A coding job is already active."
        case .noActiveJob:
            "No coding job is active."
        case .missingInstruction:
            "A start request requires an instruction."
        }
    }
}

actor PiJobController: PiRequestDispatching {
    private let rpc: any PiRPCRequesting
    private let projectName: String
    private var state: PiGroundedJobState = .unavailable
    private var pendingOutcome: PiTerminalOutcome?

    init(rpc: any PiRPCRequesting, projectName: String) {
        self.rpc = rpc
        self.projectName = projectName
    }

    func runtimeBecameReady() {
        state = .idle
        pendingOutcome = nil
    }

    func runtimeStopped() {
        state = .unavailable
        pendingOutcome = nil
    }

    func snapshot() -> PiGroundedJobState {
        state
    }

    func dispatch(_ request: PiRequest) async throws -> PiDispatchReceipt {
        switch request.operation {
        case .start:
            return try await start(request.instruction)
        case .cancel:
            return try await cancel()
        case .status:
            return .status(projectName: projectName, summary: state.summary)
        }
    }

    func receive(_ event: PiRPCEvent) {
        if event.type == "process_ended" {
            runtimeStopped()
            return
        }
        if event.type == "agent_start", state != .cancelling {
            state = .running
        }
        if let outcome = PiJobEventInterpreter.terminalOutcome(from: event) {
            pendingOutcome = outcome
        }
        guard event.type == "agent_end",
              event.raw["willRetry"] != .boolean(true) else {
            return
        }
        let outcome = pendingOutcome ?? .completed(summary: nil)
        pendingOutcome = nil
        switch outcome {
        case .completed(let summary):
            state = .completed(summary)
        case .failed(let message):
            state = .failed(message)
        case .aborted:
            state = .aborted
        }
    }

    private func start(_ instruction: String?) async throws -> PiDispatchReceipt {
        guard state != .unavailable else {
            throw PiJobControllerError.runtimeUnavailable
        }
        guard !state.isRunning else {
            throw PiJobControllerError.jobAlreadyActive
        }
        let normalized = instruction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            throw PiJobControllerError.missingInstruction
        }

        state = .starting
        do {
            _ = try await rpc.request(.prompt(
                id: UUID().uuidString,
                message: normalized
            ))
            if state == .starting {
                state = .running
            }
            return .started(projectName: projectName)
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func cancel() async throws -> PiDispatchReceipt {
        guard state != .unavailable else {
            throw PiJobControllerError.runtimeUnavailable
        }
        guard state.isRunning else {
            throw PiJobControllerError.noActiveJob
        }

        let stateBeforeCancellation = state
        state = .cancelling
        do {
            _ = try await rpc.request(.abort(id: UUID().uuidString))
            return .cancellationRequested(projectName: projectName)
        } catch {
            if state == .cancelling {
                state = stateBeforeCancellation
            }
            throw error
        }
    }
}
