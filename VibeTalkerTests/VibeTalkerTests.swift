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
