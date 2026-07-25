//
//  VibeTalkerTests.swift
//  VibeTalkerTests
//
//  Created by Matthew Barnson on 7/24/26.
//

import Foundation
import Testing
@testable import VibeTalker

struct VibeTalkerTests {
    @Test func ledgerMaintainsOrderAndRedactsSecrets() async {
        let ledger = EventLedger()
        let first = await ledger.append(.system, "started")
        let second = await ledger.append(.error, "api_key=do-not-publish")
        let events = await ledger.snapshot()

        #expect(first.sequence == 1)
        #expect(second.sequence == 2)
        #expect(events.map(\.sequence) == [1, 2])
        #expect(events[1].message == "[REDACTED]")
    }

    @Test func redactorCoversProviderTokens() {
        let value = SecretRedactor.redact(
            "token: abcdefghijklmnop sk-abcdefghijklmnop ghp_abcdefghijklmnopqrstuvwxyz"
        )

        #expect(!value.contains("abcdefghijklmnop"))
        #expect(!value.contains("ghp_"))
    }

    @Test func runtimeProcessSpecRejectsMissingExecutable() {
        let spec = RuntimeProcessSpec(
            service: .moshi,
            executableURL: URL(fileURLWithPath: "/definitely/missing/vibetalker-runtime"),
            arguments: [],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            environment: [:]
        )

        #expect(throws: ProcessCoordinatorError.self) {
            try spec.validate()
        }
    }

    @Test func processCoordinatorStartsCapturesOutputAndStops() async throws {
        let coordinator = ProcessCoordinator()
        let collector = RuntimeEventCollector()
        let spec = RuntimeProcessSpec(
            service: .referenceEncoder,
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo conditioner-ready; sleep 30"],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            environment: ["PATH": "/usr/bin:/bin"]
        )

        try await coordinator.start(spec) { event in
            await collector.append(event)
        }
        let state = await coordinator.state(for: .referenceEncoder)
        guard case .running = state else {
            Issue.record("Expected a running reference encoder, got \(state)")
            return
        }

        try await Task.sleep(for: .milliseconds(100))
        #expect(await collector.messages().contains("conditioner-ready"))

        await coordinator.stop(.referenceEncoder)
        for _ in 0..<20 {
            if await coordinator.state(for: .referenceEncoder) == .stopped {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await coordinator.state(for: .referenceEncoder) == .stopped)
    }

    @Test func runtimeInstallationBuildsPinnedLocalTopology() throws {
        let root = URL(fileURLWithPath: "/tmp/VibeTalker-Runtime-Fixture")
        let installation = RuntimeInstallation(rootURL: root)

        #expect(installation.mlxPythonURL.path.hasSuffix("moshi-mlx/.venv/bin/python"))
        #expect(installation.ragPythonURL.path.hasSuffix("moshi-rag/.venv/bin/python"))
        #expect(installation.moshiWeightURL.path.hasSuffix(
            "Models/moshika-rag-mlx-bf16.safetensors"
        ))
        #expect(throws: RuntimeInstallationError.self) {
            _ = try installation.voiceLaunchSpecs()
        }
    }

    @Test func piLaunchUsesBundledCodeAndMinimalEnvironment() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appending(path: "VibeTalker-Pi-Fixture-\(UUID().uuidString)")
        let managedRoot = fixture.appending(path: "managed")
        let bundledRoot = fixture.appending(path: "bundled")
        let piRoot = bundledRoot.appending(path: "pi")
        let rpcEntry = piRoot.appending(path: "packages/coding-agent/dist/rpc-entry.js")
        let policy = piRoot.appending(path: "vibetalker-tool-policy.ts")
        defer { try? FileManager.default.removeItem(at: fixture) }

        try FileManager.default.createDirectory(
            at: rpcEntry.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: rpcEntry)
        try Data().write(to: policy)

        let installation = RuntimeInstallation(
            rootURL: managedRoot,
            bundledRuntimeRootURL: bundledRoot
        )
        let spec = try installation.piLaunchSpec(
            nodeURL: URL(fileURLWithPath: "/bin/sh")
        )

        #expect(spec.executableURL.path == "/bin/sh")
        #expect(spec.arguments.first == rpcEntry.path)
        #expect(spec.arguments.contains(policy.path))
        #expect(spec.workingDirectoryURL.path.hasPrefix(managedRoot.deletingLastPathComponent().path))
        #expect(Set(spec.environment.keys) == Set([
            "HOME",
            "NODE_NO_WARNINGS",
            "OPENSSL_CONF",
            "PATH",
            "PI_CODING_AGENT_DIR",
            "TMPDIR"
        ]))
        #expect(spec.environment["OPENSSL_CONF"] == "/dev/null")
        #expect(spec.environment["HOME"] == managedRoot.path)
        #expect(spec.environment["PI_CODING_AGENT_DIR"] == managedRoot
            .appending(path: "PiConfig").path)

        let authenticatedSpec = try installation.piLaunchSpec(
            nodeURL: URL(fileURLWithPath: "/bin/sh"),
            credential: CodingProviderCredential(
                provider: .anthropic,
                value: "fixture-only"
            )
        )
        #expect(authenticatedSpec.environment["ANTHROPIC_API_KEY"] == "fixture-only")
        #expect(authenticatedSpec.environment["OPENAI_API_KEY"] == nil)
        #expect(authenticatedSpec.environment["OPENROUTER_API_KEY"] == nil)
    }

    @Test func interactionValidatorRejectsStaleAndPartialOutput() throws {
        let utterance = CommittedUtterance(
            voiceSessionID: UUID(),
            utteranceID: UUID(),
            revision: 1,
            transcript: "Please update the README."
        )

        #expect(throws: InteractionValidationError.staleUtterance) {
            try InteractionValidator.validate(
                InteractionOutput(
                    utteranceID: UUID(),
                    referenceResponse: "I can help with that.",
                    piRequest: nil
                ),
                for: utterance
            )
        }
        #expect(throws: InteractionValidationError.invalidPiRequest) {
            try InteractionValidator.validate(
                InteractionOutput(
                    utteranceID: utterance.utteranceID,
                    referenceResponse: "I can help with that.",
                    piRequest: PiRequest(operation: .start, instruction: nil)
                ),
                for: utterance
            )
        }
    }

    @Test func interactionValidatorNormalizesACompleteResult() throws {
        let utterance = CommittedUtterance(
            voiceSessionID: UUID(),
            utteranceID: UUID(),
            revision: 7,
            transcript: "Please update the README."
        )
        let result = try InteractionValidator.validate(
            InteractionOutput(
                utteranceID: utterance.utteranceID,
                referenceResponse: "  The request concerns the selected project.  ",
                piRequest: PiRequest(
                    operation: .start,
                    instruction: "  Update README and verify the diff.  "
                )
            ),
            for: utterance
        )

        #expect(result.referenceResponse == "The request concerns the selected project.")
        #expect(result.piRequest?.instruction == "Update README and verify the diff.")
    }

    @Test func processCoordinatorWritesAndReassemblesJSONLines() async throws {
        let coordinator = ProcessCoordinator()
        let collector = RuntimeEventCollector()
        let spec = RuntimeProcessSpec(
            service: .pi,
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "IFS= read -r line; printf '%s\\n' \"$line\""],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            environment: ["PATH": "/usr/bin:/bin"]
        )
        try await coordinator.start(spec) { event in
            await collector.append(event)
        }

        try await coordinator.writeLine(
            #"{"id":"round-trip","type":"get_state"}"#,
            to: .pi
        )
        for _ in 0..<20 {
            if await collector.messages().contains(
                #"{"id":"round-trip","type":"get_state"}"#
            ) {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(await collector.messages().contains(
            #"{"id":"round-trip","type":"get_state"}"#
        ))
    }

    @Test func piJobEventsProduceGroundedToolAndCompletionUpdates() throws {
        let toolStart = try decodePiEvent(
            #"{"type":"tool_execution_start","toolCallId":"tool-1","toolName":"write","args":{"path":"Sources/App.swift"}}"#
        )
        let toolProjection = PiJobEventInterpreter.project(
            toolStart,
            pendingOutcome: nil
        )
        #expect(toolProjection?.kind == .helper)
        #expect(toolProjection?.message == "Pi started write: Sources/App.swift")

        let turnEnd = try decodePiEvent(
            #"{"type":"turn_end","message":{"role":"assistant","content":[{"type":"text","text":"Updated App.swift and ran the focused test."}],"stopReason":"stop"},"toolResults":[]}"#
        )
        let outcome = PiJobEventInterpreter.terminalOutcome(from: turnEnd)
        #expect(outcome == .completed(
            summary: "Updated App.swift and ran the focused test."
        ))

        let agentEnd = try decodePiEvent(
            #"{"type":"agent_end","messages":[],"willRetry":false}"#
        )
        let completion = PiJobEventInterpreter.project(
            agentEnd,
            pendingOutcome: outcome
        )
        #expect(completion?.kind == .completion)
        #expect(completion?.message ==
            "Pi completed: Updated App.swift and ran the focused test.")
        #expect(completion?.lifecycle == .ended(outcome!))
    }

    @Test func piJobEventsDistinguishAbortAndFailure() throws {
        let abortEvent = try decodePiEvent(
            #"{"type":"turn_end","message":{"role":"assistant","content":[],"stopReason":"aborted"},"toolResults":[]}"#
        )
        #expect(PiJobEventInterpreter.terminalOutcome(from: abortEvent) == .aborted)

        let failureEvent = try decodePiEvent(
            #"{"type":"turn_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"provider unavailable"},"toolResults":[]}"#
        )
        #expect(PiJobEventInterpreter.terminalOutcome(from: failureEvent) ==
            .failed("provider unavailable"))
    }
}

private func decodePiEvent(_ json: String) throws -> PiRPCEvent {
    try JSONDecoder().decode(PiRPCEvent.self, from: Data(json.utf8))
}

private actor RuntimeEventCollector {
    private var events: [RuntimeProcessEvent] = []

    func append(_ event: RuntimeProcessEvent) {
        events.append(event)
    }

    func messages() -> [String] {
        events.map(\.message)
    }
}
