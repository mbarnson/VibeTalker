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
    let interaction: ValidatedInteraction?
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
    private let policy: PiRequestPolicy
    private let eventSink: @Sendable (LedgerEventKind, String) async -> Void
    private var activeVoiceSessionID: UUID?
    private var latestRevisionByUtterance: [UUID: UInt64] = [:]

    init(
        interactor: any InteractionServing,
        piDispatcher: any PiRequestDispatching,
        referenceDelivery: any ReferenceDelivering,
        policy: PiRequestPolicy = PiRequestPolicy(projectName: "Workspace"),
        eventSink: @escaping @Sendable (LedgerEventKind, String) async -> Void = { _, _ in }
    ) {
        self.interactor = interactor
        self.piDispatcher = piDispatcher
        self.referenceDelivery = referenceDelivery
        self.policy = policy
        self.eventSink = eventSink
    }

    func beginVoiceSession(_ id: UUID) async {
        if let expiry = await policy.reset(reason: "voice session changed") {
            await eventSink(.policy, expiry)
        }
        activeVoiceSessionID = id
        latestRevisionByUtterance.removeAll()
    }

    func endVoiceSession(_ id: UUID) async {
        guard activeVoiceSessionID == id else { return }
        if let expiry = await policy.reset(reason: "voice session ended") {
            await eventSink(.policy, expiry)
        }
        activeVoiceSessionID = nil
        latestRevisionByUtterance.removeAll()
    }

    func commit(_ utterance: CommittedUtterance) async throws -> CoordinatedTurn {
        let admission = try admit(utterance)

        switch await policy.resolvePending(
            with: utterance.transcript,
            origin: .voice
        ) {
        case .dispatch(let request, let message):
            await eventSink(.policy, message)
            let dispatched = try await piDispatcher.dispatch(request)
            try requireCurrent(admission)
            let reference = try await deliver(
                try groundedReference(for: request, receipt: dispatched),
                admission: admission,
                requestID: UUID()
            )
            return CoordinatedTurn(
                interaction: nil,
                reference: reference,
                piReceipt: dispatched
            )
        case .consumed(let message):
            await eventSink(.policy, message)
            let reference = try await deliver(
                "The pending request was rejected; no work was started.",
                admission: admission,
                requestID: UUID()
            )
            return CoordinatedTurn(
                interaction: nil,
                reference: reference,
                piReceipt: nil
            )
        case .none(let expiredMessage):
            if let expiredMessage {
                await eventSink(.policy, expiredMessage)
            }
        }

        let interaction: ValidatedInteraction
        do {
            interaction = try await interactor.interact(with: utterance)
        } catch {
            await eventSink(
                .error,
                "Interaction miss: \(error.localizedDescription)"
            )
            let reference = try await deliver(
                InteractionMissPolicy.reference(for: utterance.transcript),
                admission: admission,
                requestID: UUID()
            )
            return CoordinatedTurn(
                interaction: nil,
                reference: reference,
                piReceipt: nil
            )
        }
        try requireCurrent(admission)

        let receipt: PiDispatchReceipt?
        let referenceText: String
        if let request = interaction.piRequest {
            switch await policy.evaluate(request, origin: .voice) {
            case .dispatch(let approved):
                let dispatched = try await piDispatcher.dispatch(approved)
                try requireCurrent(admission)
                referenceText = try groundedReference(
                    for: approved,
                    receipt: dispatched
                )
                receipt = dispatched
            case .awaitConfirmation(let proposal):
                await eventSink(
                    .policy,
                    "Proposal \(proposal.id.uuidString) is waiting for confirmation"
                )
                referenceText = proposal.confirmationQuestion
                receipt = nil
            case .refuse(let reason):
                await eventSink(.policy, reason)
                referenceText = reason
                receipt = nil
            }
        } else {
            referenceText = interaction.referenceResponse
            receipt = nil
        }

        let delivery = try await deliver(
            referenceText,
            admission: admission,
            requestID: interaction.requestID
        )

        return CoordinatedTurn(
            interaction: interaction,
            reference: delivery,
            piReceipt: receipt
        )
    }

    private func deliver(
        _ text: String,
        admission: Admission,
        requestID: UUID
    ) async throws -> ReferenceDelivery {
        let delivery = ReferenceDelivery(
            voiceSessionID: admission.voiceSessionID,
            utteranceID: admission.utteranceID,
            interactionRequestID: requestID,
            text: text
        )
        try await referenceDelivery.deliver(delivery)
        try requireCurrent(admission)
        return delivery
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
