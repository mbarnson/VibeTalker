import Foundation
import Observation

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
    var codingProvider: CodingProvider = .anthropic
    var codingCredentialInput = ""
    var codingCredentialConfigured = false
    var codingCredentialSource = "Credential required"
    var codingCredentialStoredInKeychain = false
    var codingBaseURL = "http://127.0.0.1:8000/v1"
    var codingModelID = ""

    private let ledger = EventLedger()
    private let preflight: NativePreflight
    private let processCoordinator: ProcessCoordinator
    private let runtimeInstallation: RuntimeInstallation
    private let piClient: PiRPCClient
    private let nodeHelperURL: URL
    private let credentialStore: CodingCredentialStore
    private var pendingPiOutcome: PiTerminalOutcome?

    init(
        preflight: NativePreflight = NativePreflight(),
        processCoordinator: ProcessCoordinator = ProcessCoordinator(),
        runtimeInstallation: RuntimeInstallation? = nil,
        credentialStore: CodingCredentialStore = CodingCredentialStore(),
        nodeHelperURL: URL? = nil
    ) {
        let resolvedInstallation = runtimeInstallation ?? RuntimeInstallation(
            bundledRuntimeRootURL: Bundle.main.resourceURL?
                .appending(path: "Runtime", directoryHint: .isDirectory)
        )
        self.preflight = preflight
        self.processCoordinator = processCoordinator
        self.runtimeInstallation = resolvedInstallation
        self.piClient = PiRPCClient(processes: processCoordinator)
        self.credentialStore = credentialStore
        self.nodeHelperURL = nodeHelperURL ?? Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/vibetalker-node")
        self.runtimeArtifacts = resolvedInstallation.diagnostics()
        self.piArtifacts = resolvedInstallation.piDiagnostics(nodeURL: self.nodeHelperURL)
        Task {
            await publish(.system, "VibeTalker native host initialized")
            refreshCodingCredentialStatus()
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
                if let customProvider {
                    _ = try await piClient.request(.setModel(
                        id: UUID().uuidString,
                        provider: PiCustomProviderConfiguration.providerID,
                        modelID: customProvider.modelID
                    ))
                }
                let requestID = UUID().uuidString
                let response = try await piClient.request(.getState(id: requestID))
                guard response.success == true else {
                    throw PiRPCClientError.requestFailed(response.error ?? "get_state failed")
                }
                piRPCReady = true
                runtimeStates = await processCoordinator.snapshot()
                await publish(.completion, "Pinned source-built pi RPC session ready")
            } catch {
                piRPCReady = false
                runtimeStates = await processCoordinator.snapshot()
                await publish(.error, "Pi runtime start failed: \(error.localizedDescription)")
            }
        }
    }

    func stopPiRuntime() {
        Task {
            await piClient.stop()
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
                let specs = try runtimeInstallation.voiceLaunchSpecs()
                for spec in specs {
                    try await processCoordinator.start(spec, events: eventSink)
                    runtimeStates = await processCoordinator.snapshot()
                }
                await publish(.completion, "Local MLX Moshi-RAG topology started")
            } catch {
                runtimeStates = await processCoordinator.snapshot()
                await publish(.error, "Voice runtime start failed: \(error.localizedDescription)")
            }
        }
    }

    func stopVoiceRuntime() {
        Task {
            await processCoordinator.stop(.moshi)
            await processCoordinator.stop(.referenceEncoder)
            runtimeStates = await processCoordinator.snapshot()
            await publish(.system, "Voice runtime stop requested")
        }
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

    func submitComposer() {
        let value = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        composerText = ""

        if isJobRunning {
            if value.lowercased() == "abort" {
                Task {
                    do {
                        let response = try await piClient.request(
                            .abort(id: UUID().uuidString)
                        )
                        if response.success == true {
                            await publish(.policy, "Typed abort accepted by pi RPC")
                        } else {
                            await publish(.error, "Pi abort failed: \(response.error ?? "unknown")")
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
            do {
                let commandID = UUID().uuidString
                let response = try await piClient.request(
                    .prompt(id: commandID, message: value)
                )
                if response.success == true {
                    isJobRunning = true
                    pendingPiOutcome = nil
                    await publish(
                        .policy,
                        "Work started in \(runtimeInstallation.sandboxWorkspaceURL.lastPathComponent)"
                    )
                } else {
                    await publish(.error, "Pi declined request: \(response.error ?? "unknown")")
                }
            } catch {
                await publish(.error, "Pi request failed: \(error.localizedDescription)")
            }
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

        switch projection.lifecycle {
        case .unchanged:
            break
        case .started:
            isJobRunning = true
        case .ended:
            isJobRunning = false
            pendingPiOutcome = nil
        }
        await publish(projection.kind, projection.message)
    }
}
