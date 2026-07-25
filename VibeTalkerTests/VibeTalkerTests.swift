//
//  VibeTalkerTests.swift
//  VibeTalkerTests
//
//  Created by Matthew Barnson on 7/24/26.
//

import Testing
@testable import VibeTalker

struct VibeTalkerTests {
    @Test func ledgerMaintainsOrderAndRedactsSecrets() async {
        let ledger = EventLedger()
        let first = await ledger.append(.system, "started")
        let second = await ledger.append(.error, "api_key=do-not-publish")
        let events = await ledger.snapshot()

        #expect(first.sequence == 1)
        #expect(second.sequence == 2)
        #expect(events.map(\.sequence) == [1, 2])
        #expect(events[1].message == "[REDACTED]")
    }

    @Test func redactorCoversProviderTokens() {
        let value = SecretRedactor.redact(
            "token: abcdefghijklmnop sk-abcdefghijklmnop ghp_abcdefghijklmnopqrstuvwxyz"
        )

        #expect(!value.contains("abcdefghijklmnop"))
        #expect(!value.contains("ghp_"))
    }
}
