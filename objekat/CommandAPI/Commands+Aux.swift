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
                 summary: "Sends leaving an object: level, on/off, and what is actually wired.",
                 params: [ParamSpec("id", "uuid", "Sending object.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let object = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            let sends = object.sends.map { send -> JSONValue in
                .object(["aux": .string(send.auxID.uuidString),
                         "level_db": .number(Double(send.levelDb)),
                         "enabled": .bool(send.enabled),
                         // `routed` = what the engine ACTUALLY wires. Different from `enabled`: a send that is
                         // out of scope (another stem, another container) stays in the model and makes no
                         // sound.
                         "routed": .bool(vm.isSendRouted(from: id, to: send.auxID))])
            }
            return .object(["id": .string(id.uuidString),
                            "sends": .array(sends),
                            // What this object CAN send to, scope included.
                            "available_auxes": .array(vm.sendToolAuxes(for: id).map {
                                .string($0.id.uuidString)
                            })])
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
                            "routed": .bool(vm.isSendRouted(from: id, to: auxID))])
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
                            "routed": .bool(vm.isSendRouted(from: id, to: auxID))])
        }
    }
}
