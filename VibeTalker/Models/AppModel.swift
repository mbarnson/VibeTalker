import AppKit
import Foundation
import Observation

nonisolated enum VoiceRuntimeReadinessError: LocalizedError {
    case timedOut(RuntimeService)

    var errorDescription: String? {
        switch self {
        case .timedOut(let service):
            "\(service.rawValue) did not become ready before the startup deadline."
        }
    }
}

enum RuntimeHealth: String, Sendable {
    case idle
    case checking
    case ready
    case failed
}

@MainActor
@Observable
final class AppModel {
    var events: [LedgerEvent] = []
    var health: RuntimeHealth = .idle
    var helperRoundTrip = "Not checked"
    var sandboxStatus = "Not checked"
    var jitStatus = "Not checked"
    var composerText = ""
    var isJobRunning = false
    var runtimeStates: [RuntimeService: RuntimeProcessState] = [:]
    var runtimeArtifacts: [RuntimeArtifactDiagnostic] = []
    var piArtifacts: [RuntimeArtifactDiagnostic] = []
    var piRPCReady = false
    var codingProvider: CodingProvider {
        didSet { preferences.codingProvider = codingProvider }
    }
    var codingCredentialInput = ""
    var codingCredentialConfigured = false
    var codingCredentialSource = "Credential required"
    var codingCredentialStoredInKeychain = false
    var codingBaseURL: String {
        didSet { preferences.codingBaseURL = codingBaseURL }
    }
    var codingModelID: String {
        didSet { preferences.codingModelID = codingModelID }
    }
    var interactionProvider: InteractionProvider {
        didSet { preferences.interactionProvider = interactionProvider }
    }
    var interactionCredentialInput = ""
    var interactionCredentialConfigured = false
    var interactionCredentialSource = "Credential required"
    var interactionCredentialStoredInKeychain = false
    var interactionEndpoint: String {
        didSet { preferences.interactionEndpoint = interactionEndpoint }
    }
    var interactionModelID: String {
        didSet { preferences.interactionModelID = interactionModelID }
    }
    var referenceAdapterReady = false
    var isImportingVoiceRuntime = false
    var voiceImportStatus = "Select a source-built staging folder"

    private let ledger: EventLedger
    private let preflight: NativePreflight
    private let processCoordinator: ProcessCoordinator
    private let runtimeInstallation: RuntimeInstallation
    private let piClient: PiRPCClient
    private let piJobs: PiJobController
    private let requestPolicy: PiRequestPolicy
    private let referenceBridge: MoshiReferenceBridge
    private let referenceAdapter: MoshiChatCompletionsAdapter
    private let referenceServer: LoopbackReferenceServer
    private let moshiReferenceClient: any MoshiReferenceAccepting
    private let moshiProactiveClient: any MoshiReferenceAccepting
    private let nodeHelperURL: URL
    private let credentialStore: CodingCredentialStore
    private let voiceRuntimeImporter: VoiceRuntimeImporter
    private let preferences: AppPreferences
    private var pendingPiOutcome: PiTerminalOutcome?
    private var conversationCoordinator: ConversationCoordinator?
    private var voiceSessionID: UUID?

