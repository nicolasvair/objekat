import Foundation

// MARK: - Consolidated objects (reusable definitions)

/// A consolidated object is a subtree BAKED once (wave + sidecar in `samples/consolidate/`, or the
/// legacy `samples/objects/` for a project from before the rename) and laid down
/// as N linked instances: editing one updates them all. The bake is ASYNCHRONOUS — the engine
/// renders the submix in the background — so every command that starts one returns a `job_id`
/// rather than lying about work that isn't finished. `job.wait` or `wait_idle` closes the loop.
///
extension CommandRegistry {

    func registerConsolidateCommands() {

        register("consolidate.list",
                 summary: "Consolidated object definitions and their instances.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            // Sorted by name, then by id: two definitions routinely share a name (every clip
            // consolidated from `bip.wav` is called "bip.wav"), and the registry is a dictionary —
            // without the tie-break two identical reads could list them in different orders.
            let definitions = vm.consolidateDefinitions.values.sorted {
                ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString)
            }.map { def -> JSONValue in
                .object([
                    "id": .string(def.id.uuidString),
                    "name": .string(def.name),
                    "revision": .int(def.revision),
                    "was_group": .bool(def.wasGroup),
                    "wave": .string(def.wave),
                    // Stale = a definition this one depends on has been re-baked since.
                    // Exposing it saves a script from hearing a sound that is no longer the right one.
                    "stale": .bool(vm.isConsolidateStale(def.id)),
                    "placements": .array(vm.placementIDs(forConsolidate: def.id)
                        .map { .string($0.uuidString) }),
                ])
            }
            return .object(["definitions": .array(definitions), "count": .int(definitions.count)])
        }

        register("consolidate.make",
                 summary: "Turns an object into a reusable consolidated object (asynchronous bake). Returns a job_id.",
                 params: [ParamSpec("id", "uuid", "Group or clip to share."),
                          ParamSpec("also_link", "array<uuid>", required: false,
                                    "Other objects to replace with a linked instance."),
                          ParamSpec("mid_chain_sends", "string", required: false,
                                    "What to do with the sends that tap INSIDE the chain being baked "
                                  + "(`input` or `chain` position; `post_fader` is not concerned): "
                                  + "`refuse` (default) fails with invalid_state and "
                                  + "lists them, nothing changed; `fold` puts them back to post-fader; "
                                  + "`remove` deletes them. Both other choices are one undo point of "
                                  + "their own, taken before the bake. A `pre_fader` send is NOT a "
                                  + "choice: whatever this parameter says, an object that carries one "
                                  + "is refused (invalid_state, nothing changed), for now.")],
                 // The bake pushes its own undo when it commits (`finishConsolidate`).
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            _ = try CommandContext.shared.requireEngine()
            let id = try p.uuid("id")
            guard let object = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            guard !object.isConsolidateInstance else {
                throw CommandError(code: .invalid_state, message: "already an instance of a consolidated object")
            }
            guard vm.consolidateFolder != nil else {
                throw CommandError(code: .invalid_state,
                                   message: "save the project first (samples/consolidate/ is required)")
            }
            guard !vm.isBaking(id) else {
                throw CommandError(code: .invalid_state, message: "a render is already running on this object")
            }
            let alsoLink = p.raw["also_link"] == nil ? [] : try p.uuids("also_link")
            // The sends that tap inside the chain (docs/plan_sends_rework.md, Q-U6): no alert is ever
            // possible from here, so the caller says what to do, and the safe default is to refuse.
            let policyName = try p.string("mid_chain_sends", or: SendBakePolicy.Choice.refuse.rawValue)
            guard let policy = SendBakePolicy.Choice(rawValue: policyName) else {
                throw CommandError(code: .bad_params,
                                   message: "mid_chain_sends: refuse, fold or remove (got '\(policyName)')")
            }
            // A pre-fader send forbids the bake whatever `mid_chain_sends` says (decided 10 Oct 2026,
            // "for the moment"); it comes first when the object has both kinds.
            let blockers = vm.preFaderBlockers(of: [id] + alsoLink)
            if !blockers.isEmpty {
                throw CommandError(
                    code: .invalid_state,
                    message: "pre_fader_send: consolidation is not possible for now, \(blockers.count) send(s) "
                           + "tap before the fader (the bake renders the fader into the wave); move them to "
                           + "post_fader or delete them first",
                    details: .array(blockers.map { b in
                        .object(["object": .string(b.objectID.uuidString),
                                 "aux": .string(b.auxID.uuidString),
                                 "position": .string(b.position.name)])
                    }))
            }
            let concerned = vm.midChainSends(of: [id] + alsoLink)
            if policy == .refuse, !concerned.isEmpty {
                throw CommandError(
                    code: .invalid_state,
                    message: "mid_chain_sends: \(concerned.count) send(s) tap inside the chain that the bake "
                           + "would destroy; pass mid_chain_sends = fold or remove, or move them first",
                    details: .array(concerned.map { c in
                        .object(["object": .string(c.objectID.uuidString),
                                 "aux": .string(c.auxID.uuidString),
                                 "position": .string(c.position.name)])
                    }))
            }
            let jobID = JobRegistry.shared.begin(command: "consolidate.make")
            if object.isGroup {
                vm.consolidate(groupID: id, alsoLinkIDs: alsoLink, midChainSends: policy)
            } else {
                // A lone clip is first wrapped in a one-item group: that wrapper is what carries
                // fades and live sends on the instance.
                vm.consolidateWrappingClip(clipID: id, alsoLinkIDs: alsoLink, midChainSends: policy)
            }
            CommandAdapters.followBake(jobID, in: vm) {
                .object(["definitions": .int(vm.consolidateDefinitions.count)])
            }
            return .object(["job_id": .string(jobID)])
        }

