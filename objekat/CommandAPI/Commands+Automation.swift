import Foundation

// MARK: - Automation curves (`automation.*`)

/// The first doors onto an object's automation curves — reading them, laying a whole curve down,
/// and the two curvature gestures of the band: the ⌥-wheel (through its straight-line detent) and
/// the ⌥ + double click that straightens a segment. Before this family nothing headless could lay
/// a point, so nothing about a curve could be asserted with no screen.
///
/// A parameter (`param`) is named `"volume"`, `"pan"`, `"send:<aux uuid>"`,
/// `"plugin:<plugin uuid>:<paramID>"`, or the session file's own object form
/// (`{"type": "send", "auxID": …}`). Points are addressed by their STORAGE index, as the band
/// addresses them (@see AutomationPointRef); `t` is in seconds RELATIVE to the object's start.
extension CommandRegistry {

    static func automationParam(_ p: CommandParams, _ key: String = "param") throws -> ParamRef {
        guard let raw = p.raw[key] else {
            throw CommandError(code: .bad_params, message: "'\(key)' is required")
        }
        if let s = raw.stringValue {
            switch s {
            case "volume": return .volume
            case "pan":    return .pan
            default: break
            }
            let parts = s.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 2, parts[0] == "send", let aux = UUID(uuidString: parts[1]) {
                return .send(auxID: aux)
            }
            if parts.count == 3, parts[0] == "plugin", let key = UUID(uuidString: parts[1]) {
                return .plugin(pluginKey: key, paramID: parts[2])
            }
        } else if raw.objectValue != nil,
                  let data = try? JSONEncoder().encode(raw),
                  let ref = try? JSONDecoder().decode(ParamRef.self, from: data) {
            return ref
        }
        throw CommandError(code: .bad_params,
                           message: "'\(key)': volume | pan | send:<uuid> | plugin:<uuid>:<paramID>")
    }

    static func automationParamName(_ ref: ParamRef) -> String {
        switch ref {
        case .volume:                       return "volume"
        case .pan:                          return "pan"
        case .chainInGain:                  return "chainInGain"
        case .chainOutGain:                 return "chainOutGain"
        case .send(let aux):                return "send:\(aux.uuidString)"
        case .plugin(let key, let paramID): return "plugin:\(key.uuidString):\(paramID)"
        }
    }

    private func automationLaneJSON(_ vm: EditViewModel, objectID: UUID, param: ParamRef) -> JSONValue {
        let pts = vm.automationPoints(objectID, param)
        return .object([
            "param": .string(Self.automationParamName(param)),
            "points": .array(pts.enumerated().map { i, pt in
                .object(["index": .int(i), "t": .number(pt.t),
                         "v": .number(Double(pt.v)), "c": .number(Double(pt.c))])
            }),
        ])
    }

    private func requireObject(_ vm: EditViewModel, _ id: UUID) throws -> SoundObject {
        guard let o = vm.find(id: id) else {
            throw CommandError(code: .not_found, message: "no object \(id.uuidString)")
        }
        return o
    }

