import Foundation

nonisolated struct RuntimeInstallation: Sendable {
    let rootURL: URL
    let bundledRuntimeRootURL: URL

    init(rootURL: URL? = nil, bundledRuntimeRootURL: URL? = nil) {
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
    }

    var mlxPythonURL: URL {
        rootURL.appending(path: "moshi-mlx/.venv/bin/python")
    }

    var ragPythonURL: URL {
        rootURL.appending(path: "moshi-rag/.venv/bin/python")
    }

    var mlxWorkingDirectoryURL: URL {
        rootURL.appending(path: "moshi-mlx", directoryHint: .isDirectory)
    }

    var ragWorkingDirectoryURL: URL {
        rootURL.appending(path: "moshi-rag", directoryHint: .isDirectory)
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

    var mlxConfigurationURL: URL {
        rootURL.appending(path: "moshi-rag-mlx-config.json")
    }

    var ragConfigurationURL: URL {
        rootURL.appending(path: "moshi-rag-config.json")
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
            executable("MLX Python", mlxPythonURL, fileManager: fileManager),
            executable("Moshi-RAG Python", ragPythonURL, fileManager: fileManager),
            file("MLX Moshi-RAG weights", moshiWeightURL, fileManager: fileManager),
            file("ARC conditioner weights", conditionerWeightURL, fileManager: fileManager),
            file("Moshi tokenizer", tokenizerURL, fileManager: fileManager),
            file("Mimi weights", mimiWeightURL, fileManager: fileManager),
            file("MLX model configuration", mlxConfigurationURL, fileManager: fileManager),
            file("ARC model configuration", ragConfigurationURL, fileManager: fileManager)
        ]
    }

    func voiceLaunchSpecs() throws -> [RuntimeProcessSpec] {
        let failures = diagnostics().filter { !$0.available }
        guard failures.isEmpty else {
            throw RuntimeInstallationError.missingArtifacts(failures.map(\.label))
        }

        let commonEnvironment = [
            "HOME": rootURL.path,
            "HF_HOME": rootURL.appending(path: "HuggingFace").path,
            "NO_PROXY": "127.0.0.1,localhost",
            "PATH": "/usr/bin:/bin",
            "PYTHONUNBUFFERED": "1",
            "TMPDIR": FileManager.default.temporaryDirectory.path
        ]

        return [
            RuntimeProcessSpec(
                service: .referenceEncoder,
                executableURL: ragPythonURL,
                arguments: [
                    "-m", "moshi.moshi.server_conditioner",
                    "--moshi-weight", conditionerWeightURL.path,
                    "--lm-config", ragConfigurationURL.path,
                    "--conditioner", "reference_with_time",
                    "--cuda-device", "mps",
                    "--host", "127.0.0.1",
                    "--port", "8001"
                ],
                workingDirectoryURL: ragWorkingDirectoryURL,
                environment: commonEnvironment
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
                    "--no-browser"
                ],
                workingDirectoryURL: mlxWorkingDirectoryURL,
                environment: commonEnvironment
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
        credential: CodingProviderCredential? = nil
    ) throws -> RuntimeProcessSpec {
        let failures = piDiagnostics(nodeURL: nodeURL).filter { !$0.available }
        guard failures.isEmpty else {
            throw RuntimeInstallationError.missingArtifacts(failures.map(\.label))
        }
        try FileManager.default.createDirectory(
            at: sandboxWorkspaceURL,
            withIntermediateDirectories: true
        )

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

    var errorDescription: String? {
        switch self {
        case .missingArtifacts(let labels):
            "Managed runtime is incomplete: \(labels.joined(separator: ", "))"
        }
    }
}
