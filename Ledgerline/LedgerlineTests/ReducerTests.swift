//
//  ReducerTests.swift
//  Ledgerline
//
//  Created by Ariel Tyson on 4/7/26.
//
//
//  These tests assert the ARCHITECTURE.md promises by rule number.
//  The shuffle/duplicate tests are the convergence invariant in
//  miniature — Phase 1.4 grows them into the full property suite.
//

import Foundation
import Testing

@testable import Ledgerline

// MARK: - Test fixtures

private let ledger = UUID()
private let sam = ParticipantID(rawValue: "sam")
private let alex = ParticipantID(rawValue: "alex")

private func usd(_ dollars: Int64, _ cents: Int64 = 0) -> Money {
    Money(minorUnits: dollars * 100 + cents, currencyCode: "USD")
}

private func added(
    _ amount: Money,
    by payer: ParticipantID,
    lamport: UInt64,
    author: ParticipantID? = nil
) -> LedgerEvent {
    LedgerEvent(
        id: UUID(),
        ledgerID: ledger,
        author: author ?? payer,
        payload: .expenseAdded(
            ExpenseDetails(
                amount: amount,
                category: "General",
                note: "",
                paidBy: payer,
                participants: [sam, alex]
            )
        ),
        targetExpenseID: nil,
        lamport: lamport,
        wallClock: .now
    )
}

private func edited(
    _ target: UUID,
    amount: Money? = nil,
    note: String? = nil,
    by author: ParticipantID,
    lamport: UInt64
) -> LedgerEvent {
    LedgerEvent(
        id: UUID(),
        ledgerID: ledger,
        author: author,
        payload: .expenseEdited(
            ExpenseEdit(amount: amount, category: nil, note: note)
        ),
        targetExpenseID: target,
        lamport: lamport,
        wallClock: .now
    )
}

private func deleted(
    _ target: UUID,
    by author: ParticipantID,
    lamport: UInt64
) -> LedgerEvent {
    LedgerEvent(
        id: UUID(),
        ledgerID: ledger,
        author: author,
        payload: .expenseDeleted,
        targetExpenseID: target,
        lamport: lamport,
        wallClock: .now
    )
}

private func settled(
    _ amount: Money,
    from payer: ParticipantID,
    to payee: ParticipantID,
    lamport: UInt64
) -> LedgerEvent {
    LedgerEvent(
        id: UUID(),
        ledgerID: ledger,
        author: payer,
        payload: .settlementRecorded(
            SettlementDetails(
                amount: amount,
                payer: payer,
                payee: payee
            )
        ),
        targetExpenseID: nil,
        lamport: lamport,
        wallClock: .now
    )
}

// MARK: - Convergence

@Suite("Convergence invariant (the falsifiable claim)")
struct ConvergenceTests {

    @Test(
        "Replicas receiving the same events in any order, with duplicates, derive identical state"
    )
    func convergesUnderShuffleAndDuplication() {
        let groceries = added(usd(84, 20), by: sam, lamport: 1)
        let events: [LedgerEvent] = [
            groceries,
            edited(groceries.id, note: "Trader Joe's", by: alex, lamport: 2),
            added(usd(30), by: alex, lamport: 3),
            settled(usd(10), from: alex, to: sam, lamport: 4),
        ]

        let reference = LedgerState(reducing: events)

        for _ in 0..<100 {
            // A hostile transport: shuffled order + a re-delivered duplicate.
            var delivery = events.shuffled()
            delivery.append(events.randomElement()!)  // at-least-once
            #expect(LedgerState(reducing: delivery) == reference)
        }
    }

    @Test(
        "Reducing twice over the union equals reducing once — duplicates are no-ops"
    )
    func idempotence() {
        let e = added(usd(50), by: sam, lamport: 1)
        #expect(LedgerState(reducing: [e, e, e]) == LedgerState(reducing: [e]))
    }

    @Test("Balances are zero-sum per currency")
    func zeroSum() {
        let state = LedgerState(reducing: [
            added(usd(99, 99), by: sam, lamport: 1),
            added(usd(0, 1), by: alex, lamport: 2),
        ])
        for (_, perParticipant) in state.balances {
            #expect(perParticipant.values.reduce(0, +) == 0)
        }
    }
}

// MARK: - Merge rules, by number

@Suite("Merge rules (docs/ARCHITECTURE.md §4)")
struct MergeRuleTests {

