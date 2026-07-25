import Foundation

nonisolated enum RuntimeService: String, CaseIterable, Sendable {
    case moshi
    case referenceEncoder
    case speechToText
    case pi
}

nonisolated enum RuntimeProcessState: Equatable, Sendable {
    case stopped
    case starting
    case running(processIdentifier: Int32)
    case failed(String)
}

nonisolated struct RuntimeProcessSpec: Sendable {
    let service: RuntimeService
    let executableURL: URL
    let arguments: [String]
    let workingDirectoryURL: URL
    let environment: [String: String]

    func validate(fileManager: FileManager = .default) throws {
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw ProcessCoordinatorError.executableMissing(executableURL.path)
        }
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(
                atPath: workingDirectoryURL.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            throw ProcessCoordinatorError.workingDirectoryMissing(
                workingDirectoryURL.path
            )
        }
    }
}

nonisolated enum ProcessCoordinatorError: LocalizedError, Equatable {
    case alreadyRunning(RuntimeService)
    case executableMissing(String)
    case workingDirectoryMissing(String)
    case launchFailed(RuntimeService, String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning(let service):
            "\(service.rawValue) is already running."
        case .executableMissing(let path):
            "Runtime executable is missing or not executable: \(path)"
        case .workingDirectoryMissing(let path):
            "Runtime working directory is missing: \(path)"
        case .launchFailed(let service, let message):
            "Could not launch \(service.rawValue): \(message)"
        }
    }
}

nonisolated struct RuntimeProcessEvent: Sendable {
    enum Stream: String, Sendable {
        case lifecycle
        case standardOutput
        case standardError
    }

    let service: RuntimeService
    let stream: Stream
    let message: String
}

private nonisolated final class ManagedProcess: @unchecked Sendable {
    let process: Process
    let standardInput: Pipe
    let standardOutput: Pipe
    let standardError: Pipe

    init(
        process: Process,
        standardInput: Pipe,
        standardOutput: Pipe,
        standardError: Pipe
    ) {
        self.process = process
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

actor ProcessCoordinator {
    typealias EventSink = @Sendable (RuntimeProcessEvent) async -> Void

    private var managed: [RuntimeService: ManagedProcess] = [:]
    private var states: [RuntimeService: RuntimeProcessState] = [:]
    private var requestedStops: Set<RuntimeService> = []

    func state(for service: RuntimeService) -> RuntimeProcessState {
        states[service] ?? .stopped
    }

    func snapshot() -> [RuntimeService: RuntimeProcessState] {
        Dictionary(
            uniqueKeysWithValues: RuntimeService.allCases.map {
                ($0, states[$0] ?? .stopped)
            }
        )
    }

    func start(_ spec: RuntimeProcessSpec, events: @escaping EventSink) async throws {
        if managed[spec.service] != nil {
            throw ProcessCoordinatorError.alreadyRunning(spec.service)
        }

        try spec.validate()
        states[spec.service] = .starting

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let outputLines = LineAccumulator()
        let errorLines = LineAccumulator()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        process.currentDirectoryURL = spec.workingDirectoryURL
        process.environment = spec.environment
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        let service = spec.service
        standardOutput.fileHandleForReading.readabilityHandler = {
            Self.forward(
                outputLines.consume($0.availableData),
                service: service,
                stream: .standardOutput,
                to: events
            )
        }
        standardError.fileHandleForReading.readabilityHandler = {
            Self.forward(
                errorLines.consume($0.availableData),
                service: service,
                stream: .standardError,
                to: events
            )
        }
        process.terminationHandler = { [weak self] completed in
            Task {
                await self?.didTerminate(
                    service,
                    status: completed.terminationStatus,
                    events: events
                )
            }
        }

        do {
            try process.run()
        } catch {
            states[service] = .failed(error.localizedDescription)
            throw ProcessCoordinatorError.launchFailed(service, error.localizedDescription)
        }

        managed[service] = ManagedProcess(
            process: process,
            standardInput: standardInput,
            standardOutput: standardOutput,
            standardError: standardError
        )
        states[service] = .running(processIdentifier: process.processIdentifier)
        await events(.init(
            service: service,
            stream: .lifecycle,
            message: "started pid=\(process.processIdentifier)"
        ))
    }

    func stop(_ service: RuntimeService) async {
        guard let item = managed[service] else {
            states[service] = .stopped
            return
        }
        requestedStops.insert(service)
        item.process.terminate()
    }

    func stopAll() async {
        for service in RuntimeService.allCases {
            await stop(service)
        }
    }

    func writeLine(_ line: String, to service: RuntimeService) throws {
        guard let item = managed[service], item.process.isRunning else {
            throw ProcessCoordinatorError.launchFailed(service, "process is not running")
        }
        guard !line.contains("\n"), let data = "\(line)\n".data(using: .utf8) else {
            throw ProcessCoordinatorError.launchFailed(service, "invalid JSONL record")
        }
        try item.standardInput.fileHandleForWriting.write(contentsOf: data)
    }

    private func didTerminate(
        _ service: RuntimeService,
        status: Int32,
        events: @escaping EventSink
    ) async {
        guard let item = managed.removeValue(forKey: service) else { return }
        item.standardOutput.fileHandleForReading.readabilityHandler = nil
        item.standardError.fileHandleForReading.readabilityHandler = nil
        let wasRequested = requestedStops.remove(service) != nil
        states[service] = (status == 0 || wasRequested)
            ? .stopped
            : .failed("exit status \(status)")
        await events(.init(
            service: service,
            stream: .lifecycle,
            message: "exited status=\(status)"
        ))
    }

    private nonisolated static func forward(
        _ lines: [String],
        service: RuntimeService,
        stream: RuntimeProcessEvent.Stream,
        to events: @escaping EventSink
    ) {
        for line in lines {
            Task {
                await events(.init(
                    service: service,
                    stream: stream,
                    message: line
                ))
            }
        }
    }
}

private nonisolated final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func consume(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)

        var records: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var record = pending[..<newline]
            if record.last == 0x0D {
                record = record.dropLast()
            }
            if let line = String(data: record, encoding: .utf8) {
                records.append(line)
            }
            pending.removeSubrange(...newline)
        }
        return records
    }
}
