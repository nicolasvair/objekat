import Foundation

// MARK: - Auxes and sends

/// An aux is a timeline object like any other: it has a window, a lane, a stem. A send is
/// only wired up if the sender sits upstream of the level where the engine brings the aux
/// return back in (`canRouteSend`) — which is why these commands always return `routed`
/// next to `enabled`: a send can be asked for and stay silent, and the script must see it.
extension CommandRegistry {

    func registerAuxCommands() {

        register("aux.create",
                 summary: "Creates an aux over a time window and a lane.",
                 params: [ParamSpec("start", "number", "Start, in seconds."),
                          ParamSpec("end", "number", "End, in seconds."),
                          ParamSpec("lane", "int", required: false, "Display lane (default 0).")],
                 // `createAuxFromTimeSelection` pushes its own undo.
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let start = max(0, try p.double("start"))
            let end = try p.double("end")
            guard end > start else {
                throw CommandError(code: .bad_params, message: "'end' must come after 'start'")
            }
            let lane = max(0, try p.int("lane", or: 0))
            // We go through the SAME door as the interface: a time selection. It is what decides
            // whether the target lane falls inside an open group (the aux is then born in it).
            let selection = TimeSelection(timeRange: start...end, lanes: [lane])
            let before = Set(vm.laneEntries.map(\.item.id))
            vm.createAuxFromTimeSelection(selection)
            guard let auxID = vm.laneEntries.map(\.item.id)
                .first(where: { !before.contains($0) && vm.find(id: $0)?.isAux == true }) else {
                throw CommandError(code: .invalid_state, message: "no aux created")
            }
            return .object(["id": .string(auxID.uuidString),
                            "start": .number(start), "end": .number(end)])
        }

        register("aux.list",
                 summary: "Every aux in the project, with its active senders.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            let auxes = vm.allAuxes.map { aux -> JSONValue in
                .object(["id": .string(aux.id.uuidString),
                         "name": .string(aux.displayName),
                         "start": .number(aux.startTime),
                         "duration": .number(aux.duration),
                         "lane": .int(aux.lane),
                         "senders": .array(vm.activeSenders(toAux: aux.id).map { .string($0.uuidString) })])
            }
            return .object(["auxes": .array(auxes), "count": .int(auxes.count)])
        }

