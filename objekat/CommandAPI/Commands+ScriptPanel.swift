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
            let (controls, values) = try ScriptControls.parse(try p.array("controls"))
            let object = try p.optionalUUID("object")
            if let object, vm.find(id: object) == nil {
                throw CommandError(code: .not_found, message: "no object \(object.uuidString)")
            }
            var panel = ScriptPanel(id: UUID(), owner: CommandCallContext.caller, objectID: object,
                                    title: try p.string("title", or: ""), controls: controls,
                                    values: values)
            panel.declared = values
            if let key = try ScriptControls.rememberKey(p.raw["remember"], title: panel.title) {
                panel.rememberKey = key
                ScriptControls.applyRemembered(key, controls: controls, into: &panel.values)
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
            let labels = try ScriptControls.parseLabels(p)
            let busy: Bool? = p.raw["busy"] == nil ? nil : try p.bool("busy")
            try vm.scriptPanels.update(try p.uuid("panel_id"), status: try p.optionalString("status"),
                                       busy: busy, values: try ScriptControls.parseValues(p), labels: labels)
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
            try vm.scriptPanels.input(id, values: try ScriptControls.parseValues(p), press: try p.optionalString("press"))
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
