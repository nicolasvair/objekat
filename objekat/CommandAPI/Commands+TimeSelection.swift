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
                                    "First lane when using 'lane_count' (default 0).")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let start = max(0, try p.double("start"))
            let end = try p.double("end")
            guard end > start else {
                throw CommandError(code: .bad_params, message: "'end' must come after 'start'")
            }
            var lanes = Set<Int>()
            if p.raw["lanes"] != nil {
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
                        + "bounded by the container (a group ripples alone, the outside does not move).",
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
