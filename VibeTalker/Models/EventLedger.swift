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
    let schemaVersion: UInt8
    let id: UUID
    let sequence: UInt64
    let monotonicNanoseconds: UInt64
    let timestamp: Date
    let source: String
    let kind: LedgerEventKind
    let message: String
    let voiceSessionID: UUID?
    let utteranceID: UUID?
    let revision: UInt64?
    let interactionRequestID: UUID?
    let actionJobID: UUID?

    init(
        schemaVersion: UInt8 = 1,
        id: UUID = UUID(),
        sequence: UInt64,
        monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        timestamp: Date = .now,
        source: String = "native-host",
        kind: LedgerEventKind,
        message: String,
        voiceSessionID: UUID? = nil,
        utteranceID: UUID? = nil,
        revision: UInt64? = nil,
        interactionRequestID: UUID? = nil,
        actionJobID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.sequence = sequence
        self.monotonicNanoseconds = monotonicNanoseconds
        self.timestamp = timestamp
        self.source = source
        self.kind = kind
        self.message = message
        self.voiceSessionID = voiceSessionID
        self.utteranceID = utteranceID
        self.revision = revision
        self.interactionRequestID = interactionRequestID
        self.actionJobID = actionJobID
    }
}

actor EventLedger {
    private let persistence: EventLedgerPersistence?
    private let recentLimit: Int
    private var events: [LedgerEvent]
    private var nextSequence: UInt64
    private var droppedPersistenceEvents: UInt64 = 0

    init(fileURL: URL? = nil, recentLimit: Int = 500) {
        self.recentLimit = max(1, recentLimit)
        if let fileURL {
            let restored = Self.restoreRecent(
                from: fileURL,
                limit: self.recentLimit
            )
            events = restored
            nextSequence = (restored.last?.sequence ?? 0) + 1
            persistence = EventLedgerPersistence(fileURL: fileURL)
        } else {
            events = []
            nextSequence = 1
            persistence = nil
        }
    }

    func append(
        _ kind: LedgerEventKind,
        _ message: String,
        source: String = "native-host",
        voiceSessionID: UUID? = nil,
        utteranceID: UUID? = nil,
        revision: UInt64? = nil,
        interactionRequestID: UUID? = nil,
        actionJobID: UUID? = nil
    ) -> LedgerEvent {
        if droppedPersistenceEvents > 0 {
            let count = droppedPersistenceEvents
            droppedPersistenceEvents = 0
            let diagnostic = makeEvent(
                .diagnostic,
                "Event Ledger persistence dropped \(count) event(s)",
                source: "event-ledger"
            )
            store(diagnostic)
        }

        let event = makeEvent(
            kind,
            message,
            source: source,
            voiceSessionID: voiceSessionID,
            utteranceID: utteranceID,
            revision: revision,
            interactionRequestID: interactionRequestID,
            actionJobID: actionJobID
        )
        store(event)
        return event
    }

    func snapshot() -> [LedgerEvent] {
        events
    }

    private func makeEvent(
        _ kind: LedgerEventKind,
        _ message: String,
        source: String,
        voiceSessionID: UUID? = nil,
        utteranceID: UUID? = nil,
        revision: UInt64? = nil,
        interactionRequestID: UUID? = nil,
        actionJobID: UUID? = nil
    ) -> LedgerEvent {
        defer { nextSequence += 1 }
        return LedgerEvent(
            sequence: nextSequence,
            source: source,
            kind: kind,
            message: SecretRedactor.redact(message),
            voiceSessionID: voiceSessionID,
            utteranceID: utteranceID,
            revision: revision,
            interactionRequestID: interactionRequestID,
            actionJobID: actionJobID
        )
    }

    private func store(_ event: LedgerEvent) {
        events.append(event)
        if events.count > recentLimit {
            events.removeFirst(events.count - recentLimit)
        }
        guard let persistence else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var record = try encoder.encode(event)
            record.append(0x0A)
            if !persistence.enqueue(record) {
                droppedPersistenceEvents += 1
            }
        } catch {
            droppedPersistenceEvents += 1
        }
    }

    private static func restoreRecent(
        from fileURL: URL,
        limit: Int
    ) -> [LedgerEvent] {
        guard let data = readTail(from: fileURL, lineLimit: limit),
              !data.isEmpty else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .suffix(limit)
            .compactMap { try? decoder.decode(LedgerEvent.self, from: Data($0)) }
            .sorted { $0.sequence < $1.sequence }
    }

    private static func readTail(
        from fileURL: URL,
        lineLimit: Int,
        chunkSize: UInt64 = 64 * 1_024,
        maximumBytes: UInt64 = 8 * 1_024 * 1_024
    ) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else {
            return nil
        }

        var offset = fileSize
        var data = Data()
        var newlineCount = 0
        while offset > 0,
              UInt64(data.count) < maximumBytes,
              newlineCount <= lineLimit {
            let count = min(chunkSize, offset, maximumBytes - UInt64(data.count))
            offset -= count
            do {
                try handle.seek(toOffset: offset)
                guard let chunk = try handle.read(upToCount: Int(count)),
                      !chunk.isEmpty else {
                    break
                }
                newlineCount += chunk.reduce(into: 0) { count, byte in
                    if byte == 0x0A {
                        count += 1
                    }
                }
                data.insert(contentsOf: chunk, at: 0)
            } catch {
                return nil
            }
        }
        return data
    }
}

private nonisolated final class EventLedgerPersistence: @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation

    init(fileURL: URL, capacity: Int = 1_024) {
        var capturedContinuation: AsyncStream<Data>.Continuation?
        let stream = AsyncStream<Data>(
            bufferingPolicy: .bufferingNewest(capacity)
        ) { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!

        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !fileManager.fileExists(atPath: fileURL.path) {
                    guard fileManager.createFile(
                        atPath: fileURL.path,
                        contents: nil
                    ) else {
                        return
                    }
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                for await record in stream {
                    try handle.write(contentsOf: record)
                }
                try handle.synchronize()
                try handle.close()
            } catch {
                return
            }
        }
    }

    deinit {
        continuation.finish()
    }

    func enqueue(_ record: Data) -> Bool {
        switch continuation.yield(record) {
        case .enqueued:
            true
        case .dropped, .terminated:
            false
        @unknown default:
            false
        }
    }
}

nonisolated enum SecretRedactor {
    private static let expressions: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"(?i)(api[_-]?key|token|secret|password)\s*[:=]\s*[^\s,;]+"#
        ),
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