        register("consolidate.state",
                 summary: "Consolidated object editing in progress (the open stack), and the "
                        + "consolidated renders running with their progress (0…1).") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            // The consolidated renders running, each with the fraction its filling circle SHOWS
            // (@see RenderProgressStore) — the store the circles read, not a second reading of
            // the engine, so what a script asserts is what the eye would see. `progress` is null
            // until the engine's first answer for that render. A bake names the OBJECT wearing the
            // veil; an automatic re-bake names the DEFINITION, whose instances all fill in step.
            func progress(_ key: UUID) -> JSONValue {
                guard let f = vm.renderProgress.fraction(for: key) else { return .null }
                return .number(f)
            }
            let bakes: [JSONValue] = vm.bakingIDs.sorted { $0.uuidString < $1.uuidString }.map { id in
                .object(["kind": .string("bake"), "object": .string(id.uuidString),
                         "progress": progress(id)])
            }
            let rebakes: [JSONValue] = vm.recomputingConsolidateIDs.sorted { $0.uuidString < $1.uuidString }.map { defID in
                .object(["kind": .string("rebake"), "definition": .string(defID.uuidString),
                         "progress": progress(defID)])
            }
            return .object([
                "editing": .bool(vm.isEditingConsolidate),
                "definition": .stringOrNull(vm.editingConsolidateID?.uuidString),
                "placement": .stringOrNull(vm.editingPlacementID?.uuidString),
                // The stack has more than one level when a consolidated object is opened INSIDE another.
                "depth": .int(vm.consolidateEditStack.count),
                "renders": .array(bakes + rebakes),
            ])
        }

        register("consolidate.edit_begin",
                 summary: "Opens an instance for editing: its original content is restored in "
                        + "place, and the other instances become its live mirror.",
                 params: [ParamSpec("placement", "uuid", "Instance to open.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let placementID = try p.uuid("placement")
            guard let placement = vm.find(id: placementID), placement.isConsolidateInstance else {
                throw CommandError(code: .not_found,
                                   message: "unknown instance: \(placementID.uuidString)")
            }
            vm.openConsolidate(viaPlacementID: placementID)
            guard vm.editingPlacementID == placementID else {
                throw CommandError(code: .invalid_state,
                                   message: "opening refused (sidecar unreadable, or a render is running)")
            }
            return .object(["placement": .string(placementID.uuidString),
                            "definition": .stringOrNull(vm.editingConsolidateID?.uuidString),
                            "depth": .int(vm.consolidateEditStack.count)])
        }

        register("consolidate.edit_commit",
                 summary: "Commits the edit in progress: re-bakes the definition and propagates it "
                        + "to every instance (asynchronous). Returns a job_id.",
                 undo: .handled) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.isEditingConsolidate else {
                throw CommandError(code: .invalid_state, message: "no edit in progress")
            }
            let jobID = JobRegistry.shared.begin(command: "consolidate.edit_commit")
            vm.closeConsolidate()
            CommandAdapters.followBake(jobID, in: vm) {
                .object(["editing": .bool(vm.isEditingConsolidate)])
            }
            return .object(["job_id": .string(jobID)])
        }

        register("consolidate.edit_cancel",
                 summary: "Abandons the edit in progress and puts the instance back as it was.",
                 undo: .handled) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.isEditingConsolidate else {
                throw CommandError(code: .invalid_state, message: "no edit in progress")
            }
            vm.cancelConsolidateEdit()
            return .object(["editing": .bool(vm.isEditingConsolidate),
                            "depth": .int(vm.consolidateEditStack.count)])
        }

        register("consolidate.unmake",
                 summary: "Detaches an instance: it becomes an ordinary object again, with its "
                        + "content restored, and stops following the definition.",
                 params: [ParamSpec("placement", "uuid", "Instance to detach.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let placementID = try p.uuid("placement")
            guard let placement = vm.find(id: placementID), placement.isConsolidateInstance else {
                throw CommandError(code: .not_found,
                                   message: "unknown instance: \(placementID.uuidString)")
            }
            vm.deconsolidate(placementID: placementID)
            return .object(["placement": .string(placementID.uuidString),
                            "still_linked": .bool(vm.find(id: placementID)?.isConsolidateInstance ?? false)])
        }

        // MARK: - Hidden aliases (@see plan_consolidate.md, décision Q1)
        //
        // The family was `definition.*` before this rename; every script written against it keeps
        // working, transparently, through `execute`. Absent from bare `help`'s listing — a script
        // discovering the API fresh should only ever be offered the new names.
        registerAlias("definition.list", for: "consolidate.list")
        registerAlias("definition.make", for: "consolidate.make")
        registerAlias("definition.state", for: "consolidate.state")
        registerAlias("definition.edit_begin", for: "consolidate.edit_begin")
        registerAlias("definition.edit_commit", for: "consolidate.edit_commit")
        registerAlias("definition.edit_cancel", for: "consolidate.edit_cancel")
        registerAlias("definition.detach", for: "consolidate.unmake")
    }
}
