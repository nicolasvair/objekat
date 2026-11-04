import Foundation

// MARK: - A recording made THROUGH a loop — the pure rules
//
// (docs/plan_enregistrement_audio.md, "Rec en boucle"; engine patch 0050.)
//
// With the loop on, a recording is still ONE continuous file per input, but the head does not go straight
// on: at the loop's end it jumps back, and what the file holds is a succession of PASSES — stretches over
// which the timeline advanced one second per second of file. The engine journals them
// (`OBJEngineCore.lastRecordSegments()`); each is a `Segment`: where it starts in the FILE, how long it is,
// and where it starts on the TIMELINE. From the segments and the zone, this unit decides what each armed
// zone receives, and nowhere else:
//
//   - ONE take per pass that crosses the zone's window, cropped to it (as `RecordTakePlanner` crops a whole
//     capture) — loop and zone are independent: a zone the loop does not reach gets no take from the
//     passes that do not cross it. Every take points at the SAME file with its own `sourceOffset` (nothing is
//     cut, no `_take_N`: the handles reach the file's ends). A partial pass at the stop is kept like the
//     others; only a pass of no length is dropped;
//   - the NEWEST take goes on the top lane, the older ones below it, one lane each (`Plan.shiftBy`: every
//     existing child goes down by as many lanes as there are takes);
//   - audibility: in the default "mute" mode only the LAST pass that crosses the window stays audible (even
//     if it is partial) — the others are laid down muted — and the previous takes crossing the window are
//     muted whole, `RecordTakePlanner`'s rule, unchanged; in the "add" mode every take is audible and
//     nothing is muted;
//   - a zone no pass crosses uses the out-of-window rule of a linear recording: ONE object over the last pass,
//     at its real position (under the zone's grey area, hence silent), nothing muted, and the previous takes
//     muted at the press are given back. "Crossing" is judged on the REAL passes.
//
//   - the takes are laid down PASS BY PASS, one undo point each (`passSteps`, at most 16 — the earliest merge into the
//     first), so that ⌘Z takes the last pass away and leaves the zone as it was when the pass before was the last one:
//     `prefixLayout` is that state (`plan`'s lanes and audibility applied to the first k takes).
//
// With ONE segment this is exactly `RecordTakePlanner.plan` (asserted by the tests).
//
// A plain Foundation unit with no model behind it, compiled and asserted alone
// (tools/test_record_loop_planner.swift).

enum RecordLoopPlanner {

    typealias Child = RecordTakePlanner.Child

    /// Below this length a loop is not a loop for the recorder: the recording is linear (the engine's own
    /// floor in the session, see `ObjekatSession`).
    static let minimumLoopLength = 0.25

    /// A pass: the stretch of the file `[fileStart, fileStart + length)` was recorded while the timeline
    /// went from `timelineStart` on at the normal speed. All in seconds.
    struct Segment: Equatable {
        let fileStart: Double
        let length: Double
        let timelineStart: Double
        var timelineEnd: Double { timelineStart + length }
    }

    struct Take: Equatable {
        let start: Double
        let duration: Double
        /// Seconds of the SOURCE FILE the take begins at.
        let sourceOffset: Double
        /// The zone's own lane numbering (relative to the group).
        let lane: Int
        /// True when no pass crossed the window: the take lies in the zone's grey area.
        let outsideWindow: Bool
        /// False for a take laid down muted ("mute" mode: only the last crossing pass is audible).
        let audible: Bool
        /// The index of the pass in the segments given (chronological).
        let pass: Int
    }

    struct Plan: Equatable {
        /// Oldest first; the newest is the last and sits on the top lane.
        let takes: [Take]
        /// The existing children that end up muted (those muted at the start included).
        let mutedIDs: [UUID]
        /// Children muted at the start that must be heard again.
        var unmuteIDs: [UUID] = []
        /// The existing children that go down by `shiftBy` lanes: all of them.
        var shiftIDs: [UUID] = []
        /// How many lanes: one per take.
        var shiftBy: Int { takes.count }
    }

    /// One point of the engine's journal (`OBJEngineCore.lastRecordJournal`): from this instant of the RECORDING CLOCK on,
    /// the head is at `timeline` and advances one second per second, until the next point. The clock is the time
    /// the recording's files and MIDI notes are written in: file sample f is at `origin + f / rate` on it.
    struct JournalPoint: Equatable {
        let clock: Double
        let timeline: Double
    }

    /// The passes of ONE file (its first sample at `origin` on the clock, `length` seconds long) from the journal. The
    /// first stretch is extended back to the file's start and the last one to its end (the latency tail), whatever the
    /// journal says there; a stretch outside the file is dropped. Without a journal, a linear recording from `origin`.
    static func segments(journal: [JournalPoint], origin: Double, length: Double) -> [Segment] {
        guard length > 0 else { return [] }
        guard !journal.isEmpty else { return [Segment(fileStart: 0, length: length, timelineStart: origin)] }
        let end = origin + length
        var out: [Segment] = []
        for (i, p) in journal.enumerated() {
            let a = i == 0 ? origin : max(p.clock, origin)
            let b = i + 1 < journal.count ? min(journal[i + 1].clock, end) : end
            guard b > a else { continue }
            out.append(Segment(fileStart: a - origin, length: b - a, timelineStart: p.timeline + (a - p.clock)))
        }
        return out
    }

    /// Where the head was at an instant of the recording clock (a MIDI note's stamp): the stretch that holds it, the
    /// first one extended back, the last one forward. A clock with no journal is the timeline itself.
    static func timeline(forClock c: Double, journal: [JournalPoint]) -> Double {
        guard let first = journal.first else { return c }
        let p = journal.last(where: { $0.clock <= c }) ?? first
        return p.timeline + (c - p.clock)
    }

