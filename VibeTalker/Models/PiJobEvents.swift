import Foundation

nonisolated enum PiTerminalOutcome: Equatable, Sendable {
    case completed(summary: String?)
    case aborted
    case failed(String)

    func proactiveReference(projectName: String) -> String {
        let project = projectName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let update: String
        switch self {
        case .completed(let summary):
            let normalized = summary?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            update = normalized.flatMap { $0.isEmpty ? nil : $0 }
                .map { "The \(project) project is complete. \($0)" }
                ?? "The \(project) project is complete."
        case .aborted:
            update = "Work in the \(project) project was cancelled."
        case .failed(let message):
            let normalized = message
                .trimmingCharacters(in: .whitespacesAndNewlines)
            update = normalized.isEmpty
                ? "Work in the \(project) project failed."
                : "Work in the \(project) project failed. \(normalized)"
        }
        let firstInstruction =
            "Say exactly this completion announcement and nothing else: "
        let repeatInstruction = " Repeat the exact announcement: "
        let redactedUpdate = SecretRedactor.redact(update)
        let updateLimit = max(
            0,
            (400 - firstInstruction.count - repeatInstruction.count) / 2
        )
        let boundedUpdate = String(redactedUpdate.prefix(updateLimit))
        return firstInstruction
            + boundedUpdate
            + repeatInstruction
            + boundedUpdate
    }
}

nonisolated struct PiJobEventProjection: Equatable, Sendable {
    enum Lifecycle: Equatable, Sendable {
        case unchanged
        case started
        case ended(PiTerminalOutcome)
    }

    let kind: LedgerEventKind
    let message: String
    let lifecycle: Lifecycle
}

nonisolated enum PiJobEventInterpreter {
    static func project(
        _ event: PiRPCEvent,
        pendingOutcome: PiTerminalOutcome?
    ) -> PiJobEventProjection? {
        switch event.type {
        case "agent_start":
            return .init(
                kind: .helper,
                message: "Pi agent started",
                lifecycle: .started
            )

        case "tool_execution_start":
            let tool = event.raw.string(at: "toolName") ?? "unknown"
            let subject = event.raw.object(at: "args")?.string(at: "path")
            return .init(
                kind: .helper,
                message: subject.map { "Pi started \(tool): \($0)" }
                    ?? "Pi started \(tool)",
                lifecycle: .unchanged
            )

        case "tool_execution_end":
            let tool = event.raw.string(at: "toolName") ?? "unknown"
            let isError = event.raw.boolean(at: "isError") ?? false
            return .init(
                kind: isError ? .error : .helper,
                message: "Pi \(tool) \(isError ? "failed" : "finished")",
                lifecycle: .unchanged
            )

        case "turn_end":
            guard let message = event.raw.object(at: "message") else { return nil }
            let reason = message.string(at: "stopReason")
            let assistantText = message.assistantText()
            switch reason {
            case "aborted":
                return .init(
                    kind: .policy,
                    message: "Pi acknowledged cancellation",
                    lifecycle: .unchanged
                )
            case "error":
                return .init(
                    kind: .error,
                    message: "Pi turn failed: \(message.string(at: "errorMessage") ?? "unknown error")",
                    lifecycle: .unchanged
                )
            default:
                guard let assistantText, !assistantText.isEmpty else { return nil }
                return .init(
                    kind: .helper,
                    message: "Pi: \(assistantText)",
                    lifecycle: .unchanged
                )
            }

        case "agent_end":
            if event.raw.boolean(at: "willRetry") == true {
                return .init(
                    kind: .helper,
                    message: "Pi is retrying after a recoverable failure",
                    lifecycle: .unchanged
                )
            }
            let outcome = pendingOutcome ?? .completed(summary: nil)
            switch outcome {
            case .completed(let summary):
                return .init(
                    kind: .completion,
                    message: summary.map { "Pi completed: \($0)" } ?? "Pi job completed",
                    lifecycle: .ended(outcome)
                )
            case .aborted:
                return .init(
                    kind: .policy,
                    message: "Pi job aborted",
                    lifecycle: .ended(outcome)
                )
            case .failed(let error):
                return .init(
                    kind: .error,
                    message: "Pi job failed: \(error)",
                    lifecycle: .ended(outcome)
                )
            }

        default:
            return nil
        }
    }

    static func terminalOutcome(from event: PiRPCEvent) -> PiTerminalOutcome? {
        guard event.type == "turn_end",
              let message = event.raw.object(at: "message") else {
            return nil
        }
        switch message.string(at: "stopReason") {
        case "aborted":
            return .aborted
        case "error":
            return .failed(message.string(at: "errorMessage") ?? "unknown error")
        case "stop", "length":
            return .completed(summary: message.assistantText())
        default:
            return nil
        }
    }
}

private nonisolated extension Dictionary where Key == String, Value == JSONValue {
    func string(at key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }

    func boolean(at key: String) -> Bool? {
        guard case .boolean(let value)? = self[key] else { return nil }
        return value
    }

    func object(at key: String) -> [String: JSONValue]? {
        guard case .object(let value)? = self[key] else { return nil }
        return value
    }

    func assistantText() -> String? {
        guard case .array(let content)? = self["content"] else { return nil }
        let fragments = content.compactMap { item -> String? in
            guard case .object(let object) = item,
                  object.string(at: "type") == "text" else {
                return nil
            }
            return object.string(at: "text")
        }
        let text = fragments.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