    @Test("R1 — concurrent edits to different fields both survive")
    func disjointFieldEditsMerge() {
        let e = added(usd(80), by: sam, lamport: 1)
        // Concurrent (both lamport 2): Sam fixes the amount, Alex adds a note.
        let state = LedgerState(reducing: [
            e,
            edited(e.id, amount: usd(84, 20), by: sam, lamport: 2),
            edited(e.id, note: "with wine", by: alex, lamport: 2),
        ])
        let expense = try! #require(state.expenses[e.id])
        #expect(expense.details.amount == usd(84, 20))  // Sam's edit survived
        #expect(expense.details.note == "with wine")  // Alex's edit survived
    }

    @Test(
        "R2 — concurrent same-field edits: deterministic winner, loser in trail"
    )
    func sameFieldEditsDeterministic() {
        let e = added(usd(80), by: sam, lamport: 1)
        let samEdit = edited(e.id, amount: usd(84, 20), by: sam, lamport: 2)
        let alexEdit = edited(e.id, amount: usd(90), by: alex, lamport: 2)

        let state = LedgerState(reducing: [e, samEdit, alexEdit])
        // Tie at lamport 2 → author tiebreak: "alex" < "sam", so Sam's
        // edit folds LAST and wins the field.
        let expense = try! #require(state.expenses[e.id])
        #expect(expense.details.amount == usd(84, 20))
        #expect(expense.history.count == 3)  // nothing destroyed
        // And the adjudication is order-independent:
        #expect(LedgerState(reducing: [e, alexEdit, samEdit]) == state)
    }

    @Test("R3 — the edit/delete race (ARCHITECTURE §4.2, executable)")
    func editDeleteRace() {
        let e = added(usd(80), by: sam, lamport: 4)
        let samEdit = edited(e.id, amount: usd(84, 20), by: sam, lamport: 5)
        let alexDelete = deleted(e.id, by: alex, lamport: 5)

        let state = LedgerState(reducing: [e, samEdit, alexDelete])

        #expect(state.liveExpenses.isEmpty)  // delete wins
        let expense = try! #require(state.expenses[e.id])
        #expect(expense.isDeleted)  // tombstone
        #expect(expense.history.count == 3)  // edit preserved
        #expect(state.balances.isEmpty)  // E excluded
    }

    @Test("R4 — double delete is one tombstone")
    func deleteIsIdempotent() {
        let e = added(usd(10), by: sam, lamport: 1)
        let state = LedgerState(reducing: [
            e,
            deleted(e.id, by: sam, lamport: 2),
            deleted(e.id, by: alex, lamport: 2),
        ])
        #expect(state.expenses[e.id]?.isDeleted == true)
        #expect(state.liveExpenses.isEmpty)
    }

    @Test("R8 + settlement arithmetic — settling zeroes the balance")
    func settlementZeroesBalance() {
        let dinner = added(usd(100), by: sam, lamport: 1)  // Alex owes Sam $50
        let payUp = settled(usd(50), from: alex, to: sam, lamport: 2)
        let state = LedgerState(reducing: [dinner, payUp])
        #expect(state.balances.isEmpty)  // all square
    }

    @Test(
        "R9 — an edit whose add never arrived pends, and does not corrupt state"
    )
    func orphanEventsPend() {
        let phantom = UUID()  // add not in set
        let state = LedgerState(reducing: [
            added(usd(20), by: sam, lamport: 1),
            edited(phantom, amount: usd(99), by: alex, lamport: 7),
        ])
        #expect(state.pending.count == 1)
        #expect(state.expenses.count == 1)
        #expect(state.balances["USD"]?[alex] == -10_00)  // untouched by orphan
    }
}

// MARK: - Money determinism

@Suite("Deterministic money")
struct MoneyTests {

    @Test("The indivisible penny goes to the same participant on every replica")
    func remainderIsDeterministic() {
        let trio = [
            ParticipantID(rawValue: "zoe"),
            ParticipantID(rawValue: "alex"),
            ParticipantID(rawValue: "sam"),
        ]
        let split = LedgerState.split(100, among: trio)
        // Sorted order: alex, sam, zoe → alex gets the extra penny.
        #expect(split.map(\.1).reduce(0, +) == 100)  // conservation
        #expect(split.first(where: { $0.0.rawValue == "alex" })?.1 == 34)
        #expect(split.first(where: { $0.0.rawValue == "sam" })?.1 == 33)
        #expect(split.first(where: { $0.0.rawValue == "zoe" })?.1 == 33)
    }
}
