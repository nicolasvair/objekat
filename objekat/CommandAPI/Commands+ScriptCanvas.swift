import Foundation

/// The `script.canvas.*` family — a canvas a script declares and the app draws (@see
/// ScriptCanvasStore, plan_spectral_editor.md §2). Nothing here is an edit: `undo: .none`, no dirty
/// flag, nothing saved.
///
/// The loop a script runs: `open`, `set_image`, `set_audio`, then `wait(since_rev)` repeatedly — each
/// `wait` answers the moment the hand changes anything, or at its timeout with the canvas as it
/// stands (no error: the timeout is the script's heartbeat) — and `set_layer` / `set_audio` /
/// `update` to answer. `input` is the hand's own door for a headless test: the window goes through
/// the very same store functions.
///
/// The app records GESTURES; it never interprets them. No gain, no dB, no mask in this file. The
/// history is ENTRIES (a draft = one gesture of a pending selection, a step = a committed step), and a
/// canvas opened with `modes` has two modes — Instant and Selection — and a polarity on each gesture
/// (plan §9).
extension CommandRegistry {

    func registerScriptCanvasCommands() {

        // MARK: Payloads

        /// A number that can never reach the JSON encoder as NaN or infinity.
        func num(_ d: Double) -> JSONValue { d.isFinite ? .number(d) : .null }

        func axisPayload(_ a: CanvasAxis) -> JSONValue {
            .object(["min": num(a.lo), "max": num(a.hi), "unit": .string(a.unit),
                     "mapping": .string(a.mapping.rawValue)])
        }

        func opPayload(_ op: CanvasOp) -> JSONValue {
            var o: [String: JSONValue] = [
                "id": .int(op.id), "kind": .string(op.kind.rawValue), "tool": .string(op.tool),
                "params": .object(op.params), "polarity": .string(op.polarity.rawValue),
                "slot": .string(op.slot.rawValue),
            ]
            switch op.shape {
            case .rect(let x0, let x1, let y0, let y1):
                o["x0"] = num(x0); o["x1"] = num(x1); o["y0"] = num(y0); o["y1"] = num(y1)
            case .stroke(let points, let sizePt, let sizeX, let sizeY):
                o["points"] = .array(points.map { .array([num($0.x), num($0.y)]) })
                o["size_pt"] = num(sizePt); o["size_x"] = num(sizeX); o["size_y"] = num(sizeY)
            case .point(let x, let y):
                o["x"] = num(x); o["y"] = num(y)
            }
            return .object(o)
        }

        func entryPayload(_ e: CanvasHistoryEntry) -> JSONValue {
            var o: [String: JSONValue] = [
                "id": .int(e.id), "kind": .string(e.kind.rawValue), "active_since": .int(e.activeSince),
                "ops": .array(e.ops.map(opPayload)),
            ]
            // A step's snapshot of EVERY hand value, taken when it was sealed; a draft has none.
            if let params = e.params { o["params"] = .object(params) }
            return .object(o)
        }

        func layerPayload(_ l: CanvasLayer) -> JSONValue {
            .object(["layer": .string(l.id), "path": .string(l.image.path),
                     "width": .int(l.image.width), "height": .int(l.image.height),
                     "z": .int(l.z), "opacity": num(l.opacity),
                     "history_rev": l.historyRev.map { JSONValue.int($0) } ?? JSONValue.null])
        }

        func slotsPayload(_ t: ScriptCanvasTransport) -> JSONValue {
            var slots: [String: JSONValue] = [:]
            var durations: [String: JSONValue] = [:]
            for s in CanvasSlot.allCases {
                slots[s.rawValue] = .stringOrNull(t.slots[s])
                if let d = t.durations[s] { durations[s.rawValue] = num(d) }
            }
            return .object(["slots": .object(slots), "durations": .object(durations)])
        }

        func canvasPayload(_ c: ScriptCanvas, knownHistoryRev: Int?, viewport: CanvasViewport?,
                           position: Double) -> JSONValue {
            var history: [String: JSONValue] = [
                "rev": .int(c.historyRev), "cursor": .int(c.history.cursor), "count": .int(c.history.count),
                "pending": .int(c.history.pending),
                "unreflected": .array(c.unreflectedOpIDs.map { JSONValue.int($0) }),
            ]
            // The entries are the bulk of the answer: omitted when the script already holds this rev.
            if knownHistoryRev != c.historyRev { history["entries"] = .array(c.history.entries.map(entryPayload)) }

            var transport: [String: JSONValue] = [
                "playing": .bool(c.transport.playing), "position": num(position),
                "caret": num(c.transport.caret), "listen": .string(c.transport.listen.rawValue),
                "monitor_db": num(c.transport.monitorDB),
                "audio_history_rev": c.transport.audioHistoryRev.map { JSONValue.int($0) } ?? JSONValue.null,
            ]
            if let both = slotsPayload(c.transport).objectValue { transport.merge(both) { a, _ in a } }

            var view: JSONValue = .null
            if let world = c.world, let vp = viewport {
                view = .object(["x0": num(world.x.unwarp(vp.x0w)), "x1": num(world.x.unwarp(vp.x1w)),
                                "y0": num(world.y.unwarp(vp.y0w)), "y1": num(world.y.unwarp(vp.y1w)),
                                "width": num(vp.width), "height": num(vp.height)])
            }
            return .object([
                "canvas_id": .string(c.id.uuidString), "rev": .int(c.rev),
                "state": .string(c.state.rawValue), "values": .object(c.values),
                "events": .array(c.pendingEvents.map { .object(["button": .string($0)]) }),
                "status": .string(c.status), "busy": .bool(c.busy),
                "remember": .stringOrNull(c.rememberKey), "tool": .stringOrNull(c.activeTool),
                "modes": .bool(c.modes), "mode": .string(c.mode.rawValue),
                "polarity": .string(c.polarity.rawValue),
                "history": .object(history),
                "image": c.image.map { img in
                    var slots: [String: JSONValue] = [:]
                    for (slot, si) in c.slotImages {
                        slots[slot.rawValue] = .object(["path": .string(si.image.path), "width": .int(si.image.width),
                                                        "height": .int(si.image.height),
                                                        "history_rev": si.historyRev.map { JSONValue.int($0) } ?? JSONValue.null])
                    }
                    return .object(["path": .string(img.path), "width": .int(img.width),
                                    "height": .int(img.height), "has_values": .bool(img.hasValues),
                                    "history_rev": c.imageHistoryRev.map { JSONValue.int($0) } ?? JSONValue.null,
                                    "slots": .object(slots),
                                    "shown": .string(c.displayedImage?.path ?? img.path)])
                } ?? .null,
                "layers": .array(ScriptCanvasStore.layersInDrawOrder(c.layers).map(layerPayload)),
                "world": c.world.map { .object(["x": axisPayload($0.x), "y": axisPayload($0.y)]) } ?? .null,
                "view": view,
                "transport": .object(transport),
            ])
        }

        func readPayload(_ vm: EditViewModel, _ id: UUID, knownHistoryRev: Int?) throws -> JSONValue {
            let c = try vm.scriptCanvases.read(id)
            return canvasPayload(c, knownHistoryRev: knownHistoryRev, viewport: vm.scriptCanvases.viewport(id),
                                 position: vm.scriptCanvases.position(of: id))
        }

        // MARK: Parsing

        func bad(_ m: String) -> CommandError { CommandError(code: .bad_params, message: m) }

        func parseTools(_ raw: [JSONValue], controls: [ScriptPanelControl]) throws -> [CanvasTool] {
            var tools: [CanvasTool] = []
            for e in raw {
                guard let o = e.objectValue, let id = o["id"]?.stringValue, !id.isEmpty,
                      let kindName = o["kind"]?.stringValue,
                      let label = o["label"]?.stringValue else {
                    throw bad("a tool is {id, kind: rect|stroke|point, label, icon?, params?, size_control?}")
                }
                guard let kind = CanvasToolKind(rawValue: kindName) else {
                    throw bad("tool '\(id)': unknown kind '\(kindName)' (rect, stroke or point)")
                }
                guard !tools.contains(where: { $0.id == id }) else { throw bad("duplicate tool id '\(id)'") }
                var icon = CanvasTool.defaultIcon(for: kind)
                if let rawIcon = o["icon"] {
                    guard let s = rawIcon.stringValue else { throw bad("tool '\(id)': icon is an SF Symbol name") }
                    if !s.isEmpty { icon = s }
                }
                var params: [String] = []
                if let rawParams = o["params"] {
                    guard let arr = rawParams.arrayValue else { throw bad("tool '\(id)': params is a list of control ids") }
                    for p in arr {
                        guard let pid = p.stringValue else { throw bad("tool '\(id)': params is a list of control ids") }
                        guard let c = controls.first(where: { $0.id == pid }) else {
                            throw bad("tool '\(id)': params names an unknown control '\(pid)'")
                        }
                        guard c.kind.holdsHandValue else {
                            throw bad("tool '\(id)': control '\(pid)' holds no value a hand can set")
                        }
                        params.append(pid)
                    }
                }
                var sizeControl: String? = nil
                if let rawSize = o["size_control"], rawSize != .null {
                    guard kind == .stroke else { throw bad("tool '\(id)': size_control is only for a stroke tool") }
                    guard let sid = rawSize.stringValue,
                          let c = controls.first(where: { $0.id == sid }), c.kind == .number else {
                        throw bad("tool '\(id)': size_control must name a number control")
                    }
                    sizeControl = sid
                } else if kind == .stroke {
                    throw bad("tool '\(id)': a stroke tool needs a size_control")
                }
                tools.append(CanvasTool(id: id, kind: kind, label: label, icon: icon, params: params,
                                        sizeControl: sizeControl))
            }
            return tools
        }

        func parseAxis(_ raw: JSONValue?, _ name: String) throws -> CanvasAxis {
            guard let o = raw?.objectValue, let lo = o["min"]?.doubleValue, let hi = o["max"]?.doubleValue else {
                throw bad("'\(name)' is {min, max, unit?, mapping?}")
            }
            var unit = ""
            if let u = o["unit"], u != .null {
                guard let s = u.stringValue else { throw bad("'\(name).unit' must be a string") }
                unit = s
            }
            var mapping = CanvasAxisMapping.lin
            if let m = o["mapping"], m != .null {
                guard let s = m.stringValue, let parsed = CanvasAxisMapping(rawValue: s) else {
                    throw bad("'\(name).mapping' is \"lin\" or \"log\"")
                }
                mapping = parsed
            }
            let axis = CanvasAxis(lo: lo, hi: hi, unit: unit, mapping: mapping)
            if let why = axis.validationError { throw bad("'\(name)': \(why)") }
            return axis
        }

        // MARK: Commands

        register("script.canvas.open",
                 summary: "Opens a canvas the app draws for the script: a resizable plot with the "
                        + "script's tools (rectangle, stroke, point), a history of ENTRIES (undo / redo), "
                        + "image layers, a transport, and a sidebar of controls. With `modes: true` the "
                        + "hand also gets two modes (Instant: each gesture is a history step at once; "
                        + "Selection: gestures build a pending selection that `commit` seals into one "
                        + "step) and a draw / erase polarity on each gesture. One canvas per connection "
                        + "(a second replaces the first). Headless: the canvas exists, no window opens "
                        + "and no audio device is touched.",
                 params: [ParamSpec("title", "string", required: false, "Window title."),
                          ParamSpec("object", "uuid", required: false,
                                    "The object it is about: the canvas closes if it disappears."),
                          ParamSpec("controls", "array<control>", required: false,
                                    "The script.panel.open vocabulary: bool | number (optionally with presets) | button | choice | progress | section."),
                          ParamSpec("tools", "array<{id,kind,label,icon?,params?,size_control?}>",
                                    "kind: rect | stroke | point. `params` lists the bool / number / choice controls "
                                  + "snapshotted into each op. A stroke tool needs `size_control`, a number "
                                  + "control giving the diameter in screen points (1…1000); any other kind "
                                  + "refuses it. The first declared tool is active; with none declared a left "
                                  + "click in the plot does nothing (there is no Hand: navigation is the wheel, "
                                  + "⇧-wheel, the pinch and Fit)."),
                          ParamSpec("status", "string", required: false, "Initial status line."),
                          ParamSpec("busy", "bool", required: false, "Initial busy indicator."),
                          ParamSpec("modes", "bool", required: false,
                                    "Offer the Instant / Selection modes and the draw / erase polarity "
                                  + "(default false: Instant only, no operation is ever `subtract`). The "
                                  + "mode at opening is `instant`, never remembered."),
                          ParamSpec("remember", "string|true", required: false,
                                    "As for a panel: Validate stores the values, a re-open shows them, Reset restores the declared ones.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let (controls, values) = try ScriptControls.parse(p.raw["controls"] == nil ? [] : try p.array("controls"))
            let tools = try parseTools(try p.array("tools"), controls: controls)
            let object = try p.optionalUUID("object")
            if let object, vm.find(id: object) == nil {
                throw CommandError(code: .not_found, message: "no object \(object.uuidString)")
            }
            var canvas = ScriptCanvas(id: UUID(), owner: CommandCallContext.caller, objectID: object,
                                      title: try p.string("title", or: ""), controls: controls,
                                      values: values, tools: tools,
                                      activeTool: tools.first?.id)
            canvas.modes = try p.bool("modes", or: false)
            canvas.declared = values
            if let key = try ScriptControls.rememberKey(p.raw["remember"], title: canvas.title) {
                canvas.rememberKey = key
                ScriptControls.applyRemembered(key, controls: controls, into: &canvas.values)
                ScriptCanvasStore.applyRememberedState(to: &canvas)
                // The monitoring level is the PROJECT's, not the user's: another project opens at 0 dB.
                canvas.transport.monitorDB = CanvasProjectSettings.monitor(of: vm.canvasSettings[key])
            }
            canvas.status = try p.string("status", or: "")
            canvas.busy = try p.bool("busy", or: false)
            vm.scriptCanvases.open(canvas)
            return .object(["canvas_id": .string(canvas.id.uuidString), "rev": .int(0)])
        }

        register("script.canvas.set_image",
                 summary: "Sets the BASE image and the world it covers — or, with `slot`, the picture of one audio slot. "
                        + "`x` / `y` are {min, max, unit?, mapping?} "
                        + "(unit \"s\" gives time rulers, \"Hz\" Hz / kHz rulers; mapping \"lin\" or \"log\", the "
                        + "latter needing min > 0). The file is an OBJKCNV1 (indexed, with values), an OBJKRGB1 "
                        + "or any image ImageIO reads (no values). Same axes as before: the view and the layers "
                        + "are kept; otherwise the view is refitted and every layer dropped. `history_rev` = the "
                        + "history revision the image reflects (counted with the layers' to hide traces). "
                        + "With `slot` (original | result | delta) the file is that slot's picture instead: it covers "
                        + "the SAME world as the base image (no `x` / `y`, which are ignored; a base image must exist), "
                        + "and the plot draws the picture of the slot being HEARD, the base image when that slot has "
                        + "none — so switching what is heard switches the picture with no round trip. `path: null` "
                        + "with `slot` removes it. Never moves rev.",
                 params: [ParamSpec("canvas_id", "uuid", "The canvas."),
                          ParamSpec("path", "string|null", required: false,
                                    "The image file (required; null only with `slot`: removes that picture)."),
                          ParamSpec("slot", "string", required: false,
                                    "original | result | delta: the picture of that audio slot instead of the base image."),
                          ParamSpec("x", "object", required: false, "{min, max, unit?, mapping?} (base image only)."),
                          ParamSpec("y", "object", required: false, "{min, max, unit?, mapping?} (base image only)."),
                          ParamSpec("value_unit", "string", required: false,
                                    "The unit of the image's values, for the pointer readout."),
                          ParamSpec("history_rev", "int", required: false,
                                    "The history revision this image reflects (a script that redraws the "
                                  + "spectrogram to show the result): the app hides the trace of every op it covers.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("canvas_id")
            let historyRev = try p.optionalInt("history_rev")
            var slot: CanvasSlot? = nil
            if let s = try p.optionalString("slot") {
                guard let parsed = CanvasSlot(rawValue: s) else { throw bad("'slot' is \"original\", \"result\" or \"delta\"") }
                slot = parsed
            }
            guard let c = vm.scriptCanvases.canvases[id] else {
                throw CommandError(code: .not_found, message: "no canvas \(id.uuidString)")
            }
            guard c.state == .open else {
                throw CommandError(code: .invalid_state, message: "canvas is \(c.state.rawValue)")
            }
            if let slot {
                // A slot's picture covers the base image's world: no axes of its own.
                var picture: ScriptCanvasImage? = nil
                if p.raw["path"] == .null {
                    // removes the slot's picture
                } else {
                    picture = try ScriptCanvasImage.load(path: try p.string("path"))
                }
                try vm.scriptCanvases.setSlotImage(id, slot: slot, image: picture, historyRev: historyRev)
                return .object(["width": .int(picture?.width ?? 0), "height": .int(picture?.height ?? 0),
                                "has_values": .bool(picture?.hasValues ?? false)])
            }
            let x = try parseAxis(p.raw["x"], "x")
            let y = try parseAxis(p.raw["y"], "y")
            let valueUnit = try p.string("value_unit", or: "")
            let image = try ScriptCanvasImage.load(path: try p.string("path"))
            try vm.scriptCanvases.setImage(id, image: image, world: CanvasWorld(x: x, y: y), valueUnit: valueUnit,
                                           historyRev: historyRev)
            return .object(["width": .int(image.width), "height": .int(image.height),
                            "has_values": .bool(image.hasValues)])
        }

        register("script.canvas.set_layer",
                 summary: "Adds or replaces an overlay layer (an OBJKRGB1, an OBJKCNV1 or an ImageIO file); "
                        + "`path: null` removes it. A layer always covers the world rectangle exactly, row 0 on "
                        + "top, any size. Drawn above the base in ascending z (default 0), opacity 0…1 "
                        + "(default 1), at most 8. `history_rev` = the history revision the layer reflects: the "
                        + "app hides the trace of every op it covers. Never moves rev.",
                 params: [ParamSpec("canvas_id", "uuid", "The canvas."),
                          ParamSpec("layer", "string", "The layer's id (non-empty)."),
                          ParamSpec("path", "string|null", required: false, "The image file; null removes the layer."),
                          ParamSpec("history_rev", "int", required: false, "The history revision it reflects."),
                          ParamSpec("opacity", "number", required: false, "0…1."),
                          ParamSpec("z", "int", required: false, "Draw order.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("canvas_id")
            let layer = try p.string("layer")
            guard !layer.isEmpty else { throw bad("'layer' must not be empty") }
            let z = try p.optionalInt("z")
            let historyRev = try p.optionalInt("history_rev")
            let opacity = try p.optionalDouble("opacity")
            guard let c = vm.scriptCanvases.canvases[id] else {
                throw CommandError(code: .not_found, message: "no canvas \(id.uuidString)")
            }
            guard c.state == .open else {
                throw CommandError(code: .invalid_state, message: "canvas is \(c.state.rawValue)")
            }
            guard c.image != nil else {
                throw CommandError(code: .invalid_state, message: "no base image yet (script.canvas.set_image first)")
            }
            var image: ScriptCanvasImage? = nil
            if let rawPath = p.raw["path"], rawPath != .null {
                image = try ScriptCanvasImage.load(path: try p.string("path"))
            } else if p.raw["path"] == nil {
                throw bad("parameter 'path' (string or null) required")
            }
            let layers = try vm.scriptCanvases.setLayer(id, layer: layer, image: image, z: z,
                                                        opacity: opacity, historyRev: historyRev)
            return .object(["layers": .array(layers.map(layerPayload))])
        }

        register("script.canvas.set_audio",
                 summary: "Sets the three audio slots — original, result, delta — each a file path, or null to "
                        + "clear it (an absent slot is kept). `offset` = the x value at which the files' sample 0 "
                        + "plays (default 0, kept when absent). `history_rev` = the history revision the files "
                        + "reflect: while history.rev is ahead of it the window shows \"computing\". Clearing the "
                        + "slot being heard (`listen`) falls back to the original; clearing the original stops "
                        + "playback. `listen` chooses the slot heard. Never moves rev.",
                 params: [ParamSpec("canvas_id", "uuid", "The canvas."),
                          ParamSpec("original", "string|null", required: false, "Path, or null."),
                          ParamSpec("result", "string|null", required: false, "Path, or null."),
                          ParamSpec("delta", "string|null", required: false, "Path, or null."),
                          ParamSpec("offset", "number", required: false, "x of the files' sample 0."),
                          ParamSpec("history_rev", "int", required: false, "The history revision the files reflect."),
                          ParamSpec("listen", "string", required: false,
                                    "original | result | delta: the slot to hear, as the window's switch (it must "
                                  + "hold a file once this call is applied, else `invalid_state` and nothing is stored). "
                                  + "A script says it once, with its first files.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("canvas_id")
            var slots: [CanvasSlot: String?] = [:]
            for slot in CanvasSlot.allCases {
                guard let raw = p.raw[slot.rawValue] else { continue }
                if raw == .null { slots.updateValue(nil, forKey: slot) }
                else { slots.updateValue(try p.string(slot.rawValue), forKey: slot) }
            }
            let offset = try p.optionalDouble("offset")
            let historyRev = try p.optionalInt("history_rev")
            var listen: CanvasListen? = nil
            if let s = try p.optionalString("listen") {
                guard let l = CanvasListen(rawValue: s) else { throw bad("'listen' is \"original\", \"result\" or \"delta\"") }
                listen = l
            }
            try vm.scriptCanvases.setAudio(id, slots: slots, offset: offset, historyRev: historyRev, listen: listen)
            let c = try vm.scriptCanvases.read(id)
            var out: [String: JSONValue] = [
                "playing": .bool(c.transport.playing),
                "position": num(vm.scriptCanvases.position(of: id)),
                "caret": num(c.transport.caret),
            ]
            if let both = slotsPayload(c.transport).objectValue { out.merge(both) { a, _ in a } }
            return .object(out)
        }

        register("script.canvas.get",
                 summary: "The canvas as it stands: rev, state (open|validated|cancelled|closed), values, the "
                        + "button events since the last read (which this read empties), tool, modes / mode / "
                        + "polarity, history (rev, cursor, count, pending, unreflected op ids, entries), "
                        + "image, layers, world, view, transport.",
                 params: [ParamSpec("canvas_id", "uuid", "The canvas."),
                          ParamSpec("known_history_rev", "int", required: false,
                                    "When equal to history.rev, history.entries is omitted.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            return try readPayload(vm, try p.uuid("canvas_id"), knownHistoryRev: try p.optionalInt("known_history_rev"))
        }

        register("script.canvas.wait",
                 summary: "Long poll: answers as soon as rev > since_rev or the canvas is no longer open; at "
                        + "the timeout it answers the CURRENT state (no error — loop).",
                 params: [ParamSpec("canvas_id", "uuid", "The canvas."),
                          ParamSpec("since_rev", "int", "The last rev the script has seen."),
                          ParamSpec("timeout_ms", "int", required: false, "At most 5000 (default 1000)."),
                          ParamSpec("known_history_rev", "int", required: false,
                                    "When equal to history.rev, history.entries is omitted.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("canvas_id")
            let since = try p.int("since_rev")
            let known = try p.optionalInt("known_history_rev")
            let budget = Duration.milliseconds(min(5000, max(0, try p.int("timeout_ms", or: 1000))))
            let started = ContinuousClock.now
            while true {
                // Read without draining first: only a wait that RETURNS drains the events.
                guard let cur = vm.scriptCanvases.canvases[id] else {
                    throw CommandError(code: .not_found, message: "no canvas \(id.uuidString)")
                }
                if cur.rev > since || cur.state != .open || ContinuousClock.now - started >= budget {
                    return try readPayload(vm, id, knownHistoryRev: known)
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        register("script.canvas.update",
                 summary: "The script writes back: a status line, the busy flag, recalibrated values, new "
                        + "labels. Never moves rev (it would wake the script's own wait).",
                 params: [ParamSpec("canvas_id", "uuid", "The canvas."),
                          ParamSpec("status", "string", required: false, "Status line."),
                          ParamSpec("busy", "bool", required: false, "Busy indicator."),
                          ParamSpec("values", "object", required: false,
                                    "Control id → value (a progress: 0…1, or null = indeterminate)."),
                          ParamSpec("labels", "object", required: false, "Control id → new label.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let labels = try ScriptControls.parseLabels(p)
            let busy: Bool? = p.raw["busy"] == nil ? nil : try p.bool("busy")
            try vm.scriptCanvases.update(try p.uuid("canvas_id"), status: try p.optionalString("status"),
                                         busy: busy, values: try ScriptControls.parseValues(p), labels: labels)
            return .object(["ok": .bool(true)])
        }

        register("script.canvas.close",
                 summary: "Closes the canvas (state 'closed') and its window; stops its audio. Closing the "
                        + "connection does the same.",
                 params: [ParamSpec("canvas_id", "uuid", "The canvas.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("canvas_id")
            guard vm.scriptCanvases.canvases[id] != nil else {
                throw CommandError(code: .not_found, message: "no canvas \(id.uuidString)")
            }
            vm.scriptCanvases.end(id, as: .closed)
            return .object(["closed": .bool(true)])
        }

        register("script.canvas.input",
                 summary: "The HAND's door, for a headless test — the window goes through the same store "
                        + "functions. Applied in this order: values, tool, mode, polarity, view, op, commit, "
                        + "discard, undo, redo, seek, listen, monitor_db, play, press. `op` is {kind: rect, x0, x1, y0, y1, "
                        + "polarity?} (sorted and clamped to the world; zero area adds nothing), {kind: stroke, "
                        + "points: [[x, y], …] (2…20000, kept as given), view_scale?: {x, y} (points per warped "
                        + "unit; default the current view), polarity?} or {kind: point, x, y, polarity?}; it uses "
                        + "the active tool when its kind matches, else the first tool of that kind. `polarity` "
                        + "defaults to the toggle's (Selection mode) or `add` (Instant); `subtract` in Instant "
                        + "is `invalid_state`. A stroke shorter than 1 point on screen adds nothing. In Instant "
                        + "mode an op is a history STEP at once; in Selection mode it is a DRAFT (pending "
                        + "selection). `commit` seals the pending drafts into ONE step (`added: false` with "
                        + "none); `discard` throws them away (the window's \"Ignore\"). `mode` (instant | "
                        + "select) is `invalid_state` without `modes` and while a selection is pending. Moves "
                        + "rev on a values change, an added op, a commit, a discard, an undo, a redo or a "
                        + "press; not on tool, mode, polarity, view or transport.",
                 params: [ParamSpec("canvas_id", "uuid", "The canvas."),
                          ParamSpec("values", "object", required: false, "Control id → value."),
                          ParamSpec("press", "string", required: false,
                                    "A button id, 'validate', 'cancel' or (remember canvases) 'reset'."),
                          ParamSpec("tool", "string", required: false, "A tool id."),
                          ParamSpec("mode", "string", required: false, "instant | select (needs `modes`)."),
                          ParamSpec("polarity", "string", required: false,
                                    "add | subtract: the toggle's state (subtract needs the selection mode)."),
                          ParamSpec("view", "object", required: false, "{x0, x1, y0, y1} in data units."),
                          ParamSpec("op", "object", required: false, "A gesture (see above)."),
                          ParamSpec("commit", "bool", required: false,
                                    "true seals the pending selection into one step (the window's \"Apply\")."),
                          ParamSpec("discard", "bool", required: false,
                                    "true throws the pending selection away (the window's \"Ignore\")."),
                          ParamSpec("undo", "bool", required: false, "One entry back."),
                          ParamSpec("redo", "bool", required: false, "One entry forward."),
                          ParamSpec("seek", "number", required: false, "Caret (and playhead if playing), clamped to [0, end]."),
                          ParamSpec("listen", "string", required: false,
                                    "original | result | delta (`invalid_state` when that slot is empty)."),
                          ParamSpec("monitor_db", "number", required: false,
                                    "The monitoring level, dB (-20…+20, clamped; 0 = unity): what is HEARD in the "
                                  + "window, never a file the script wrote. App-owned; a remembering canvas keeps it "
                                  + "in the PROJECT. Does not move rev."),
                          ParamSpec("play", "bool", required: false, "true starts at the caret, false stops.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let store = vm.scriptCanvases
            let id = try p.uuid("canvas_id")
            guard let before = store.canvases[id] else {
                throw CommandError(code: .not_found, message: "no canvas \(id.uuidString)")
            }
            guard before.state == .open else {
                throw CommandError(code: .invalid_state, message: "canvas is \(before.state.rawValue)")
            }
            // Parse what can be parsed before touching anything.
            let values = try ScriptControls.parseValues(p)
            let press = try p.optionalString("press")
            let tool = try p.optionalString("tool")
            var mode: CanvasMode? = nil
            if let s = try p.optionalString("mode") {
                guard let m = CanvasMode(rawValue: s) else { throw bad("'mode' is \"instant\" or \"select\"") }
                mode = m
            }
            func parsePolarity(_ raw: String, _ what: String) throws -> CanvasPolarity {
                guard let pol = CanvasPolarity(rawValue: raw) else {
                    throw CommandError(code: .bad_params, message: "'\(what)' is \"add\" or \"subtract\"")
                }
                return pol
            }
            var polarity: CanvasPolarity? = nil
            if let s = try p.optionalString("polarity") { polarity = try parsePolarity(s, "polarity") }
            var view: [Double]? = nil
            if let raw = p.raw["view"] {
                guard let o = raw.objectValue, let x0 = o["x0"]?.doubleValue, let x1 = o["x1"]?.doubleValue,
                      let y0 = o["y0"]?.doubleValue, let y1 = o["y1"]?.doubleValue else {
                    throw bad("'view' is {x0, x1, y0, y1} in data units")
                }
                view = [x0, x1, y0, y1]
            }
            var listen: CanvasListen? = nil
            if let s = try p.optionalString("listen") {
                guard let l = CanvasListen(rawValue: s) else { throw bad("'listen' is \"original\", \"result\" or \"delta\"") }
                listen = l
            }
            var opKind: String? = nil
            var opObject: [String: JSONValue] = [:]
            var opPolarity: CanvasPolarity? = nil
            if let raw = p.raw["op"] {
                guard let o = raw.objectValue, let k = o["kind"]?.stringValue,
                      CanvasToolKind(rawValue: k) != nil else {
                    throw bad("'op' is {kind: rect|stroke|point, …}")
                }
                opKind = k
                opObject = o
                if let rawPol = o["polarity"], rawPol != .null {
                    guard let s = rawPol.stringValue else { throw bad("'op.polarity' is \"add\" or \"subtract\"") }
                    opPolarity = try parsePolarity(s, "op.polarity")
                }
            }
            let wantCommit = try p.bool("commit", or: false)
            let wantDiscard = try p.bool("discard", or: false)
            let wantUndo = try p.bool("undo", or: false)
            let wantRedo = try p.bool("redo", or: false)
            let seek = try p.optionalDouble("seek")
            let monitor = try p.optionalDouble("monitor_db")
            let play: Bool? = p.raw["play"] == nil ? nil : try p.bool("play")

            let number = { (o: [String: JSONValue], key: String) throws -> Double in
                guard let d = o[key]?.doubleValue, d.isFinite else {
                    throw CommandError(code: .bad_params, message: "op.\(key) is a finite number")
                }
                return d
            }

            // Values first, and alone: a refused batch changes nothing (the store's own rule).
            if !values.isEmpty { try store.input(id, values: values, press: nil) }
            if let tool { try store.selectTool(id, tool: tool) }
            if let mode { try store.setMode(id, mode) }
            if let polarity { try store.setPolarity(id, polarity) }
            if let v = view { try store.setView(id, x0: v[0], x1: v[1], y0: v[2], y1: v[3]) }
            var added = false
            if let kind = opKind {
                switch kind {
                case "rect":
                    added = try store.addRect(id, x0: try number(opObject, "x0"), x1: try number(opObject, "x1"),
                                              y0: try number(opObject, "y0"), y1: try number(opObject, "y1"),
                                              polarity: opPolarity)
                case "stroke":
                    guard let raw = opObject["points"]?.arrayValue else { throw bad("op.points is [[x, y], …]") }
                    guard raw.count >= ScriptCanvasStore.minStrokePoints, raw.count <= ScriptCanvasStore.maxStrokePoints else {
                        throw bad("a stroke has \(ScriptCanvasStore.minStrokePoints) to \(ScriptCanvasStore.maxStrokePoints) points")
                    }
                    var points: [CanvasPoint] = []
                    points.reserveCapacity(raw.count)
                    for e in raw {
                        guard let pair = e.arrayValue, pair.count == 2, let x = pair[0].doubleValue,
                              let y = pair[1].doubleValue, x.isFinite, y.isFinite else {
                            throw bad("op.points is [[x, y], …] with finite numbers")
                        }
                        points.append(CanvasPoint(x: x, y: y))
                    }
                    var scale: (x: Double, y: Double)? = nil
                    if let rawScale = opObject["view_scale"], rawScale != .null {
                        guard let o = rawScale.objectValue, let sx = o["x"]?.doubleValue,
                              let sy = o["y"]?.doubleValue else {
                            throw bad("op.view_scale is {x, y} (points per warped unit)")
                        }
                        scale = (sx, sy)
                    }
                    added = try store.addStroke(id, points: points, scale: scale, polarity: opPolarity)
                default:
                    added = try store.addPoint(id, x: try number(opObject, "x"), y: try number(opObject, "y"),
                                               polarity: opPolarity)
                }
            }
            var committed = false
            if wantCommit { committed = try store.commit(id) }
            var discarded = false
            if wantDiscard { discarded = try store.discardPending(id) }
            if wantUndo { try store.undo(id) }
            if wantRedo { try store.redo(id) }
            if let seek { try store.seek(id, to: seek) }
            if let listen { try store.setListen(id, listen) }
            if let monitor { try store.setMonitor(id, db: monitor) }
            if let play { if play { try store.play(id) } else { try store.stop(id) } }
            if let press { try store.input(id, values: [:], press: press) }
            let c = store.canvases[id]
            return .object(["rev": .int(c?.rev ?? 0), "history_rev": .int(c?.historyRev ?? 0),
                            "cursor": .int(c?.history.cursor ?? 0), "pending": .int(c?.history.pending ?? 0),
                            "added": .bool(added || committed), "committed": .bool(committed),
                            "discarded": .bool(discarded)])
        }

        register("script.canvas.list",
                 summary: "The canvases currently known.",
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            vm.pruneScriptOverlays()
            let rows = vm.scriptCanvases.canvases.values.sorted { $0.id.uuidString < $1.id.uuidString }
            return .object(["canvases": .array(rows.map { c in
                .object(["canvas_id": .string(c.id.uuidString), "title": .string(c.title),
                         "state": .string(c.state.rawValue),
                         "object": .stringOrNull(c.objectID?.uuidString)])
            })])
        }
    }
}
