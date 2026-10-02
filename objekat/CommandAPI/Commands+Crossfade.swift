import Foundation

// MARK: - Crossfades

/// A crossfade is the zone two neighbours SHARE, and nothing else — no object of its own, no flag
/// saying a pair is crossfaded (@see EditViewModel+Crossfade). These commands therefore address a
/// SEAM, either by naming the two objects or by pointing at a time on a lane, and the only thing
/// they set is the zone's width. The shape of each side stays `object.set_fade_curve`'s business:
/// a crossfade is two curves facing each other, and which two is the user's call.
extension CommandRegistry {

    func registerCrossfadeCommands() {

        /// The pair a command is aimed at: named outright, or found from a time on a lane.
        func resolvePair(_ p: CommandParams, _ vm: EditViewModel) throws -> (left: UUID, right: UUID) {
            if p.raw["left"] != nil || p.raw["right"] != nil {
                let left = try p.uuid("left"), right = try p.uuid("right")
                for id in [left, right] where vm.find(id: id) == nil {
                    throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
                }
                return (left, right)
            }
            guard p.raw["at"] != nil else {
                throw CommandError(code: .bad_params,
                                   message: "name the pair with 'left' and 'right', or point at a "
                                          + "seam with 'at' and 'lane'")
            }
            let at = try p.double("at")
            let lane = try p.int("lane", or: 0)
            let container = p.raw["container"] != nil ? try p.uuid("container") : nil
            if let container, vm.find(id: container) == nil {
                throw CommandError(code: .not_found, message: "unknown container: \(container.uuidString)")
            }
            guard let pair = vm.seamPair(nearTime: at, lane: lane, container: container) else {
                throw CommandError(code: .not_found,
                                   message: "no seam on lane \(lane) near \(at) s — two objects "
                                          + "must MEET there, a gap is not a seam")
            }
            return pair
        }

        /// The refusals, turned into the machine contract. Each one names what the hand would be
        /// shown, since a seam that will not open has to say so rather than do nothing.
        func refuse(_ reason: EditViewModel.SeamRefusal) -> CommandError {
            switch reason {
            case .notSiblings:
                return CommandError(code: .bad_params,
                                    message: "the two objects are not neighbours: a crossfade "
                                           + "lives between siblings of one lane")
            case .gap:
                return CommandError(code: .invalid_state,
                                    message: "the two objects do not meet: there is no seam to open")
            case .porthole:
                return CommandError(code: .invalid_state,
                                    message: "a looping container refuses it: its window is a "
                                           + "porthole onto a pattern, not an edge")
            case .noMaterial:
                return CommandError(code: .invalid_state,
                                    message: "no material left on either side: the seam cannot open")
            case .tooWide:
                return CommandError(code: .invalid_state,
                                    message: "too wide for what the two objects can give")
            }
        }

        func zonePayload(_ z: EditViewModel.CrossfadeZone) -> JSONValue {
            .object(["left": .string(z.leftID.uuidString),
                     "right": .string(z.rightID.uuidString),
                     "container": z.containerID.map { .string($0.uuidString) } ?? .null,
                     "lane": .int(z.lane),
                     "start": .number(z.start),
                     "end": .number(z.end),
                     "width": .number(z.width)])
        }

        register("crossfade.open",
                 summary: "Opens the seam between two adjacent objects of one lane into a "
                        + "crossfade `width` seconds wide, or resizes the one already there. "
                        + "Opening is free because the trim is non-destructive: it re-exposes the "
                        + "matter the edges hid, it does not fabricate any. Symmetric when both "
                        + "sides have material, lopsided when only one has, refused when neither "
                        + "has. `width` = 0 shuts it back to a butt joint.",
                 params: [ParamSpec("left", "uuid", required: false, "Left-hand object."),
                          ParamSpec("right", "uuid", required: false, "Right-hand object."),
                          ParamSpec("at", "number", required: false,
                                    "Failing a pair: the time, in seconds, of the seam to take."),
                          ParamSpec("lane", "int", required: false, "With `at`: the lane (default 0)."),
                          ParamSpec("container", "uuid", required: false,
                                    "With `at`: search inside this group (default: the top level)."),
                          ParamSpec("width", "number", "Width of the zone, in seconds."),
                          ParamSpec("start", "number", required: false,
                                    "Where the zone should BEGIN. Default: centred on the join, "
                                  + "which is what opening a shut seam wants. Same width plus a "
                                  + "new start = moving the seam; a new width with one edge kept "
                                  + "= widening from the other. A wish, not an order: it is "
                                  + "clamped like the width."),
                          ParamSpec("cross_gap", "string", required: false,
                                    "'left' or 'right': the two objects no longer touch, and THAT "
                                  + "one's facing edge travels across the gap to reach the other "
                                  + "before any zone opens — one movement, as under the hand. "
                                  + "Without it a gap is refused: there is no seam to open."),
                          ParamSpec("pin", "string", required: false,
                                    "'start' or 'end': that edge of the zone described by `start` "
                                  + "and `width` is HELD, and the width is clamped rather than the "
                                  + "edge slid. Without it a width the held side cannot give is "
                                  + "taken out of the other edge — right for opening a seam, wrong "
                                  + "for a hand holding one.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let pair = try resolvePair(p, vm)
            let width = try p.double("width")
            guard width >= 0 else {
                throw CommandError(code: .bad_params, message: "'width' cannot be negative")
            }
            let idealStart = p.raw["start"] != nil ? try p.double("start") : nil
            var approach: EditViewModel.SeamApproach = .none
            if p.raw["cross_gap"] != nil {
                guard let l = vm.find(id: pair.left), let r = vm.find(id: pair.right) else {
                    throw CommandError(code: .not_found, message: "object lost")
                }
                let (a, b) = l.startTime <= r.startTime ? (l, r) : (r, l)
                let gap = max(0, b.startTime - (a.startTime + a.duration))
                switch try p.string("cross_gap") {
                case "left":  approach = .leftGrows(gap)
                case "right": approach = .rightGrows(gap)
                default:
                    throw CommandError(code: .bad_params, message: "'cross_gap' is 'left' or 'right'")
                }
            }
            var pin: EditViewModel.ZonePin? = nil
            if p.raw["pin"] != nil {
                guard let s = idealStart else {
                    throw CommandError(code: .bad_params, message: "'pin' needs 'start'")
                }
                switch try p.string("pin") {
                case "start": pin = .start(s)
                case "end":   pin = .end(s + width)
                default:
                    throw CommandError(code: .bad_params, message: "'pin' is 'start' or 'end'")
                }
            }
            switch vm.openCrossfade(leftID: pair.left, rightID: pair.right, width: width,
                                    idealStart: idealStart, pin: pin, approach: approach) {
            case .failure(let reason):
                throw refuse(reason)
            case .success(let zone):
                // A zone asked for and a zone obtained are not the same thing: the width is
                // clamped by what the two objects can give. The caller is told what it GOT.
                return .object(["requested_width": .number(width),
                                "zone": zone.map(zonePayload) ?? .null])
            }
        }

        register("crossfade.close",
                 summary: "Shuts a crossfade back to a butt joint, both edges coming back onto the "
                        + "middle of the zone. The matter the zone had re-exposed goes back behind "
                        + "the edges, where a trim always leaves it.",
                 params: [ParamSpec("left", "uuid", required: false, "Left-hand object."),
                          ParamSpec("right", "uuid", required: false, "Right-hand object."),
                          ParamSpec("at", "number", required: false, "Failing a pair: the seam's time."),
                          ParamSpec("lane", "int", required: false, "With `at`: the lane (default 0)."),
                          ParamSpec("container", "uuid", required: false,
                                    "With `at`: search inside this group.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let pair = try resolvePair(p, vm)
            if case .failure(let reason) = vm.closeCrossfade(leftID: pair.left, rightID: pair.right) {
                throw refuse(reason)
            }
            return .object(["left": .string(pair.left.uuidString),
                            "right": .string(pair.right.uuidString)])
        }

        register("crossfade.list",
                 summary: "Every crossfade in the project, at every depth. Derived from the "
                        + "geometry — a crossfade is the common zone itself, nothing records one.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            let zones = vm.allCrossfadeZones()
            return .object(["count": .int(zones.count),
                            "crossfades": .array(zones.map(zonePayload))])
        }

        #if DEBUG
        register("debug.crossfade_drag",
                 summary: """
                 DEBUG. A crossfade DRAG with no mouse: the very per-frame function the gesture \
                 calls (`EditViewModel.driveCrossfadeFrame`), fed with the zone under the hand \
                 (`lefts[0]` / `rights[0]`), the zones that follow it (the other pairs, in the same \
                 order), the `part` taken and one travel `dx` (seconds, UNSNAPPED) per frame, then \
                 the release (`commitCrossfadeDrag`). The frames are worked out on the gesture's \
                 COPIES: `drag_items_writes` must be 0 — the model is written once, on release \
                 (`commit_items_writes`), behind ONE undo point (none if nothing moved). \
                 `legacy: true` lays each frame on the MODEL instead, the way it was laid before the \
                 copies (`batched: false` one write at a time) — kept so the two can be compared \
                 octet for octet. Answers what it cost, READ OFF COUNTERS rather than a clock: \
                 `items_writes` and `lane_entries_rebuilds` (O(N) each), plus the milliseconds. \
                 Not present in Release builds.
                 """,
                 params: [ParamSpec("lefts", "array<uuid>", "Left objects, one per zone (the first is the grabbed zone)."),
                          ParamSpec("rights", "array<uuid>", "Right objects, same order."),
                          ParamSpec("part", "string", "both | move | sideStart | sideEnd."),
                          ParamSpec("dx", "array<number>", "The travel of each frame, in seconds."),
                          ParamSpec("via_edge_band", "bool", required: false,
                                    "Taken through the lower half's crop band (default false)."),
                          ParamSpec("overshoot_y", "number", required: false,
                                    "With `both`: the vertical travel outside the row, in px (the bend)."),
                          ParamSpec("s_curve", "bool", required: false, "With `both`: ⌥ held."),
                          ParamSpec("legacy", "bool", required: false,
                                    "Lay the frames on the model, one frame at a time, as before the copies (default false)."),
                          ParamSpec("batched", "bool", required: false,
                                    "With `legacy`: the frame's writes in ONE batch (default true).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let lefts = try p.uuids("lefts"), rights = try p.uuids("rights")
            guard !lefts.isEmpty, lefts.count == rights.count else {
                throw CommandError(code: .bad_params, message: "'lefts' and 'rights' must have the same, non-zero length")
            }
            let part: CrossfadeDragState.Part
            switch try p.string("part") {
            case "both": part = .both
            case "move": part = .move
            case "sideStart": part = .sideStart
            case "sideEnd": part = .sideEnd
            default: throw CommandError(code: .bad_params, message: "'part' is both | move | sideStart | sideEnd")
            }
            guard case .array(let raw)? = p.raw["dx"] else {
                throw CommandError(code: .bad_params, message: "'dx' must be an array of numbers")
            }
            let dxs: [Double] = raw.compactMap { if case .number(let d) = $0 { return d } else { return nil } }
            let viaEdgeBand = try p.bool("via_edge_band", or: false)
            var tracks: [CrossfadePairTrack] = []
            var lane = 0
            for (l, r) in zip(lefts, rights) {
                guard let z = vm.crossfadeZone(leftID: l, rightID: r) else {
                    throw CommandError(code: .invalid_state, message: "not a crossfade: \(l.uuidString) / \(r.uuidString)")
                }
                var t = CrossfadePairTrack(
                    leftID: z.leftID, rightID: z.rightID, anchorStart: z.start, anchorEnd: z.end,
                    leftCurveAnchor: vm.find(id: z.leftID)?.fadeOutCurve ?? .linear,
                    rightCurveAnchor: vm.find(id: z.rightID)?.fadeInCurve ?? .linear)
                if viaEdgeBand,
                   let held = vm.find(id: part == .sideStart ? z.rightID : z.leftID) {
                    t.heldAnchor = (held.startTime, held.duration)
                }
                if tracks.isEmpty { lane = z.lane }
                tracks.append(t)
            }
            var state = CrossfadeDragState(tracks: tracks, grabbedIndex: 0, part: part,
                                           viaEdgeBand: viaEdgeBand, lane: lane)
            state.overshootY = part == .both ? try p.double("overshoot_y", or: 0) : 0
            state.bendTravelPx = 40
            state.sCurve = part == .both ? try p.bool("s_curve", or: false) : false
            let legacy = try p.bool("legacy", or: false)
            let batched = try p.bool("batched", or: true)

            // The frames: on the gesture's COPIES by default (the model, the engine and the undo
            // stack untouched while the hand is down), or — `legacy` — laid on the model one frame
            // at a time the way the gesture was laid before the copies.
            let w0 = vm.itemsWriteCount, r0 = vm.laneEntriesRebuildCount, u0 = vm.undoPushCount
            let t0 = CFAbsoluteTimeGetCurrent()
            for dx in dxs {
                if legacy { vm.driveCrossfadeFrameLive(&state, shift: dx, batched: batched) }
                else { vm.driveCrossfadeFrame(&state, shift: dx) }
            }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            let dragWrites = vm.itemsWriteCount - w0, dragRebuilds = vm.laneEntriesRebuildCount - r0
            let dragUndo = vm.undoPushCount - u0
            // The release: ONE undo point and ONE write (nothing at all for the legacy path, which
            // has been writing all along).
            let tc = CFAbsoluteTimeGetCurrent()
            if legacy { if state.didChange { vm.isDirty = true } }
            else { vm.commitCrossfadeDrag(state) }
            let commitMs = (CFAbsoluteTimeGetCurrent() - tc) * 1000
            let frames = max(1, dxs.count)
            let writes = vm.itemsWriteCount - w0, rebuilds = vm.laneEntriesRebuildCount - r0
            return .object(["frames": .int(dxs.count),
                            "zones": .int(tracks.count),
                            "legacy": .bool(legacy),
                            "did_change": .bool(state.didChange),
                            "undo_pushes": .int(vm.undoPushCount - u0),
                            "items_writes": .int(writes),
                            "lane_entries_rebuilds": .int(rebuilds),
                            // What the frames cost BEFORE the release: 0 writes is the whole point.
                            "drag_items_writes": .int(dragWrites),
                            "drag_lane_entries_rebuilds": .int(dragRebuilds),
                            "drag_undo_pushes": .int(dragUndo),
                            "commit_items_writes": .int(writes - dragWrites),
                            "writes_per_frame": .number(Double(dragWrites) / Double(frames)),
                            "rebuilds_per_frame": .number(Double(dragRebuilds) / Double(frames)),
                            "ms_total": .number(ms + commitMs),
                            "ms_per_frame": .number(ms / Double(frames)),
                            "commit_ms": .number(commitMs)])
        }
        #endif
    }
}
