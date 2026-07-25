import Foundation

enum RuntimeService: String, CaseIterable, Sendable {
    case moshi
    case referenceEncoder
    case speechToText
    case pi
}

enum RuntimeProcessState: Equatable, Sendable {
    case stopped
    case starting
    case running(processIdentifier: Int32)
    case failed(String)
}

struct RuntimeProcessSpec: Sendable {
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

enum ProcessCoordinatorError: LocalizedError, Equatable {
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

struct RuntimeProcessEvent: Sendable {
    enum Stream: String, Sendable {
        case lifecycle
        case standardOutput
        case standardError
    }

    let service: RuntimeService
    let stream: Stream
    let message: String
}

private final class ManagedProcess: @unchecked Sendable {
    let process: Process
    let standardOutput: Pipe
    let standardError: Pipe

    init(process: Process, standardOutput: Pipe, standardError: Pipe) {
        self.process = process
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
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        process.currentDirectoryURL = spec.workingDirectoryURL
        process.environment = spec.environment
        process.standardOutput = standardOutput
        process.standardError = standardError

        let service = spec.service
        standardOutput.fileHandleForReading.readabilityHandler = {
            Self.forward($0.availableData, service: service, stream: .standardOutput, to: events)
        }
        standardError.fileHandleForReading.readabilityHandler = {
            Self.forward($0.availableData, service: service, stream: .standardError, to: events)
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
        _ data: Data,
        service: RuntimeService,
        stream: RuntimeProcessEvent.Stream,
        to events: @escaping EventSink
    ) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return
        }
        for line in text.split(whereSeparator: \.isNewline) {
            Task {
                await events(.init(
                    service: service,
                    stream: stream,
                    message: String(line)
                ))
            }
        }
    }
}
