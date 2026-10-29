import Foundation

// MARK: - Where an input dropped on the timeline goes — the pure rules
//
// An input (a row of the Inputs tab) is dragged onto the timeline and released at a point: a time and
// a display lane. What that does is decided HERE, from what the view model read around the point, and
// nowhere else — the ghost under the cursor, the drop itself and `rec.drop` all ask this one function,
// so what the hand is told and what happens cannot drift apart.
//
//   - on a GROUP that can record  -> the input is assigned to it (`.assign`)
//   - on a group that cannot (infinite, looping, an instance of a consolidated object), or on any other
//     object (a clip, a MIDI clip, an aux)                                               -> refused
//   - on a time selection (the point lies in it, on one of its lanes) -> a zone with exactly its in/out
//   - on empty room  -> a zone from the point, 40 % of the view wide, or up to the next object of the
//     lane if that is closer; shorter than max(1 s, 24 px) -> refused
//   - inside an open group (the lane is one of its sub-lanes) the zone is a sub-group (`parent`)
//
// SEVERAL inputs dragged at once (`planMany`): one lane per input, DOWNWARDS from the lane of the hand, in
// the order given (the channels'). Each lane is planned by the rules above on its own — so each zone has
// its own end (40 % of the view, or the next object of ITS lane) — and the refusal is GLOBAL: one lane
// refused refuses the lot (a drop that made three of four zones would be a gesture nobody asked for).
//
// A plain Foundation unit with no model behind it, compiled and asserted alone
// (tools/test_record_zone_planner.swift).

enum RecordZonePlanner {

    /// What the zone is when nothing says otherwise: this share of the visible width.
    static let viewShare = 0.4
    /// A zone shorter than this is refused: a second, or this many pixels, whichever is longer.
    static let minSeconds = 1.0
    static let minPixels = 24.0

    /// An object that sits on the lane aimed at (same container, same display lane).
    struct LaneObject: Equatable {
        enum Kind: Equatable {
            /// Anything that is not a group: a clip, a MIDI clip, an aux.
            case other
            /// A group; `recordable` is false for an infinite bus, a looping group, a consolidated instance.
            case group(recordable: Bool)
        }
        let id: UUID
        let start: Double
        /// `.infinity` for an infinite bus (its band has no end).
        let end: Double
        let kind: Kind

        init(id: UUID, start: Double, end: Double, kind: Kind) {
            self.id = id; self.start = start; self.end = end; self.kind = kind
        }
    }

    /// The time selection, in display lanes.
    struct Selection: Equatable {
        let start: Double
        let end: Double
        let lanes: Set<Int>

        init(start: Double, end: Double, lanes: Set<Int>) {
            self.start = start; self.end = end; self.lanes = lanes
        }
    }

    /// The open group the lane is a sub-lane of, when it is. `allowed` is false when that group cannot
    /// take a zone (looping, or an open consolidated object).
    struct Parent: Equatable {
        let id: UUID
        let allowed: Bool

        init(id: UUID, allowed: Bool) { self.id = id; self.allowed = allowed }
    }

    enum Refusal: String, Equatable {
        /// The point is on a clip (or any non-group object): nothing to record into.
        case onObject
        /// The group under the point cannot record (infinite, looping, consolidated).
        case notRecordable
        /// The container the lane belongs to cannot take a zone.
        case parentNotRecordable
        /// Less room than max(1 s, 24 px) before the next object.
        case tooShort
        /// The selection's span would lie over an object of the lane.
        case overlap
    }

    enum Plan: Equatable {
        /// Make an empty group over [start, end), named after the input, in `parent` (nil = top level).
        case create(start: Double, end: Double, parent: UUID?)
        /// The input goes to this existing group.
        case assign(group: UUID)
        case refuse(Refusal)

        var isRefusal: Bool { if case .refuse = self { return true } else { return false } }
    }

    /// - Parameters:
    ///   - time: where the point falls, in seconds (already snapped by the caller).
    ///   - displayLane: the lane the point is on.
    ///   - visibleSpanSecs: the width of the view, in seconds.
    ///   - pixelsPerSecond: the zoom, for the pixel floor.
    ///   - laneObjects: what sits on that lane, in that container.
    static func plan(time: Double, displayLane: Int, visibleSpanSecs: Double, pixelsPerSecond: Double,
                     laneObjects: [LaneObject], selection: Selection?, parent: Parent?) -> Plan {
        if let parent, !parent.allowed { return .refuse(.parentNotRecordable) }
        let t = max(0, time)

        if let hit = laneObjects.first(where: { t >= $0.start && t < $0.end }) {
            switch hit.kind {
            case .other: return .refuse(.onObject)
            case .group(let recordable): return recordable ? .assign(group: hit.id) : .refuse(.notRecordable)
            }
        }

        if let s = selection, s.lanes.contains(displayLane), t >= s.start, t <= s.end {
            let start = max(0, s.start)
            guard s.end - start > 0 else { return .refuse(.tooShort) }
            if laneObjects.contains(where: { $0.start < s.end && $0.end > start }) { return .refuse(.overlap) }
            return .create(start: start, end: s.end, parent: parent?.id)
        }

        var end = t + viewShare * max(0, visibleSpanSecs)
        if let next = laneObjects.filter({ $0.start >= t }).map(\.start).min() { end = min(end, next) }
        let floor = max(minSeconds, pixelsPerSecond > 0 ? minPixels / pixelsPerSecond : minSeconds)
        guard end - t >= floor - 1e-9 else { return .refuse(.tooShort) }
        return .create(start: t, end: end, parent: parent?.id)
    }

    /// What the lane aimed at holds, for `planMany`: the same three facts `plan` takes. nil for a row that
    /// is not one of the timeline (a clip's piano roll, an automation band): nothing can be put there.
    struct LaneContext {
        let objects: [LaneObject]
        let selection: Selection?
        let parent: Parent?

        init(objects: [LaneObject], selection: Selection?, parent: Parent?) {
            self.objects = objects; self.selection = selection; self.parent = parent
        }
    }

    /// One plan per input, on the lanes `firstLane`, `firstLane + 1`… (`count` of them). `context` reads a
    /// lane; the instant, the view and the zoom are the hand's, the same for all.
    static func planMany(time: Double, firstLane: Int, count: Int, visibleSpanSecs: Double,
                         pixelsPerSecond: Double, context: (Int) -> LaneContext?) -> [Plan] {
        (0 ..< max(0, count)).map { i in
            let lane = firstLane + i
            guard let c = context(lane) else { return .refuse(.onObject) }
            return plan(time: time, displayLane: lane, visibleSpanSecs: visibleSpanSecs,
                        pixelsPerSecond: pixelsPerSecond, laneObjects: c.objects,
                        selection: c.selection, parent: c.parent)
        }
    }

    /// The drop as a whole is refused as soon as one of its lanes is.
    static func isRefused(_ plans: [Plan]) -> Bool { plans.contains { $0.isRefusal } }
}
