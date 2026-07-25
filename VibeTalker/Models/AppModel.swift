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

    private let ledger = EventLedger()
    private let preflight: NativePreflight
    private let processCoordinator: ProcessCoordinator
    private let runtimeInstallation: RuntimeInstallation

    init(
        preflight: NativePreflight = NativePreflight(),
        processCoordinator: ProcessCoordinator = ProcessCoordinator(),
        runtimeInstallation: RuntimeInstallation = RuntimeInstallation()
    ) {
        self.preflight = preflight
        self.processCoordinator = processCoordinator
        self.runtimeInstallation = runtimeInstallation
        self.runtimeArtifacts = runtimeInstallation.diagnostics()
        Task {
            await publish(.system, "VibeTalker native host initialized")
        }
    }

    func refreshRuntimeInstallation() {
        runtimeArtifacts = runtimeInstallation.diagnostics()
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

    func startVoiceRuntime() {
        guard health == .ready else {
            Task { await publish(.policy, "Voice start declined; native preflight is not ready") }
            return
        }

        Task {
            do {
                let specs = try runtimeInstallation.voiceLaunchSpecs()
                for spec in specs {
                    try await processCoordinator.start(spec) { [weak self] event in
                        await self?.publishRuntime(event)
                    }
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
                isJobRunning = false
                Task { await publish(.policy, "Typed abort accepted; active job cancelled") }
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
            await publish(.policy, "Request recorded; pi integration is gated on native preflight")
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
}
