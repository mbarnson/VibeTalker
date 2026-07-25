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

        #expect(installation.pythonURL.path.hasSuffix("Python/bin/python3.12"))
        #expect(installation.mlxPythonURL == installation.ragPythonURL)
        #expect(installation.moshiWeightURL.path.hasSuffix(
            "Models/moshika-rag-mlx-bf16.safetensors"
        ))
        #expect(throws: RuntimeInstallationError.self) {
            _ = try installation.voiceLaunchSpecs()
        }
    }

    @Test func voiceRuntimeRoutesMoshiRetrievalThroughCoordinatorAdapter() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "VibeTalker-Voice-Fixture-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        let installation = RuntimeInstallation(rootURL: root)
        let executableURLs = [
            installation.pythonURL
        ]
        let fileURLs = [
            installation.mlxSitePackagesURL
                .appending(path: "moshi_mlx/__init__.py"),
            installation.ragSitePackagesURL
                .appending(path: "moshi/__init__.py"),
            installation.moshiWeightURL,
            installation.conditionerWeightURL,
            installation.tokenizerURL,
            installation.mimiWeightURL,
            installation.mlxConfigurationURL,
            installation.ragConfigurationURL
        ]
        for url in executableURLs + fileURLs {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }
        for url in executableURLs {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        }

        let adapterURL = try #require(
            URL(string: "http://127.0.0.1:8173/v1")
        )
        let specs = try installation.voiceLaunchSpecs(
            referenceBaseURL: adapterURL
        )
        let moshi = try #require(specs.first(where: { $0.service == .moshi }))
        let conditioner = try #require(
            specs.first(where: { $0.service == .referenceEncoder })
        )

        #expect(moshi.environment["LLM_BASE_URL"] == adapterURL.absoluteString)
        #expect(moshi.environment["LLM_MODEL_NAME"] == "vibetalker-coordinator")
        #expect(moshi.environment["LLM_API_KEY"] == "loopback-only")
        #expect(moshi.environment["REFERENCE_ENCODER_URL"] == "http://127.0.0.1:8001")
        #expect(!moshi.environment.keys.contains("OMLX_API_KEY"))
        #expect(moshi.environment["PYTHONHOME"] == root.appending(path: "Python").path)
        #expect(moshi.environment["PYTHONPATH"] == installation.mlxSitePackagesURL.path)
        #expect(conditioner.environment["PYTHONPATH"] == installation.ragSitePackagesURL.path)
        #expect(moshi.environment["HF_HUB_OFFLINE"] == "1")
        #expect(conditioner.arguments.prefix(2) == ["-m", "moshi.server_conditioner"])
        #expect(conditioner.arguments.contains("--config"))
        #expect(!conditioner.arguments.contains("--lm-config"))
        let staticIndex = try #require(moshi.arguments.firstIndex(of: "--static"))
        #expect(moshi.arguments[staticIndex + 1] == "none")
    }

    @Test func voiceRuntimeImporterMovesValidatedPayloadIntoManagedRoot() throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory
            .appending(path: "VibeTalker-Voice-Import-\(UUID().uuidString)")
        let source = fixture.appending(path: "source")
        let destination = fixture.appending(path: "managed")
        defer { try? fileManager.removeItem(at: fixture) }

        let sourceInstallation = RuntimeInstallation(rootURL: source)
        let requiredFiles = [
            sourceInstallation.mlxSitePackagesURL
                .appending(path: "moshi_mlx/__init__.py"),
            sourceInstallation.ragSitePackagesURL
                .appending(path: "moshi/__init__.py"),
            sourceInstallation.moshiWeightURL,
            sourceInstallation.conditionerWeightURL,
            sourceInstallation.tokenizerURL,
            sourceInstallation.mimiWeightURL,
            sourceInstallation.mlxConfigurationURL,
            sourceInstallation.ragConfigurationURL
        ]
        for url in [sourceInstallation.pythonURL] + requiredFiles {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: sourceInstallation.pythonURL.path
        )
        try """
        moshi=\(VoiceRuntimeImporter.moshiRevision)
        moshi-rag=\(VoiceRuntimeImporter.ragRevision)
        """.write(
            to: source.appending(path: ".vibetalker-voice-runtime"),
            atomically: true,
            encoding: .utf8
        )

        let stale = destination.appending(path: "Models/stale.bin")
        try fileManager.createDirectory(
            at: stale.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: stale)

        let destinationInstallation = RuntimeInstallation(
            rootURL: destination,
            bundledVoiceRuntimeRootURL: source
        )
        try VoiceRuntimeImporter().importRuntime(
            from: source,
            into: destinationInstallation
        )

        let unavailableArtifacts = destinationInstallation.diagnostics()
            .filter { !$0.available }
        #expect(unavailableArtifacts.isEmpty)
        #expect(!fileManager.fileExists(atPath: stale.path))
        #expect(fileManager.fileExists(
            atPath: destination.appending(path: ".vibetalker-voice-runtime").path
        ))
    }

    @Test func voiceRuntimeImporterRejectsUnpinnedPayload() throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory
            .appending(path: "VibeTalker-Voice-Reject-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: fixture) }
        try fileManager.createDirectory(at: fixture, withIntermediateDirectories: true)
        try "moshi=mutable-main\nmoshi-rag=mutable-main\n".write(
            to: fixture.appending(path: ".vibetalker-voice-runtime"),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: VoiceRuntimeImporterError.revisionMismatch) {
            try VoiceRuntimeImporter().importRuntime(
                from: fixture,
                into: RuntimeInstallation(
                    rootURL: fixture.deletingLastPathComponent()
                        .appending(path: "managed-\(UUID().uuidString)")
                )
            )
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
        #expect(authenticatedSpec.environment["OMLX_API_KEY"] == nil)
    }

    @Test func piLaunchConfiguresCompatibleProviderWithoutPersistingSecret() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appending(path: "VibeTalker-Compatible-Fixture-\(UUID().uuidString)")
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
        let configuration = try #require(PiCustomProviderConfiguration(
            provider: .responsesCompatible,
            baseURL: "http://127.0.0.1:8000/v1",
            modelID: "fixture-model"
        ))
        let spec = try installation.piLaunchSpec(
            nodeURL: URL(fileURLWithPath: "/bin/sh"),
            credential: CodingProviderCredential(
                provider: .responsesCompatible,
                value: "fixture-secret"
            ),
            customProvider: configuration
        )

        #expect(spec.environment["OMLX_API_KEY"] == "fixture-secret")
        #expect(spec.environment["OPENAI_API_KEY"] == nil)

        let modelsURL = managedRoot.appending(path: "PiConfig/models.json")
        let modelsText = try String(contentsOf: modelsURL, encoding: .utf8)
        #expect(modelsText.contains(#""api" : "openai-responses""#))
        #expect(modelsText.contains(#""apiKey" : "$OMLX_API_KEY""#))
        #expect(modelsText.contains(#""id" : "fixture-model""#))
        #expect(!modelsText.contains("fixture-secret"))
    }

    @Test func piSetModelCommandUsesPinnedRPCShape() throws {
        let command = PiRPCCommand.setModel(
            id: "set-model-1",
            provider: PiCustomProviderConfiguration.providerID,
            modelID: "fixture-model"
        )
        let data = try JSONEncoder().encode(command)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )

        #expect(object == [
            "id": "set-model-1",
            "type": "set_model",
            "provider": "vibetalker-omlx",
            "modelId": "fixture-model"
        ])
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

    @Test func responsesSSEDecoderRequiresTypedCompletion() throws {
        var decoder = ResponsesSSEDecoder()
        #expect(try decoder.consume("event: response.output_text.delta") == nil)
        #expect(try decoder.consume(
            #"data: {"type":"response.output_text.delta","delta":"partial"}"#
        ) == nil)
        #expect(try decoder.consume("") == nil)

        let completed = try decoder.consume(
            #"data: {"type":"response.completed","response":{"id":"resp_fixture","output":[{"content":[{"type":"output_text","text":"{\"utterance_id\":\"00000000-0000-0000-0000-000000000001\"}"}]}]}}"#
        )
        #expect(completed == ProviderResult(
            responseID: "resp_fixture",
            structuredText:
                #"{"utterance_id":"00000000-0000-0000-0000-000000000001"}"#
        ))
    }

    @Test func responsesSSEDecoderSurfacesProviderFailure() throws {
        var decoder = ResponsesSSEDecoder()
        #expect(throws: InteractorError.self) {
            try decoder.consume(
                #"data: {"type":"response.failed","response":{"id":"resp_bad","error":{"message":"model unavailable"}}}"#
            )
        }
    }

    @Test func coordinatorPublishesGroundedStartOnlyAfterPiAcceptance() async throws {
        let sessionID = UUID()
        let utterance = CommittedUtterance(
            voiceSessionID: sessionID,
            utteranceID: UUID(),
            revision: 1,
            transcript: "Please update the README."
        )
        let interactor = StubInteractor(
            reference: "I understand the coding request.",
            piRequest: PiRequest(
                operation: .start,
                instruction: "Update the README."
            )
        )
        let dispatcher = StubPiDispatcher(
            receipt: .started(projectName: "Workspace")
        )
        let references = ReferenceCollector()
        let coordinator = ConversationCoordinator(
            interactor: interactor,
            piDispatcher: dispatcher,
            referenceDelivery: references
        )
        await coordinator.beginVoiceSession(sessionID)

        let turn = try await coordinator.commit(utterance)

        #expect(turn.reference.text == "Work started in Workspace.")
        #expect(turn.piReceipt == .started(projectName: "Workspace"))
        #expect(await dispatcher.requests() == [PiRequest(
            operation: .start,
            instruction: "Update the README."
        )])
        #expect(await references.deliveries() == [turn.reference])
    }

    @Test func coordinatorRejectsStaleTranscriptBeforeInteraction() async throws {
        let sessionID = UUID()
        let utteranceID = UUID()
        let interactor = StubInteractor(
            reference: "A short factual response.",
            piRequest: nil
        )
        let dispatcher = StubPiDispatcher(
            receipt: .started(projectName: "Workspace")
        )
        let references = ReferenceCollector()
        let coordinator = ConversationCoordinator(
            interactor: interactor,
            piDispatcher: dispatcher,
            referenceDelivery: references
        )
        await coordinator.beginVoiceSession(sessionID)

        _ = try await coordinator.commit(CommittedUtterance(
            voiceSessionID: sessionID,
            utteranceID: utteranceID,
            revision: 2,
            transcript: "What changed?"
        ))

        await #expect(throws: ConversationCoordinatorError.self) {
            try await coordinator.commit(CommittedUtterance(
                voiceSessionID: sessionID,
                utteranceID: utteranceID,
                revision: 1,
                transcript: "This is stale."
            ))
        }
        #expect(await interactor.callCount() == 1)
        #expect(await references.deliveries().count == 1)
    }

    @Test func coordinatorDoesNotPublishMismatchedPiReceipt() async throws {
        let sessionID = UUID()
        let interactor = StubInteractor(
            reference: "Checking status.",
            piRequest: PiRequest(operation: .status, instruction: nil)
        )
        let dispatcher = StubPiDispatcher(
            receipt: .started(projectName: "Workspace")
        )
        let references = ReferenceCollector()
        let coordinator = ConversationCoordinator(
            interactor: interactor,
            piDispatcher: dispatcher,
            referenceDelivery: references
        )
        await coordinator.beginVoiceSession(sessionID)

        await #expect(throws: ConversationCoordinatorError.self) {
            try await coordinator.commit(CommittedUtterance(
                voiceSessionID: sessionID,
                utteranceID: UUID(),
                revision: 1,
                transcript: "How is the job going?"
            ))
        }
        #expect(await references.deliveries().isEmpty)
    }

    @Test func moshiAdapterUsesLatestHumanTurnAndCoalescesRetrievalRetry() async throws {
        let interactor = StubInteractor(
            reference: "The grounded coding acknowledgement is supplied by Pi.",
            piRequest: PiRequest(
                operation: .start,
                instruction: "Update the README."
            )
        )
        let dispatcher = StubPiDispatcher(
            receipt: .started(projectName: "Workspace")
        )
        let bridge = MoshiReferenceBridge()
        let deliveredToMoshi = ReferenceCollector()
        await bridge.setDeliverySink { delivery in
            try await deliveredToMoshi.deliver(delivery)
        }
        let coordinator = ConversationCoordinator(
            interactor: interactor,
            piDispatcher: dispatcher,
            referenceDelivery: bridge
        )
        let sessionID = UUID()
        await coordinator.beginVoiceSession(sessionID)
        await bridge.beginSession(sessionID) { utterance in
            try await coordinator.commit(utterance)
        }
        let adapter = MoshiChatCompletionsAdapter(bridge: bridge)
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "vibetalker",
            "messages": [
                [
                    "role": "system",
                    "content": "You are a helpful assistant."
                ],
                [
                    "role": "user",
                    "content": """
                    Example:
                    Human: What color is the sky?
                    Reference: The daytime sky is blue.
                    Human: Please update the README.
                    Reference:
                    """
                ]
            ]
        ])

        async let first = adapter.respond(to: request)
        async let retry = adapter.respond(to: request)
        let (firstResult, retryResult) = try await (first, retry)

        #expect(firstResult == retryResult)
        #expect(firstResult.statusCode == 200)
        #expect(await interactor.callCount() == 1)
        #expect(await dispatcher.requests() == [
            PiRequest(operation: .start, instruction: "Update the README.")
        ])
        #expect(await deliveredToMoshi.deliveries().count == 1)

        let payload = try #require(
            JSONSerialization.jsonObject(with: firstResult.body)
                as? [String: Any]
        )
        let choices = try #require(payload["choices"] as? [[String: Any]])
        let choice = try #require(choices.first)
        let message = try #require(choice["message"] as? [String: Any])
        #expect(message["content"] as? String == "Work started in Workspace.")
    }

    @Test func loopbackReferenceServerServesPinnedMoshiRoute() async throws {
        let interactor = StubInteractor(
            reference: "Cobalt is the verification color.",
            piRequest: nil
        )
        let dispatcher = StubPiDispatcher(
            receipt: .status(projectName: "Workspace", summary: "Idle")
        )
        let bridge = MoshiReferenceBridge()
        let coordinator = ConversationCoordinator(
            interactor: interactor,
            piDispatcher: dispatcher,
            referenceDelivery: bridge
        )
        let sessionID = UUID()
        await coordinator.beginVoiceSession(sessionID)
        await bridge.beginSession(sessionID) { utterance in
            try await coordinator.commit(utterance)
        }
        let adapter = MoshiChatCompletionsAdapter(bridge: bridge)
        let server = LoopbackReferenceServer(
            adapter: adapter,
            bridge: bridge
        )
        let baseURL = try await server.start()
        defer { server.stop() }

        var request = URLRequest(
            url: baseURL.appending(path: "chat/completions")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "vibetalker-coordinator",
            "messages": [[
                "role": "user",
                "content": "Human: What is the verification color?\nReference:"
            ]]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let payload = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let choices = try #require(payload["choices"] as? [[String: Any]])
        let choice = try #require(choices.first)
        let message = try #require(choice["message"] as? [String: Any])
        #expect(message["content"] as? String == "Cobalt is the verification color.")
    }

    @Test func loopbackReferenceServerCommitsCanonicalTranscript() async throws {
        let interactor = StubInteractor(
            reference: "The transcript reached the Coordinator.",
            piRequest: nil
        )
        let bridge = MoshiReferenceBridge()
        let coordinator = ConversationCoordinator(
            interactor: interactor,
            piDispatcher: StubPiDispatcher(
                receipt: .status(projectName: "Workspace", summary: "Idle")
            ),
            referenceDelivery: bridge
        )
        let sessionID = UUID()
        let utteranceID = UUID()
        await coordinator.beginVoiceSession(sessionID)
        await bridge.beginSession(sessionID) { utterance in
            try await coordinator.commit(utterance)
        }
        let server = LoopbackReferenceServer(
            adapter: MoshiChatCompletionsAdapter(bridge: bridge),
            bridge: bridge
        )
        let baseURL = try await server.start()
        defer { server.stop() }

        var request = URLRequest(url: baseURL.appending(path: "transcripts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "utterance_id": utteranceID.uuidString,
            "revision": 1,
            "transcript": "Send this canonical transcript.",
            "committed": true
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let payload = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(payload["accepted"] as? Bool == true)
        #expect(payload["utterance_id"] as? String == utteranceID.uuidString)
        #expect(await interactor.callCount() == 1)
    }

    @Test func piJobControllerSerializesTypedAndVoiceAdmission() async throws {
        let rpc = StubPiRPCRequester()
        let jobs = PiJobController(rpc: rpc, projectName: "Workspace")
        await jobs.runtimeBecameReady()

        let receipt = try await jobs.dispatch(PiRequest(
            operation: .start,
            instruction: "Update the README."
        ))
        #expect(receipt == .started(projectName: "Workspace"))
        #expect(await jobs.snapshot() == .running)

        await #expect(throws: PiJobControllerError.self) {
            try await jobs.dispatch(PiRequest(
                operation: .start,
                instruction: "Race a second job."
            ))
        }

        let status = try await jobs.dispatch(PiRequest(
            operation: .status,
            instruction: nil
        ))
        #expect(status == .status(
            projectName: "Workspace",
            summary: "The coding job is running."
        ))
        #expect(await rpc.commandTypes() == ["prompt"])
    }

    @Test func piJobControllerGroundsTerminalEventState() async throws {
        let rpc = StubPiRPCRequester()
        let jobs = PiJobController(rpc: rpc, projectName: "Workspace")
        await jobs.runtimeBecameReady()
        _ = try await jobs.dispatch(PiRequest(
            operation: .start,
            instruction: "Run the focused test."
        ))

        await jobs.receive(try decodePiEvent(
            #"{"type":"turn_end","message":{"role":"assistant","content":[{"type":"text","text":"Focused test passed."}],"stopReason":"stop"},"toolResults":[]}"#
        ))
        await jobs.receive(try decodePiEvent(
            #"{"type":"agent_end","messages":[],"willRetry":false}"#
        ))

        #expect(await jobs.snapshot() == .completed("Focused test passed."))
        let status = try await jobs.dispatch(PiRequest(
            operation: .status,
            instruction: nil
        ))
        #expect(status == .status(
            projectName: "Workspace",
            summary: "Completed. Focused test passed."
        ))
    }

    @Test func piJobControllerKeepsCancellationWhileStartAcknowledgementIsDelayed() async throws {
        let rpc = SuspendedPromptPiRPCRequester()
        let jobs = PiJobController(rpc: rpc, projectName: "Workspace")
        await jobs.runtimeBecameReady()

        let start = Task {
            try await jobs.dispatch(PiRequest(
                operation: .start,
                instruction: "Run a long coding job."
            ))
        }
        await rpc.waitUntilPromptStarts()

        let cancelReceipt = try await jobs.dispatch(PiRequest(
            operation: .cancel,
            instruction: nil
        ))
        #expect(cancelReceipt == .cancellationRequested(projectName: "Workspace"))
        #expect(await jobs.snapshot() == .cancelling)

        await rpc.resumePrompt()
        _ = try await start.value
        #expect(await jobs.snapshot() == .cancelling)

        await jobs.receive(try decodePiEvent(
            #"{"type":"agent_start"}"#
        ))
        #expect(await jobs.snapshot() == .cancelling)
        #expect(await rpc.commandTypes() == ["prompt", "abort"])
    }

    @Test func piJobControllerAcceptsGroundedCompletionWithoutSummary() async throws {
        let rpc = StubPiRPCRequester()
        let jobs = PiJobController(rpc: rpc, projectName: "Workspace")
        await jobs.runtimeBecameReady()
        _ = try await jobs.dispatch(PiRequest(
            operation: .start,
            instruction: "Perform a silent task."
        ))

        await jobs.receive(try decodePiEvent(
            #"{"type":"agent_end","messages":[],"willRetry":false}"#
        ))

        #expect(await jobs.snapshot() == .completed(nil))
        let status = try await jobs.dispatch(PiRequest(
            operation: .status,
            instruction: nil
        ))
        #expect(status == .status(
            projectName: "Workspace",
            summary: "The coding job completed."
        ))
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

