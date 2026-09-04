import Foundation

// MARK: - Sound objects (reusable definitions)

/// A sound object is a subtree BAKED once (wave + sidecar in `samples/objects/`) and laid down
/// as N linked instances: editing one updates them all. The bake is ASYNCHRONOUS — the engine
/// renders the submix in the background — so every command that starts one returns a `job_id`
/// rather than lying about work that isn't finished. `job.wait` or `wait_idle` closes the loop.
///
extension CommandRegistry {

    func registerDefinitionCommands() {

        register("definition.list",
                 summary: "Sound object definitions and their instances.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            let definitions = vm.objectDefinitions.values.sorted { $0.name < $1.name }.map { def -> JSONValue in
                .object([
                    "id": .string(def.id.uuidString),
                    "name": .string(def.name),
                    "revision": .int(def.revision),
                    "was_group": .bool(def.wasGroup),
                    "wave": .string(def.wave),
                    "volume_db": .number(Double(def.volume)),
                    "pan": .number(Double(def.pan)),
                    "muted": .bool(def.isMuted),
                    // Stale = a definition this one depends on has been re-baked since.
                    // Exposing it saves a script from hearing a sound that is no longer the right one.
                    "stale": .bool(vm.isDefinitionStale(def.id)),
                    "placements": .array(vm.placementIDs(forDefinition: def.id)
                        .map { .string($0.uuidString) }),
                ])
            }
            return .object(["definitions": .array(definitions), "count": .int(definitions.count)])
        }

        register("definition.make",
                 summary: "Turns an object into a reusable sound object (asynchronous bake). Returns a job_id.",
                 params: [ParamSpec("id", "uuid", "Group or clip to share."),
                          ParamSpec("also_link", "array<uuid>", required: false,
                                    "Other objects to replace with a linked instance.")],
                 // The bake pushes its own undo when it commits (`finishMakeSharedDefinition`).
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            _ = try CommandContext.shared.requireEngine()
            let id = try p.uuid("id")
            guard let object = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            guard !object.isObjectInstance else {
                throw CommandError(code: .invalid_state, message: "already an instance of a sound object")
            }
            guard vm.objectsFolder != nil else {
                throw CommandError(code: .invalid_state,
                                   message: "save the project first (samples/objects/ is required)")
            }
            guard !vm.isBaking(id) else {
                throw CommandError(code: .invalid_state, message: "a render is already running on this object")
            }
            let alsoLink = p.raw["also_link"] == nil ? [] : try p.uuids("also_link")
            let jobID = JobRegistry.shared.begin(command: "definition.make")
            if object.isGroup {
                vm.makeObject(fromGroupID: id, alsoLinkIDs: alsoLink)
            } else {
                // A lone clip is first wrapped in a one-item group: that wrapper is what carries
                // fades and live sends on the instance.
                vm.makeObjectWrappingClip(clipID: id, alsoLinkIDs: alsoLink)
            }
            CommandAdapters.followBake(jobID, in: vm) {
                .object(["definitions": .int(vm.objectDefinitions.count)])
            }
            return .object(["job_id": .string(jobID)])
        }

        register("definition.state",
                 summary: "Sound object editing in progress (the open stack).") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            return .object([
                "editing": .bool(vm.isEditingObject),
                "definition": .stringOrNull(vm.editingDefinitionID?.uuidString),
                "placement": .stringOrNull(vm.editingPlacementID?.uuidString),
                // The stack has more than one level when a sound object is opened INSIDE another.
                "depth": .int(vm.objectEditStack.count),
            ])
        }

        register("definition.edit_begin",
                 summary: "Opens an instance for editing: its original content is restored in "
                        + "place, and the other instances become its live mirror.",
                 params: [ParamSpec("placement", "uuid", "Instance to open.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let placementID = try p.uuid("placement")
            guard let placement = vm.find(id: placementID), placement.isObjectInstance else {
                throw CommandError(code: .not_found,
                                   message: "unknown instance: \(placementID.uuidString)")
            }
            vm.openObject(viaPlacementID: placementID)
            guard vm.editingPlacementID == placementID else {
                throw CommandError(code: .invalid_state,
                                   message: "opening refused (sidecar unreadable, or a render is running)")
            }
            return .object(["placement": .string(placementID.uuidString),
                            "definition": .stringOrNull(vm.editingDefinitionID?.uuidString),
                            "depth": .int(vm.objectEditStack.count)])
        }

        register("definition.edit_commit",
                 summary: "Commits the edit in progress: re-bakes the definition and propagates it "
                        + "to every instance (asynchronous). Returns a job_id.",
                 undo: .handled) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.isEditingObject else {
                throw CommandError(code: .invalid_state, message: "no edit in progress")
            }
            let jobID = JobRegistry.shared.begin(command: "definition.edit_commit")
            vm.closeObject()
            CommandAdapters.followBake(jobID, in: vm) {
                .object(["editing": .bool(vm.isEditingObject)])
            }
            return .object(["job_id": .string(jobID)])
        }

        register("definition.edit_cancel",
                 summary: "Abandons the edit in progress and puts the instance back as it was.",
                 undo: .handled) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.isEditingObject else {
                throw CommandError(code: .invalid_state, message: "no edit in progress")
            }
            vm.cancelObjectEdit()
            return .object(["editing": .bool(vm.isEditingObject),
                            "depth": .int(vm.objectEditStack.count)])
        }

        register("definition.detach",
                 summary: "Detaches an instance: it becomes an ordinary object again, with its "
                        + "content restored, and stops following the definition.",
                 params: [ParamSpec("placement", "uuid", "Instance to detach.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let placementID = try p.uuid("placement")
            guard let placement = vm.find(id: placementID), placement.isObjectInstance else {
                throw CommandError(code: .not_found,
                                   message: "unknown instance: \(placementID.uuidString)")
            }
            vm.detachFromDefinition(placementID: placementID)
            return .object(["placement": .string(placementID.uuidString),
                            "still_linked": .bool(vm.find(id: placementID)?.isObjectInstance ?? false)])
        }
    }
}
