//
//  LamportClockTests.swift
//  Ledgerline
//
//  Created by Ariel Tyson on 12/6/26.
//
//  First tests of the convergence story. These don't test "code paths";
//  they test the *distributed systems properties* the engine depends on.
//

import Foundation
import Testing

@testable import Ledgerline

@Suite("Lamport clock properties")
struct LamportClockTests {

    @Test("Local events are strictly increasing")
    func localMonotonicity() {
        var clock = LamportClock()
        let a = clock.tick()
        let b = clock.tick()
        let c = clock.tick()
        #expect(a < b && b < c)
    }

    @Test(
        "Causality: an event created after observing a remote event is stamped later"
    )
    func happenedBeforeIsRespected() {
        // Device A does some work...
        var deviceA = LamportClock()
        _ = deviceA.tick()
        _ = deviceA.tick()
        let remoteStamp = deviceA.tick()  // A's event, lamport = 3

        // Device B has done LESS work (its wall clock might even be
        // set in the future — irrelevant). B receives A's event:
        var deviceB = LamportClock()
        _ = deviceB.tick()  // B at 1
        deviceB.observe(remoteStamp)  // B fast-forwards to 3

        // Anything B does NOW is causally after A's event:
        let bNext = deviceB.tick()
        #expect(bNext > remoteStamp)
    }

    @Test("Concurrent events can tie — and the tie is real information")
    func concurrencyProducesTies() {
        // Two devices working in airplane mode, neither has seen the other:
        var deviceA = LamportClock()
        var deviceB = LamportClock()
        let a = deviceA.tick()  // 1
        let b = deviceB.tick()  // 1
        // Equal stamps == neither causally preceded the other.
        // The merge rules (Commit 1.3) adjudicate; the total order's
        // author tiebreak guarantees every replica adjudicates identically.
        #expect(a == b)
    }
}

@Suite("Total order properties")
struct TotalOrderTests {

    private func event(lamport: UInt64, author: String) -> LedgerEvent {
        LedgerEvent(
            id: UUID(),
            ledgerID: UUID(),
            author: ParticipantID(rawValue: author),
            payload: .expenseDeleted,
            targetExpenseID: nil,
            lamport: lamport,
            wallClock: .now
        )
    }

    @Test(
        "Every replica sorts the same event set identically, regardless of arrival order"
    )
    func orderIsDeterministicUnderShuffle() {
        let events = [
            event(lamport: 2, author: "sam"),
            event(lamport: 1, author: "alex"),
            event(lamport: 2, author: "alex"),  // ties with sam@2 → author breaks it
            event(lamport: 3, author: "sam"),
        ]

        let sortedOnce = events.sorted(by: LedgerEvent.totalOrder)

        // Simulate 50 replicas receiving the same events in random orders:
        for _ in 0..<50 {
            let shuffled = events.shuffled().sorted(by: LedgerEvent.totalOrder)
            #expect(shuffled == sortedOnce)
        }
    }

    @Test("Wall clocks play no role in ordering")
    func wallClockIsCosmetic() {
        var early = event(lamport: 5, author: "sam")
        var late = event(lamport: 1, author: "alex")
        // Force the wall clocks to LIE (skewed device, changed timezone):
        early = LedgerEvent(
            id: early.id,
            ledgerID: early.ledgerID,
            author: early.author,
            payload: early.payload,
            targetExpenseID: nil,
            lamport: 5,
            wallClock: .distantPast
        )
        late = LedgerEvent(
            id: late.id,
            ledgerID: late.ledgerID,
            author: late.author,
            payload: late.payload,
            targetExpenseID: nil,
            lamport: 1,
            wallClock: .distantFuture
        )

        let sorted = [early, late].sorted(by: LedgerEvent.totalOrder)
        // lamport 1 comes first — the absurd wall clocks are ignored:
        #expect(sorted.first?.lamport == 1)
    }
}
