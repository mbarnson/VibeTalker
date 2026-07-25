import Foundation

struct PreflightDetail: Sendable {
    let passed: Bool
    let message: String
}

struct NativePreflightReport: Sendable {
    let details: [PreflightDetail]

    var passed: Bool {
        details.allSatisfy(\.passed)
    }

    var helperRoundTrip: String {
        details.first(where: { $0.message.hasPrefix("stdio:") })?.message ?? "Unavailable"
    }

    var jitComparison: String {
        details.first(where: { $0.message.hasPrefix("JIT:") })?.message ?? "Unavailable"
    }

    var sandboxSummary: String {
        let checks = details.filter {
            $0.message.hasPrefix("outside write:") || $0.message.hasPrefix("network:")
        }
        return checks.isEmpty ? "Unavailable" : checks.map(\.message).joined(separator: " · ")
    }
}

enum NativePreflightError: LocalizedError {
    case helperMissing
    case malformedResponse
    case helperFailure(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            "The embedded Node helper is missing from the application bundle."
        case .malformedResponse:
            "The Node helper returned malformed JSON."
        case .helperFailure(let message):
            "The Node helper failed: \(message)"
        }
    }
}

actor NativePreflight {
    private let helperURL: URL?

    init(helperURL: URL? = nil) {
        self.helperURL = helperURL
    }

    func run() async throws -> NativePreflightReport {
        let nodeURL = helperURL ?? Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/vibetalker-node")
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path) else {
            throw NativePreflightError.helperMissing
        }
        guard let scriptURL = Bundle.main.url(
            forResource: "native-preflight-helper",
            withExtension: "mjs"
        ), let opensslConfigurationURL = Bundle.main.url(
            forResource: "openssl",
            withExtension: "cnf"
        ) else {
            throw NativePreflightError.helperMissing
        }

        let client = JSONLineProcessClient(
            executableURL: nodeURL,
            arguments: [scriptURL.path],
            environment: [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "NODE_NO_WARNINGS": "1",
                "OPENSSL_CONF": opensslConfigurationURL.path,
                "PATH": "/usr/bin:/bin",
                "TMPDIR": FileManager.default.temporaryDirectory.path
            ]
        )

        let ping = try await client.request(["operation": "ping"])
        let jit = try await client.request(["operation": "jit"])
        let escape = try await client.request(["operation": "escapeFixtures"])

        let pong = ping["message"] as? String == "pong"
        let jitEnabled = jit["jit"] as? Bool == true
        let jitless = jit["jitlessCompatible"] as? Bool == true
        let outsideDenied = escape["outsideWriteDenied"] as? Bool == true
        let networkDenied = escape["networkDenied"] as? Bool == true

        return NativePreflightReport(details: [
            .init(passed: pong, message: "stdio: \(pong ? "ping/pong passed" : "ping/pong failed")"),
            .init(
                passed: jitEnabled && jitless,
                message: "JIT: enabled=\(jitEnabled), --jitless comparison=\(jitless)"
            ),
            .init(
                passed: outsideDenied,
                message: "outside write: \(outsideDenied ? "denied" : "NOT denied")"
            ),
            .init(
                passed: networkDenied,
                message: "network: \(networkDenied ? "denied" : "NOT denied")"
            )
        ])
    }
}

private struct JSONLineProcessClient: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]

    func request(_ payload: [String: String]) async throws -> [String: Any] {
        try await Task.detached {
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors

            try process.run()
            let data = try JSONSerialization.data(withJSONObject: payload)
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.write(Data([0x0A]))
            try input.fileHandleForWriting.close()

            process.waitUntilExit()
            let result = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()

            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8) ?? "unknown error"
                throw NativePreflightError.helperFailure(message)
            }
            guard
                let line = String(data: result, encoding: .utf8)?
                    .split(separator: "\n").first,
                let response = try JSONSerialization.jsonObject(
                    with: Data(line.utf8)
                ) as? [String: Any]
            else {
                throw NativePreflightError.malformedResponse
            }
            return response
        }.value
    }
}
