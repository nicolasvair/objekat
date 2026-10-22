//
//  CompatClock.swift
//  objekat
//
//  `Duration`, `ContinuousClock` and `Task.sleep(for:)` are macOS 13. They are only used by the
//  command API and the script stores (budgets, polling), so ONE implementation is kept
//  everywhere, with no `#available`: a monotonic clock over `DispatchTime`, the same semantics.
//  To delete when the deployment target is >= 13.
//

import Foundation

struct CompatDuration: Comparable, Sendable {
    var nanoseconds: Int64

    static func milliseconds(_ ms: Int) -> CompatDuration {
        CompatDuration(nanoseconds: Int64(ms) * 1_000_000)
    }

    static func < (lhs: CompatDuration, rhs: CompatDuration) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// How many `rhs` fit in `lhs` (`Duration / Duration`).
    static func / (lhs: CompatDuration, rhs: CompatDuration) -> Double {
        Double(lhs.nanoseconds) / Double(rhs.nanoseconds)
    }

    /// Whole milliseconds.
    var ms: Int { Int(nanoseconds / 1_000_000) }
}

struct CompatInstant: Comparable, Sendable {
    var uptimeNanoseconds: UInt64

    static func - (lhs: CompatInstant, rhs: CompatInstant) -> CompatDuration {
        CompatDuration(nanoseconds: Int64(bitPattern: lhs.uptimeNanoseconds &- rhs.uptimeNanoseconds))
    }

    static func < (lhs: CompatInstant, rhs: CompatInstant) -> Bool {
        lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
    }
}

enum CompatClock {
    static var now: CompatInstant { CompatInstant(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) }
}

extension Task where Success == Never, Failure == Never {
    /// `Task.sleep(for:)`.
    static func compatSleep(_ duration: CompatDuration) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, duration.nanoseconds)))
    }
}
