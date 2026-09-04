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