private actor StubInteractor: InteractionServing {
    private let reference: String
    private let piRequest: PiRequest?
    private var calls = 0

    init(reference: String, piRequest: PiRequest?) {
        self.reference = reference
        self.piRequest = piRequest
    }

    func interact(with utterance: CommittedUtterance) async throws -> ValidatedInteraction {
        calls += 1
        return ValidatedInteraction(
            requestID: UUID(),
            utterance: utterance,
            referenceResponse: reference,
            piRequest: piRequest,
            providerResponseID: "stub-response",
            latency: .milliseconds(1)
        )
    }

    func callCount() -> Int {
        calls
    }
}

private actor StubPiDispatcher: PiRequestDispatching {
    private let receipt: PiDispatchReceipt
    private var received: [PiRequest] = []

    init(receipt: PiDispatchReceipt) {
        self.receipt = receipt
    }

    func dispatch(_ request: PiRequest) async throws -> PiDispatchReceipt {
        received.append(request)
        return receipt
    }

    func requests() -> [PiRequest] {
        received
    }
}

private actor ReferenceCollector: ReferenceDelivering {
    private var received: [ReferenceDelivery] = []

    func deliver(_ delivery: ReferenceDelivery) async throws {
        received.append(delivery)
    }

    func deliveries() -> [ReferenceDelivery] {
        received
    }
}

