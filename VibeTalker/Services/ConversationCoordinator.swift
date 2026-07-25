import Foundation

nonisolated protocol ReferenceDelivering: Sendable {
    func deliver(_ delivery: ReferenceDelivery) async throws
}

nonisolated protocol PiRequestDispatching: Sendable {
    func dispatch(_ request: PiRequest) async throws -> PiDispatchReceipt
}

nonisolated struct ReferenceDelivery: Equatable, Sendable {
    let voiceSessionID: UUID
    let utteranceID: UUID
    let interactionRequestID: UUID
    let text: String
}

nonisolated enum PiDispatchReceipt: Equatable, Sendable {
    case started(projectName: String)
    case cancellationRequested(projectName: String)
    case status(projectName: String, summary: String)
}

nonisolated struct CoordinatedTurn: Equatable, Sendable {
    let interaction: ValidatedInteraction
    let reference: ReferenceDelivery
    let piReceipt: PiDispatchReceipt?
}

nonisolated enum ConversationCoordinatorError: LocalizedError, Equatable {
    case noActiveVoiceSession
    case wrongVoiceSession
    case staleTranscriptRevision
    case emptyTranscript
    case staleInteraction
    case mismatchedPiReceipt
    case invalidGroundedText

    var errorDescription: String? {
        switch self {
        case .noActiveVoiceSession:
            "No voice session is active."
        case .wrongVoiceSession:
            "The committed transcript belongs to a different voice session."
        case .staleTranscriptRevision:
            "The committed transcript revision is stale."
        case .emptyTranscript:
            "The committed transcript is empty."
        case .staleInteraction:
            "The Interaction result became stale before delivery."
        case .mismatchedPiReceipt:
            "Pi returned a receipt for a different operation."
        case .invalidGroundedText:
            "Coordinator evidence contains invalid project or status text."
        }
    }
}

actor ConversationCoordinator {
    private struct Admission: Equatable {
        let voiceSessionID: UUID
        let utteranceID: UUID
        let revision: UInt64
    }

    private let interactor: any InteractionServing
    private let piDispatcher: any PiRequestDispatching
    private let referenceDelivery: any ReferenceDelivering
    private var activeVoiceSessionID: UUID?
    private var latestRevisionByUtterance: [UUID: UInt64] = [:]

    init(
        interactor: any InteractionServing,
        piDispatcher: any PiRequestDispatching,
        referenceDelivery: any ReferenceDelivering
    ) {
        self.interactor = interactor
        self.piDispatcher = piDispatcher
        self.referenceDelivery = referenceDelivery
    }

    func beginVoiceSession(_ id: UUID) {
        activeVoiceSessionID = id
        latestRevisionByUtterance.removeAll()
    }

    func endVoiceSession(_ id: UUID) {
        guard activeVoiceSessionID == id else { return }
        activeVoiceSessionID = nil
        latestRevisionByUtterance.removeAll()
    }

    func commit(_ utterance: CommittedUtterance) async throws -> CoordinatedTurn {
        let admission = try admit(utterance)
        let interaction = try await interactor.interact(with: utterance)
        try requireCurrent(admission)

        let receipt: PiDispatchReceipt?
        let referenceText: String
        if let request = interaction.piRequest {
            let dispatched = try await piDispatcher.dispatch(request)
            try requireCurrent(admission)
            referenceText = try groundedReference(
                for: request,
                receipt: dispatched
            )
            receipt = dispatched
        } else {
            referenceText = interaction.referenceResponse
            receipt = nil
        }

        let delivery = ReferenceDelivery(
            voiceSessionID: utterance.voiceSessionID,
            utteranceID: utterance.utteranceID,
            interactionRequestID: interaction.requestID,
            text: referenceText
        )
        try await referenceDelivery.deliver(delivery)
        try requireCurrent(admission)

        return CoordinatedTurn(
            interaction: interaction,
            reference: delivery,
            piReceipt: receipt
        )
    }

    private func admit(_ utterance: CommittedUtterance) throws -> Admission {
        guard let activeVoiceSessionID else {
            throw ConversationCoordinatorError.noActiveVoiceSession
        }
        guard activeVoiceSessionID == utterance.voiceSessionID else {
            throw ConversationCoordinatorError.wrongVoiceSession
        }
        guard !utterance.transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else {
            throw ConversationCoordinatorError.emptyTranscript
        }
        let latest = latestRevisionByUtterance[utterance.utteranceID] ?? 0
        guard utterance.revision > latest else {
            throw ConversationCoordinatorError.staleTranscriptRevision
        }
        latestRevisionByUtterance[utterance.utteranceID] = utterance.revision
        return Admission(
            voiceSessionID: utterance.voiceSessionID,
            utteranceID: utterance.utteranceID,
            revision: utterance.revision
        )
    }

    private func requireCurrent(_ admission: Admission) throws {
        guard activeVoiceSessionID == admission.voiceSessionID,
              latestRevisionByUtterance[admission.utteranceID]
                == admission.revision else {
            throw ConversationCoordinatorError.staleInteraction
        }
    }

    private func groundedReference(
        for request: PiRequest,
        receipt: PiDispatchReceipt
    ) throws -> String {
        switch (request.operation, receipt) {
        case (.start, .started(let projectName)):
            return "Work started in \(try grounded(projectName))."
        case (.cancel, .cancellationRequested(let projectName)):
            return "Cancellation requested for \(try grounded(projectName))."
        case (.status, .status(let projectName, let summary)):
            return "\(try grounded(projectName)): \(try grounded(summary))"
        default:
            throw ConversationCoordinatorError.mismatchedPiReceipt
        }
    }

    private func grounded(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 400 else {
            throw ConversationCoordinatorError.invalidGroundedText
        }
        return normalized
    }
}
