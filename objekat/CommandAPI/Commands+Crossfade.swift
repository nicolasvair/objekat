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
            switch vm.openCrossfade(leftID: pair.left, rightID: pair.right,
                                    width: width, idealStart: idealStart, pin: pin) {
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
    }
}
