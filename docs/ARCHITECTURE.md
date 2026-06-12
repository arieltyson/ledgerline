# Ledgerline — Architecture

Design rationale and the complete merge-rule specification. This document is written *before* the rules are fully implemented (per the plan), so that the implementation answers to the spec — not the other way around.

---

## 1. The Central Decision: Events, Not Rows

Ledgerline never stores a balance and never mutates an expense. Every user action — add, edit, delete, settle — is an **immutable `LedgerEvent`** appended to a log. All visible state is *derived*:

```
LedgerState = reduce(events.sorted(by: totalOrder))
```

**Why.** A shared ledger is a replicated system: the same data lives on every participant's devices plus iCloud, with no coordinator. Replicas *will* receive concurrent writes. A mutable-row design forces a choice of "winner" at write time (last-writer-wins), which silently destroys the loser's action — and in a ledger, a destroyed action **changes who owes whom**. An event log dissolves the problem: concurrent actions both survive as facts; deterministic ordering rules adjudicate their combined effect; every replica, holding the same facts, derives the same state.

This is the core mechanism of event sourcing, replicated logs, and CRDTs, implemented with plain records.

## 2. The Correctness Property

> **Convergence invariant:** after any sequence of concurrent edits on any number of devices, all replicas that have received the same set of events compute **identical** `LedgerState`.

This is *strong eventual consistency* (the CRDT correctness condition). It is falsifiable, and the test suite falsifies it or doesn't: random event sets, delivered to simulated replicas in shuffled orders, with duplicates injected — asserting identical derived state every time.

Three properties of the reducer make the invariant achievable:

1. **Determinism** — no randomness, no clock reads, no iteration-order dependence. Same input set ⇒ same output, always.
2. **Idempotence under duplicates** — events are deduplicated by `id` before folding. Required because delivery is *at least once* (see §6).
3. **Total order** — events are folded in an order every replica agrees on (see §3).

## 3. Time and Ordering

**Wall clocks are display-only.** Device clocks skew, drift, and get changed by users. No ordering, comparison, or adjudication ever reads `wallClock`.

