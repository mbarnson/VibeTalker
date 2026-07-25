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
