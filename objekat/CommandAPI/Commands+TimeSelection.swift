import Foundation

// MARK: - Time selection and clipboard

/// A time selection is not a selection of objects: it is a RECTANGLE (range × lanes) that cuts
/// through whatever it crosses. It is the door through which auxes, MIDI clips and groups are
/// created over a range — hence its place here rather than under `selection.*`.
///
/// ⚠️ The lanes are DISPLAY lanes: an open group shifts everything below it.
/// `object.list` returns `display_lane` next to `lane` — the former is the one to aim at.
extension CommandRegistry {

    func registerTimeSelectionCommands() {

        register("timesel.set",
                 summary: "Sets the time selection (range × display lanes).",
                 params: [ParamSpec("start", "number", "Start, in seconds."),
                          ParamSpec("end", "number", "End, in seconds."),
                          ParamSpec("lanes", "array<int>", required: false,
                                    "Display lanes covered (default [0])."),
                          ParamSpec("lane_count", "int", required: false,
                                    "When 'lanes' is absent: how many lanes from 'lane'.") ,
                          ParamSpec("lane", "int", required: false,
                                    "First lane when using 'lane_count' (default 0)."),
                          ParamSpec("all_lanes", "bool", required: false,
                                    "Every OBJECT lane the timeline has (automation rows left out) "
                                  + "— what a drag in the time ruler traces. Wins over 'lanes'.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let start = max(0, try p.double("start"))
            let end = try p.double("end")
            guard end > start else {
                throw CommandError(code: .bad_params, message: "'end' must come after 'start'")
            }
            var lanes = Set<Int>()
            if (try p.bool("all_lanes", or: false)) {
                lanes = vm.allObjectLanes()
            } else if p.raw["lanes"] != nil {
                for value in try p.array("lanes") {
                    guard let lane = value.intValue else {
                        throw CommandError(code: .bad_params, message: "'lanes': a list of integers was expected")
                    }
                    lanes.insert(max(0, lane))
                }
            } else {
                let first = max(0, try p.int("lane", or: 0))
                let count = max(1, try p.int("lane_count", or: 1))
                lanes = Set(first..<(first + count))
            }
            guard !lanes.isEmpty else {
                throw CommandError(code: .bad_params, message: "no lane")
            }
            vm.timeSelection = TimeSelection(timeRange: start...end, lanes: lanes)
            return CommandAdapters.selectionPayload(vm)
        }

        register("timesel.clear", summary: "Clears the time selection (the objects stay selected).") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            vm.timeSelection = nil
            return CommandAdapters.selectionPayload(vm)
        }

        register("timesel.snap_probe",
                 summary: "Asks the SNAP what a time selection carried by the hand would land on, "
                        + "and touches nothing (no move, no undo, no selection change). `dt` is the "
                        + "travel the hand asks for; the answer is the travel the drag would APPLY "
                        + "(`dt`), where the guide line would stand (`guide_time`), whether it landed "
                        + "on a real mark (`on_target`, the yellow guide), which edge decided "
                        + "(`edge`: start | end | object_start | object_end) and whether the wall at "
                        + "zero stopped it (`clamped`), plus the range's bounds after the travel "
                        + "(`start`, `end`). Precedence: a real mark (an edge, a marker, a region's "
                        + "bound — the grid is NOT one) within 8 px of the range's START, or of its "
                        + "END (nearer wins, a tie goes to the start = the caret); else a real mark "
                        + "within reach of the grabbed object's edges (`grab`); else the grid, on the "
                        + "range's bounds. The range itself stops at zero, whatever objects lie later. "
                        + "Without `copy` the scraps a cut leaves at the two bounds (and the objects "
                        + "the range crosses) are kept out of the targets, as the drag does; with "
                        + "`copy` (⌥) the originals stay in place and ARE targets.",
                 params: [ParamSpec("dt", "number", "The travel the hand asks for, in seconds."),
                          ParamSpec("copy", "bool", required: false,
                                    "⌥: the range is COPIED, the originals stay and are targets "
                                  + "(default false)."),
                          ParamSpec("grab", "uuid", required: false,
                                    "The object grabbed: its edges, clipped to the range, are the "
                                  + "second-rank candidates."),
                          ParamSpec("snap", "bool", required: false,
                                    "Snap on or off for the probe (default true; ⌘ is neutralised).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            guard let sel = vm.timeSelection else {
                throw CommandError(code: .invalid_state, message: "no time selection")
            }
            let lo = sel.timeRange.lowerBound
            let hi = sel.timeRange.upperBound
            let rawDt = try p.double("dt")
            let copy = try p.bool("copy", or: false)
            var objectStart: Double? = nil
            var objectEnd: Double? = nil
            if let grab = try p.optionalUUID("grab") {
                guard let e = vm.laneEntries.first(where: { $0.item.id == grab }) else {
                    throw CommandError(code: .not_found, message: "unknown object: \(grab.uuidString)")
                }
                // What the drag's cuts at the bounds leave of it: the part inside the range.
                objectStart = max(e.absStart, lo)
                objectEnd = min(e.absStart + e.item.duration, hi)
            }
            var excluded: Set<UUID> = []
            if !copy {
                // Everything the range crosses is either carried or cut into scraps; both are kept
                // out, which is what the drag's `selectionMoveExcluded` does with the real pieces.
                let crossed = Set(vm.laneEntries.filter { e in
                    sel.lanes.contains(e.displayLane)
                        && e.absStart < hi && e.absStart + e.item.duration > lo
                }.map(\.item.id))
                excluded = vm.selectionMoveExcluded(range: sel.timeRange, lanes: sel.lanes, moved: crossed)
            }
            let snap = try p.bool("snap", or: true)
            var r = SelectionMoveSnap.Result(dt: rawDt, guideTime: lo + rawDt, onTarget: false,
                                             edge: .start, clamped: false)
            CommandAdapters.withSnapping(snap, vm) {
                r = vm.snappedSelectionMove(range: sel.timeRange, rawDt: rawDt,
                                            objectStart: objectStart, objectEnd: objectEnd,
                                            excluding: excluded)
            }
            return .object(["dt": .number(r.dt),
                            "guide_time": .number(r.guideTime),
                            "on_target": .bool(r.onTarget),
                            "edge": .string(r.edge.rawValue),
                            "clamped": .bool(r.clamped),
                            "start": .number(lo + r.dt),
                            "end": .number(hi + r.dt)])
        }

        register("selection.context_click",
                 summary: "Plays the DECISION of a right click, minus the menu itself "
                        + "(`ContextMenuPlan`, the same code the timeline's monitor runs). With `id`: "
                        + "a click on that object — `zone`: `time` (the upper half of the block) or "
                        + "`body` (the lower half, the default); `time` is the instant of the point "
                        + "(default: the middle of the object), and the point's lane is the object's "
                        + "own display lane. Without `id`: a click on an EMPTY lane — `lane` (the "
                        + "display row) and `time` are then required, and the caller states that no "
                        + "object lies under the point. Answers `layout` (`range_annotations_menu` "
                        + "when the point lies inside the time selection ON an object — the object "
                        + "marker and the comment, nothing else — `range_menu` when it lands on an "
                        + "empty lane while a time selection exists ANYWHERE, inside it or not — "
                        + "today's menu — `group_selection_menu` "
                        + "when it lands on an empty lane with NO time selection while clips (not "
                        + "consolidated instances) are selected: 'Group the selection' alone, "
                        + "`object_time_menu` | "
                        + "`object_body_menu` | `nothing`, i.e. no menu and the event goes on to the "
                        + "views), whether the click `selects_object`, whether the object marker "
                        + "(`offers_object_marker`) and the comment (`offers_comment`) are offered, "
                        + "and `applied`. With `apply` (the default) a click that selects does it "
                        + "now, exactly as the monitor does before building the menu: the time "
                        + "selection is cleared, the object becomes the selection and the cursor "
                        + "goes to its start — unless it is ALREADY selected, in which case nothing "
                        + "at all changes (the multiple selection is kept). The upper half, a click "
                        + "inside the range and a click on an empty lane never select. `apply: false` "
                        + "only asks.",
                 params: [ParamSpec("id", "uuid", required: false,
                                    "The object under the point; omit it for an empty lane."),
                          ParamSpec("zone", "string", required: false,
                                    "time | body (default body); ignored without `id`."),
                          ParamSpec("lane", "int", required: false,
                                    "The point's display row; required without `id`, ignored with it."),
                          ParamSpec("time", "number", required: false,
                                    "The point's instant in seconds (default with `id`: the object's "
                                    + "middle; required without)."),
                          ParamSpec("apply", "bool", required: false,
                                    "Perform the selection the click makes (default true).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let entry: LaneEntry?
            let zone: ContextMenuPlan.BlockZone?
            let lane: Int
            let time: Double
            if let id = try p.optionalUUID("id") {
                guard let e = vm.laneEntries.first(where: { $0.item.id == id }) else {
                    throw CommandError(code: .not_found, message: "unknown or hidden object: \(id.uuidString)")
                }
                entry = e
                switch try p.string("zone", or: "body") {
                case "time": zone = .time
                case "body": zone = .body
                default:
                    throw CommandError(code: .bad_params, message: "'zone': time or body")
                }
                lane = e.displayLane
                time = max(0, try p.optionalDouble("time") ?? (e.absStart + e.item.duration / 2))
            } else {
                entry = nil
                zone = nil
                lane = try p.int("lane")
                time = max(0, try p.double("time"))
            }
            let plan = vm.contextClickPlan(objectID: entry?.item.id, displayLane: lane,
                                           time: time, zone: zone)
            var applied = false
            if try p.bool("apply", or: true), plan.selectsObject, let entry {
                vm.selectForContextClick(entry, isPlaying: vm.isTransportPlaying,
                                         onMoveCursor: { vm.cursorPosition = max(0, $0) })
                applied = true
            }
            let layout: String
            switch plan.layout {
            case .rangeMenu: layout = "range_menu"
            case .rangeObjectMenu: layout = "range_object_menu"
            case .objectTimeMenu: layout = "object_time_menu"
            case .objectBodyMenu: layout = "object_body_menu"
            case .groupSelectionMenu: layout = "group_selection_menu"
            case .nothing: layout = "nothing"
            }
            return .object(["layout": .string(layout),
                            "selects_object": .bool(plan.selectsObject),
                            "offers_object_marker": .bool(plan.offersObjectMarker),
                            "offers_comment": .bool(plan.offersComment),
                            "applied": .bool(applied),
                            "selection": CommandAdapters.selectionPayload(vm)])
        }

        register("selection.click",
                 summary: "Plays the LEFT CLICK of the select tool on the lanes — the very code the "
                        + "timeline runs (`EditViewModel.handleLaneClick`), for a top-level object "
                        + "and for a child of an open group alike (there is ONE rule, whatever the "
                        + "depth). With `id`: a click on that object — `zone`: `time` (the upper "
                        + "half of the block) or `body` (the lower half, the default); `time` is the "
                        + "instant of the point (default: the middle of the object) and the point's "
                        + "lane is the object's own display lane. Without `id`: a click on an EMPTY "
                        + "lane — `lane` (the display row) and `time` are then required. `shift`, "
                        + "`cmd` (⌘) and `option` (⌥, with `double`) are the modifiers held. "
                        + "`double` is a double click (open/close a consolidated object, a piano "
                        + "roll, an automation band, unfold a group). On time (the upper half, or an "
                        + "empty lane) a plain click lays the caret and ⇧ / ⌘ trace or grow a time "
                        + "selection; on the BODY ⇧ extends the object selection over the "
                        + "rectangle lanes × time and ⌘ toggles the object (the cursor following "
                        + "the earliest selected start). `time` is taken LITERALLY unless `snap` is "
                        + "true (then the project's snap applies, as under the hand). Answers the "
                        + "selection.",
                 params: [ParamSpec("id", "uuid", required: false,
                                    "The object under the point; omit it for an empty lane."),
                          ParamSpec("zone", "string", required: false,
                                    "time | body (default body); ignored without `id`."),
                          ParamSpec("lane", "int", required: false,
                                    "The point's display row; required without `id`, ignored with it."),
                          ParamSpec("time", "number", required: false,
                                    "The point's instant in seconds (default with `id`: the object's "
                                  + "middle; required without)."),
                          ParamSpec("shift", "bool", required: false, "⇧ held (default false)."),
                          ParamSpec("cmd", "bool", required: false, "⌘ held (default false)."),
                          ParamSpec("option", "bool", required: false,
                                    "⌥ held (default false); only read with `double`."),
                          ParamSpec("double", "bool", required: false,
                                    "A double click (default false)."),
                          ParamSpec("snap", "bool", required: false,
                                    "Snap the instant to the grid as the hand would (default false).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let hit: LaneClickHit
            if let id = try p.optionalUUID("id") {
                guard let e = vm.laneEntries.first(where: { $0.item.id == id }) else {
                    throw CommandError(code: .not_found, message: "unknown or hidden object: \(id.uuidString)")
                }
                let zone: ContextMenuPlan.BlockZone
                switch try p.string("zone", or: "body") {
                case "time": zone = .time
                case "body": zone = .body
                default:
                    throw CommandError(code: .bad_params, message: "'zone': time or body")
                }
                hit = LaneClickHit(entry: e, zone: zone, lane: e.displayLane,
                                   time: max(0, try p.optionalDouble("time")
                                                 ?? (e.absStart + e.item.duration / 2)))
            } else {
                hit = LaneClickHit(entry: nil, zone: nil, lane: max(0, try p.int("lane")),
                                   time: max(0, try p.double("time")))
            }
            let shift = try p.bool("shift", or: false)
            let cmd = try p.bool("cmd", or: false)
            let option = try p.bool("option", or: false)
            let double = try p.bool("double", or: false)
            let snap = try p.bool("snap", or: false)
            CommandAdapters.withSnapping(snap, vm) {
                vm.handleLaneClick(hit, shift: shift, cmd: cmd, option: option,
                                   isDoubleTap: double, isPlaying: vm.isTransportPlaying,
                                   onMoveCursor: { vm.cursorPosition = max(0, $0) })
            }
            return CommandAdapters.selectionPayload(vm)
        }

        register("timesel.step_lane",
                 summary: "Slides the TIME SELECTION one displayed row up or down, keeping its span "
                        + "of time and its height — the traced passage travels, the matter does not: "
                        + "nothing changes lane and nothing sounds different (it is what the bare "
                        + "↑ / ↓ arrows do). With OBJECTS selected and no range traced, the frame "
                        + "they fill is adopted and travels instead, the objects being deselected. "
                        + "An empty row is a row like any other here. At the two ends — row 0, and "
                        + "the last row the timeline draws — nothing moves and the selection is kept.",
                 params: [ParamSpec("by", "int", "-1 = one row up, +1 = one row down.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.timeSelection != nil || vm.selectedObjectsFrame() != nil else {
                throw CommandError(code: .invalid_state, message: "no time selection and no object selected")
            }
            let moved = vm.stepTimeSelectionLanes(by: try p.int("by"))
            guard case .object(var payload) = CommandAdapters.selectionPayload(vm) else {
                return CommandAdapters.selectionPayload(vm)
            }
            // False at an end: the selection stays exactly where it was rather than being clipped.
            payload["moved"] = .bool(moved)
            return .object(payload)
        }

        register("caret.set",
                 summary: "Lays the INSERTION CARET on a display row — what a plain click in an "
                        + "empty part of the timeline does: the selections are let go of, and it is "
                        + "from there that a paste lands and that the bare arrows then walk. "
                        + "'time' moves the cursor with it, the cursor being the caret's instant.",
                 params: [ParamSpec("lane", "int", "Display row."),
                          ParamSpec("time", "number", required: false,
                                    "Instant, in seconds (default: the cursor where it is).")],
                 undo: .none) { p in
            let session = try CommandContext.shared.requireSession()
            let vm = session.viewModel
            let lane = max(0, try p.int("lane"))
            if p.raw["time"] != nil { session.seek(to: max(0, try p.double("time"))) }
            vm.clearSelection()
            vm.caretLane = lane
            // A plain click lays the ⇧-extension origin at the same point (@see the tap handler).
            vm.timeSelectionOrigin = (lane: lane, time: vm.cursorPosition)
            return CommandAdapters.selectionPayload(vm)
        }

        register("caret.step_lane",
                 summary: "Moves the INSERTION CARET one displayed row up or down — what the bare "
                        + "↑ / ↓ arrows do when NOTHING is selected, a click alone having laid a "
                        + "point of insertion. Nothing is modified and no undo is pushed. An empty "
                        + "row is a row like any other, and at the two ends — row 0, and the last "
                        + "row the timeline draws — the caret stays where it is. With a range "
                        + "traced or objects selected the arrows belong to `timesel.step_lane`, "
                        + "which is the state this command refuses.",
                 params: [ParamSpec("by", "int", "-1 = one row up, +1 = one row down.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.caretLane != nil else {
                throw CommandError(code: .invalid_state, message: "no caret laid")
            }
            guard vm.timeSelection == nil, vm.selectedIDs.isEmpty else {
                throw CommandError(code: .invalid_state,
                                   message: "a selection holds the arrows: see timesel.step_lane")
            }
            let moved = vm.stepCaretLane(by: try p.int("by"))
            guard case .object(var payload) = CommandAdapters.selectionPayload(vm) else {
                return CommandAdapters.selectionPayload(vm)
            }
            // False at an end: the caret stays exactly on the row it was on.
            payload["moved"] = .bool(moved)
            return .object(payload)
        }

        register("timesel.copy",
                 summary: "Copies the content of the time selection to the clipboard.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.timeSelection != nil else {
                throw CommandError(code: .invalid_state, message: "no time selection")
            }
            vm.copyTimeSelection()
            return .object(["copied": .int(vm.clipboard?.clips.count ?? 0)])
        }

        register("timesel.cut",
                 summary: "Cuts the content of the time selection (copy, then delete).",
                 // `deleteTimeSelection` pushes its own undo, and `cutTimeSelection` calls it.
                 undo: .handled) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.timeSelection != nil else {
                throw CommandError(code: .invalid_state, message: "no time selection")
            }
            vm.cutTimeSelection()
            return .object(["copied": .int(vm.clipboard?.clips.count ?? 0)])
        }

        register("timesel.delete",
                 summary: "Deletes the content of the time selection (without going through the clipboard).",
                 undo: .handled) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.timeSelection != nil else {
                throw CommandError(code: .invalid_state, message: "no time selection")
            }
            let before = vm.laneEntries.count
            vm.deleteTimeSelection()
            return .object(["objects_before": .int(before),
                            "objects_after": .int(vm.laneEntries.count)])
        }

        register("timesel.ripple_delete",
                 summary: "Deletes the time selection AND closes the gap: what follows slides back, "
                        + "on the SELECTED lanes only, bounded by the container (a group ripples alone, "
                        + "the outside does not move; the container's window shrinks only if every one "
                        + "of its lanes was selected).",
                 undo: .handled) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard let sel = vm.timeSelection else {
                throw CommandError(code: .invalid_state, message: "no time selection")
            }
            let container = vm.rippleContainerID(forLanes: sel.lanes)
            let before = vm.laneEntries.count
            vm.rippleDeleteTimeSelection()
            return .object(["objects_before": .int(before),
                            "objects_after": .int(vm.laneEntries.count),
                            "closed": .number(sel.timeRange.upperBound - sel.timeRange.lowerBound),
                            "container": container.map { .string($0.uuidString) } ?? .null])
        }

        register("timesel.group",
                 summary: "Groups the content of the time selection (objects that straddle it are cut).",
                 undo: .handled) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard let selection = vm.timeSelection else {
                throw CommandError(code: .invalid_state, message: "no time selection")
            }
            let before = Set(vm.laneEntries.map(\.item.id))
            vm.createGroupFromTimeSelection(selection)
            guard let groupID = vm.laneEntries.map(\.item.id)
                .first(where: { !before.contains($0) && vm.find(id: $0)?.isGroup == true }) else {
                throw CommandError(code: .invalid_state, message: "no group created")
            }
            return .object(["id": .string(groupID.uuidString)])
        }

        // MARK: clipboard

        register("clipboard.copy",
                 summary: "Copies the object selection to the clipboard.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard !vm.selectedIDs.isEmpty else {
                throw CommandError(code: .invalid_state, message: "no object selected")
            }
            vm.copySelected()
            return .object(["copied": .int(vm.clipboard?.clips.count ?? 0)])
        }

        register("clipboard.cut",
                 summary: "Cuts the object selection to the clipboard.",
                 undo: .bus) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard !vm.selectedIDs.isEmpty else {
                throw CommandError(code: .invalid_state, message: "no object selected")
            }
            vm.cutSelected()
            return .object(["cut": .int(vm.clipboard?.clips.count ?? 0)])
        }

        register("clipboard.paste",
                 summary: "Pastes the clipboard: at the time selection if there is one, at the playhead otherwise.",
                 undo: .bus) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.clipboard != nil else {
                throw CommandError(code: .invalid_state, message: "clipboard empty")
            }
            vm.paste()
            return .object(["ids": .array(vm.selectedIDs.map { .string($0.uuidString) }),
                            "count": .int(vm.selectedIDs.count)])
        }
    }
}