    init(
        preflight: NativePreflight = NativePreflight(),
        processCoordinator: ProcessCoordinator = ProcessCoordinator(),
        runtimeInstallation: RuntimeInstallation? = nil,
        credentialStore: CodingCredentialStore = CodingCredentialStore(),
        preferences: AppPreferences = AppPreferences(),
        voiceRuntimeImporter: VoiceRuntimeImporter = VoiceRuntimeImporter(),
        moshiReferenceClient: any MoshiReferenceAccepting = MoshiReferenceHTTPClient(),
        moshiProactiveClient: any MoshiReferenceAccepting = MoshiReferenceHTTPClient(
            endpoint: URL(string: "http://127.0.0.1:8999/api/proactive")!
        ),
        nodeHelperURL: URL? = nil
    ) {
        let resolvedInstallation = runtimeInstallation ?? RuntimeInstallation(
            bundledRuntimeRootURL: Bundle.main.resourceURL?
                .appending(path: "Runtime", directoryHint: .isDirectory),
            bundledVoiceRuntimeRootURL: Bundle.main.bundleURL
                .appending(path: "Contents/Resources/voice-runtime"),
            bundledVoiceExecutableURL: Bundle.main.bundleURL
                .appending(path: "Contents/Helpers/vibetalker-python"),
            opensslConfigurationURL: Bundle.main.url(
                forResource: "openssl",
                withExtension: "cnf"
            )
        )
        self.ledger = EventLedger(
            fileURL: resolvedInstallation.rootURL
                .deletingLastPathComponent()
                .appending(path: "EventLedger", directoryHint: .isDirectory)
                .appending(path: "events.jsonl")
        )
        self.preflight = preflight
        self.processCoordinator = processCoordinator
        self.runtimeInstallation = resolvedInstallation
        self.piClient = PiRPCClient(processes: processCoordinator)
        self.requestPolicy = PiRequestPolicy(
            projectName: resolvedInstallation.sandboxWorkspaceURL.lastPathComponent
        )
        self.piJobs = PiJobController(
            rpc: self.piClient,
            projectName: resolvedInstallation.sandboxWorkspaceURL.lastPathComponent
        )
        let referenceBridge = MoshiReferenceBridge()
        self.referenceBridge = referenceBridge
        let referenceAdapter = MoshiChatCompletionsAdapter(bridge: referenceBridge)
        self.referenceAdapter = referenceAdapter
        self.referenceServer = LoopbackReferenceServer(
            adapter: referenceAdapter,
            bridge: referenceBridge
        )
        self.moshiReferenceClient = moshiReferenceClient
        self.moshiProactiveClient = moshiProactiveClient
        self.credentialStore = credentialStore
        self.preferences = preferences
        self.codingProvider = preferences.codingProvider
        self.codingBaseURL = preferences.codingBaseURL
        self.codingModelID = preferences.codingModelID
        self.interactionProvider = preferences.interactionProvider
        self.interactionEndpoint = preferences.interactionEndpoint
        self.interactionModelID = preferences.interactionModelID
        self.voiceRuntimeImporter = voiceRuntimeImporter
        self.nodeHelperURL = nodeHelperURL ?? Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/vibetalker-node")
        self.runtimeArtifacts = resolvedInstallation.diagnostics()
        self.piArtifacts = resolvedInstallation.piDiagnostics(nodeURL: self.nodeHelperURL)
        Task { [weak self, referenceBridge] in
            guard let self else { return }
            await referenceBridge.setEventSink { [weak self] kind, message in
                await self?.publish(kind, message)
            }
            await publish(.system, "VibeTalker native host initialized")
            refreshCodingCredentialStatus()
            refreshInteractionCredentialStatus()
            if ProcessInfo.processInfo.environment[
                "VIBETALKER_ACCEPTANCE_AUTOSTART"
            ] == "1" {
                await runAcceptanceAutostart()
            }
        }
    }

    func refreshInteractionCredentialStatus() {
        let provider = interactionProvider.credentialProvider
        Task {
            do {
                if ProcessInfo.processInfo.environment[provider.environmentKey]?.isEmpty == false {
                    interactionCredentialConfigured = true
                    interactionCredentialSource = "Development environment"
                    interactionCredentialStoredInKeychain = false
                } else {
                    interactionCredentialConfigured = try await credentialStore.contains(provider)
                    interactionCredentialSource = interactionCredentialConfigured
                        ? "Keychain configured"
                        : "Credential required"
                    interactionCredentialStoredInKeychain = interactionCredentialConfigured
                }
            } catch {
                interactionCredentialConfigured = false
                interactionCredentialSource = "Credential unavailable"
                interactionCredentialStoredInKeychain = false
                await publish(
                    .error,
                    "Could not inspect \(interactionProvider.displayName) credential: \(error.localizedDescription)"
                )
            }
        }
    }