**Lamport clocks are the ordering authority.** Each replica keeps a counter: increment on local action (`tick`), fast-forward past anything received (`observe`). Guarantee: if event A *happened-before* B (B's author had seen A), then `A.lamport < B.lamport`.

**Ties are information.** Equal Lamport stamps mean the events are *concurrent* — neither author knew of the other. Concurrency is exactly what the merge rules (§4) adjudicate. For replicas to adjudicate identically, the order must be total, so ties break deterministically:

```
totalOrder = (lamport, author, eventID)   // strictly increasing tuple
```

The author tiebreak is arbitrary *by design* — what matters is not which concurrent event "wins" a tie, but that **every replica picks the same one**.

## 4. The Merge Rules

The complete adjudication table for concurrent events. "Concurrent" means equal Lamport stamps or, more generally, neither causally preceding the other; causally ordered events simply fold in order and need no rules.

### 4.1 Rule table

| # | Concurrent pair (same target) | Resolution | Rationale |
|---|---|---|---|
| R1 | `expenseEdited` × `expenseEdited`, **different fields** | Both apply (field-level merge) | `ExpenseEdit` carries only changed fields; disjoint edits don't conflict at all. Field granularity exists precisely for this. |
| R2 | `expenseEdited` × `expenseEdited`, **same field** | Later in `totalOrder` wins the field; both visible in audit trail | A genuine conflict needs a deterministic winner; the loser is preserved as history, not destroyed. |
| R3 | `expenseEdited` × `expenseDeleted` | **Delete wins** live state; edit preserved in audit trail | Deletion is the stronger statement of intent. The edit is not lost — the trail shows "edited, then removed." |
| R4 | `expenseDeleted` × `expenseDeleted` | Idempotent — one tombstone | Deleting twice is deleting once. |
| R5 | `expenseAdded` × `expenseAdded` (distinct ids, similar content) | Both stand; **Duplicate Sentinel** flags near-duplicates (same amount+category, close wall time) for one-tap user merge | The engine cannot know whether two identical-looking expenses are one purchase logged twice or two real purchases. Ambiguity goes to the user, never to silent deletion. The user's merge is itself an event (`expenseDeleted` on one). |
| R6 | `settlementRecorded` × concurrent `expenseAdded` | Expense falls **outside** the settlement; remains owed | A settlement covers only expenses its author had *seen* (causally prior). A concurrent expense was invisible to the settler — covering it would settle money the settler never agreed to. |
| R7 | `settlementRecorded` × `expenseEdited` (expense inside the settlement) | Settlement records the **amount actually transferred**; the edit adjusts the *expense*, and the balance reflects the difference | Settlements are facts about money that moved, not formulas. Editing a settled expense re-opens the delta, visibly. |
| R8 | `settlementRecorded` × `settlementRecorded` (same pair, both directions or same direction) | Both stand; balances are arithmetic over all of them | Settlements are payments. Two payments are two payments. |
| R9 | Any event targeting an expense whose `expenseAdded` is missing locally | Held in a pending set until the add arrives; excluded from derived state | Causal dependency: an edit cannot be interpreted without its target. At-least-once delivery makes out-of-order arrival routine, not exceptional. |

### 4.2 Worked example — the classic edit/delete race

1. Sam and Alex both have expense **E** ($80 Groceries, lamport 4) and are both offline.
2. Sam edits E's amount to $84.20 → `expenseEdited`, lamport 5, author `sam`.
3. Alex deletes E → `expenseDeleted`, lamport 5, author `alex`.
4. Both reconnect; both replicas now hold all events.
5. Total order: the two lamport-5 events tie → author tiebreak (`alex` < `sam`) orders delete before edit. **The order doesn't matter to the outcome** — R3 applies to the concurrent pair regardless: E is not in live state; the audit trail on E's history shows both Sam's edit and Alex's deletion, attributed and timestamped.
6. Both devices derive identical balances excluding E. Nothing was silently lost; the disagreement is *visible* and reversible (either user can re-add from history).

A row-based LWW design resolves this same race by coin flip: whichever write lands second erases the other, and one user's action vanishes without trace.

### 4.3 Worked example — settlement vs. concurrent expense

1. Balance: Alex owes Sam $50. Sam (online) records `settlementRecorded` ($50, alex→sam), lamport 9.
2. Alex (offline, hasn't seen it) adds a $30 expense paid by Sam, lamport 9 — concurrent.
3. After sync: R6 — the $30 expense is outside the settlement (Sam's settlement could only cover what Sam had seen). Derived balance: Alex owes Sam $15 (their half of the new expense). The settlement history shows $50 settled; the ledger shows the new expense arrived "after" it causally.
4. Both replicas compute $15. No money vanished, none was double-counted.

## 5. Tombstones and the Audit Trail

Deletion writes a tombstone event; nothing is ever erased. Consequences, all intentional:

- "Who deleted the dinner?" always has an answer.
- Undo is trivial (deletion of facts is impossible, so reversal is just another event).
- The log grows monotonically — bounded by §8's compaction.

## 6. Delivery Semantics

The transport (CloudKit silent push + token fetch) provides **at-least-once** delivery: pushes coalesce, delay, or drop; fetches retry after crashes; the same event can arrive twice. The design treats this as normal:

- Duplicates: deduplicated by event `id` at the store boundary; the reducer is idempotent regardless.
- Gaps/reordering: §4.1 R9 pends causally-dependent events; a reconciliation fetch runs on every app foreground — push is an accelerant, never the mechanism of record.
- **Cursor atomicity:** the `CKServerChangeToken` is persisted in the *same transaction* as the events it covers, and only after them. Of the two possible crash outcomes — re-fetching events we already have (harmless: idempotence) vs. advancing past events we never stored (permanent loss) — the design makes only the harmless one reachable.

## 7. The Dual-Layer Sync Split

| Data | Layer | Why |
|---|---|---|
| User's own data (preferences, personal categories, device state) | **SwiftData ↔ CloudKit automatic mirroring** → private database | Single-writer-per-account data with no cross-user concurrency; the automatic layer is the right tool and demonstrates knowing when *not* to hand-roll. |
| The shared ledger (event records, ledger metadata) | **Raw CloudKit** — custom `CKRecordZone` + `CKShare`, `CKDatabaseSubscription`, manual token fetches | Sharing and ordering control sit below what the mirror exposes; the event-record design requires owning the write path. |

Event records are **write-once**, which makes CloudKit's `serverRecordChanged` conflict rare by construction — conflict resolution hasn't been avoided, it has been *relocated* into the reducer where it is deterministic and testable. The one mutable record (ledger metadata: name, emoji) keeps a conventional three-way merge handler (client/server/ancestor), and the asymmetry is deliberate: mutable data gets record-level merging, factual data gets log-level merging.

## 8. Compaction

Reducing from genesis on every change is O(history). The store snapshots derived state at a Lamport watermark and folds only newer events — log compaction, with one rule: **a snapshot may only cover prefixes that are causally complete** (no pending events below the watermark). Snapshots are replica-local cache, never synced; the log remains the single source of truth.

## 9. What This Architecture Refuses To Do

- **No stored balances.** A stored balance is a cache that can disagree with its source; a derived balance cannot.
- **No wall-clock adjudication.** Ever.
- **No silent conflict resolution that discards a user action.** Every adjudication either merges (R1), preserves the loser visibly (R2, R3), or asks the user (R5).
- **No exactly-once assumptions.** The system is correct under duplication and reordering, or it is not correct.
- **No third-party backend.** Identity, storage, transport, and access control all ride the participants' own iCloud — the constraint that makes the project meaningful.
