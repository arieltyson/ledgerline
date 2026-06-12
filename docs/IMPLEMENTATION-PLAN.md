# Ledgerline — Implementation Plan

Step-by-step implementation plan, structured the way a staff engineer on a persistence/sync team would run it: modularity, protocol-oriented design, testability, strict modern Swift (Swift 6 concurrency) — and, because this project exists to demonstrate sync mastery, an explicit explanation of the **distributed systems concept** each phase exercises.

The roadmap prioritizes an **append-only event ledger as the architectural spine**, building outward from a pure, fully-tested convergence engine to local persistence, then private sync, then multi-user shared sync, then polish. Every phase produces a working, testable increment.

> **The architectural bet, stated up front:** balances are never stored — they are *derived* by reducing an ordered log of immutable events. Every hard problem in this app (conflicts, offline edits, multi-device agreement) becomes tractable because of this one decision. This is the same bet behind event sourcing, replicated logs, and CRDTs.

---

## Phase 0: CloudKit & Project Setup (The "Paperwork")

**Goal:** Get the Apple-side infrastructure configured before writing domain code, because container provisioning and a second test account have lead time.

**Commit 0.1: Project Initialization**
- Xcode project, SwiftUI App lifecycle.
- Folder structure: `App/`, `Features/` (Ledger, Expenses, Balances, History, Sharing), `Core/` (Engine, Persistence, Sync, DesignSystem), `Tests/`, `docs/`.
- Swift 6 strict concurrency mode. Minimum deployment target iOS 17.
- `.gitignore`, repository initialization.

**Commit 0.2: iCloud Capability & Container**
- Signing & Capabilities → **iCloud** → **CloudKit** → container `iCloud.com.<you>.ledgerline`.
- **Background Modes** → **Remote notifications** (CloudKit silent pushes arrive this way).
- Confirm the container in the CloudKit Console.

**Commit 0.3: The Second Identity**
- A second Apple ID signed into a second device.
- *Why now:* shared-database development requires two iCloud identities, and simulator CloudKit support is partial (no push delivery). Discover this in Phase 0, not Phase 5.

**Commit 0.4: Schema Discipline Document**
- Create `SCHEMA.md`. Every CloudKit record type and field gets written here *first*.
- **DS concept — schema evolution in a replicated system:** once promoted to production, CloudKit fields cannot be deleted; old clients in the wild may still read them. In any system with replicas you don't control, the schema is a *contract across time*. Design additively from day one.

---

## Phase 1: The Convergence Engine (The "Spine")

**Goal:** The entire event-sourcing core as pure Swift — zero dependencies on SwiftData, CloudKit, or UI — tested exhaustively. If this layer is correct, everything above it is plumbing.

**Commit 1.1: The Event Domain Model**
- `LedgerEvent` (immutable, `Sendable`, Lamport-stamped), `EventPayload` enum (illegal states unrepresentable), `Money` as integer minor units, `ParticipantID`, `LamportClock`, and the deterministic `totalOrder`.
- **DS concept — two clocks:** wall clocks skew and lie; a **Lamport clock** (increment on local action, fast-forward on receipt) guarantees that causally-ordered events have ordered stamps. Concurrent events may tie — and the tie is *information*: neither party knew of the other. Ties are broken deterministically (author, then id) so every replica agrees.

**Commit 1.2: The Reducer (Derived State)**
- `LedgerState` (live expenses + computed balances) and the pure function `reduce(_ events: [LedgerEvent]) -> LedgerState`, folding events in total order after dedup by `id`.
- **DS concept — determinism and idempotence:** convergence means *replicas holding the same event set compute identical state*. The reducer must be deterministic (no randomness, no clock reads) and idempotent under duplicates, because at-least-once delivery *will* hand you the same event twice. This pair of properties is state-machine replication in miniature.

**Commit 1.3: The Merge Rules (Conflict Semantics)**
- The adjudication rules for concurrent events, implemented in the reducer and documented in `ARCHITECTURE.md` (rules are written down *before* they are implemented).
- **DS concept — last-writer-wins is data loss:** LWW on a mutable row silently destroys one user's concurrent action — in a ledger, that changes who owes whom. Immutable events make conflicts an *ordering question* (both survive; rules adjudicate) instead of an *overwrite question* (one is destroyed). This is the CRDT insight applied with plain records.

**Commit 1.4: The Invariant Test Suite (The Crown Jewel)**
- Property-style tests: random event sets delivered to N simulated replicas in different orders, with duplicates, with partitions — assert all replicas reduce to **identical state**.
- **DS concept — convergence as a falsifiable property:** strong eventual consistency (the CRDT correctness condition) states: replicas that have received the same updates are in the same state. A pure reducer over a set makes this *testable* with no servers and no network.

---