    func saveInteractionCredential() {
        let interactionProvider = interactionProvider
        let provider = interactionProvider.credentialProvider
        let value = interactionCredentialInput
        interactionCredentialInput = ""
        Task {
            do {
                try await credentialStore.save(value, for: provider)
                interactionCredentialConfigured = true
                interactionCredentialSource = "Keychain configured"
                interactionCredentialStoredInKeychain = true
                await publish(
                    .policy,
                    "\(interactionProvider.displayName) credential saved in Keychain"
                )
            } catch {
                interactionCredentialConfigured = false
                await publish(
                    .error,
                    "Could not save interaction credential: \(error.localizedDescription)"
                )
            }
        }
    }

    func deleteInteractionCredential() {
        let interactionProvider = interactionProvider
        let provider = interactionProvider.credentialProvider
        interactionCredentialInput = ""
        Task {
            do {
                try await credentialStore.delete(provider)
                interactionCredentialConfigured = false
                interactionCredentialSource = "Credential required"
                interactionCredentialStoredInKeychain = false
                await publish(
                    .policy,
                    "\(interactionProvider.displayName) credential removed from Keychain"
                )
            } catch {
                await publish(
                    .error,
                    "Could not remove interaction credential: \(error.localizedDescription)"
                )
            }
        }
    }

    func refreshCodingCredentialStatus() {
        let provider = codingProvider
        Task {
            do {
                if ProcessInfo.processInfo.environment[provider.environmentKey]?.isEmpty == false {
                    codingCredentialConfigured = true
                    codingCredentialSource = "Development environment"
                    codingCredentialStoredInKeychain = false
                } else {
                    codingCredentialConfigured = try await credentialStore.contains(provider)
                    codingCredentialSource = codingCredentialConfigured
                        ? "Keychain configured"
                        : "Credential required"
                    codingCredentialStoredInKeychain = codingCredentialConfigured
                }
            } catch {
                codingCredentialConfigured = false
                codingCredentialSource = "Credential unavailable"
                codingCredentialStoredInKeychain = false
                await publish(
                    .error,
                    "Could not inspect \(provider.displayName) credential: \(error.localizedDescription)"
                )
            }
        }
    }

    func saveCodingCredential() {
        let provider = codingProvider
        let value = codingCredentialInput
        codingCredentialInput = ""
        Task {
            do {
                try await credentialStore.save(value, for: provider)
                codingCredentialConfigured = true
                codingCredentialSource = "Keychain configured"
                codingCredentialStoredInKeychain = true
                await publish(
                    .policy,
                    "\(provider.displayName) coding credential saved in Keychain"
                )
            } catch {
                codingCredentialConfigured = false
                await publish(
                    .error,
                    "Could not save coding credential: \(error.localizedDescription)"
                )
            }
        }
    }

    func deleteCodingCredential() {
        let provider = codingProvider
        codingCredentialInput = ""
        Task {
            do {
                try await credentialStore.delete(provider)
                codingCredentialConfigured = false
                codingCredentialSource = "Credential required"
                codingCredentialStoredInKeychain = false
                await publish(
                    .policy,
                    "\(provider.displayName) coding credential removed from Keychain"
                )
            } catch {
                await publish(
                    .error,
                    "Could not remove coding credential: \(error.localizedDescription)"
                )
            }
        }
    }

    func refreshRuntimeInstallation() {
        runtimeArtifacts = runtimeInstallation.diagnostics()
        piArtifacts = runtimeInstallation.piDiagnostics(nodeURL: nodeHelperURL)
        let missing = runtimeArtifacts.filter { !$0.available }
        Task {
            if missing.isEmpty {
                await publish(.diagnostic, "Managed voice runtime is complete")
            } else {
                await publish(
                    .diagnostic,
                    "Managed voice runtime missing \(missing.count) required artifacts"
                )
            }
        }
    }

