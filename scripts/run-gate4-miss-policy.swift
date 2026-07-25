import Foundation

private struct Corpus: Decodable {
    struct Turn: Decodable {
        let category: String
        let transcript: String
        let expectsExplicitNonDispatch: Bool

        enum CodingKeys: String, CodingKey {
            case category
            case transcript
            case expectsExplicitNonDispatch = "expects_explicit_non_dispatch"
        }
    }

    let schemaVersion: Int
    let turns: [Turn]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case turns
    }
}

@main
private enum Gate4MissPolicy {
    static func main() throws {
        let data = try Data(contentsOf: URL(
            fileURLWithPath: "Fixtures/Gate4/interaction-miss-corpus.json"
        ))
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        guard corpus.schemaVersion == 1, corpus.turns.count == 20 else {
            throw NSError(
                domain: "Gate4MissPolicy",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid frozen corpus"]
            )
        }

        let explicit = "no work was started"
        let matches = corpus.turns.filter { turn in
            InteractionMissPolicy.reference(for: turn.transcript)
                .contains(explicit) == turn.expectsExplicitNonDispatch
        }.count
        let actionTurns = corpus.turns.filter { $0.category == "action" }
        let ordinaryTurns = corpus.turns.filter { $0.category == "ordinary" }
        let summary: [String: Any] = [
            "schema_version": 1,
            "turn_count": corpus.turns.count,
            "expected_classification_matches": matches,
            "heuristic_action_clarity": actionTurns.filter {
                InteractionMissPolicy.reference(for: $0.transcript)
                    .contains(explicit)
            }.count,
            "heuristic_ordinary_explicit_non_dispatch": ordinaryTurns.filter {
                InteractionMissPolicy.reference(for: $0.transcript)
                    .contains(explicit)
            }.count,
            "neutral_action_clarity": 0,
            "neutral_ordinary_explicit_non_dispatch": 0
        ]
        let output = try JSONSerialization.data(
            withJSONObject: summary,
            options: [.prettyPrinted, .sortedKeys]
        )
        print(String(decoding: output, as: UTF8.self))
        guard matches == corpus.turns.count else {
            throw NSError(
                domain: "Gate4MissPolicy",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Interaction-miss policy disagrees with frozen corpus"
                ]
            )
        }
    }
}
