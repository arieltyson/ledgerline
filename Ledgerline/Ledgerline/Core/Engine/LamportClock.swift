//
//  LamportClock.swift
//  Ledgerline — Core/Engine
//
//  A Lamport logical clock: the device's position in causal history.
//  Two rules, total. (Lamport, "Time, Clocks, and the Ordering of
//  Events in a Distributed System", 1978 — the most-cited paper in
//  distributed computing, and it fits in a struct.)
//

import Foundation

struct LamportClock: Codable, Sendable, Hashable {
    /// The highest causal position this replica has witnessed.
    private(set) var counter: UInt64 = 0

    /// RULE 1 — local action: increment, then stamp the event.
    /// Returns the value to put on the new event.
    mutating func tick() -> UInt64 {
        counter += 1
        return counter
    }

    /// RULE 2 — receiving a remote event: fast-forward past it.
    /// After observing, any *future* local event is guaranteed a
    /// higher stamp than everything this replica has ever seen —
    /// which is exactly the happened-before guarantee.
    mutating func observe(_ remoteValue: UInt64) {
        counter = max(counter, remoteValue)
    }
}
