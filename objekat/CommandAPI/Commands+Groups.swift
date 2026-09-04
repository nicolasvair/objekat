import Foundation

// MARK: - Groups

/// A group is not a filing folder: it is a CONTAINER with its own window, its own stem and
/// its own engine submix. Hence commands that all go through the view-model's methods rather
/// than rebuilding `kind = .group(...)` by hand — rebuilding the graph (`syncAddGroup`,
/// `resyncAllSends`) is inseparable from the gesture.
extension CommandRegistry {

    func registerGroupCommands() {

        register("group.create",
                 summary: "Groups objects (default: the current selection). A subgroup if every "
                        + "member shares the same parent, a root group otherwise.",
                 params: [ParamSpec("ids", "array<uuid>", required: false,
                                    "Objects to group; default = current selection.")],
                 // `createGroupFromSelection` delegates to `createGroup`, which pushes its own undo.
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let ids: Set<UUID>
            if p.raw["ids"] != nil {
                ids = Set(try CommandAdapters.existingIDs(try p.uuids("ids"), in: vm))
            } else {
                ids = vm.effectiveSelectedIDs
            }
            guard !ids.isEmpty else {
                throw CommandError(code: .invalid_state, message: "no object to group")
            }
            // The only reliable way to name the group just created: compare the identifiers before
            // and after. `createGroup(from:in:)` does leave the selection on the new group, but the
            // root variant does not — so it cannot be relied on.
            let before = Set(vm.laneEntries.map(\.item.id))
            vm.createGroupFromSelection(ids)
            let created = vm.laneEntries.map(\.item.id).filter { !before.contains($0) }
            guard let groupID = created.first(where: { vm.find(id: $0)?.isGroup == true }) else {
                throw CommandError(code: .invalid_state, message: "no group created")
            }
            return .object(["id": .string(groupID.uuidString),
                            "members": .int(ids.count)])
        }

        register("group.disband",
                 summary: "Ungroups: the children move up to the group's own level.",
                 params: [ParamSpec("id", "uuid", "Group to ungroup.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let group = vm.find(id: id), case .group(let children, _) = group.kind else {
                throw CommandError(code: .not_found, message: "unknown group: \(id.uuidString)")
            }
            guard !vm.isBaking(id) else {
                throw CommandError(code: .invalid_state,
                                   message: "a render is running on this group — wait for it (wait_idle)")
            }
            let childCount = children.count
            vm.disbandGroup(id: id)
            return .object(["released": .int(childCount)])
        }

        register("group.expand",
                 summary: "Opens or closes a group (showing its content inline).",
                 params: [ParamSpec("id", "uuid", "Target group."),
                          ParamSpec("expanded", "bool", required: false,
                                    "Wanted state; absent = toggle.")],
                 // The interface doesn't make opening undoable (`toggleGroupExpansion` pushes no undo):
                 // driving it from a script must not turn it into an editing gesture either.
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard vm.find(id: id)?.isGroup == true else {
                throw CommandError(code: .not_found, message: "unknown group: \(id.uuidString)")
            }
            let wanted = try p.bool("expanded", or: !vm.isGroupExpanded(id))
            if vm.isGroupExpanded(id) != wanted { vm.toggleGroupExpansion(id: id) }
            return .object(["id": .string(id.uuidString),
                            "expanded": .bool(vm.isGroupExpanded(id))])
        }

        register("group.reparent",
                 summary: "Moves objects into a group, at their current position.",
                 params: [ParamSpec("ids", "array<uuid>", "Objects to move in."),
                          ParamSpec("group", "uuid", "Receiving group."),
                          ParamSpec("child_lane", "int", required: false,
                                    "Sub-lane to land on inside the group (default 0).")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let ids = Set(try CommandAdapters.existingIDs(try p.uuids("ids"), in: vm))
            let groupID = try p.uuid("group")
            guard vm.find(id: groupID)?.isGroup == true else {
                throw CommandError(code: .not_found, message: "unknown group: \(groupID.uuidString)")
            }
            guard let grabbed = ids.first else {
                throw CommandError(code: .bad_params, message: "'ids' cannot be empty")
            }
            let childLane = max(0, try p.int("child_lane", or: 0))
            // `dt = 0` and anchors taken from the CURRENT positions: that is exactly the drag
            // "dropped without moving". The method stays the sole owner of recomputing relative
            // lanes, of re-wiring the engine and of the cycle guard.
            let anchors = CommandAdapters.currentAnchors(ids, in: vm)
            if let sourceGroup = vm.parentGroup(for: grabbed) {
                vm.reparentChildBetweenGroups(childIDs: ids, sourceGroupID: sourceGroup.id,
                                              targetGroupID: groupID, anchors: anchors,
                                              grabbedID: grabbed, grabbedChildLane: childLane, dt: 0)
            } else {
                vm.reparentToGroup(clipIDs: ids, groupID: groupID, anchors: anchors,
                                   grabbedID: grabbed, grabbedChildLane: childLane, dt: 0)
            }
            return .object(["group": .string(groupID.uuidString),
                            "moved": .int(ids.count)])
        }

        register("group.eject",
                 summary: "Moves children out of their group, up to the root level.",
                 params: [ParamSpec("ids", "array<uuid>", "Children to move out."),
                          ParamSpec("lane", "int", required: false,
                                    "Root lane to land on (default: the group's lane).")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let ids = Set(try p.uuids("ids"))
            guard let grabbed = ids.first else {
                throw CommandError(code: .bad_params, message: "'ids' cannot be empty")
            }
            guard let group = vm.parentGroup(for: grabbed) else {
                throw CommandError(code: .invalid_state,
                                   message: "object already at root level: \(grabbed.uuidString)")
            }
            let lane = max(0, try p.int("lane", or: group.lane))
            let anchors = CommandAdapters.currentAnchors(ids, in: vm)
            vm.ejectFromGroup(childIDs: ids, groupID: group.id, anchors: anchors,
                              grabbedID: grabbed, dt: 0, baseLane: lane)
            return .object(["from_group": .string(group.id.uuidString),
                            "ejected": .int(ids.count)])
        }
    }
}