    func importVoiceRuntime(from sourceURL: URL) {
        guard !isImportingVoiceRuntime else { return }
        isImportingVoiceRuntime = true
        voiceImportStatus = "Importing source-built runtime…"
        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        Task { [weak self] in
            guard let self else {
                if hasSecurityScope {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
                return
            }
            defer {
                if hasSecurityScope {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
                isImportingVoiceRuntime = false
            }
            do {
                let importer = voiceRuntimeImporter
                let installation = runtimeInstallation
                try await Task.detached(priority: .userInitiated) {
                    try importer.importRuntime(
                        from: sourceURL,
                        into: installation
                    )
                }.value
                runtimeArtifacts = installation.diagnostics()
                voiceImportStatus = "Source-built runtime imported"
                await publish(
                    .completion,
                    "Pinned source-built voice runtime imported into the app container"
                )
            } catch {
                voiceImportStatus = "Import failed"
                await publish(
                    .error,
                    "Voice runtime import failed: \(error.localizedDescription)"
                )
            }
        }
    }

    func startPiRuntime() {
        guard health == .ready else {
            Task { await publish(.policy, "Pi start declined; native preflight is not ready") }
            return
        }
        let eventSink: PiRPCClient.EventSink = { [weak self] event in
            await self?.receivePiEvent(event)
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let customProvider: PiCustomProviderConfiguration?
                if codingProvider.customPiAPI != nil {
                    guard let configuration = PiCustomProviderConfiguration(
                        provider: codingProvider,
                        baseURL: codingBaseURL,
                        modelID: codingModelID
                    ) else {
                        throw RuntimeInstallationError.invalidCustomProvider
                    }
                    customProvider = configuration
                } else {
                    customProvider = nil
                }
                let credential: CodingProviderCredential?
                if let value = ProcessInfo.processInfo.environment[
                    codingProvider.environmentKey
                ], !value.isEmpty {
                    credential = .init(provider: codingProvider, value: value)
                } else {
                    credential = try await credentialStore.credential(for: codingProvider)
                }
                let spec = try runtimeInstallation.piLaunchSpec(
                    nodeURL: nodeHelperURL,
                    credential: credential,
                    customProvider: customProvider
                )
                try await piClient.start(spec: spec, events: eventSink)
                let piProvider: String
                let piModelID: String
                if let customProvider {
                    piProvider = PiCustomProviderConfiguration.providerID
                    piModelID = customProvider.modelID
                } else if let defaultModelID = codingProvider.defaultPiModelID {
                    piProvider = codingProvider.piProviderID
                    piModelID = defaultModelID
                } else {
                    throw RuntimeInstallationError.invalidCustomProvider
                }
                let modelResponse = try await piClient.request(.setModel(
                    id: UUID().uuidString,
                    provider: piProvider,
                    modelID: piModelID
                ))
                guard modelResponse.success == true else {
                    throw PiRPCClientError.requestFailed(
                        modelResponse.error ?? "set_model failed"
                    )
                }
                let requestID = UUID().uuidString
                let response = try await piClient.request(.getState(id: requestID))
                guard response.success == true else {
                    throw PiRPCClientError.requestFailed(response.error ?? "get_state failed")
                }
                piRPCReady = true
                await piJobs.runtimeBecameReady()
                runtimeStates = await processCoordinator.snapshot()
                await publish(.completion, "Pinned source-built pi RPC session ready")
            } catch {
                await piJobs.runtimeStopped()
                piRPCReady = false
                runtimeStates = await processCoordinator.snapshot()
                await publish(.error, "Pi runtime start failed: \(error.localizedDescription)")
            }
        }
    }

    func stopPiRuntime() {
        Task {
            await piClient.stop()
            await piJobs.runtimeStopped()
            piRPCReady = false
            isJobRunning = false
            pendingPiOutcome = nil
            runtimeStates = await processCoordinator.snapshot()
            await publish(.system, "Pi runtime stopped")
        }
    }

    func startVoiceRuntime() {
        guard health == .ready else {
            Task { await publish(.policy, "Voice start declined; native preflight is not ready") }
            return
        }

        let eventSink: ProcessCoordinator.EventSink = { [weak self] event in
            await self?.publishRuntime(event)
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let endpoint = interactionEndpoint
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let modelID = interactionModelID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let endpointURL = URL(string: endpoint),
                      ["http", "https"].contains(endpointURL.scheme?.lowercased()),
                      endpointURL.host != nil,
                      !modelID.isEmpty else {
                    throw InteractorError.invalidConfiguration
                }
                let interactionKey: String?
                let interactionCredentialProvider =
                    interactionProvider.credentialProvider
                if let environmentKey = ProcessInfo.processInfo.environment[
                    interactionCredentialProvider.environmentKey
                ], !environmentKey.isEmpty {
                    interactionKey = environmentKey
                } else {
                    interactionKey = try await credentialStore.credential(
                        for: interactionCredentialProvider
                    )?.value
                }
                let interactor = ResponsesInteractor(configuration: .init(
                    endpoint: endpointURL,
                    model: modelID,
                    apiKey: interactionKey,
                    reasoningEffort: interactionProvider.reasoningEffort,
                    transport: interactionProvider.transport
                ))
                let coordinator = ConversationCoordinator(
                    interactor: interactor,
                    piDispatcher: piJobs,
                    referenceDelivery: referenceBridge,
                    policy: requestPolicy
                ) { [weak self] kind, message in
                    await self?.publish(kind, message)
                }
                let sessionID = UUID()
                await coordinator.beginVoiceSession(sessionID)
                await referenceBridge.beginSession(sessionID) { utterance in
                    try await coordinator.commit(utterance)
                }
                let moshiReferenceClient = moshiReferenceClient
                await referenceBridge.setDeliverySink { delivery in
                    try await moshiReferenceClient.accept(delivery)
                }
                let moshiProactiveClient = moshiProactiveClient
                await referenceBridge.setProactiveDeliverySink { delivery in
                    try await moshiProactiveClient.accept(delivery)
                }
                await referenceAdapter.reset()
                let referenceBaseURL = try await referenceServer.start()
                conversationCoordinator = coordinator
                voiceSessionID = sessionID

                let specs = try runtimeInstallation.voiceLaunchSpecs(
                    referenceBaseURL: referenceBaseURL
                )
                for spec in specs {
                    try await processCoordinator.start(spec, events: eventSink)
                    runtimeStates = await processCoordinator.snapshot()
                    try await waitForVoiceService(spec.service)
                }
                referenceAdapterReady = true
                await publish(
                    .completion,
                    "Coordinator adapter ready at \(referenceBaseURL.absoluteString)"
                )
                await publish(.completion, "Local MLX Moshi-RAG topology started")
                let voiceURL = URL(string: "http://127.0.0.1:8999")!
                if NSWorkspace.shared.open(voiceURL) {
                    await publish(.completion, "Opened the local Moshi voice client")
                } else {
                    await publish(.error, "Could not open the local Moshi voice client")
                }
            } catch {
                await processCoordinator.stop(.moshi)
                await processCoordinator.stop(.speechToText)
                await processCoordinator.stop(.referenceEncoder)
                await endVoiceSession()
                runtimeStates = await processCoordinator.snapshot()
                await publish(.error, "Voice runtime start failed: \(error.localizedDescription)")
            }
        }
    }

