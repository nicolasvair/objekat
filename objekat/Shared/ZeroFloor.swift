import Foundation

/// The floor at t = 0, for EVERY object a gesture moves — at any depth.
///
/// The rules (the user's, 16 October 2026; they replace `ZeroClamp` of 2 October, under which a
/// child of a group had no wall at all). Every time is ABSOLUTE timeline time, and an object's
/// start is ITS OWN start, even when a group's window or a crop hides it. (In the model a child
/// keeps an absolute `startTime` already, @see [[project-negative-start-convention]]: nothing has
/// to be summed.)
///
///  - R1. An object moved by a gesture — root, child, grandchild… — is floored at 0.
///  - R2. A group is floored by its OWN start only, never by its children: carrying a group left
///    may push its children before 0 (group A@20 holding c@10, dragged −25: A stops at 0, c −10).
///  - R3. An object that starts NEGATIVE when the gesture opens is not floored while it stays
///    negative (c@−10 dragged −5 → −15).
///  - R4. Sticky within the gesture: once its start has reached 0 it is floored for the rest of
///    THAT gesture (c@−10 dragged +15 → +5; back left in the same gesture, it stops at 0).
///  - R5. A selection keeps its spacing: ONE common travel, limited by the most constraining
///    object, each applying its own floor (R1/R3/R4).
///  - R6. Nested groups are R2 again: what is carried is never asked.
///  - R7. A left-edge trim never extends a start below 0 — and an edge already negative is not
///    extended at all (it is not forced to 0 either: cropping a negative head is still allowed).
///  - R9. An edge before 0 is invisible, so it is never a snap target.
///
/// Pure arithmetic with no model behind it, so it can be compiled and asserted alone
/// (`tools/test_zero_floor.swift`). The callers pass the starts of what the gesture MOVES (never
/// the descendants it carries — R2) as they were when the gesture opened; `Gesture` keeps the
/// one piece of state a drag has (R4).
enum ZeroFloor {

    /// One moved object as the floor reads it. `absStart` = its start when the gesture opened.
    typealias Start = (absStart: Double, startedNegative: Bool, crossedZero: Bool)

    /// Below this, a start counts as negative; at or above it, a start has reached 0. Floating
    /// arithmetic (a cut, a snap) leaves starts at -1e-12 where 0 was meant.
    static let epsilon = 1e-9

    /// True when `start` is before 0 (R3 applies to an object that starts there).
    static func isNegative(_ start: Double) -> Bool { start < -epsilon }

    /// True when the floor applies to this object right now: it started at or after 0 (R1), or it
    /// has reached 0 during this gesture (R4).
    static func isFloored(startedNegative: Bool, crossedZero: Bool) -> Bool {
        !startedNegative || crossedZero
    }

    /// The most the selection may travel to the LEFT (`-.infinity` for none): the strongest of the
    /// floored objects' walls (R5). Positive when an object that crossed 0 has to stay there.
    static func leftTravelLimit(starts: [Start]) -> Double {
        var limit = -Double.infinity
        for s in starts where isFloored(startedNegative: s.startedNegative, crossedZero: s.crossedZero) {
            limit = max(limit, -s.absStart)
        }
        return limit
    }

    /// The common travel to apply: what the hand asked, stopped by the floor (R1–R6).
    static func clampedDelta(starts: [Start], proposedDelta: Double) -> Double {
        max(proposedDelta, leftTravelLimit(starts: starts))
    }

    /// The same, for starts read with no gesture history (a release, an API call, a paste): an
    /// object is negative or not by its own start, and nothing has crossed yet. Weaker than any
    /// gesture's own answer, never stronger — so re-applying it to a travel a drag has already
    /// floored changes nothing.
    static func clampedDelta(startsAt starts: [Double], proposedDelta: Double) -> Double {
        clampedDelta(starts: starts.map { (absStart: $0, startedNegative: isNegative($0), crossedZero: false) },
                     proposedDelta: proposedDelta)
    }

    /// ONE object taken from `old` to `proposed` in a single step (`object.move`): floored at 0
    /// unless it starts negative (R1, R3).
    static func clampedStart(from old: Double, to proposed: Double) -> Double {
        isNegative(old) ? proposed : max(0, proposed)
    }

    /// The per-gesture half (R4): which moved objects have reached 0 since the hand took them.
    /// One per drag, reset with it; `ID` is the object's identity.
    struct Gesture<ID: Hashable> {
        private(set) var crossed: Set<ID> = []

        init() {}

        /// The travel to apply this frame. `starts` = the moved objects' starts when the gesture
        /// OPENED (the anchors, never the live model); `proposedDelta` = the hand's total travel
        /// since. An object that lands at or after 0 is remembered as crossed.
        mutating func clamp(starts: [ID: Double], proposedDelta: Double) -> Double {
            let list: [Start] = starts.map {
                (absStart: $0.value, startedNegative: ZeroFloor.isNegative($0.value),
                 crossedZero: crossed.contains($0.key))
            }
            let dt = ZeroFloor.clampedDelta(starts: list, proposedDelta: proposedDelta)
            for (id, s) in starts where ZeroFloor.isNegative(s) && s + dt >= -ZeroFloor.epsilon {
                crossed.insert(id)
            }
            return dt
        }
    }

    /// R7: how far the LEFT edge of an object may move (`dStart` of a trim; negative = extending to
    /// the left): the source content available before the edge (`room`, ∞ for an object with no
    /// source) and the floor — 0 for an edge at or after 0, no extension at all for an edge that is
    /// already before it.
    static func trimLimit(start: Double, room: Double) -> Double {
        max(isNegative(start) ? 0 : -start, -room)
    }

    /// R7 for a trim given as an absolute start (`object.trim`): `requested`, floored at 0, or at
    /// the current start when that one is already negative (a crop of a negative head is allowed).
    static func trimmedStart(from old: Double, to requested: Double) -> Double {
        max(requested, min(0, old))
    }

    /// R9: may this instant be a snap target? An edge before 0 is invisible.
    static func isSnapTarget(_ t: Double) -> Bool { t >= -epsilon }

    /// An object that LANDS at the root (ejected from a group, or an ⌥ copy of a child laid at the
    /// root) is floored there whatever it started at: the root wall predates these rules and is
    /// kept (a root object with a negative head is only ever made by dissolving a group).
    static func rootStart(_ start: Double) -> Double { max(0, start) }
}
