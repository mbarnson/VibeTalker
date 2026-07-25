import Foundation

nonisolated struct RuntimeInstallation: Sendable {
    let rootURL: URL
    let bundledRuntimeRootURL: URL
    let bundledVoiceRuntimeRootURL: URL
    let bundledVoiceExecutableURL: URL

    init(
        rootURL: URL? = nil,
        bundledRuntimeRootURL: URL? = nil,
        bundledVoiceRuntimeRootURL: URL? = nil,
        bundledVoiceExecutableURL: URL? = nil
    ) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.rootURL = applicationSupport
                .appending(path: "VibeTalker", directoryHint: .isDirectory)
                .appending(path: "Runtime", directoryHint: .isDirectory)
        }
        self.bundledRuntimeRootURL = bundledRuntimeRootURL ?? self.rootURL
        self.bundledVoiceRuntimeRootURL = bundledVoiceRuntimeRootURL ?? self.rootURL
        self.bundledVoiceExecutableURL = bundledVoiceExecutableURL
            ?? self.bundledVoiceRuntimeRootURL.appending(path: "Python/bin/python3.12")
    }

    var pythonURL: URL {
        bundledVoiceExecutableURL
    }

    var mlxPythonURL: URL {
        pythonURL
    }

    var ragPythonURL: URL {
        pythonURL
    }

    var mlxSitePackagesURL: URL {
        bundledVoiceRuntimeRootURL.appending(path: "moshi-mlx/site-packages")
    }

    var ragSitePackagesURL: URL {
        bundledVoiceRuntimeRootURL.appending(path: "moshi-rag/site-packages")
    }

    var sttExecutableURL: URL {
        bundledVoiceRuntimeRootURL.appending(path: "Bin/vibetalker-stt")
    }

    var moshiClientURL: URL {
        bundledVoiceRuntimeRootURL.appending(
            path: "Client",
            directoryHint: .isDirectory
        )
    }

    var mlxWorkingDirectoryURL: URL {
        bundledVoiceRuntimeRootURL.appending(
            path: "moshi-mlx",
            directoryHint: .isDirectory
        )
    }

    var ragWorkingDirectoryURL: URL {
        bundledVoiceRuntimeRootURL.appending(
            path: "moshi-rag",
            directoryHint: .isDirectory
        )
    }

    var modelDirectoryURL: URL {
        rootURL.appending(path: "Models", directoryHint: .isDirectory)
    }

    var moshiWeightURL: URL {
        modelDirectoryURL.appending(path: "moshika-rag-mlx-bf16.safetensors")
    }

    var conditionerWeightURL: URL {
        modelDirectoryURL.appending(path: "moshika-rag-pytorch-bf16.safetensors")
    }

    var tokenizerURL: URL {
        modelDirectoryURL.appending(path: "tokenizer_spm_32k_3.model")
    }

    var mimiWeightURL: URL {
        modelDirectoryURL.appending(path: "tokenizer-e351c8d8-checkpoint125.safetensors")
    }

    var sttWeightURL: URL {
        modelDirectoryURL.appending(path: "stt-1b-en-fr.safetensors")
    }

    var sttTokenizerURL: URL {
        modelDirectoryURL.appending(path: "tokenizer_en_fr_audio_8000.model")
    }

    var sttMimiWeightURL: URL {
        modelDirectoryURL.appending(path: "stt-mimi-e351c8d8-125.safetensors")
    }

    var mlxConfigurationURL: URL {
        rootURL.appending(path: "moshi-rag-mlx-config.json")
    }

    var ragConfigurationURL: URL {
        rootURL.appending(path: "moshi-rag-config.json")
    }

    var sttConfigurationURL: URL {
        rootURL.appending(path: "moshi-stt.toml")
    }

    var piWorkingDirectoryURL: URL {
        bundledRuntimeRootURL.appending(path: "pi", directoryHint: .isDirectory)
    }

    var piRPCEntryURL: URL {
        piWorkingDirectoryURL.appending(path: "packages/coding-agent/dist/rpc-entry.js")
    }

    var piToolPolicyURL: URL {
        piWorkingDirectoryURL.appending(path: "vibetalker-tool-policy.ts")
    }

    var sandboxWorkspaceURL: URL {
        rootURL
            .deletingLastPathComponent()
            .appending(path: "Workspace", directoryHint: .isDirectory)
    }

    func diagnostics(fileManager: FileManager = .default) -> [RuntimeArtifactDiagnostic] {
        [
            executable("Packaged Python 3.12", pythonURL, fileManager: fileManager),
            executable(
                "Source-built Kyutai STT worker",
                sttExecutableURL,
                fileManager: fileManager
            ),
            file(
                "MLX Moshi source package",
                mlxSitePackagesURL.appending(path: "moshi_mlx/__init__.py"),
                fileManager: fileManager
            ),
            file(
                "Moshi-RAG conditioner package",
                ragSitePackagesURL.appending(path: "moshi/__init__.py"),
                fileManager: fileManager
            ),
            file(
                "Pinned Moshi browser client",
                moshiClientURL.appending(path: "index.html"),
                fileManager: fileManager
            ),
            file("MLX Moshi-RAG weights", moshiWeightURL, fileManager: fileManager),
            file("ARC conditioner weights", conditionerWeightURL, fileManager: fileManager),
            file("Moshi tokenizer", tokenizerURL, fileManager: fileManager),
            file("Mimi weights", mimiWeightURL, fileManager: fileManager),
            file("Kyutai STT weights", sttWeightURL, fileManager: fileManager),
            file("Kyutai STT tokenizer", sttTokenizerURL, fileManager: fileManager),
            file("Kyutai STT Mimi weights", sttMimiWeightURL, fileManager: fileManager),
            file("MLX model configuration", mlxConfigurationURL, fileManager: fileManager),
            file("ARC model configuration", ragConfigurationURL, fileManager: fileManager),
            file("Kyutai STT configuration", sttConfigurationURL, fileManager: fileManager)
        ]
    }

    func voiceLaunchSpecs(
        referenceBaseURL: URL? = nil
    ) throws -> [RuntimeProcessSpec] {
        let failures = diagnostics().filter { !$0.available }
        guard failures.isEmpty else {
            throw RuntimeInstallationError.missingArtifacts(failures.map(\.label))
        }

        var commonEnvironment = [
            "HOME": rootURL.path,
            "HF_HOME": rootURL.appending(path: "HuggingFace").path,
            "NO_PROXY": "127.0.0.1,localhost",
            "PATH": "/usr/bin:/bin",
            "PYTHONHOME": bundledVoiceRuntimeRootURL.appending(path: "Python").path,
            "PYTHONNOUSERSITE": "1",
            "PYTHONUNBUFFERED": "1",
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "TMPDIR": FileManager.default.temporaryDirectory.path
        ]
        if let referenceBaseURL {
            commonEnvironment["LLM_BASE_URL"] = referenceBaseURL.absoluteString
            commonEnvironment["LLM_MODEL_NAME"] = "vibetalker-coordinator"
            commonEnvironment["LLM_API_KEY"] = "loopback-only"
            commonEnvironment["REFERENCE_ENCODER_URL"] = "http://127.0.0.1:8001"
        }

        var conditionerEnvironment = commonEnvironment
        conditionerEnvironment["PYTHONPATH"] = ragSitePackagesURL.path
        var moshiEnvironment = commonEnvironment
        moshiEnvironment["PYTHONPATH"] = mlxSitePackagesURL.path
        var sttEnvironment = commonEnvironment
        sttEnvironment["RAYON_NUM_THREADS"] = "4"
        sttEnvironment["VECLIB_MAXIMUM_THREADS"] = "4"
        let sttURL =
            "ws://127.0.0.1:8997/api/asr_streaming?auth_id=loopback-only"
        let transcriptURL = referenceBaseURL?
            .appending(path: "transcripts")
            .absoluteString ?? "http://127.0.0.1:8173/v1/transcripts"

        return [
            RuntimeProcessSpec(
                service: .referenceEncoder,
                executableURL: ragPythonURL,
                arguments: [
                    "-m", "moshi.server_conditioner",
                    "--moshi-weight", conditionerWeightURL.path,
                    "--config", ragConfigurationURL.path,
                    "--conditioner", "reference_with_time",
                    "--cuda-device", "mps",
                    "--host", "127.0.0.1",
                    "--port", "8001"
                ],
                workingDirectoryURL: rootURL,
                environment: conditionerEnvironment
            ),
            RuntimeProcessSpec(
                service: .speechToText,
                executableURL: sttExecutableURL,
                arguments: [
                    "worker",
                    "--addr", "127.0.0.1",
                    "--port", "8997",
                    "--cpu",
                    "--silent",
                    "--config", sttConfigurationURL.path
                ],
                workingDirectoryURL: rootURL,
                environment: sttEnvironment
            ),
            RuntimeProcessSpec(
                service: .moshi,
                executableURL: mlxPythonURL,
                arguments: [
                    "-m", "moshi_mlx.local_web",
                    "--moshi-weight", moshiWeightURL.path,
                    "--tokenizer", tokenizerURL.path,
                    "--mimi-weight", mimiWeightURL.path,
                    "--lm-config", mlxConfigurationURL.path,
                    "--first-speaker", "user",
                    "--host", "127.0.0.1",
                    "--port", "8999",
                    "--static", moshiClientURL.path,
                    "--no-browser",
                    "--stt-url", sttURL,
                    "--transcript-url", transcriptURL
                ],
                workingDirectoryURL: mlxWorkingDirectoryURL,
                environment: moshiEnvironment
            )
        ]
    }

    func piDiagnostics(
        nodeURL: URL,
        fileManager: FileManager = .default
    ) -> [RuntimeArtifactDiagnostic] {
        [
            executable("Embedded Node runtime", nodeURL, fileManager: fileManager),
            file("Pinned pi RPC build", piRPCEntryURL, fileManager: fileManager),
            file("VibeTalker pi tool policy", piToolPolicyURL, fileManager: fileManager)
        ]
    }

    func piLaunchSpec(
        nodeURL: URL,
        credential: CodingProviderCredential? = nil,
        customProvider: PiCustomProviderConfiguration? = nil
    ) throws -> RuntimeProcessSpec {
        let failures = piDiagnostics(nodeURL: nodeURL).filter { !$0.available }
        guard failures.isEmpty else {
            throw RuntimeInstallationError.missingArtifacts(failures.map(\.label))
        }
        try FileManager.default.createDirectory(
            at: sandboxWorkspaceURL,
            withIntermediateDirectories: true
        )
        if let customProvider {
            try writePiCustomProvider(customProvider)
        }

        var environment = [
            "HOME": rootURL.path,
            "NODE_NO_WARNINGS": "1",
            "OPENSSL_CONF": "/dev/null",
            "PATH": "/usr/bin:/bin",
            "PI_CODING_AGENT_DIR": rootURL.appending(path: "PiConfig").path,
            "TMPDIR": FileManager.default.temporaryDirectory.path
        ]
        if let credential {
            environment[credential.provider.environmentKey] = credential.value
        }

        return RuntimeProcessSpec(
            service: .pi,
            executableURL: nodeURL,
            arguments: [
                piRPCEntryURL.path,
                "--no-session",
                "--no-extensions",
                "--extension", piToolPolicyURL.path,
                "--no-skills",
                "--no-prompt-templates",
                "--no-themes",
                "--no-context-files",
                "--no-approve"
            ],
            workingDirectoryURL: sandboxWorkspaceURL,
            environment: environment
        )
    }

    private func writePiCustomProvider(
        _ configuration: PiCustomProviderConfiguration
    ) throws {
        let configurationDirectory = rootURL
            .appending(path: "PiConfig", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: configurationDirectory,
            withIntermediateDirectories: true
        )
        let payload: [String: Any] = [
            "providers": [
                PiCustomProviderConfiguration.providerID: [
                    "name": "VibeTalker oMLX",
                    "baseUrl": configuration.baseURL.absoluteString,
                    "apiKey": "$\(configuration.environmentKey)",
                    "api": configuration.api,
                    "models": [[
                        "id": configuration.modelID,
                        "name": configuration.modelID,
                        "reasoning": true,
                        "input": ["text"],
                        "cost": [
                            "input": 0,
                            "output": 0,
                            "cacheRead": 0,
                            "cacheWrite": 0
                        ],
                        "contextWindow": 128_000,
                        "maxTokens": 16_384
                    ]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: configurationDirectory.appending(path: "models.json"),
            options: .atomic
        )
    }

    private func executable(
        _ label: String,
        _ url: URL,
        fileManager: FileManager
    ) -> RuntimeArtifactDiagnostic {
        .init(
            label: label,
            url: url,
            available: fileManager.isExecutableFile(atPath: url.path)
        )
    }

    private func file(
        _ label: String,
        _ url: URL,
        fileManager: FileManager
    ) -> RuntimeArtifactDiagnostic {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return .init(label: label, url: url, available: exists && !isDirectory.boolValue)
    }
}

nonisolated struct RuntimeArtifactDiagnostic: Identifiable, Sendable {
    var id: String { url.path }
    let label: String
    let url: URL
    let available: Bool
}

nonisolated enum RuntimeInstallationError: LocalizedError, Equatable {
    case missingArtifacts([String])
    case invalidCustomProvider

    var errorDescription: String? {
        switch self {
        case .missingArtifacts(let labels):
            "Managed runtime is incomplete: \(labels.joined(separator: ", "))"
        case .invalidCustomProvider:
            "A valid HTTP(S) endpoint and model ID are required for a compatible provider."
        }
    }
}

nonisolated enum VoiceRuntimeImporterError: LocalizedError, Equatable {
    case invalidSource
    case revisionMismatch
    case incompleteSource([String])
    case sourceMatchesDestination
    case unsafeSymbolicLink(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            "The selected folder is not a VibeTalker voice-runtime staging directory."
        case .revisionMismatch:
            "The staged voice runtime does not match VibeTalker's pinned revisions."
        case .incompleteSource(let labels):
            "The staged voice runtime is incomplete: \(labels.joined(separator: ", "))."
        case .sourceMatchesDestination:
            "The staged runtime must be outside VibeTalker's managed runtime directory."
        case .unsafeSymbolicLink(let path):
            "The staged runtime contains a link outside its root: \(path)."
        }
    }
}

nonisolated struct VoiceRuntimeImporter: Sendable {
    static let moshiRevision = "e6a55d2722a65870ef52a6c9f6ecfc0e90f38362"
    static let ragRevision = "8c6dfc101b7871baa428424bcdc583b74fb561d9"

    private let components = [
        "Models",
        "moshi-rag-mlx-config.json",
        "moshi-rag-config.json",
        "moshi-stt.toml",
        ".vibetalker-voice-runtime"
    ]

    func importRuntime(
        from sourceURL: URL,
        into installation: RuntimeInstallation,
        fileManager: FileManager = .default
    ) throws {
        let source = sourceURL.standardizedFileURL
        let destination = installation.rootURL.standardizedFileURL
        guard source != destination,
              !destination.path.hasPrefix(source.path + "/"),
              !source.path.hasPrefix(destination.path + "/") else {
            throw VoiceRuntimeImporterError.sourceMatchesDestination
        }

        try validate(
            source,
            codeRootURL: installation.bundledVoiceRuntimeRootURL,
            codeExecutableURL: installation.bundledVoiceExecutableURL,
            fileManager: fileManager
        )
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )

        let transactionID = UUID().uuidString
        let staging = destination.appending(
            path: ".voice-import-\(transactionID)",
            directoryHint: .isDirectory
        )
        let backup = destination.appending(
            path: ".voice-backup-\(transactionID)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)

        var installedComponents: [String] = []
        var backedUpComponents: [String] = []
        do {
            for component in components {
                try fileManager.copyItem(
                    at: source.appending(path: component),
                    to: staging.appending(path: component)
                )
            }
            try validate(
                staging,
                codeRootURL: installation.bundledVoiceRuntimeRootURL,
                codeExecutableURL: installation.bundledVoiceExecutableURL,
                fileManager: fileManager
            )

            for component in components {
                let current = destination.appending(path: component)
                if fileManager.fileExists(atPath: current.path) {
                    try fileManager.moveItem(
                        at: current,
                        to: backup.appending(path: component)
                    )
                    backedUpComponents.append(component)
                }
                try fileManager.moveItem(
                    at: staging.appending(path: component),
                    to: current
                )
                installedComponents.append(component)
            }
            try fileManager.removeItem(at: backup)
            try fileManager.removeItem(at: staging)
        } catch {
            for component in installedComponents.reversed() {
                try? fileManager.removeItem(
                    at: destination.appending(path: component)
                )
            }
            for component in backedUpComponents.reversed() {
                try? fileManager.moveItem(
                    at: backup.appending(path: component),
                    to: destination.appending(path: component)
                )
            }
            try? fileManager.removeItem(at: backup)
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func validate(
        _ rootURL: URL,
        codeRootURL: URL,
        codeExecutableURL: URL,
        fileManager: FileManager
    ) throws {
        let markerURL = rootURL.appending(path: ".vibetalker-voice-runtime")
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8) else {
            throw VoiceRuntimeImporterError.invalidSource
        }
        guard marker.contains("moshi=\(Self.moshiRevision)"),
              marker.contains("moshi-rag=\(Self.ragRevision)") else {
            throw VoiceRuntimeImporterError.revisionMismatch
        }
        let missing = RuntimeInstallation(
            rootURL: rootURL,
            bundledVoiceRuntimeRootURL: codeRootURL,
            bundledVoiceExecutableURL: codeExecutableURL
        )
            .diagnostics(fileManager: fileManager)
            .filter { !$0.available }
            .map(\.label)
        guard missing.isEmpty else {
            throw VoiceRuntimeImporterError.incompleteSource(missing)
        }
        try validateSymbolicLinks(in: rootURL, fileManager: fileManager)
    }

    private func validateSymbolicLinks(
        in rootURL: URL,
        fileManager: FileManager
    ) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw VoiceRuntimeImporterError.invalidSource
        }
        for case let itemURL as URL in enumerator {
            let values = try itemURL.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink == true else { continue }
            let resolved = itemURL.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(rootURL.path + "/") else {
                throw VoiceRuntimeImporterError.unsafeSymbolicLink(itemURL.path)
            }
        }
    }
}
