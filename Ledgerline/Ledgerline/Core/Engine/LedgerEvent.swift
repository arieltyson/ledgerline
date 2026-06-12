//
//  LedgerEvent.swift
//  Ledgerline — Core/Engine
//
//  The atomic unit of the entire system. Every user action becomes one
//  immutable LedgerEvent. Nothing in the engine ever mutates state;
//  state is *derived* by reducing an ordered set of these events.
//
//  This file has ZERO dependencies on SwiftData, CloudKit, or UI.
//  That is a load-bearing architectural decision, not tidiness.
//

import Foundation

// MARK: - Identity

/// A stable identity for one participant in a ledger.
/// In Phase 4 this will carry the CloudKit user record name; the engine
/// only requires that it is stable and totally ordered (for tiebreaks).
struct ParticipantID: RawRepresentable, Codable, Sendable, Hashable, Comparable
{
    let rawValue: String

    static func < (lhs: ParticipantID, rhs: ParticipantID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Money

/// Money is stored as integer minor units (cents), never floating point.
/// 0.1 + 0.2 != 0.3 in Double — a ledger whose balances drift by
/// floating-point error fails its own convergence invariant.
struct Money: Codable, Sendable, Hashable {
    /// Amount in minor units (e.g. cents). $84.20 == 8420.
    var minorUnits: Int64
    /// ISO 4217 code, e.g. "USD". Kept per-amount so multi-currency
    /// ledgers remain representable later without a schema break.
    var currencyCode: String
}

// MARK: - Event payloads

/// Everything needed to describe a newly added expense.
struct ExpenseDetails: Codable, Sendable, Hashable {
    var amount: Money
    var category: String
    var note: String
    /// Who paid, and who owes shares. Equal split between participants
    /// is the MVP; the structure leaves room for weighted splits.
    var paidBy: ParticipantID
    var participants: [ParticipantID]
}

/// A partial edit. Only non-nil fields are changed — this matters for
/// merging: two concurrent edits to *different* fields should both
/// survive, which a whole-object overwrite would make impossible.
struct ExpenseEdit: Codable, Sendable, Hashable {
    var amount: Money?
    var category: String?
    var note: String?
}

/// A settlement: `payer` paid `payee` some amount to square up.
struct SettlementDetails: Codable, Sendable, Hashable {
    var amount: Money
    var payer: ParticipantID
    var payee: ParticipantID
}

/// The action itself. Modeling this as an enum with associated values
/// makes illegal states unrepresentable: an "edit" cannot exist without
/// edit details, a "delete" carries nothing but its target.
enum EventPayload: Codable, Sendable, Hashable {
    case expenseAdded(ExpenseDetails)
    case expenseEdited(ExpenseEdit)
    case expenseDeleted
    case settlementRecorded(SettlementDetails)
}

// MARK: - The event

/// One immutable fact: "this participant did this action at this point
/// in causal history." Events are never edited and never deleted —
/// corrections are *new events*.
struct LedgerEvent: Codable, Sendable, Hashable, Identifiable {
    /// Globally unique. Also the deduplication key: at-least-once
    /// delivery (CloudKit push + fetch) WILL hand us duplicates,
    /// and `id` is how a duplicate is recognized as a no-op.
    let id: UUID

    /// Which ledger this event belongs to.
    let ledgerID: UUID

    /// Who performed the action.
    let author: ParticipantID

    /// What happened.
    let payload: EventPayload

    /// For payloads that act on an existing expense (edit, delete),
    /// the id of the expenseAdded event being acted upon.
    let targetExpenseID: UUID?

    /// Lamport logical clock — the ONLY ordering authority.
    let lamport: UInt64

    /// Human-readable timestamp. Display only. Never compared,
    /// never used for ordering, never trusted across devices.
    let wallClock: Date
}

// MARK: - Total order

extension LedgerEvent {
    /// Deterministic total order across ALL replicas.
    ///
    /// Primary:  lamport   — causal order (if A happened-before B,
    ///                        A.lamport < B.lamport is guaranteed).
    /// Tiebreak: author    — concurrent events (equal lamport) need an
    ///                        arbitrary but *agreed-upon* order so every
    ///                        replica folds them identically.
    /// Final:    id        — same author, same lamport (shouldn't occur,
    ///                        but the order must be total, so close it).
    static func totalOrder(_ a: LedgerEvent, _ b: LedgerEvent) -> Bool {
        if a.lamport != b.lamport { return a.lamport < b.lamport }
        if a.author != b.author { return a.author < b.author }
        return a.id.uuidString < b.id.uuidString
    }
}
