import Foundation

/// The wall at t = 0, and WHO it applies to.
///
/// The rule (the user's, 2 October 2026): **an object is clamped at zero, EXCEPT when it is inside a
/// group — then it is the GROUP that is clamped at zero, and its objects may start before it.**
///
/// What that means in the model (@see [[project-negative-start-convention]]): a group's window is a
/// FRAME, not a cut, and its children keep an ABSOLUTE `startTime`. So
///  - a ROOT object (clip, MIDI, aux or group — nothing above it) cannot start before 0;
///  - a DESCENDANT of a group has no wall of its own: moving, trimming or dropping it never moves the
///    group's window, so there is nothing to clamp; what stays ≥ 0 is the root group above it, which
///    is a root object like any other. Carrying a ROOT group carries its children by the same shift,
///    so they go negative only by what they already were — the group is what stops at 0.
///  - an object that LEAVES a group for the root becomes a root object and is clamped on arrival
///    (`ejectFromGroup`); one that enters a group was a root object until the drop and was clamped
///    during the drag.
///
/// Pure arithmetic with no model behind it — the half that can be asserted alone
/// (`tools/test_zero_clamp.swift`); the callers say whether the object is at the root.
enum ZeroClamp {

    /// The lowest start an object may take: 0 at the root, nothing inside a group.
    static func lowestStart(isRoot: Bool) -> Double { isRoot ? 0 : -.infinity }

    /// `start`, brought up to the wall that applies to the object.
    static func clamp(_ start: Double, isRoot: Bool) -> Double {
        max(lowestStart(isRoot: isRoot), start)
    }

    /// The most a SET of moved objects may travel to the LEFT (a negative number, `-.infinity` for
    /// none): the wall of the root objects among them, the descendants being free. This is the
    /// `dt ≥ wall` the drag applies to the whole selection (the leftmost root object stops at 0 while
    /// the hand carries on).
    static func leftTravelLimit(starts: [(start: Double, isRoot: Bool)]) -> Double {
        var limit = -Double.infinity
        for s in starts where s.isRoot { limit = max(limit, -s.start) }
        return limit
    }

    /// How far the LEFT edge of an object may be pulled to the right (`dStart` of a trim; negative =
    /// the edge going left): the source content available before the edge (`room`, ∞ for an object
    /// with no source) and, for a root object only, the wall at 0.
    static func trimLimit(start: Double, room: Double, isRoot: Bool) -> Double {
        max(isRoot ? -start : -.infinity, -room)
    }
}