    func registerAutomationCommands() {

        register("automation.list",
                 summary: "An object's automation curves: one entry per automated parameter, its "
                        + "points in STORAGE order ({index, t, v, c}; t relative to the object's "
                        + "start, c the curvature of the segment the point starts).",
                 params: [ParamSpec("id", "uuid", "The object.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let obj = try self.requireObject(vm, try p.uuid("id"))
            return .object([
                "id": .string(obj.id.uuidString),
                "lanes": .array(obj.automation.map {
                    self.automationLaneJSON(vm, objectID: obj.id, param: $0.param)
                }),
            ])
        }

        register("automation.set_points",
                 summary: "Lays a whole curve down on one parameter, replacing what it had: points "
                        + "[{t, v, c?}] in that storage order. An empty list removes the curve "
                        + "('no point = no automation'). Values are clamped to the parameter's range, "
                        + "c to -1…1. Drops the point selection (its indices name the old curve).",
                 params: [ParamSpec("id", "uuid", "The object."),
                          ParamSpec("param", "string|object", "The parameter (see the family's note)."),
                          ParamSpec("points", "array<object>", "[{t, v, c?}].")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let obj = try self.requireObject(vm, try p.uuid("id"))
            let param = try Self.automationParam(p)
            var pts: [AutomationPoint] = []
            for (k, e) in try p.array("points").enumerated() {
                guard let t = e["t"]?.doubleValue, let v = e["v"]?.doubleValue else {
                    throw CommandError(code: .bad_params, message: "points[\(k)]: needs numeric t and v")
                }
                let c = e["c"]?.doubleValue ?? 0
                pts.append(AutomationPoint(t: t, v: Float(v), c: Float(c)))
            }
            vm.clearAutomationPointSelection()
            vm.updateAutomationRows(objectID: obj.id) { lanes in
                if let i = lanes.firstIndex(where: { $0.param == param }) {
                    lanes[i].points = pts
                } else if !pts.isEmpty {
                    lanes.append(AutomationLane(param: param, points: pts))
                }
            }
            if case .send(let auxID) = param { vm.syncSendEngine(objectID: obj.id, auxID: auxID) }
            return self.automationLaneJSON(vm, objectID: obj.id, param: param)
        }

        register("automation.select_points",
                 summary: "Sets the automation POINT selection (what clicks and ⇧/⌘-clicks in a band "
                        + "pick): `indices` (storage) on one curve; an empty list empties it. Drops "
                        + "the time selection, as picking points by hand does. Session state, no undo.",
                 params: [ParamSpec("id", "uuid", "The object."),
                          ParamSpec("param", "string|object", "The parameter."),
                          ParamSpec("indices", "array<int>", "Storage indices.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let obj = try self.requireObject(vm, try p.uuid("id"))
            let param = try Self.automationParam(p)
            let count = vm.automationPoints(obj.id, param).count
            var refs: Set<AutomationPointRef> = []
            for v in try p.array("indices") {
                guard let i = v.intValue, i >= 0, i < count else {
                    throw CommandError(code: .bad_params, message: "'indices': 0…\(count - 1)")
                }
                refs.insert(AutomationPointRef(objectID: obj.id, param: param, index: i))
            }
            vm.setAutomationPointSelection(refs)
            return .object(["selected": .array(vm.selectedIndices(objectID: obj.id, param: param).map { .int($0) })])
        }

        register("automation.straighten",
                 summary: "Brings segments back to a straight line (c = 0 on their left point) — what "
                        + "⌥ + double click on a segment does. `index` = the segment's left point "
                        + "(storage index); without it, every segment of the curve; with `selection: "
                        + "true` instead, every segment the POINT SELECTION holds (both ends selected), "
                        + "on every object — what the double click does inside a selection. One undo "
                        + "point, none if nothing was bent. Answers `straightened` (how many were bent).",
                 params: [ParamSpec("id", "uuid", required: false, "The object (not with `selection`)."),
                          ParamSpec("param", "string|object", required: false, "The parameter (not with `selection`)."),
                          ParamSpec("index", "int", required: false, "The segment's left point."),
                          ParamSpec("selection", "bool", required: false,
                                    "true = the segments of the current point selection.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            var refs: [AutomationPointRef] = []
            if try p.bool("selection", or: false) {
                var byRow: [EditViewModel.RowKey: Set<Int>] = [:]
                for r in vm.selectedAutomationPoints {
                    byRow[EditViewModel.RowKey(r.objectID, r.param), default: []].insert(r.index)
                }
                for (key, idx) in byRow {
                    for i in AutomationCurveShape.segmentOwners(
                        of: vm.automationPoints(key.objectID, key.param), selected: idx) {
                        refs.append(AutomationPointRef(objectID: key.objectID, param: key.param, index: i))
                    }
                }
            } else {
                let obj = try self.requireObject(vm, try p.uuid("id"))
                let param = try Self.automationParam(p)
                let pts = vm.automationPoints(obj.id, param)
                if let i = try p.optionalInt("index") {
                    guard pts.indices.contains(i) else {
                        throw CommandError(code: .bad_params, message: "'index': 0…\(pts.count - 1)")
                    }
                    refs = [AutomationPointRef(objectID: obj.id, param: param, index: i)]
                } else {
                    refs = AutomationCurveShape.segmentOwners(of: pts, selected: Set(pts.indices))
                        .map { AutomationPointRef(objectID: obj.id, param: param, index: $0) }
                }
            }
            let n = vm.straightenAutomationSegments(refs)
            return .object(["straightened": .int(n), "segments": .int(refs.count)])
        }

        register("automation.wheel_curvature",
                 summary: "The ⌥-wheel over a segment: `steps` notches UPWARDS (the curve rises), "
                        + "from the curvature the wheel gesture started on, through the straight-line "
                        + "detent (crossing straight lands on it and holds it one more notch). "
                        + "`new_gesture` (default true) opens a gesture and its undo point, as a "
                        + "pause in the wheel does; false continues the previous call's gesture.",
                 params: [ParamSpec("id", "uuid", "The object."),
                          ParamSpec("param", "string|object", "The parameter."),
                          ParamSpec("index", "int", "The segment's left point (storage index)."),
                          ParamSpec("steps", "int", "Notches, positive = upwards."),
                          ParamSpec("new_gesture", "bool", required: false, "Default true.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let obj = try self.requireObject(vm, try p.uuid("id"))
            let param = try Self.automationParam(p)
            let index = try p.int("index")
            guard vm.automationPoints(obj.id, param).indices.contains(index) else {
                throw CommandError(code: .bad_params, message: "'index' names no point")
            }
            let newGesture = try p.bool("new_gesture", or: true)
            if newGesture { vm.beginAutomationEdit() }
            vm.adjustAutomationCurvature(objectID: obj.id, param: param, at: index,
                                         steps: try p.int("steps"), newGesture: newGesture)
            return self.automationLaneJSON(vm, objectID: obj.id, param: param)
        }
    }
}
