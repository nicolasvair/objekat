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
//     being heard, the new one replaces them. One undo gives it all back;
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
        /// The children to mute, in the order given.
        let mutedIDs: [UUID]
    }

    static func plan(windowStart: Double, windowEnd: Double, children: [Child], capture: Capture) -> Plan {
        let lane = (children.map(\.lane).max() ?? -1) + 1
        let start = max(windowStart, capture.origin)
        let end = min(windowEnd, capture.origin + capture.length)
        guard end > start else {
            return Plan(take: Take(start: capture.origin, duration: capture.length, sourceOffset: 0,
                                   lane: lane, outsideWindow: true),
                        mutedIDs: [])
        }
        let muted = children.filter { !$0.isMuted && $0.start < windowEnd && $0.end > windowStart }.map(\.id)
        return Plan(take: Take(start: start, duration: end - start, sourceOffset: start - capture.origin,
                               lane: lane, outsideWindow: false),
                    mutedIDs: muted)
    }
}