## Phase 2: Local Persistence (The "Ground Floor")

**Goal:** A fully functional, single-user, offline expense tracker backed by SwiftData — a complete app before any cloud code exists.

**Commit 2.1: SwiftData Models**
- `@Model` classes: `Ledger`, `StoredEvent`, `SyncCursor` (modeled now; used by sync later). Map between pure `LedgerEvent` values and `StoredEvent` models at the persistence boundary — the engine never imports SwiftData.

**Commit 2.2: The Local Event Store**
- An `EventStore` actor: `append`, `events(for:)`, deduplication by event ID at the insert boundary; owns and atomically advances the device's Lamport counter.
- **DS concept — the replica's identity:** each install is a *replica* with its own clock and partial view of the log. "One replica among peers," not "the data."

**Commit 2.3: The Solo UI**
- `LedgerView` with `@Query`; balances and expense list rendered from `reduce(events)`; entry form; audit-trail detail view.

**Commit 2.4: Inspect the SQLite (The Depth Move)**
- Open the store's `.sqlite` file; read the generated tables, `Z`-prefixed Core Data naming, keys and relationships. Document in `INTERNALS.md`.

---

## Phase 3: Private Sync — One User, Many Devices (The "Mirror")

**Goal:** The same user's ledger syncs across their devices via SwiftData's built-in CloudKit mirroring — the automatic layer, used deliberately and studied.

**Commit 3.1: Enable Mirroring**
- Point the SwiftData container at the CloudKit container's **private database**. Resolve the model constraints mirroring imposes (no unique constraints; optionality/defaults) and record each in `INTERNALS.md` — constraints that exist *because* of replication (local uniqueness can't be enforced when another replica may insert concurrently).

**Commit 3.2: Observe the Machinery**
- In the CloudKit Console: the `CD_`-prefixed record types, the single custom zone, token bookkeeping.
- **DS concept — log-based replication:** the mirror exports local transactions and imports remote ones, tracked by **change tokens** — cursors meaning "everything up to here" in the server's change log. Phase 4 implements this by hand; watch the automatic version first.

**Commit 3.3: Two-Device Verification**
- Same Apple ID, two devices: converge; then airplane-mode one, edit on both, reconnect, verify the event log absorbs it without loss.
- **DS concept — eventual consistency, felt:** propagation takes seconds. The UI must be **optimistic** (local writes instant; remote changes reconcile on arrival). CloudKit chooses availability over consistency under partition — the CAP tradeoff, and the entire point of local-first.

---

## Phase 4: The Shared Ledger — Many Users (The "Hard Part")

**Goal:** Two different iCloud users on one ledger. The mirror's sharing support is limited, so this layer is hand-driven raw CloudKit.

**Commit 4.1: The Sync Protocol (Interface First)**
```swift
protocol LedgerSyncService: Sendable {
    func createSharedLedger(_ ledger: Ledger) async throws -> ShareInvitation
    func acceptInvitation(_ metadata: ShareMetadata) async throws
    func push(_ events: [LedgerEvent]) async throws
    func pullChanges() async throws -> [LedgerEvent]   // token-driven delta
}
```
- Note the absence of "update expense" / "set balance": the protocol moves immutable events only. The API shape enforces the architecture.

**Commit 4.2: Zone + Share**
- Custom `CKRecordZone` per ledger in the owner's private database; root record wrapped in a `CKShare`; invite flow and acceptance (zone appears in the participant's **shared database**).
- **DS concept — identity without an auth server:** CloudKit provides stable user IDs and zone-level access enforcement. Authentication, authorization, and tenant isolation with zero account code.

