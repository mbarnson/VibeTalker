import Foundation

nonisolated enum LedgerEventKind: String, Codable, CaseIterable, Sendable {
    case system
    case diagnostic
    case transcript
    case reference
    case request
    case policy
    case helper
    case error
    case completion
}

nonisolated struct LedgerEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let sequence: UInt64
    let timestamp: Date
    let kind: LedgerEventKind
    let message: String
    let turnID: UUID?
    let jobID: UUID?

    init(
        id: UUID = UUID(),
        sequence: UInt64,
        timestamp: Date = .now,
        kind: LedgerEventKind,
        message: String,
        turnID: UUID? = nil,
        jobID: UUID? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
        self.turnID = turnID
        self.jobID = jobID
    }
}

actor EventLedger {
    private var events: [LedgerEvent] = []
    private var nextSequence: UInt64 = 1

    func append(
        _ kind: LedgerEventKind,
        _ message: String,
        turnID: UUID? = nil,
        jobID: UUID? = nil
    ) -> LedgerEvent {
        let event = LedgerEvent(
            sequence: nextSequence,
            kind: kind,
            message: SecretRedactor.redact(message),
            turnID: turnID,
            jobID: jobID
        )
        nextSequence += 1
        events.append(event)
        return event
    }

    func snapshot() -> [LedgerEvent] {
        events
    }
}

nonisolated enum SecretRedactor {
    private static let expressions: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)(api[_-]?key|token|secret|password)\s*[:=]\s*[^\s,;]+"#),
        try! NSRegularExpression(pattern: #"\b(sk-[A-Za-z0-9_-]{12,})\b"#),
        try! NSRegularExpression(pattern: #"\b(gh[oprsu]_[A-Za-z0-9]{20,})\b"#)
    ]

    static func redact(_ text: String) -> String {
        expressions.reduce(text) { partial, expression in
            let range = NSRange(partial.startIndex..., in: partial)
            return expression.stringByReplacingMatches(
                in: partial,
                range: range,
                withTemplate: "[REDACTED]"
            )
        }
    }
}
