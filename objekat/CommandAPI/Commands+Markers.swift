import Foundation

// MARK: - Markers, regions, comments

/// Everything this family touches is PURELY VISUAL: it names moments and lays down text, and not
/// one command here changes a sample of what is heard. That is worth stating in the machine
/// contract too, because a script that has just moved a region and hears no difference should not
/// go looking for the bug.
///
/// TWO FRAMES OF REFERENCE, and it is this family's one real trap. A marker on a ROW of the band
/// carries an ABSOLUTE time; a marker carried by an OBJECT carries a time RELATIVE to that object's
/// start — exactly like its automation points, and for the same reason: the object then moves for
/// free. `object.list_markers` returns BOTH readings so that a caller never has to do the sum
/// itself.
///
/// A region is a marker that has an end: one type, `duration` 0 = a point, > 0 = a span. There is
/// no `region.*` family, and that is deliberate rather than missing.
extension CommandRegistry {

    func registerMarkerCommands() {

        /// `color_index` is null when the mark takes the colour of what carries it — the ROW for a
        /// mark of the band, white for one carried by an object. Null is not 'no colour': it is
        /// 'the one I inherit', which is what nearly every mark wants (@see Marker.colorIndex).
        func markerPayload(_ m: Marker) -> JSONValue {
            .object(["id": .string(m.id.uuidString),
                     "time": .number(m.time),
                     "duration": .number(m.duration),
                     "is_region": .bool(m.isRegion),
                     "name": .string(m.name),
                     "color_index": m.colorIndex.map(JSONValue.int) ?? .null])
        }

        func lanePayload(_ l: MarkerLane) -> JSONValue {
            .object(["id": .string(l.id.uuidString),
                     "name": .string(l.name),
                     "color_index": .int(l.colorIndex),
                     "visible": .bool(l.isVisible),
                     "count": .int(l.markers.count),
                     "markers": .array(l.sortedMarkers.map(markerPayload))])
        }

        func commentPayload(_ c: TimelineComment, _ vm: EditViewModel) -> JSONValue {
            let dl = vm.displayLane(forBase: c.lane, inParent: c.parentID)
            return .object(["id": .string(c.id.uuidString),
                     // `start` / `end` are the STORED values, in the comment's own frame: absolute
                     // for a comment of the timeline, relative to its group when it has one.
                     // `abs_start` / `abs_end` are always in edit seconds.
                     "start": .number(c.startTime),
                     "duration": .number(c.duration),
                     "end": .number(c.endTime),
                     "abs_start": .number(vm.commentAbsStart(c)),
                     "abs_end": .number(vm.commentAbsStart(c) + c.duration),
                     // The group it lives in, null for the timeline (@see TimelineComment.parentID).
                     "parent": c.parentID.map { JSONValue.string($0.uuidString) } ?? .null,
                     "lane": .int(c.lane),
                     // The BASE row is what is stored; `display_lane` is where it is actually drawn
                     // once the open groups and piano rolls above it have taken their rows. The two
                     // differ as soon as something is unfolded above — and a comment that did not
                     // follow would be a note left beside the wrong lane. NULL when the comment is
                     // not on screen at all: its group is folded, so it has no row.
                     "display_lane": dl.map(JSONValue.int) ?? .null,
                     "text": .string(c.text),
                     "color_index": c.colorIndex.map(JSONValue.int) ?? .null])
        }

        /// A row named outright, or the one a creation with no row lands on. Refusing an unknown id
        /// rather than falling back on the default row: a script that mistypes a uuid must be told,
        /// not quietly served something else.
        func requireLane(_ p: CommandParams, _ vm: EditViewModel) throws -> UUID {
            guard p.raw["lane"] != nil else { return vm.ensureMarkerLane() }
            let id = try p.uuid("lane")
            guard vm.markerLane(id: id) != nil else {
                throw CommandError(code: .not_found, message: "unknown marker lane: \(id.uuidString)")
            }
            return id
        }

        // MARK: Rows of the band

        register("marker_lane.create",
                 summary: "Adds a row to the marker band. A row is a named layer one can show or "
                        + "hide, holding markers AND regions: several readings of one project can "
                        + "then coexist without fighting for the same strip of screen.",
                 params: [ParamSpec("name", "string", required: false, "Its name. Default: numbered."),
                          ParamSpec("color_index", "int", required: false,
                                    "A hue from the object palette (0…15). Default: the next one along.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let name = p.raw["name"] != nil ? try p.string("name") : nil
            let color = p.raw["color_index"] != nil ? try p.int("color_index") : nil
            let id = vm.addMarkerLane(name: name, colorIndex: color)
            return .object(["lane": .string(id.uuidString)])
        }

        register("marker_lane.list",
                 summary: "Every row of the band and everything on it, markers and regions "
                        + "together, in reading order. Times are ABSOLUTE here.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            return .object(["count": .int(vm.markerLanes.count),
                            "lanes": .array(vm.markerLanes.map(lanePayload))])
        }

        register("marker_lane.rename",
                 summary: "Renames a row.",
                 params: [ParamSpec("lane", "uuid", "The row."),
                          ParamSpec("name", "string", "Its new name.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("lane")
            guard vm.renameMarkerLane(id: id, to: try p.string("name")) else {
                throw CommandError(code: .not_found, message: "unknown marker lane: \(id.uuidString)")
            }
            return .object(["lane": .string(id.uuidString)])
        }

        register("marker_lane.set_visible",
                 summary: "Shows or hides a row. NOT a deletion: the content stays, only the "
                        + "band's height changes.",
                 params: [ParamSpec("lane", "uuid", "The row."),
                          ParamSpec("visible", "bool", "true = shown.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("lane")
            guard vm.setMarkerLaneVisible(id: id, try p.bool("visible")) else {
                throw CommandError(code: .not_found, message: "unknown marker lane: \(id.uuidString)")
            }
            return .object(["lane": .string(id.uuidString),
                            "visible": .bool(vm.markerLane(id: id)?.isVisible ?? false)])
        }

        register("marker_lane.set_color",
                 summary: "The row's hue — and therefore the DEFAULT of every mark on it. A mark "
                        + "given a colour of its own keeps it: that is what asking for one means.",
                 params: [ParamSpec("lane", "uuid", "The row."),
                          ParamSpec("color_index", "int", "A hue from the object palette (0…15).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("lane")
            guard vm.setMarkerLaneColor(id: id, colorIndex: try p.int("color_index")) else {
                throw CommandError(code: .not_found, message: "unknown marker lane: \(id.uuidString)")
            }
            return .object(["lane": .string(id.uuidString),
                            "color_index": .int(vm.markerLane(id: id)?.colorIndex ?? 0)])
        }

        register("marker_lane.remove",
                 summary: "Deletes a row AND everything on it. To give its pixels back without "
                        + "losing its content, `marker_lane.set_visible` is the one.",
                 params: [ParamSpec("lane", "uuid", "The row.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("lane")
            guard vm.removeMarkerLane(id: id) else {
                throw CommandError(code: .not_found, message: "unknown marker lane: \(id.uuidString)")
            }
            return .object(["removed": .string(id.uuidString)])
        }

        // MARK: Markers and regions of the band

        register("marker.add",
                 summary: "Lays a marker on a row — a region as soon as `duration` is greater than "
                        + "zero. Time ABSOLUTE, in seconds. With no `lane`, it lands on the first "
                        + "visible row, and one is created if the band is empty.",
                 params: [ParamSpec("at", "number", "Where, in seconds."),
                          ParamSpec("lane", "uuid", required: false, "Which row."),
                          ParamSpec("duration", "number", required: false,
                                    "Its length in seconds. 0 or absent = a point, not a region."),
                          ParamSpec("name", "string", required: false, "Its name.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let lane = try requireLane(p, vm)
            guard let made = vm.addMarker(laneID: lane,
                                          at: try p.double("at"),
                                          duration: try p.double("duration", or: 0),
                                          name: try p.string("name", or: "")) else {
                throw CommandError(code: .invalid_state, message: "the row went while we were laying it")
            }
            return .object(["lane": .string(made.lane.uuidString),
                            "marker": .string(made.marker.uuidString)])
        }

        register("marker.move",
                 summary: "Moves a marker, and resizes it when it is a region. Time ABSOLUTE. "
                        + "With `snap`, both bounds go through the timeline's own snap — the "
                        + "door the band's drag uses, the mark left out of its own targets.",
                 params: [ParamSpec("lane", "uuid", "Its row."),
                          ParamSpec("marker", "uuid", "The marker."),
                          ParamSpec("at", "number", "Its new time, in seconds."),
                          ParamSpec("duration", "number", required: false,
                                    "Its new length. Absent = left alone. 0 turns a region back "
                                  + "into a point."),
                          ParamSpec("snap", "bool", required: false,
                                    "Apply snapping (default false: exact positioning).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let lane = try p.uuid("lane"), marker = try p.uuid("marker")
            var at = try p.double("at")
            var d = p.raw["duration"] != nil ? try p.double("duration") : nil
            // The hand's own door, and the reason this parameter exists: a mark that is dragged
            // must not catch on ITSELF, and nothing headless could say whether it did until the
            // snap could be asked for here. A region snaps at BOTH ends — it is two instants.
            if try p.bool("snap", or: false) {
                CommandAdapters.withSnapping(true, vm) {
                    let end = d.map { at + $0 }
                    at = vm.snapTime(at, excluding: [marker])
                    if let end { d = max(0, vm.snapTime(end, excluding: [marker]) - at) }
                }
            }
            guard vm.moveMarker(laneID: lane, markerID: marker, to: at, duration: d) else {
                throw CommandError(code: .not_found, message: "no such marker on that row")
            }
            let moved = vm.markerLane(id: lane)?.markers.first { $0.id == marker }
            return .object(["lane": .string(lane.uuidString), "marker": .string(marker.uuidString),
                            "at": .number(moved?.time ?? at),
                            "duration": .number(moved?.duration ?? d ?? 0)])
        }

        register("marker.set_color",
                 summary: "A marker's or a region's own hue. WITHOUT `color_index` it goes back to "
                        + "taking its row's, which is the default — an absent parameter is the way "
                        + "to say 'inherit again', since null and absent are one thing here.",
                 params: [ParamSpec("lane", "uuid", "Its row."),
                          ParamSpec("marker", "uuid", "The marker."),
                          ParamSpec("color_index", "int", required: false,
                                    "A hue from the object palette (0…15). Absent = the row's.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let lane = try p.uuid("lane"), marker = try p.uuid("marker")
            let color = p.raw["color_index"] != nil ? try p.int("color_index") : nil
            guard vm.setMarkerColor(laneID: lane, markerID: marker, colorIndex: color) else {
                throw CommandError(code: .not_found, message: "no such marker on that row")
            }
            return .object(["lane": .string(lane.uuidString), "marker": .string(marker.uuidString),
                            "color_index": color.map(JSONValue.int) ?? .null])
        }

        register("marker.set_lane",
                 summary: "Moves a marker or a region to another row of the band, KEEPING ITS "
                        + "IDENTITY — the same id, hence the same selection and the same handle for "
                        + "a script holding it. Its time does not change: a row is a layer of "
                        + "reading, not a place on the timeline.",
                 params: [ParamSpec("lane", "uuid", "Its row now."),
                          ParamSpec("marker", "uuid", "The marker."),
                          ParamSpec("to", "uuid", "The row it goes to.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let lane = try p.uuid("lane"), marker = try p.uuid("marker"), target = try p.uuid("to")
            guard vm.markerLane(id: target) != nil else {
                throw CommandError(code: .not_found, message: "unknown marker lane: \(target.uuidString)")
            }
            guard vm.moveMarkerToLane(from: lane, markerID: marker, to: target) else {
                throw CommandError(code: .not_found, message: "no such marker on that row")
            }
            return .object(["lane": .string(target.uuidString), "marker": .string(marker.uuidString)])
        }

        register("marker.rename",
                 summary: "Renames a marker or a region.",
                 params: [ParamSpec("lane", "uuid", "Its row."),
                          ParamSpec("marker", "uuid", "The marker."),
                          ParamSpec("name", "string", "Its new name.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let lane = try p.uuid("lane"), marker = try p.uuid("marker")
            guard vm.renameMarker(laneID: lane, markerID: marker, to: try p.string("name")) else {
                throw CommandError(code: .not_found, message: "no such marker on that row")
            }
            return .object(["lane": .string(lane.uuidString), "marker": .string(marker.uuidString)])
        }

        register("marker.remove",
                 summary: "Deletes a marker or a region.",
                 params: [ParamSpec("lane", "uuid", "Its row."),
                          ParamSpec("marker", "uuid", "The marker.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let lane = try p.uuid("lane"), marker = try p.uuid("marker")
            guard vm.removeMarker(laneID: lane, markerID: marker) else {
                throw CommandError(code: .not_found, message: "no such marker on that row")
            }
            return .object(["removed": .string(marker.uuidString)])
        }

        // MARK: Markers carried by an object

        register("object.add_marker",
                 summary: "Lays a marker inside an object. Give `at` for an ABSOLUTE time (the "
                        + "one a hand would point at) or `rel` for a time in the object's own "
                        + "frame; it is stored relative either way, which is what makes the object "
                        + "free to move afterwards. It then survives a cut, a trim, a reverse, a "
                        + "varispeed and a ripple, exactly as an automation curve does.",
                 params: [ParamSpec("object", "uuid", "The object carrying it."),
                          ParamSpec("at", "number", required: false, "Absolute time, in seconds."),
                          ParamSpec("rel", "number", required: false,
                                    "Failing `at`: time from the start of the object."),
                          ParamSpec("duration", "number", required: false,
                                    "Its length. 0 or absent = a point."),
                          ParamSpec("name", "string", required: false, "Its name.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let objectID = try p.uuid("object")
            guard vm.find(id: objectID) != nil else {
                throw CommandError(code: .not_found, message: "unknown object: \(objectID.uuidString)")
            }
            let duration = try p.double("duration", or: 0)
            let name = try p.string("name", or: "")
            let made: UUID?
            if p.raw["at"] != nil {
                made = vm.addObjectMarker(objectID: objectID, atAbsoluteTime: try p.double("at"),
                                          duration: duration, name: name)
            } else if p.raw["rel"] != nil {
                made = vm.addObjectMarker(objectID: objectID, atRelativeTime: try p.double("rel"),
                                          duration: duration, name: name)
            } else {
                throw CommandError(code: .bad_params, message: "give 'at' (absolute) or 'rel' (from the object's start)")
            }
            guard let id = made else {
                throw CommandError(code: .invalid_state, message: "the object went while we were laying it")
            }
            return .object(["object": .string(objectID.uuidString), "marker": .string(id.uuidString)])
        }

        register("object.list_markers",
                 summary: "The markers an object carries. `time` is in the OBJECT's frame (what is "
                        + "stored); `absolute_time` is the same instant read on the timeline — both "
                        + "are given so that no caller has to do the sum, container nesting included.",
                 params: [ParamSpec("object", "uuid", "The object.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let objectID = try p.uuid("object")
            guard let object = vm.find(id: objectID) else {
                throw CommandError(code: .not_found, message: "unknown object: \(objectID.uuidString)")
            }
            let origin = vm.absoluteStart(of: objectID) ?? object.startTime
            let markers = object.markers.sorted { $0.time < $1.time }.map { m -> JSONValue in
                guard case .object(var fields) = markerPayload(m) else { return markerPayload(m) }
                fields["absolute_time"] = .number(origin + m.time)
                // A marker can sit OUTSIDE the window without being lost: a left trim or the right
                // half of a cut pushes it behind the edge, where it keeps a negative time and comes
                // back if the edge is reopened. Saying so beats leaving a caller to wonder.
                fields["audible"] = .bool(m.time >= -1e-9 && m.time <= object.duration + 1e-9)
                return .object(fields)
            }
            return .object(["object": .string(objectID.uuidString),
                            "origin": .number(origin),
                            "count": .int(markers.count),
                            "markers": .array(markers)])
        }

        register("object.rename_marker",
                 summary: "Renames a marker carried by an object.",
                 params: [ParamSpec("object", "uuid", "The object."),
                          ParamSpec("marker", "uuid", "The marker."),
                          ParamSpec("name", "string", "Its new name.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let objectID = try p.uuid("object"), marker = try p.uuid("marker")
            guard vm.renameObjectMarker(objectID: objectID, markerID: marker, to: try p.string("name")) else {
                throw CommandError(code: .not_found, message: "no such marker on that object")
            }
            return .object(["object": .string(objectID.uuidString), "marker": .string(marker.uuidString)])
        }

        register("object.move_marker",
                 summary: "Moves a marker carried by an object, and resizes it when it is a "
                        + "region. Give `at` for an ABSOLUTE time (the one a hand would point at) "
                        + "or `rel` for a time in the object's own frame; it is stored relative "
                        + "either way. With `snap` the instant goes through the timeline's own "
                        + "snap — the door the drag uses, the mark left out of its own targets. "
                        + "A negative `rel` is legal: that is a mark behind an edge, kept and not "
                        + "drawn. The HAND clamps to the object's window, this door does not.",
                 params: [ParamSpec("object", "uuid", "The object carrying it."),
                          ParamSpec("marker", "uuid", "The marker."),
                          ParamSpec("at", "number", required: false, "Absolute time, in seconds."),
                          ParamSpec("rel", "number", required: false,
                                    "Failing `at`: time from the start of the object."),
                          ParamSpec("duration", "number", required: false,
                                    "Its new length. Absent = left alone. 0 turns a region back "
                                  + "into a point."),
                          ParamSpec("snap", "bool", required: false,
                                    "Apply snapping (default false: exact positioning).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let objectID = try p.uuid("object"), marker = try p.uuid("marker")
            guard let object = vm.find(id: objectID) else {
                throw CommandError(code: .not_found, message: "unknown object: \(objectID.uuidString)")
            }
            let origin = vm.absoluteStart(of: objectID) ?? object.startTime
            var absolute: Double
            if p.raw["at"] != nil        { absolute = try p.double("at") }
            else if p.raw["rel"] != nil  { absolute = origin + (try p.double("rel")) }
            else {
                throw CommandError(code: .bad_params, message: "give 'at' (absolute) or 'rel' (from the object's start)")
            }
            var d = p.raw["duration"] != nil ? try p.double("duration") : nil
            if try p.bool("snap", or: false) {
                CommandAdapters.withSnapping(true, vm) {
                    let end = d.map { absolute + $0 }
                    absolute = vm.snapTime(absolute, excluding: [marker])
                    if let end { d = max(0, vm.snapTime(end, excluding: [marker]) - absolute) }
                }
            }
            guard vm.moveObjectMarker(objectID: objectID, markerID: marker,
                                      toRelativeTime: absolute - origin, duration: d) else {
                throw CommandError(code: .not_found, message: "no such marker on that object")
            }
            let moved = vm.find(id: objectID)?.markers.first { $0.id == marker }
            return .object(["object": .string(objectID.uuidString),
                            "marker": .string(marker.uuidString),
                            "rel": .number(moved?.time ?? absolute - origin),
                            "absolute_time": .number(origin + (moved?.time ?? absolute - origin)),
                            "duration": .number(moved?.duration ?? d ?? 0)])
        }

        register("object.set_marker_color",
                 summary: "The hue of a marker carried by an object. WITHOUT `color_index` it goes "
                        + "back to white, which is the default here: a mark laid on matter has no "
                        + "row to take a colour from, and white reads against any waveform.",
                 params: [ParamSpec("object", "uuid", "The object."),
                          ParamSpec("marker", "uuid", "The marker."),
                          ParamSpec("color_index", "int", required: false,
                                    "A hue from the object palette (0…15). Absent = white.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let objectID = try p.uuid("object"), marker = try p.uuid("marker")
            let color = p.raw["color_index"] != nil ? try p.int("color_index") : nil
            guard vm.setObjectMarkerColor(objectID: objectID, markerID: marker, colorIndex: color) else {
                throw CommandError(code: .not_found, message: "no such marker on that object")
            }
            return .object(["object": .string(objectID.uuidString), "marker": .string(marker.uuidString),
                            "color_index": color.map(JSONValue.int) ?? .null])
        }

        register("object.remove_marker",
                 summary: "Deletes a marker carried by an object.",
                 params: [ParamSpec("object", "uuid", "The object."),
                          ParamSpec("marker", "uuid", "The marker.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let objectID = try p.uuid("object"), marker = try p.uuid("marker")
            guard vm.removeObjectMarker(objectID: objectID, markerID: marker) else {
                throw CommandError(code: .not_found, message: "no such marker on that object")
            }
            return .object(["removed": .string(marker.uuidString)])
        }

        // MARK: Comments

        register("comment.create",
                 summary: "Lays a free text over a span of the timeline. The text is markdown, "
                        + "inline (bold, italic, code, links). A comment is not a sound object: it "
                        + "has no engine object, and it does not move with a ripple or a cut.",
                 params: [ParamSpec("from", "number", "Start, in ABSOLUTE seconds."),
                          ParamSpec("to", "number", "End, in ABSOLUTE seconds."),
                          ParamSpec("lane", "int", required: false,
                                    "Its row (default 0), in the same frame as `object.add`'s — the "
                                  + "BASE row, not the visual one: opening a group above it pushes "
                                  + "the comment down with everything else instead of leaving it "
                                  + "beside somebody else's lane. WITH `parent`, it is a row of "
                                  + "that group's band (0 = the first row under it)."),
                          ParamSpec("parent", "uuid", required: false,
                                    "The GROUP to lay it IN, recursively. Absent = the timeline. "
                                  + "Inside a group the comment's time and row become the group's "
                                  + "own, so it follows it when it is moved or copied, and it is "
                                  + "not drawn while the group is folded. A parent that is not a "
                                  + "group is ignored."),
                          ParamSpec("text", "string", required: false, "Its content.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            var parent: UUID? = nil
            if let rawParent = p.raw["parent"], rawParent != .null { parent = try p.uuid("parent") }
            guard let id = vm.addComment(from: try p.double("from"), to: try p.double("to"),
                                         lane: try p.int("lane", or: 0),
                                         parentID: parent,
                                         text: try p.string("text", or: "")) else {
                throw CommandError(code: .bad_params, message: "'from' and 'to' must bound a real span")
            }
            return .object(["comment": .string(id.uuidString)])
        }

        register("comment.list",
                 summary: "Every comment laid on the timeline.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            return .object(["count": .int(vm.comments.count),
                            "comments": .array(vm.comments.map { commentPayload($0, vm) })])
        }

        register("comment.set_text",
                 summary: "Rewrites a comment's text.",
                 params: [ParamSpec("comment", "uuid", "The comment."),
                          ParamSpec("text", "string", "Its new content, in markdown.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("comment")
            guard vm.setCommentText(id: id, try p.string("text")) else {
                throw CommandError(code: .not_found, message: "unknown comment: \(id.uuidString)")
            }
            return .object(["comment": .string(id.uuidString)])
        }

        register("comment.move",
                 summary: "Moves a comment, and resizes, re-rows or re-homes it if asked.",
                 params: [ParamSpec("comment", "uuid", "The comment."),
                          ParamSpec("at", "number", "Its new start, in ABSOLUTE seconds."),
                          ParamSpec("duration", "number", required: false, "Its new length."),
                          ParamSpec("lane", "int", required: false,
                                    "Its new row (the BASE one, in its own frame)."),
                          ParamSpec("parent", "uuid", required: false,
                                    "The GROUP to move it into. Give it EXPLICITLY NULL to bring "
                                  + "it back onto the timeline; absent leaves the frame alone. "
                                  + "`at` and `lane` are then read in the frame it ends up in.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("comment")
            let d = p.raw["duration"] != nil ? try p.double("duration") : nil
            let l = p.raw["lane"] != nil ? try p.int("lane") : nil
            // A DOUBLE optional: absent = leave the frame alone, an explicit null = the timeline.
            var parent: UUID?? = nil
            if let raw = p.raw["parent"] {
                if case .null = raw { parent = .some(nil) }
                else { parent = .some(try p.uuid("parent")) }
            }
            guard vm.moveComment(id: id, to: try p.double("at"), duration: d, lane: l,
                                 parent: parent) else {
                throw CommandError(code: .not_found, message: "unknown comment: \(id.uuidString)")
            }
            return .object(["comment": .string(id.uuidString)])
        }

        register("comment.set_color",
                 summary: "A comment's hue. WITHOUT `color_index` it goes back to WHITE, which is "
                        + "what a comment is born: white is not in the object palette, so a note "
                        + "never reads as one more object laid on the lane.",
                 params: [ParamSpec("comment", "uuid", "The comment."),
                          ParamSpec("color_index", "int", required: false,
                                    "A hue from the object palette (0…15). Absent = white.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("comment")
            let color = p.raw["color_index"] != nil ? try p.int("color_index") : nil
            guard vm.setCommentColor(id: id, colorIndex: color) else {
                throw CommandError(code: .not_found, message: "unknown comment: \(id.uuidString)")
            }
            return .object(["comment": .string(id.uuidString),
                            "color_index": color.map(JSONValue.int) ?? .null])
        }

        register("comment.remove",
                 summary: "Deletes a comment.",
                 params: [ParamSpec("comment", "uuid", "The comment.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("comment")
            guard vm.removeComment(id: id) else {
                throw CommandError(code: .not_found, message: "unknown comment: \(id.uuidString)")
            }
            return .object(["removed": .string(id.uuidString)])
        }
    }
}