        register("send.list",
                 summary: "Sends leaving an object: level, on/off, and what the bridge actually lays.",
                 params: [ParamSpec("id", "uuid", "Sending object.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let object = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            // Computed NOW from the model: an answer must not depend on whether the coalesced bridge
            // sync has run yet (a scheduling loop is only known to the plan).
            let live = vm.sendStatusNow()
            let sends = object.sends.map { send -> JSONValue in
                let status = vm.sendStatus(from: id, to: send.auxID, using: live)
                var refusal: JSONValue = .null
                var statusName = "off"
                switch status {
                case .off:              statusName = "off"
                case .active:           statusName = "active"
                case .refused(let why): statusName = "refused"; refusal = .string(why.rawValue)
                }
                return .object(["aux": .string(send.auxID.uuidString),
                         "level_db": .number(Double(send.levelDb)),
                         "enabled": .bool(send.enabled),
                         // `routed` = what the plan ACTUALLY lays: alive AND accepted. Different from
                         // `enabled`: a send that is refused (another stem, a scheduling loop) stays in
                         // the model and makes no sound — `status` and `refusal` say which and why.
                         "routed": .bool(status == .active),
                         "status": .string(statusName),
                         "refusal": refusal,
                         // A CURVE drives the level: `level_db` is still what is written, but it is
                         // no longer what is heard, and no gesture of the hand may change it
                         // (@see EditViewModel.selectedSendersWithFreeLevel). Here so that the lock
                         // can be asserted with no screen.
                         "automated": .bool(vm.isAutomated(.send(auxID: send.auxID), on: id))])
            }
            return .object(["id": .string(id.uuidString),
                            "sends": .array(sends),
                            // What this object CAN send to by the static rule (any time, any depth)...
                            "reachable_auxes": .array(vm.allAuxes.filter { vm.canRouteSend(from: id, to: $0.id) }
                                                        .map { .string($0.id.uuidString) }),
                            // ...and what the tools OFFER: the reachable ones that overlap it in time.
                            "available_auxes": .array(vm.sendToolAuxes(for: id).map {
                                .string($0.id.uuidString)
                            })])
        }

        register("send.candidates",
                 summary: "Every aux in the project as seen from a sender: the plan's verdict "
                        + "(`refusal` null = a send would be accepted; else why: outOfStem, hostNotAux, "
                        + "ancestorSource, cycle…), whether it overlaps the sender in time, its group path "
                        + "and stem.",
                 params: [ParamSpec("id", "uuid", "Sending object.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let sender = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            let auxes = vm.allAuxes
            let refusals = vm.sendRefusals(from: id, among: Set(auxes.map(\.id)))
            let rows = auxes.map { aux -> JSONValue in
                var path: [JSONValue] = []
                var cursor = aux.id
                while let g = vm.parentGroup(for: cursor) { path.insert(.string(g.displayName), at: 0); cursor = g.id }
                let stemID = aux.stemID ?? vm.mainStemID
                let stemName = vm.stems.first { $0.id == stemID }.map { $0.id == vm.mainStemID ? "Main" : $0.name } ?? "Main"
                return .object(["aux": .string(aux.id.uuidString),
                                "name": .string(aux.displayName),
                                "group_path": .array(path),
                                "stem": .string(stemName),
                                "overlaps": .bool(aux.isInfiniteBus
                                                  || (aux.startTime < sender.startTime + sender.duration
                                                      && aux.startTime + aux.duration > sender.startTime)),
                                "refusal": refusals[aux.id].map { .string($0.rawValue) } ?? .null])
            }
            return .object(["id": .string(id.uuidString), "candidates": .array(rows)])
        }

        register("send.remove",
                 summary: "Deletes a send entry (and the automation lane aimed at it). There was no "
                        + "other way to take an entry out of the model.",
                 params: [ParamSpec("id", "uuid", "Sending object."),
                          ParamSpec("aux", "uuid", "Receiving aux.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            let auxID = try p.uuid("aux")
            guard let object = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            guard object.sends.contains(where: { $0.auxID == auxID }) else {
                throw CommandError(code: .not_found, message: "no send from \(id.uuidString) to \(auxID.uuidString)")
            }
            vm.removeSend(from: id, to: auxID)
            return .object(["id": .string(id.uuidString), "aux": .string(auxID.uuidString), "removed": .bool(true)])
        }

        register("send.set_level",
                 summary: "Sets (or creates) the level of a send towards an aux.",
                 params: [ParamSpec("id", "uuid", "Sending object."),
                          ParamSpec("aux", "uuid", "Receiving aux."),
                          ParamSpec("db", "number", "Level, in dB.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            let auxID = try p.uuid("aux")
            try CommandAdapters.checkSendPair(id, auxID, in: vm)
            vm.setSendLevel(from: id, to: auxID, levelDb: Float(try p.double("db")))
            return .object(["id": .string(id.uuidString),
                            "aux": .string(auxID.uuidString),
                            "level_db": .number(Double(vm.sendLevel(from: id, to: auxID))),
                            "routed": .bool(vm.sendStatus(from: id, to: auxID, using: vm.sendStatusNow()) == .active)])
        }

        register("send.adjust_level",
                 summary: "Moves the send level BY a delta over the SELECTION — the path the "
                        + "hand's gestures take (the Send tool's knob, the wheel, the inspector's "
                        + "box). A send whose level carries an automation CURVE is left alone: "
                        + "the curve is what is heard, and a knob that answered would be changing "
                        + "nothing (see `automated` in send.list). Absolute setting, and exact "
                        + "even under a curve, since it is the machine's door: send.set_level.",
                 params: [ParamSpec("aux", "uuid", "Receiving aux."),
                          ParamSpec("db", "number", "Travel in dB, added to each current level."),
                          ParamSpec("ids", "array<uuid>", required: false,
                                    "Sending objects; default = current selection.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let auxID = try p.uuid("aux")
            guard let aux = vm.find(id: auxID), aux.isAux else {
                throw CommandError(code: .bad_params,
                                   message: "not an aux: \(auxID.uuidString)")
            }
            // The selection is what the selection-level setter reads, exactly as the hand leaves
            // it: `ids` merely lays it down first.
            if p.raw["ids"] != nil {
                vm.selectIDs(Set(try CommandAdapters.existingIDs(try p.uuids("ids"), in: vm)))
            }
            let touched = vm.selectedSendersWithFreeLevel(toAux: auxID)
            vm.adjustSendLevelSelected(toAux: auxID, deltaDb: Float(try p.double("db")))
            return .object(["aux": .string(auxID.uuidString),
                            "count": .int(touched.count),
                            "moved": .array(touched.map { .string($0.uuidString) }),
                            // Those the curve holds: named rather than merely absent, so a script
                            // can tell 'out of scope' from 'locked by an automation'.
                            "locked": .array(vm.selectedSenders(toAux: auxID)
                                               .filter { !touched.contains($0) }
                                               .map { .string($0.uuidString) })])
        }

        register("send.enable",
                 summary: "Turns a send on or off (without losing its level).",
                 params: [ParamSpec("id", "uuid", "Sending object."),
                          ParamSpec("aux", "uuid", "Receiving aux."),
                          ParamSpec("enabled", "bool", "true = send active.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            let auxID = try p.uuid("aux")
            try CommandAdapters.checkSendPair(id, auxID, in: vm)
            vm.setSendEnabled(from: id, to: auxID, enabled: try p.bool("enabled"))
            return .object(["id": .string(id.uuidString),
                            "aux": .string(auxID.uuidString),
                            "enabled": .bool(vm.isSendEnabled(from: id, to: auxID)),
                            "routed": .bool(vm.sendStatus(from: id, to: auxID, using: vm.sendStatusNow()) == .active)])
        }

        #if DEBUG
        register("debug.selection_send_scope",
                 summary: """
                 DEBUG. The ORACLE of the multiple selection's caches: for the LIVE selection, \
                 puts the cached path (`parentIDMap`, `allAuxes`, `sendScope(forSenders:)`, \
                 `multiSelectionSnapshot`: what the inspector reads) next to the reference it \
                 replaced (a plain tree walk, no cache — `_reference…`), and answers every \
                 disagreement in `mismatches` (empty = agreement, `ok: true`). Call it after any \
                 mutation that has to invalidate a cache; it changes nothing. `parent_sample` \
                 bounds how many objects have their `parentGroup(for:)` compared with the walk \
                 (default 400; the selected ones are always compared). `new_ms` / `reference_ms` \
                 are the two costs. Not present in Release builds.
                 """,
                 params: [ParamSpec("parent_sample", "int", required: false,
                                    "How many objects to compare parent lookups on (default 400).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let r = vm._selectionSendScopeAudit(parentSample: max(1, try p.int("parent_sample", or: 400)))
            var out: [String: JSONValue] = ["ok": .bool(r.mismatches.isEmpty),
                                            "mismatches": .array(r.mismatches.prefix(20).map { .string($0) }),
                                            "mismatch_count": .int(r.mismatches.count),
                                            "new_ms": .number(r.newMs),
                                            "reference_ms": .number(r.referenceMs)]
            for (k, v) in r.info { out[k] = .int(v) }
            return .object(out)
        }
        #endif
    }
}
