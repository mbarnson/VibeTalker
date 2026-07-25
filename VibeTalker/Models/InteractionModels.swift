import Foundation

nonisolated struct CommittedUtterance: Equatable, Sendable {
    let voiceSessionID: UUID
    let utteranceID: UUID
    let revision: UInt64
    let transcript: String
}

nonisolated enum PiOperation: String, Codable, Sendable {
    case start
    case cancel
    case status
}

nonisolated struct PiRequest: Codable, Equatable, Sendable {
    let operation: PiOperation
    let instruction: String?
}

nonisolated enum PiRequestOrigin: String, Equatable, Sendable {
    case voice
    case console
}

nonisolated struct PendingPiProposal: Equatable, Sendable {
    let id: UUID
    let request: PiRequest
    let normalizedAction: String
    let origin: PiRequestOrigin
    let projectName: String
    let riskReason: String
    let expiresAt: Date

    var confirmationQuestion: String {
        "This request would \(riskReason) in \(projectName). "
            + (origin == .voice ? "Say" : "Type")
            + " confirm to continue, or no to reject it."
    }
}

nonisolated enum PiPolicyDecision: Equatable, Sendable {
    case dispatch(PiRequest)
    case awaitConfirmation(PendingPiProposal)
    case refuse(String)
}

nonisolated enum PendingProposalResolution: Equatable, Sendable {
    case none(expiredMessage: String?)
    case dispatch(PiRequest, message: String)
    case consumed(message: String)
}