    /// The range of the timeline the head is going to walk over from `startPosition`: `[start, ∞)` without a
    /// loop (or when it is behind the head), the loop's own range (extended back to the press if the press is
    /// before it) otherwise. A loop shorter than `minimumLoopLength` counts for none.
    static func reachableRange(startPosition: Double, loop: ClosedRange<Double>?) -> ClosedRange<Double> {
        guard let l = loop, l.upperBound - l.lowerBound >= minimumLoopLength, startPosition < l.upperBound else {
            return startPosition...Double.greatestFiniteMagnitude
        }
        return min(startPosition, l.lowerBound)...l.upperBound
    }

    /// The previous takes to mute when the recording STARTS: `RecordTakePlanner.mutesAtStart`, aware of the
    /// loop — a press beyond the window is no reason to leave the previous takes audible when the loop is
    /// going to bring the head back through it.
    static func mutesAtStart(windowStart: Double, windowEnd: Double, children: [Child],
                             startPosition: Double, loop: ClosedRange<Double>?,
                             mutesPrevious: Bool = true) -> [UUID] {
        guard mutesPrevious else { return [] }
        let reach = reachableRange(startPosition: startPosition, loop: loop)
        guard reach.lowerBound < windowEnd, reach.upperBound > windowStart else { return [] }
        return children.filter { !$0.isMuted && $0.start < windowEnd && $0.end > windowStart }.map(\.id)
    }

    // MARK: One undo step per pass

    /// The undo steps a recording through a loop is laid down in: ⌘Z takes the LAST pass away, the next one the
    /// pass before. `passes` are the indices (`Take.pass`) of the passes that gave at least one take, across every
    /// zone. One step per pass, oldest first; above `cap` the earliest passes merge into the FIRST step, so that the
    /// undo stack (50 entries) is not flushed by one recording.
    static func passSteps(passes: [Int], cap: Int = 16) -> [[Int]] {
        let sorted = Array(Set(passes)).sorted()
        guard !sorted.isEmpty, cap > 0 else { return [] }
        guard sorted.count > cap else { return sorted.map { [$0] } }
        let merged = sorted.count - cap + 1
        return [Array(sorted[0..<merged])] + sorted[merged...].map { [$0] }
    }

    /// What a zone looks like after the first `k` of its takes were laid down: the lane and the audibility of
    /// each take, oldest first. These are `plan`'s own rules (the newest on the top lane; in "mute" the last one
    /// only is audible) applied to a prefix — the state "stopped after pass k".
    static func prefixLayout(takeCount k: Int, baseLane: Int, mutesPrevious: Bool) -> [(lane: Int, audible: Bool)] {
        (0..<max(0, k)).map { n in (lane: baseLane + (k - 1 - n), audible: !mutesPrevious || n == k - 1) }
    }

    /// - Parameters:
    ///   - segments: the passes, oldest first (a pass of no length is dropped here).
    ///   - mutesPrevious: the zone's take mode: false = "add".
    ///   - mutedAtStart: the children `mutesAtStart` muted when the recording began (`children` still tells
    ///     them muted; the plan reads them as they were before).
    static func plan(windowStart: Double, windowEnd: Double, children: [Child], segments: [Segment],
                     mutesPrevious: Bool = true, mutedAtStart: Set<UUID> = []) -> Plan {
        let baseLane = RecordTakePlanner.takeLane(children: children)
        let shift = children.map(\.id)
        let before = children.map { c in
            mutedAtStart.contains(c.id) ? Child(id: c.id, start: c.start, end: c.end, lane: c.lane, isMuted: false) : c
        }
        let passes = segments.enumerated().filter { $0.element.length > 0 }

        // The passes that cross the window, cropped to it.
        struct Crop { let pass: Int; let start: Double; let end: Double; let offset: Double }
        let crops: [Crop] = passes.compactMap { (i, s) in
            let a = max(windowStart, s.timelineStart), b = min(windowEnd, s.timelineEnd)
            return b > a ? Crop(pass: i, start: a, end: b, offset: s.fileStart + (a - s.timelineStart)) : nil
        }

        guard !crops.isEmpty else {
            // No pass crosses the window: one object over the last pass, outside the window, nothing muted.
            guard let (i, s) = passes.last else {
                return Plan(takes: [], mutedIDs: [], unmuteIDs: before.map(\.id).filter { mutedAtStart.contains($0) },
                            shiftIDs: [])
            }
            return Plan(takes: [Take(start: s.timelineStart, duration: s.length, sourceOffset: s.fileStart,
                                     lane: baseLane, outsideWindow: true, audible: true, pass: i)],
                        mutedIDs: [],
                        unmuteIDs: before.map(\.id).filter { mutedAtStart.contains($0) },
                        shiftIDs: shift)
        }

        let k = crops.count
        let takes = crops.enumerated().map { (n, c) in
            Take(start: c.start, duration: c.end - c.start, sourceOffset: c.offset,
                 lane: baseLane + (k - 1 - n),                       // the newest (last) on the top lane
                 outsideWindow: false,
                 audible: !mutesPrevious || n == k - 1,              // "mute": the last crossing pass only
                 pass: c.pass)
        }
        let muted = mutesPrevious
            ? before.filter { !$0.isMuted && $0.start < windowEnd && $0.end > windowStart }.map(\.id)
            : []
        return Plan(takes: takes, mutedIDs: muted, shiftIDs: shift)
    }
}
