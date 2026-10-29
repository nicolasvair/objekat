import Foundation

// MARK: - What a finished recording becomes in a zone — the pure rules
//
// A recording ends with ONE file per input, which holds everything from the press of "record" to the
// stop (the HANDLES: the take is longer than the zone, and its edges can be pulled out into that matter).
// What each armed zone receives is decided HERE from three facts only — the zone's window, its children,
// and where the file sits on the timeline — and nowhere else:
//
//   - the take is the file CROPPED to the zone's window: it starts at max(window start, file origin) and
//     ends at min(window end, file end); `sourceOffset` is how far into the file it starts (seconds of
//     the SOURCE, the model's convention, speed 1);
//   - it goes on the lane BELOW the lowest child (older takes on top, the newest at the bottom);
//   - every direct child not muted yet that crosses the window is muted whole — the previous takes stop
//     being heard, the new one replaces them. One undo gives it all back. They are muted when the
//     recording STARTS (`mutesAtStart`: they would be heard while the next one is played), unless the
//     press already lies beyond the window; at the stop `plan` is told which ones were (`mutedAtStart`)
//     and says which of them to give back when the capture turns out not to cross the window;
//   - a capture that does not cross the window at all (record pressed after the zone ended, or stopped
//     before it began) still gives an object, over the WHOLE capture, in the grey area of the zone —
//     there it is outside the window, hence silent — and then nothing is muted: the zone would go dumb.
//
// A plain Foundation unit with no model behind it, compiled and asserted alone
// (tools/test_record_take_planner.swift).

enum RecordTakePlanner {

    /// A direct child of the zone, as the planner needs to see it.
    struct Child: Equatable {
        let id: UUID
        let start: Double
        let end: Double
        let lane: Int
        let isMuted: Bool
    }

    /// The file a recording left: the timeline instant of its first sample and its length, in seconds.
    struct Capture: Equatable {
        let origin: Double
        let length: Double
    }

    struct Take: Equatable {
        let start: Double
        let duration: Double
        /// Seconds of the SOURCE FILE the take begins at (0 when it starts with the file).
        let sourceOffset: Double
        /// The zone's own lane numbering (relative to the group).
        let lane: Int
        /// True when the capture did not cross the window: the take lies in the zone's grey area.
        let outsideWindow: Bool
    }

    struct Plan: Equatable {
        let take: Take
        /// The children that end up muted by this take, in the order given (those muted at the start
        /// included).
        let mutedIDs: [UUID]
        /// Children muted at the start that must be heard again: the capture did not cross the window.
        var unmuteIDs: [UUID] = []
    }

    /// The lane (the zone's own numbering) a take goes on: just below the lowest child.
    static func takeLane(children: [Child]) -> Int { (children.map(\.lane).max() ?? -1) + 1 }

    /// The unmuted children that cross the window.
    private static func crossing(_ children: [Child], _ windowStart: Double, _ windowEnd: Double) -> [UUID] {
        children.filter { !$0.isMuted && $0.start < windowEnd && $0.end > windowStart }.map(\.id)
    }

    /// The previous takes to mute when the recording STARTS at `startPosition`: the unmuted children that
    /// cross the window — none when the press already lies at or beyond the window's end (the capture
    /// cannot cross it, so nothing would replace them).
    static func mutesAtStart(windowStart: Double, windowEnd: Double, children: [Child],
                             startPosition: Double) -> [UUID] {
        startPosition < windowEnd ? crossing(children, windowStart, windowEnd) : []
    }

    /// - Parameter mutedAtStart: the children `mutesAtStart` muted when the recording began. `children`
    ///   still tells them muted; the plan reads them as they were before.
    static func plan(windowStart: Double, windowEnd: Double, children: [Child], capture: Capture,
                     mutedAtStart: Set<UUID> = []) -> Plan {
        let lane = takeLane(children: children)
        let before = children.map { c in
            mutedAtStart.contains(c.id) ? Child(id: c.id, start: c.start, end: c.end, lane: c.lane, isMuted: false) : c
        }
        let start = max(windowStart, capture.origin)
        let end = min(windowEnd, capture.origin + capture.length)
        guard end > start else {
            return Plan(take: Take(start: capture.origin, duration: capture.length, sourceOffset: 0,
                                   lane: lane, outsideWindow: true),
                        mutedIDs: [],
                        unmuteIDs: before.map(\.id).filter { mutedAtStart.contains($0) })
        }
        return Plan(take: Take(start: start, duration: end - start, sourceOffset: start - capture.origin,
                               lane: lane, outsideWindow: false),
                    mutedIDs: crossing(before, windowStart, windowEnd))
    }
}