**Commit 4.3: Push — Writing Events**
- Each local event uploads as an immutable `CKRecord`; batch with `CKModifyRecordsOperation`; mark `serverAcknowledged` on success (drives the UI's "pending" badge).
- **DS concept — immutability defuses write conflicts:** write-once records make `serverRecordChanged` rare *by construction*. Conflict resolution hasn't been dodged — it moved into the reducer, where it is deterministic and testable. Implement the three-way merge handler for the one mutable record kept (ledger metadata) and document the asymmetry.

**Commit 4.4: Pull — Subscriptions, Push, and Tokens**
- `CKDatabaseSubscription` on the shared database; silent push (`content-available`) → fetch zone changes with the stored `CKServerChangeToken` → insert via the deduplicating store → fast-forward the Lamport clock past the max incoming value → persist the token.
- **DS concept — at-least-once delivery:** pushes coalesce, delay, drop; fetches retry after crashes. The real guarantee is *at least once*, never *exactly once* — hence the idempotent reducer and dedup. Also reconcile on every foreground; never depend on push alone.

**Commit 4.5: The Partition Drill**
- Scripted two-device test: airplane-mode B → both add/edit (same expense included) → reconnect → assert identical balances and a complete audit trail. Add the **Duplicate Sentinel** (near-duplicate concurrent entries → one-tap merge).

---

## Phase 5: User Interface & Experience (The "Trust")

**Commit 5.1: Design System** — palette, rounded type scale, `BalanceCard`, `ExpenseRow`, `PendingBadge`, `ParticipantAvatar`; light/dark from day one.
**Commit 5.2: The Dashboard** — derived "who owes whom" front and center; recent expenses; participant presence derived from latest-seen events.
**Commit 5.3: Sync-State Honesty** — pending glyphs, quiet reconnect indicator, merge prompts as friendly questions. Local-first apps earn trust by making state visible.
**Commit 5.4: Audit Trail & History** — per-expense event timeline; settlements; Charts monthly view — all derived from the log.
**Commit 5.5: Settle-Up Flow** — settlement events referencing covered expenses; concurrent expenses clearly shown as outside the settlement.

---

## Phase 6: Hardening & Edge Cases (The "Staff" Touch)

**Commit 6.1: Crash-Safety of the Sync Pipeline**
- Persist the change token *only after* events are durably stored (one transaction). Kill the app mid-fetch and verify.
- **DS concept — atomic cursor advancement:** token-before-data loses events forever; data-before-token merely re-fetches (harmless — idempotence again). Always choose the failure mode that duplicates over the one that loses. This is consumer-offset management in every log system.

**Commit 6.2: Account-State Edge Cases** — iCloud sign-out mid-session; account switching; share revocation (local copy → read-only "archived"); `CKError.quotaExceeded`.

**Commit 6.3: Schema Evolution Rehearsal** — add a new field end-to-end with old clients still working; document the additive-only workflow in `SCHEMA.md`.

**Commit 6.4: Performance Pass** — snapshot reduced state at a Lamport watermark; fold only newer events (log compaction). Measure with Instruments; record numbers in `INTERNALS.md`.

---

## Phase 7: Documentation & Proof (The "Artifact")

**Commit 7.1: `ARCHITECTURE.md`** — event-ledger design, two-clock rationale, merge rules with worked examples, why LWW corrupts a ledger, the convergence invariant, the dual-layer sync split.
**Commit 7.2: DocC + README** — `///` docs on the engine's public surface; README with a partition-drill GIF.
**Commit 7.3: Real-World Proof** — multi-week TestFlight soak with a real second person; log every sync anomaly and how the design absorbed it.

---

## Timeline Summary

| Phase | Description | Estimated Time | Key Dependency |
|---|---|---|---|
| 0 | CloudKit & project setup | 1–2 days | Second Apple ID, container |
| 1 | Convergence engine + invariant tests | 4–6 days | None |
| 2 | Local persistence (SwiftData) | 3–4 days | Phase 1 |
| 3 | Private sync (mirroring) | 3–4 days | Phases 0, 2 |
| 4 | Shared ledger (raw CloudKit) | 6–8 days | Phases 0, 1, 3 |
| 5 | UI & experience | 4–6 days | Phase 4 |
| 6 | Hardening & edge cases | 3–4 days | Phase 4 |
| 7 | Documentation & proof | 2–3 days + soak | All |
| | **Total** | **~26–37 days** | |

## Parallel Work Opportunities

- Phase 1 needs no Apple infrastructure — build the engine while the container and second account are set up.
- Phase 5 UI can begin against the Phase 2 local store with mock multi-user data; real sync slots underneath unchanged (the Commit 4.1 protocol boundary guarantees it).
- Start `ARCHITECTURE.md` during Phase 1 — merge rules are written down *before* they're implemented.
- Begin the TestFlight soak as soon as Phase 4 lands; real usage accumulates while Phases 5–6 are built.

## The Concept Index (What Each Phase Proves)

| Distributed systems concept | Where it lives |
|---|---|
| Lamport logical clocks vs. wall clocks | 1.1 — ordering authority |
| Deterministic, idempotent state replication | 1.2 — the reducer |
| Conflict semantics; LWW data loss; CRDT-style merge | 1.3 — merge rules |
| Strong eventual consistency as a testable property | 1.4 — invariant suite |
| Replicas; schema as a cross-time contract | 0.4, 2.2, 6.3 |
| Log-based replication & change cursors | 3.2, 4.4 — change tokens |
| CAP; availability under partition; optimistic UI | 3.3, 5.3 |
| At-least-once delivery & deduplication | 4.4 |
| Three-way merge (client/server/ancestor) | 4.3 |
| Atomic cursor management; loss vs. duplication | 6.1 |
| Log compaction / snapshotting | 6.4 |

Built inside-out — engine first, transport last. The pure engine at the core means the transport could be swapped, the UI replaced, or the ledger extended to N participants without touching the part that makes the system correct.
