//
//  LedgerState.swift
//  Ledgerline
//
//  Created by Ariel Tyson on 4/7/26.
//
//  Derived state and the reducer. The single most important property of
//  this file: `LedgerState(reducing:)` is a PURE function of an event
//  set. No clock reads, no randomness, no I/O, no iteration-order
//  dependence. Replicas holding the same events derive identical state —
//  that is the convergence invariant, and it lives or dies here.
//
//  Merge rules implemented: R1–R4, R8, R9 (see docs/ARCHITECTURE.md §4).
//  R5 (Duplicate Sentinel) is a presentation-layer concern over this
//  state; R6/R7 fall out of the arithmetic (see balance notes below).
//

import Foundation

// MARK: - Derived snapshots

/// The current, fully-merged view of one expense — an interpretation
/// of events, never a stored object. `id` is the id of the
/// `expenseAdded` event that created it.
struct ExpenseSnapshot: Identifiable, Sendable, Hashable {
    let id: UUID
    private(set) var details: ExpenseDetails
    private(set) var isDeleted: Bool  // tombstone (R3, R4)
    private(set) var history: [LedgerEvent]  // full audit trail, in order

    fileprivate init(added: LedgerEvent, details: ExpenseDetails) {
        self.id = added.id
        self.details = details
        self.isDeleted = false
        self.history = [added]
    }

    /// R1/R2 — field-level merge. Only non-nil fields apply, so
    /// concurrent edits to different fields both survive (R1), and the
    /// fold order (totalOrder) makes the later same-field edit win
    /// deterministically (R2). Either way the event joins the trail.
    fileprivate mutating func apply(edit: ExpenseEdit, from event: LedgerEvent)
    {
        if let amount = edit.amount { details.amount = amount }
        if let category = edit.category { details.category = category }
        if let note = edit.note { details.note = note }
        history.append(event)
    }

    /// R3/R4 — delete wins live state; idempotent; nothing erased.
    fileprivate mutating func apply(deletion event: LedgerEvent) {
        isDeleted = true
        history.append(event)
    }
}

// MARK: - Ledger state

/// Everything derivable from an event set. Hashable so tests can assert
/// replica states are *identical*, not merely similar.
struct LedgerState: Sendable, Hashable {

    /// Every expense ever added (tombstones included — the audit trail
    /// is part of the state). Keyed by the creating event's id.
    private(set) var expenses: [UUID: ExpenseSnapshot] = [:]

    /// All settlements, in total order. R8: settlements are payments;
    /// two payments are two payments — never coalesced.
    private(set) var settlements: [LedgerEvent] = []

    /// R9 — events whose target `expenseAdded` is absent from the set.
    /// Causality note: an editor must have SEEN the add (you cannot edit
    /// what you don't have), so add.lamport < edit.lamport is guaranteed
    /// and in-set targets always resolve during an ordered fold. Pending
    /// therefore only holds events whose add hasn't ARRIVED at all —
    /// routine under at-least-once, out-of-order delivery.
    private(set) var pending: [LedgerEvent] = []

    /// Live (non-tombstoned) expenses in deterministic display order.
    var liveExpenses: [ExpenseSnapshot] {
        expenses.values
            .filter { !$0.isDeleted }
            .sorted { LedgerEvent.totalOrder($0.history[0], $1.history[0]) }
    }

    /// Net position per participant, per ISO currency code, in minor
    /// units. Positive ⇒ is owed; negative ⇒ owes. Zero-sum per currency.
    ///
    /// R6/R7 note: balance arithmetic is COMMUTATIVE — every live
    /// expense and every settlement contributes a signed amount, so a
    /// settlement and a concurrent expense cannot corrupt each other;
    /// the concurrent expense simply remains in the net (R6), and an
    /// edit to a settled expense re-opens exactly the delta (R7).
    /// "Which expenses a settlement covered" is presentation, not math.
    private(set) var balances: [String: [ParticipantID: Int64]] = [:]

    // MARK: Reduction

    /// THE reducer. Deterministic and idempotent:
    ///  1. dedup by event id (at-least-once delivery WILL repeat events)
    ///  2. sort into the agreed total order
    ///  3. fold
    init(reducing events: some Collection<LedgerEvent>) {
        var seen = Set<UUID>()
        let ordered =
            events
            .filter { seen.insert($0.id).inserted }  // (1) idempotence
            .sorted(by: LedgerEvent.totalOrder)  // (2) agreed order

        for event in ordered {  // (3) fold
            switch event.payload {

            case .expenseAdded(let details):
                expenses[event.id] = ExpenseSnapshot(
                    added: event,
                    details: details
                )

            case .expenseEdited(let edit):
                guard let target = event.targetExpenseID,
                    expenses[target] != nil
                else {
                    pending.append(event)
                    continue
                }
                expenses[target]?.apply(edit: edit, from: event)

            case .expenseDeleted:
                guard let target = event.targetExpenseID,
                    expenses[target] != nil
                else {
                    pending.append(event)
                    continue
                }
                expenses[target]?.apply(deletion: event)

            case .settlementRecorded:
                settlements.append(event)
            }
        }

        recomputeBalances()
    }

    // MARK: Balances

    private mutating func recomputeBalances() {
        balances = [:]

        for expense in expenses.values where !expense.isDeleted {
            let d = expense.details
            add(d.amount.minorUnits, to: d.paidBy, in: d.amount.currencyCode)
            for (participant, share) in Self.split(
                d.amount.minorUnits,
                among: d.participants
            ) {
                add(-share, to: participant, in: d.amount.currencyCode)
            }
        }

        for event in settlements {
            guard case .settlementRecorded(let s) = event.payload else {
                continue
            }
            add(s.amount.minorUnits, to: s.payer, in: s.amount.currencyCode)
            add(-s.amount.minorUnits, to: s.payee, in: s.amount.currencyCode)
        }

        // Drop zeroed entries so settled-up states compare identical.
        for currency in Array(balances.keys) {
            let nonZero = balances[currency]?.filter { $0.value != 0 }
            balances[currency] = nonZero?.isEmpty == true ? nil : nonZero
        }
    }

    private mutating func add(
        _ delta: Int64,
        to participant: ParticipantID,
        in currency: String
    ) {
        balances[currency, default: [:]][participant, default: 0] += delta
    }

    /// Equal split with DETERMINISTIC remainder allocation. 100¢ among
    /// three people is 34/33/33 — and every replica must hand the extra
    /// penny to the SAME person, or the convergence invariant fails on
    /// a one-cent disagreement. Remainder pennies go to the first
    /// participants in sorted (ParticipantID) order.
    static func split(
        _ minorUnits: Int64,
        among participants: [ParticipantID]
    ) -> [(ParticipantID, Int64)] {
        guard !participants.isEmpty else { return [] }
        let count = Int64(participants.count)
        let base = minorUnits / count
        let remainder = abs(Int(minorUnits % count))
        let sign: Int64 = minorUnits < 0 ? -1 : 1

        return participants.sorted().enumerated().map { index, participant in
            (participant, base + (index < remainder ? sign : 0))
        }
    }
}
