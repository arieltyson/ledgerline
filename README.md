# Ledgerline

**A local-first shared expense ledger for iOS — built entirely on SwiftData + CloudKit, with no third-party backend.**

Two (or more) people share a ledger. Both can add, edit, delete, and settle expenses — simultaneously, offline, on any of their devices — and every replica provably converges to **identical balances**. No server. No accounts. No last-writer-wins data loss.

> **Why this project exists:** most apps treat sync as a feature bolted onto a database. Ledgerline treats it as the core engineering problem — because in a ledger, a botched merge doesn't lose a sentence, it *changes who owes whom*. The interesting code here is the convergence engine, not the UI.

---

## The Core Idea: Events, Not Rows

Ledgerline never stores a balance and never mutates an expense row. Every user action — add, edit, delete, settle — is an **immutable event** appended to a shared log. State is *derived* by deterministically reducing that log:

```
balances = reduce(events.sorted(by: lamportClock))
```

This one decision makes every hard problem tractable:

| Problem | Row-based answer | Ledgerline's answer |
|---|---|---|
| Two users edit the same expense offline | Last writer wins — one edit silently destroyed | Both events survive; ordering rules adjudicate; audit trail shows both |
| Edit races a delete | Undefined / data loss | Delete wins live state; edit preserved in history (tombstone pattern) |
| Settlement races a new expense | Money vanishes or double-counts | Causal ordering decides cleanly: concurrent expense falls outside the settlement |
| Same event delivered twice (at-least-once push) | Duplicate row | Idempotent reducer + dedup by event ID — a no-op |
| Device clocks skew | Wrong "winner" chosen by wall clock | Lamport logical clocks are the only ordering authority; wall time is display-only |

## The Falsifiable Claim

> **After any sequence of concurrent edits on any number of devices, all replicas that have received the same event set compute byte-identical state.**

This is strong eventual consistency (the CRDT correctness condition), and because the reducer is a pure function, it's *testable*: the suite generates random event sets, delivers them to simulated replicas in different orders — with duplicates, with partitions — and asserts identical derived state on every replica. See [`Tests/ConvergenceTests`](Tests/).

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  SwiftUI  (@Query-driven views, optimistic UI,          │
│            sync-state honesty: pending badges, merges)  │
├─────────────────────────────────────────────────────────┤
│  Convergence Engine  (pure Swift, zero dependencies)    │
│  • LedgerEvent (immutable, Lamport-stamped)             │
│  • reduce(events) -> LedgerState  (deterministic,       │
│    idempotent)                                          │
│  • Merge rules: edit/edit, edit/delete,                 │
│    settlement/concurrent-expense                        │
├─────────────────────────────────────────────────────────┤
│  Persistence  (SwiftData → SQLite)                      │
│  • Append-only event store, dedup at insert boundary    │
│  • Device Lamport clock, atomically advanced            │
├──────────────────────────┬──────────────────────────────┤
│  Private sync            │  Shared sync                 │
│  SwiftData + CloudKit    │  Raw CloudKit:               │
│  mirroring (automatic)   │  custom CKRecordZone,        │
│  → user's private DB     │  CKShare, CKDatabase-        │
│                          │  Subscription, silent push,  │
│                          │  CKServerChangeToken deltas  │
└──────────────────────────┴──────────────────────────────┘
                 No third-party backend.
        All data lives in the participants' iCloud.
```

**The deliberate dual-layer design:** each user's *private* data rides the automatic SwiftData↔CloudKit mirror; the *shared* ledger is hand-driven raw CloudKit (zones, shares, subscriptions, change tokens), because sharing and ordering control sit below what the mirror exposes. Knowing which layer to use where is half the point.

## Distributed Systems Concepts, Implemented

Each concept below is load-bearing in this codebase — not decorative:

- **Lamport logical clocks** — event ordering authority; ties between concurrent events are detected, not papered over
- **Deterministic, idempotent reduction** — state-machine replication in miniature; same event set ⇒ same state, duplicates are no-ops
- **CRDT-style merge semantics** — conflicts become ordering questions (both survive) instead of overwrite questions (one is destroyed)
- **Log-based replication with change cursors** — `CKServerChangeToken` delta fetches; the token advances atomically *after* events are durably stored (the failure mode duplicates, never loses)
- **At-least-once delivery handling** — silent pushes are coalesced/dropped by design; reconciliation sweep on every foreground
- **Availability under partition (CAP)** — fully functional offline; optimistic local writes; convergence on reconnect
- **Tombstones & audit trails** — deletion is an event, never an erasure
- **Log compaction** — reduced-state snapshots at a Lamport watermark keep cold-start cost bounded
- **Schema as a cross-time contract** — additive-only CloudKit schema evolution, rehearsed end-to-end

## Status & Roadmap

Built inside-out — engine first, transport last. Each phase is a working increment:

- [ ] **Phase 0** — CloudKit container, capabilities, second test identity
- [ ] **Phase 1** — Convergence engine + invariant test suite *(pure Swift, no dependencies)*
- [ ] **Phase 2** — Local persistence (SwiftData) + solo app
- [ ] **Phase 3** — Private sync via CloudKit mirroring (one user, many devices)
- [ ] **Phase 4** — Shared ledger via raw CloudKit (`CKShare`, zones, subscriptions, token deltas)
- [ ] **Phase 5** — UI/UX: sync-state honesty, audit trail, settle-up, Duplicate Sentinel
- [ ] **Phase 6** — Hardening: crash-safe cursor advancement, account edge cases, compaction
- [ ] **Phase 7** — Docs + multi-week real-user TestFlight soak

Full plan with per-commit breakdown: [`docs/IMPLEMENTATION-PLAN.md`](docs/)
Design rationale and merge rules: [`docs/ARCHITECTURE.md`](docs/)

## Requirements

- iOS 17+, Xcode 16+, Swift 6 (strict concurrency)
- Two iCloud accounts and ideally two physical devices for shared-sync development (simulator CloudKit support is partial — no push delivery)
- An Apple Developer account with a CloudKit container (`iCloud.com.<you>.ledgerline`)

## Reading That Shaped the Design

- Kleppmann, *Designing Data-Intensive Applications* — replication, consistency models, conflict resolution
- Kleppmann et al., *Local-first software* (Ink & Switch, 2019) — the seven ideals this app is built against
- Shapiro et al., *Conflict-free Replicated Data Types* (2011) — the convergence condition the test suite asserts
- Apple, WWDC19 §202 *Using Core Data with CloudKit*; WWDC21 sharing sessions; SwiftData sessions (2023–)

## License

MIT