    private func waitForVoiceService(_ service: RuntimeService) async throws {
        let endpoint: URL
        switch service {
        case .referenceEncoder:
            endpoint = URL(string: "http://127.0.0.1:8001/docs")!
        case .speechToText:
            endpoint = URL(string: "http://127.0.0.1:8997/api/build_info")!
        case .moshi:
            endpoint = URL(string: "http://127.0.0.1:8999/")!
        case .pi:
            return
        }

        let deadline = ContinuousClock.now + .seconds(45)
        while ContinuousClock.now < deadline {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 1
            if let (data, response) = try? await URLSession.shared.data(for: request),
               VoiceRuntimeReadinessProbe.isReady(
                   service: service,
                   data: data,
                   response: response
               ) {
                await publish(.diagnostic, "\(service.rawValue) readiness probe passed")
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw VoiceRuntimeReadinessError.timedOut(service)
    }

    func stopVoiceRuntime() {
        Task {
            await processCoordinator.stop(.moshi)
            await processCoordinator.stop(.speechToText)
            await processCoordinator.stop(.referenceEncoder)
            await endVoiceSession()
            runtimeStates = await processCoordinator.snapshot()
            await publish(.system, "Voice runtime stop requested")
        }
    }

    func applicationWillTerminate() {
        processCoordinator.terminateAllImmediately()
        referenceServer.stop()
    }

    private func endVoiceSession() async {
        if let voiceSessionID, let conversationCoordinator {
            await conversationCoordinator.endVoiceSession(voiceSessionID)
        }
        await referenceBridge.endSession()
        await referenceBridge.setDeliverySink { _ in }
        await referenceBridge.setProactiveDeliverySink { _ in }
        await referenceAdapter.reset()
        referenceServer.stop()
        referenceAdapterReady = false
        conversationCoordinator = nil
        voiceSessionID = nil
    }

    func runNativePreflight() {
        guard health != .checking else { return }
        health = .checking

        Task {
            await publish(.diagnostic, "Gate 0 native preflight started")
            do {
                let report = try await preflight.run()
                helperRoundTrip = report.helperRoundTrip
                jitStatus = report.jitComparison
                sandboxStatus = report.sandboxSummary
                health = report.passed ? .ready : .failed
                for detail in report.details {
                    await publish(detail.passed ? .diagnostic : .error, detail.message)
                }
                await publish(
                    report.passed ? .completion : .error,
                    report.passed ? "Gate 0 preflight passed" : "Gate 0 preflight did not pass"
                )
            } catch {
                health = .failed
                await publish(.error, "Gate 0 preflight failed: \(error.localizedDescription)")
            }
        }
    }

    private func runAcceptanceAutostart() async {
        await publish(.diagnostic, "Signed acceptance autostart requested")
        runNativePreflight()

        let preflightDeadline = ContinuousClock.now + .seconds(30)
        while health == .checking, ContinuousClock.now < preflightDeadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard health == .ready else {
            await publish(.error, "Signed acceptance autostart stopped at preflight")
            return
        }

        startPiRuntime()
        let piDeadline = ContinuousClock.now + .seconds(30)
        while !piRPCReady, ContinuousClock.now < piDeadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard piRPCReady else {
            await publish(.error, "Signed acceptance autostart timed out waiting for pi RPC")
            return
        }

        startVoiceRuntime()
        await publish(.diagnostic, "Signed acceptance runtime launch requested")
    }

    func submitComposer() {
        let value = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        composerText = ""

        if isJobRunning {
            if value.lowercased() == "abort" {
                Task {
                    do {
                        let receipt = try await piJobs.dispatch(PiRequest(
                            operation: .cancel,
                            instruction: nil
                        ))
                        if case .cancellationRequested = receipt {
                            await publish(.policy, "Typed abort accepted by pi RPC")
                        }
                    } catch {
                        await publish(.error, "Pi abort failed: \(error.localizedDescription)")
                    }
                }
            } else {
                Task {
                    await publish(
                        .policy,
                        "Typed input declined while a job is active; only abort is accepted"
                    )
                }
            }
            return
        }

        Task {
            await publish(.request, "Typed Pi Request: \(value)")
            guard piRPCReady else {
                await publish(.policy, "Request declined; pinned pi RPC session is not ready")
                return
            }

            switch await requestPolicy.resolvePending(
                with: value,
                origin: .console
            ) {
            case .dispatch(let request, let message):
                await publish(.policy, message)
                await dispatchComposerRequest(request)
                return
            case .consumed(let message):
                await publish(.policy, message)
                return
            case .none(let expiredMessage):
                if let expiredMessage {
                    await publish(.policy, expiredMessage)
                }
            }

            let request = PiRequest(operation: .start, instruction: value)
            switch await requestPolicy.evaluate(request, origin: .console) {
            case .dispatch(let approved):
                await dispatchComposerRequest(approved)
            case .awaitConfirmation(let proposal):
                await publish(
                    .policy,
                    "Proposal \(proposal.id.uuidString): \(proposal.confirmationQuestion)"
                )
            case .refuse(let reason):
                await publish(.policy, reason)
            }
        }
    }

    private func dispatchComposerRequest(_ request: PiRequest) async {
        do {
            let receipt = try await piJobs.dispatch(request)
            isJobRunning = (await piJobs.snapshot()).isRunning
            pendingPiOutcome = nil
            if case .started(let projectName) = receipt {
                await publish(.policy, "Work started in \(projectName)")
            }
        } catch {
            await publish(.error, "Pi request failed: \(error.localizedDescription)")
        }
    }

    private func publish(_ kind: LedgerEventKind, _ message: String) async {
        _ = await ledger.append(kind, message)
        events = await ledger.snapshot()
    }

    private func publishRuntime(_ event: RuntimeProcessEvent) async {
        let kind: LedgerEventKind = event.stream == .standardError ? .error : .helper
        await publish(kind, "\(event.service.rawValue): \(event.message)")
        runtimeStates = await processCoordinator.snapshot()
    }

    private func receivePiEvent(_ event: PiRPCEvent) async {
        await piJobs.receive(event)
        isJobRunning = (await piJobs.snapshot()).isRunning
        if case .string(let record)? = event.raw["record"] {
            if event.type == "process_ended" {
                piRPCReady = false
                isJobRunning = false
                pendingPiOutcome = nil
                runtimeStates = await processCoordinator.snapshot()
            }
            await publish(
                event.type == "process_stderr" ? .error : .helper,
                "pi \(event.type): \(record)"
            )
            return
        }

        if let outcome = PiJobEventInterpreter.terminalOutcome(from: event) {
            pendingPiOutcome = outcome
        }
        guard let projection = PiJobEventInterpreter.project(
            event,
            pendingOutcome: pendingPiOutcome
        ) else {
            if event.type != "message_update" {
                await publish(.helper, "pi event: \(event.type)")
            }
            return
        }

        let terminalOutcome: PiTerminalOutcome?
        switch projection.lifecycle {
        case .unchanged:
            terminalOutcome = nil
        case .started:
            isJobRunning = true
            terminalOutcome = nil
        case .ended(let outcome):
            isJobRunning = false
            pendingPiOutcome = nil
            terminalOutcome = outcome
        }
        await publish(projection.kind, projection.message)
        if let terminalOutcome {
            await deliverProactiveReference(terminalOutcome)
        }
    }

    private func deliverProactiveReference(_ outcome: PiTerminalOutcome) async {
        guard referenceAdapterReady, voiceSessionID != nil else { return }
        let projectName = runtimeInstallation.sandboxWorkspaceURL.lastPathComponent
        do {
            _ = try await referenceBridge.deliverProactive(
                outcome.proactiveReference(projectName: projectName)
            )
        } catch {
            await publish(
                .error,
                "Proactive completion delivery failed: \(error.localizedDescription)"
            )
        }
    }
}
