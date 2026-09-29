import Foundation

/// The `script.panel.*` family — a window a script declares and the app draws (@see
/// ScriptPanelStore). Nothing here is an edit: `undo: .none`, no dirty flag, nothing saved.
///
/// The loop a script runs: `open`, then `wait(since_rev)` repeatedly — each `wait` answers the
/// moment the hand changes anything, or at its timeout with the panel as it stands (no error: the
/// timeout is the script's heartbeat) — and `update` to write a status line back. `input` is the
/// hand's own door for a headless test: the window goes through the very same store function.
extension CommandRegistry {

    func registerScriptPanelCommands() {

        func panelPayload(_ p: ScriptPanel) -> JSONValue {
            .object(["panel_id": .string(p.id.uuidString), "rev": .int(p.rev),
                     "state": .string(p.state.rawValue),
                     "values": .object(p.values),
                     "events": .array(p.pendingEvents.map { .object(["button": .string($0)]) }),
                     "status": .string(p.status), "busy": .bool(p.busy),
                     "remember": .stringOrNull(p.rememberKey)])
        }

        func bad(_ m: String) -> CommandError { CommandError(code: .bad_params, message: m) }

        func parseControls(_ arr: [JSONValue]) throws -> ([ScriptPanelControl], [String: JSONValue]) {
            var controls: [ScriptPanelControl] = []
            var values: [String: JSONValue] = [:]
            var seen = Set<String>()
            for e in arr {
                guard let o = e.objectValue, let id = o["id"]?.stringValue, !id.isEmpty,
                      let kindName = o["kind"]?.stringValue,
                      let kind = ScriptPanelControl.Kind(rawValue: kindName),
                      let label = o["label"]?.stringValue else {
                    throw bad("a control is {id, kind: bool|number|button|choice|progress|section, label, …}")
                }
                guard seen.insert(id).inserted else { throw bad("duplicate control id '\(id)'") }
                var lo = 0.0, hi = 1.0, step = 1.0
                var options: [ScriptPanelOption] = []
                switch kind {
                case .bool:
                    values[id] = .bool(o["value"]?.boolValue ?? false)
                case .number:
                    guard let mn = o["min"]?.doubleValue, let mx = o["max"]?.doubleValue,
                          let st = o["step"]?.doubleValue else {
                        throw bad("number control '\(id)' needs min, max and step")
                    }
                    guard mn < mx else { throw bad("control '\(id)': min must be below max") }
                    guard st > 0 else { throw bad("control '\(id)': step must be > 0") }
                    lo = mn; hi = mx; step = st
                    let v = o["value"]?.doubleValue ?? mn
                    guard v >= mn, v <= mx else { throw bad("control '\(id)': value out of range") }
                    values[id] = .number(v)
                case .choice:
                    guard let raw = o["options"]?.arrayValue, !raw.isEmpty else {
                        throw bad("choice control '\(id)' needs a non-empty options list")
                    }
                    for e in raw {
                        guard let eo = e.objectValue, let oid = eo["id"]?.stringValue, !oid.isEmpty,
                              let olabel = eo["label"]?.stringValue else {
                            throw bad("control '\(id)': an option is {id, label}")
                        }
                        guard !options.contains(where: { $0.id == oid }) else {
                            throw bad("control '\(id)': duplicate option id '\(oid)'")
                        }
                        options.append(ScriptPanelOption(id: oid, label: olabel))
                    }
                    let v = o["value"]?.stringValue ?? options[0].id
                    guard options.contains(where: { $0.id == v }) else {
                        throw bad("control '\(id)': value is not one of its options")
                    }
                    values[id] = .string(v)
                case .progress:
                    // absent = 0, explicit null = indeterminate
                    if let raw = o["value"], case .null = raw { values[id] = .null }
                    else {
                        let v = o["value"]?.doubleValue ?? 0
                        guard v >= 0, v <= 1 else { throw bad("control '\(id)': a progress is 0…1 or null") }
                        values[id] = .number(v)
                    }
                case .button, .section: break
                }
                var control = ScriptPanelControl(id: id, kind: kind, label: label, min: lo, max: hi,
                                                 step: step, unit: o["unit"]?.stringValue ?? "",
                                                 enabledBy: o["enabled_by"]?.stringValue)
                control.options = options
                if let adv = o["advanced"] {
                    guard let b = adv.boolValue else { throw bad("control '\(id)': advanced must be a bool") }
                    control.advanced = b
                }
                controls.append(control)
            }
            for c in controls {
                if let by = c.enabledBy {
                    guard let target = controls.first(where: { $0.id == by }), target.kind == .bool else {
                        throw bad("control '\(c.id)': enabled_by must name a bool control")
                    }
                }
            }
            return (controls, values)
        }

        func parseValues(_ p: CommandParams) throws -> [String: JSONValue] {
            guard let v = p.raw["values"] else { return [:] }
            guard let o = v.objectValue else { throw bad("'values' must be an object") }
            return o
        }

        register("script.panel.open",
                 summary: "Opens a panel the app draws for the script: checkboxes, sliders, buttons, "
                        + "a status line, Validate / Cancel. One panel per connection (a second "
                        + "replaces the first). Headless: the panel exists, no window opens.",
                 params: [ParamSpec("title", "string", required: false, "Window title."),
                          ParamSpec("controls", "array<{id,kind,label,value?,min?,max?,step?,unit?,enabled_by?,options?,advanced?}>",
                                    "kind: bool | number | button | choice | progress | section. A progress is a bar the script drives (value 0…1, null = indeterminate); a section is a heading. A number needs min, max, step; a choice needs options [{id,label}] and its value is an option id. "
                                  + "enabled_by = the id of a bool control that greys this one. advanced = true hides the control until the hand presses the window's Expert button."),
                          ParamSpec("object", "uuid", required: false,
                                    "The object it is about: the panel closes if it disappears."),
                          ParamSpec("status", "string", required: false, "Initial status line."),
                          ParamSpec("busy", "bool", required: false, "Initial busy indicator."),
                          ParamSpec("remember", "string|true", required: false,
                                    "A key: the panel opens on the values last VALIDATED under it "
                                  + "(those that still fit), Validate stores them, and the app adds a "
                                  + "Reset button. `true` = a key derived from the title.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let (controls, values) = try parseControls(try p.array("controls"))
            let object = try p.optionalUUID("object")
            if let object, vm.find(id: object) == nil {
                throw CommandError(code: .not_found, message: "no object \(object.uuidString)")
            }
            var panel = ScriptPanel(id: UUID(), owner: CommandCallContext.caller, objectID: object,
                                    title: try p.string("title", or: ""), controls: controls,
                                    values: values)
            panel.declared = values
            if let raw = p.raw["remember"], raw != .null, raw != .bool(false) {
                var key: String
                if case .string(let k) = raw { key = k }
                else if raw == .bool(true) { key = panel.title }
                else { throw bad("'remember' is a key (string) or true") }
                key = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { throw bad("'remember' needs a non-empty key (or a title)") }
                panel.rememberKey = key
                let kept = ScriptPanelMemory.applicable(ScriptPanelMemory.load(key), to: controls)
                for (k, v) in kept { panel.values[k] = v }
            }
            panel.status = try p.string("status", or: "")
            panel.busy = try p.bool("busy", or: false)
            vm.scriptPanels.open(panel)
            return .object(["panel_id": .string(panel.id.uuidString), "rev": .int(0)])
        }

        register("script.panel.get",
                 summary: "The panel as it stands: rev, state (open|validated|cancelled|closed), the "
                        + "values, the button events since the last read (which this read empties).",
                 params: [ParamSpec("panel_id", "uuid", "The panel.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            return panelPayload(try vm.scriptPanels.read(try p.uuid("panel_id")))
        }

        register("script.panel.wait",
                 summary: "Long poll: answers as soon as rev > since_rev or the panel is no longer "
                        + "open; at the timeout it answers the CURRENT state (no error — loop).",
                 params: [ParamSpec("panel_id", "uuid", "The panel."),
                          ParamSpec("since_rev", "int", "The last rev the script has seen."),
                          ParamSpec("timeout_ms", "int", required: false, "At most 5000 (default 1000).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("panel_id")
            let since = try p.int("since_rev")
            let budget = Duration.milliseconds(min(5000, max(0, try p.int("timeout_ms", or: 1000))))
            let started = ContinuousClock.now
            while true {
                // Read without draining first: only a wait that RETURNS drains the events.
                guard let cur = vm.scriptPanels.panels[id] else {
                    throw CommandError(code: .not_found, message: "no panel \(id.uuidString)")
                }
                if cur.rev > since || cur.state != .open || ContinuousClock.now - started >= budget {
                    return panelPayload(try vm.scriptPanels.read(id))
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        register("script.panel.update",
                 summary: "The script writes back: a status line, the busy flag, recalibrated values. "
                        + "Never moves rev (it would wake the script's own wait).",
                 params: [ParamSpec("panel_id", "uuid", "The panel."),
                          ParamSpec("status", "string", required: false, "Status line."),
                          ParamSpec("busy", "bool", required: false, "Busy indicator."),
                          ParamSpec("values", "object", required: false,
                                    "Control id → value (a progress: 0…1, or null = indeterminate)."),
                          ParamSpec("labels", "object", required: false,
                                    "Control id → new label (what a progress bar says it is doing).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            var labels: [String: String] = [:]
            if let raw = p.raw["labels"] {
                guard let o = raw.objectValue else { throw bad("'labels' must be an object") }
                for (k, v) in o {
                    guard let t = v.stringValue else { throw bad("'labels.\(k)' must be a string") }
                    labels[k] = t
                }
            }
            let busy: Bool? = p.raw["busy"] == nil ? nil : try p.bool("busy")
            try vm.scriptPanels.update(try p.uuid("panel_id"), status: try p.optionalString("status"),
                                       busy: busy, values: try parseValues(p), labels: labels)
            return .object(["ok": .bool(true)])
        }

        register("script.panel.close",
                 summary: "Closes the panel (state 'closed'). Closing the connection does the same.",
                 params: [ParamSpec("panel_id", "uuid", "The panel.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("panel_id")
            guard vm.scriptPanels.panels[id] != nil else {
                throw CommandError(code: .not_found, message: "no panel \(id.uuidString)")
            }
            vm.scriptPanels.end(id, as: .closed)
            return .object(["closed": .bool(true)])
        }

        register("script.panel.input",
                 summary: "The HAND's door, for a headless test — the window goes through the same "
                        + "store function. Sets values and / or presses a button id, 'validate' or "
                        + "'cancel'. Moves rev.",
                 params: [ParamSpec("panel_id", "uuid", "The panel."),
                          ParamSpec("values", "object", required: false, "Control id → value."),
                          ParamSpec("press", "string", required: false,
                                    "A button id, 'validate', 'cancel' or (remember panels) 'reset'.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("panel_id")
            try vm.scriptPanels.input(id, values: try parseValues(p), press: try p.optionalString("press"))
            return .object(["rev": .int(vm.scriptPanels.panels[id]?.rev ?? 0)])
        }

        register("script.panel.list",
                 summary: "The panels currently known.",
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            vm.pruneScriptOverlays()
            let rows = vm.scriptPanels.panels.values.sorted { $0.id.uuidString < $1.id.uuidString }
            return .object(["panels": .array(rows.map { p in
                .object(["panel_id": .string(p.id.uuidString), "title": .string(p.title),
                         "state": .string(p.state.rawValue),
                         "object": .stringOrNull(p.objectID?.uuidString)])
            })])
        }
    }
}
