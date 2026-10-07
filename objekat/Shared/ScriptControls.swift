import Foundation

// MARK: - The control vocabulary a script declares — parse, apply, remember

/// The controls of a script's window (checkboxes, sliders, choices, buttons, progress bars,
/// sections) and what happens to their values, in ONE place for the two windows that carry them:
/// the panel (`script.panel.*`, @see ScriptPanelStore) and the canvas's sidebar
/// (`script.canvas.*`, @see ScriptCanvasStore). Extracted, with no change in behaviour, from
/// `Commands+ScriptPanel` and `ScriptPanelStore`: the code is the same and so are the messages —
/// a script written against the panel must get the very same answers from the canvas.
///
/// What a HAND can set is `bool`, `number` and `choice` (`holdsHandValue`); what the SCRIPT can
/// write back also includes a `progress`. A `button` and a `section` hold no value.
enum ScriptControls {

    private static func bad(_ m: String) -> CommandError { CommandError(code: .bad_params, message: m) }

    // MARK: Parsing what a script declares

    static func parse(_ arr: [JSONValue]) throws -> ([ScriptPanelControl], [String: JSONValue]) {
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
            var presets: [Double] = []
            if let raw = o["presets"] {
                guard kind == .number else { throw bad("control '\(id)': presets belong to a number") }
                guard let arr = raw.arrayValue else { throw bad("control '\(id)': presets is a list of numbers") }
                for e in arr {
                    guard let d = e.doubleValue else { throw bad("control '\(id)': presets is a list of numbers") }
                    presets.append(d)
                }
            }
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
                if o["presets"] != nil, let why = ScriptControlPresets.problem(presets, min: mn, max: mx) {
                    throw bad("control '\(id)': \(why)")
                }
                // With presets, the default is the first one unless the script names one of them.
                let v = o["value"]?.doubleValue ?? (presets.first ?? mn)
                guard v >= mn, v <= mx else { throw bad("control '\(id)': value out of range") }
                guard presets.isEmpty || presets.contains(v) else {
                    throw bad("control '\(id)': value is not one of its presets")
                }
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
            control.presets = presets
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

    /// `values` of a command, as an object (absent = empty).
    static func parseValues(_ p: CommandParams) throws -> [String: JSONValue] {
        guard let v = p.raw["values"] else { return [:] }
        guard let o = v.objectValue else { throw bad("'values' must be an object") }
        return o
    }

    /// `labels` of `update`: control id → new text.
    static func parseLabels(_ p: CommandParams) throws -> [String: String] {
        var labels: [String: String] = [:]
        if let raw = p.raw["labels"] {
            guard let o = raw.objectValue else { throw bad("'labels' must be an object") }
            for (k, v) in o {
                guard let t = v.stringValue else { throw bad("'labels.\(k)' must be a string") }
                labels[k] = t
            }
        }
        return labels
    }

    // MARK: What the hand does

    /// Applies what a hand (the window, or an `input` command) set. Unknown ids and kinds that do
    /// not match are refused; a number is clamped to its range. Throws before the caller has stored
    /// anything, so a refused batch changes nothing.
    static func applyHand(_ input: [String: JSONValue], controls: [ScriptPanelControl],
                          into values: inout [String: JSONValue]) throws {
        for (key, v) in input {
            guard let c = controls.first(where: { $0.id == key }), c.kind.holdsHandValue else {
                throw CommandError(code: .bad_params, message: "no value control '\(key)'")
            }
            switch c.kind {
            case .bool:
                guard let b = v.boolValue else {
                    throw CommandError(code: .bad_params, message: "'\(key)' is a bool")
                }
                values[key] = .bool(b)
            case .number:
                guard let d = v.doubleValue else {
                    throw CommandError(code: .bad_params, message: "'\(key)' is a number")
                }
                values[key] = .number(fit(d, to: c))
            case .choice:
                guard let s = v.stringValue, c.options.contains(where: { $0.id == s }) else {
                    throw CommandError(code: .bad_params,
                                       message: "'\(key)' is one of \(c.options.map(\.id))")
                }
                values[key] = .string(s)
            case .button, .progress, .section: break
            }
        }
    }

    /// What a number control holds for `d`: clamped to its range, then — when it has `presets` — snapped to
    /// the nearest preset (a slider keeps whatever it is given within the range).
    static func fit(_ d: Double, to c: ScriptPanelControl) -> Double {
        let clamped = Swift.min(c.max, Swift.max(c.min, d))
        guard !c.presets.isEmpty else { return clamped }
        return ScriptControlPresets.nearest(clamped, in: c.presets) ?? clamped
    }

    /// The values a hand can set (never a progress bar, a button or a section).
    static func handValues(_ controls: [ScriptPanelControl],
                           _ values: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for c in controls where c.kind.holdsHandValue { out[c.id] = values[c.id] }
        return out
    }

    // MARK: What the script writes back

    /// New texts for some controls (`update`'s `labels`).
    static func applyLabels(_ labels: [String: String], to controls: inout [ScriptPanelControl]) throws {
        for (key, text) in labels {
            guard let i = controls.firstIndex(where: { $0.id == key }) else {
                throw CommandError(code: .bad_params, message: "no control '\(key)'")
            }
            controls[i].label = text
        }
    }

    /// `update`'s `values`: a progress is 0…1 or null, the other kinds as for a hand.
    static func applyScript(_ input: [String: JSONValue], controls: [ScriptPanelControl],
                            into values: inout [String: JSONValue]) throws {
        for (key, v) in input {
            guard let c = controls.first(where: { $0.id == key }), c.kind.holdsValue else {
                throw CommandError(code: .bad_params, message: "no value control '\(key)'")
            }
            if c.kind == .progress {
                if case .null = v { values[key] = .null }
                else if let d = v.doubleValue { values[key] = .number(Swift.min(1, Swift.max(0, d))) }
                else { throw CommandError(code: .bad_params, message: "'\(key)': a progress is 0…1 or null") }
            } else if c.kind == .bool, let b = v.boolValue { values[key] = .bool(b) }
            else if c.kind == .number, let d = v.doubleValue {
                values[key] = .number(fit(d, to: c))
            } else if c.kind == .choice, let s = v.stringValue, c.options.contains(where: { $0.id == s }) {
                values[key] = .string(s)
            } else {
                throw CommandError(code: .bad_params, message: "'\(key)': wrong type")
            }
        }
    }

    // MARK: Remember

    /// `remember` of `open`: a key (string) or `true` (= the title); nil when absent, null or false.
    static func rememberKey(_ raw: JSONValue?, title: String) throws -> String? {
        guard let raw, raw != .null, raw != .bool(false) else { return nil }
        var key: String
        if case .string(let k) = raw { key = k }
        else if raw == .bool(true) { key = title }
        else { throw bad("'remember' is a key (string) or true") }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw bad("'remember' needs a non-empty key (or a title)") }
        return key
    }

    /// Puts onto `values` what was remembered under `key` and still fits `controls`.
    static func applyRemembered(_ key: String, controls: [ScriptPanelControl],
                                into values: inout [String: JSONValue]) {
        let kept = ScriptPanelMemory.applicable(ScriptPanelMemory.load(key), to: controls)
        for (k, v) in kept { values[k] = v }
    }

    /// Validate is the ONLY thing that remembers: not Cancel, not the window closing.
    static func remember(_ key: String, controls: [ScriptPanelControl], values: [String: JSONValue]) {
        ScriptPanelMemory.save(key, handValues(controls, values))
    }

    /// `press: "reset"`: back to what the script DECLARED, and the memory erased.
    static func reset(_ key: String, controls: [ScriptPanelControl], declared: [String: JSONValue],
                      into values: inout [String: JSONValue]) {
        for c in controls where c.kind.holdsHandValue { values[c.id] = declared[c.id] }
        ScriptPanelMemory.erase(key)
    }
}