actor PiRequestPolicy {
    private let projectName: String
    private var pendingProposal: PendingPiProposal?

    init(projectName: String) {
        self.projectName = projectName
    }

    func reset(reason: String) -> String? {
        guard let pendingProposal else { return nil }
        self.pendingProposal = nil
        return "Proposal \(pendingProposal.id.uuidString) expired: \(reason)"
    }

    func resolvePending(
        with input: String,
        origin: PiRequestOrigin,
        now: Date = Date()
    ) -> PendingProposalResolution {
        guard let proposal = pendingProposal else {
            return .none(expiredMessage: nil)
        }
        guard proposal.expiresAt > now else {
            pendingProposal = nil
            return .none(
                expiredMessage:
                    "Proposal \(proposal.id.uuidString) expired after 30 seconds"
            )
        }
        guard proposal.origin == origin else {
            pendingProposal = nil
            return .none(
                expiredMessage:
                    "Proposal \(proposal.id.uuidString) expired after input from "
                    + "a different control channel"
            )
        }

        let normalized = Self.normalized(input)
        if Self.confirmations.contains(normalized) {
            pendingProposal = nil
            return .dispatch(
                proposal.request,
                message:
                    "Proposal \(proposal.id.uuidString) confirmed via \(origin.rawValue)"
            )
        }
        if Self.rejections.contains(normalized) {
            pendingProposal = nil
            return .consumed(
                message:
                    "Proposal \(proposal.id.uuidString) rejected via \(origin.rawValue)"
            )
        }

        pendingProposal = nil
        return .none(
            expiredMessage:
                "Proposal \(proposal.id.uuidString) expired after an unrelated "
                + "\(origin.rawValue) input"
        )
    }

    func evaluate(
        _ request: PiRequest,
        origin: PiRequestOrigin,
        now: Date = Date()
    ) -> PiPolicyDecision {
        guard request.operation == .start, let instruction = request.instruction else {
            return .dispatch(request)
        }

        let normalized = Self.normalized(instruction)
        if let reason = Self.unavailableReason(
            in: instruction.lowercased(),
            normalized: normalized
        ) {
            pendingProposal = nil
            return .refuse(
                "\(reason) is unavailable in Slice One; no work was started."
            )
        }
        if let riskReason = Self.confirmationReason(in: normalized) {
            let proposal = PendingPiProposal(
                id: UUID(),
                request: request,
                normalizedAction: normalized,
                origin: origin,
                projectName: projectName,
                riskReason: riskReason,
                expiresAt: now.addingTimeInterval(30)
            )
            pendingProposal = proposal
            return .awaitConfirmation(proposal)
        }
        pendingProposal = nil
        return .dispatch(request)
    }

    private static let confirmations: Set<String> = [
        "confirm", "confirmed", "yes", "yes confirm", "proceed", "go ahead", "do it"
    ]
    private static let rejections: Set<String> = [
        "no", "reject", "cancel", "never mind", "nevermind", "do not"
    ]

    private static func normalized(_ value: String) -> String {
        String(value.lowercased().map { character in
            character.isLetter || character.isNumber ? character : " "
        })
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func unavailableReason(
        in rawInstruction: String,
        normalized instruction: String
    ) -> String? {
        let externalMarkers = [
            "../", "~/", "/users/", "outside the workspace", "outside workspace",
            "desktop folder", "documents folder", "home directory"
        ]
        if externalMarkers.contains(where: { marker in
            (marker.contains("/") ? rawInstruction : instruction).contains(marker)
        }) {
            return "Access outside the selected workspace"
        }

        let projectMarkers = [
            "another project", "different project", "switch project", "change project",
            "other repository", "another repository", "git clone", "clone the repo",
            "clone the repository"
        ]
        if projectMarkers.contains(where: instruction.contains) {
            return "Project switching"
        }
        return nil
    }

    private static func confirmationReason(in instruction: String) -> String? {
        let destructiveMarkers = [
            "delete", "remove", "erase", "wipe", "destroy", "overwrite",
            "discard", "truncate", "drop database", "reset hard", "git clean",
            "revert all"
        ]
        if destructiveMarkers.contains(where: instruction.contains) {
            return "perform a destructive change"
        }

        let ambiguousInstructions: Set<String> = [
            "fix it", "change it", "update it", "handle it", "make it work"
        ]
        if ambiguousInstructions.contains(instruction)
            || instruction.split(separator: " ").count < 3 {
            return "act on an ambiguous instruction"
        }
        return nil
    }
}

nonisolated enum InteractionMissPolicy {
    static func reference(for transcript: String) -> String {
        let words = Set(
            transcript
                .lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
        )
        let actionWords: Set<String> = [
            "add", "build", "change", "create", "delete", "edit", "fix",
            "implement", "refactor", "remove", "rename", "run", "test", "update",
            "write"
        ]
        if !words.isDisjoint(with: actionWords) {
            return "I couldn't verify that request, so no work was started."
        }
        return "I couldn't retrieve that context just now."
    }
}

nonisolated struct InteractionOutput: Codable, Equatable, Sendable {
    let utteranceID: UUID
    let referenceResponse: String
    let piRequest: PiRequest?

    enum CodingKeys: String, CodingKey {
        case utteranceID = "utterance_id"
        case referenceResponse = "reference_response"
        case piRequest = "pi_request"
    }
}

nonisolated struct ValidatedInteraction: Equatable, Sendable {
    let requestID: UUID
    let utterance: CommittedUtterance
    let referenceResponse: String
    let piRequest: PiRequest?
    let providerResponseID: String?
    let latency: Duration
}

nonisolated enum InteractionValidationError: LocalizedError, Equatable {
    case staleUtterance
    case invalidReference
    case invalidPiRequest

    var errorDescription: String? {
        switch self {
        case .staleUtterance:
            "Interaction output does not match the current utterance."
        case .invalidReference:
            "Interaction Reference must contain 1–400 characters."
        case .invalidPiRequest:
            "Interaction Pi Request is malformed."
        }
    }
}

nonisolated enum InteractionValidator {
    static func validate(
        _ output: InteractionOutput,
        for utterance: CommittedUtterance
    ) throws -> InteractionOutput {
        guard output.utteranceID == utterance.utteranceID else {
            throw InteractionValidationError.staleUtterance
        }

        let reference = output.referenceResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty, reference.count <= 400 else {
            throw InteractionValidationError.invalidReference
        }

        let piRequest = try output.piRequest.map(validate)
        return InteractionOutput(
            utteranceID: output.utteranceID,
            referenceResponse: reference,
            piRequest: piRequest
        )
    }

    private static func validate(_ request: PiRequest) throws -> PiRequest {
        let instruction = request.instruction?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch request.operation {
        case .start:
            guard
                let instruction,
                !instruction.isEmpty,
                instruction.count <= 4_000
            else {
                throw InteractionValidationError.invalidPiRequest
            }
            return PiRequest(operation: .start, instruction: instruction)
        case .cancel, .status:
            guard instruction == nil || instruction?.isEmpty == true else {
                throw InteractionValidationError.invalidPiRequest
            }
            return PiRequest(operation: request.operation, instruction: nil)
        }
    }
}