private actor StubPiRPCRequester: PiRPCRequesting {
    private var commands: [PiRPCCommand] = []

    func request(_ command: PiRPCCommand) async throws -> PiRPCResponse {
        commands.append(command)
        return PiRPCResponse(
            id: command.id,
            type: "response",
            command: commandType(command),
            success: true,
            data: nil,
            error: nil
        )
    }

    func commandTypes() -> [String] {
        commands.map(commandType)
    }

    private func commandType(_ command: PiRPCCommand) -> String {
        switch command {
        case .getState: "get_state"
        case .setModel: "set_model"
        case .prompt: "prompt"
        case .abort: "abort"
        }
    }
}

private actor SuspendedPromptPiRPCRequester: PiRPCRequesting {
    private var commands: [PiRPCCommand] = []
    private var promptStarted = false
    private var promptContinuation: CheckedContinuation<Void, Never>?

    func request(_ command: PiRPCCommand) async throws -> PiRPCResponse {
        commands.append(command)
        if case .prompt = command {
            promptStarted = true
            await withCheckedContinuation { continuation in
                promptContinuation = continuation
            }
        }
        return PiRPCResponse(
            id: command.id,
            type: "response",
            command: commandType(command),
            success: true,
            data: nil,
            error: nil
        )
    }

    func waitUntilPromptStarts() async {
        while !promptStarted {
            await Task.yield()
        }
    }

    func resumePrompt() {
        promptContinuation?.resume()
        promptContinuation = nil
    }

    func commandTypes() -> [String] {
        commands.map(commandType)
    }

    private func commandType(_ command: PiRPCCommand) -> String {
        switch command {
        case .getState: "get_state"
        case .setModel: "set_model"
        case .prompt: "prompt"
        case .abort: "abort"
        }
    }
}
