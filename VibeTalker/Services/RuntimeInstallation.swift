import Foundation

struct RuntimeInstallation: Sendable {
    let rootURL: URL

    init(rootURL: URL? = nil) {
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

struct RuntimeArtifactDiagnostic: Identifiable, Sendable {
    var id: String { url.path }
    let label: String
    let url: URL
    let available: Bool
}

enum RuntimeInstallationError: LocalizedError, Equatable {
    case missingArtifacts([String])

    var errorDescription: String? {
        switch self {
        case .missingArtifacts(let labels):
            "Managed runtime is incomplete: \(labels.joined(separator: ", "))"
        }
    }
}
