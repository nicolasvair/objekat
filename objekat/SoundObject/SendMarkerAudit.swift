import Foundation

// The audit of send markers — docs/plan_sends_rework.md §D.1.B step 2.2. Pure: it reads a model, it
// changes nothing. `debug.send_marker_audit` runs it (and, from step 2.3, adds the engine's half), and
// the scenario asserts "no violation" after every phase.
//
// WHY. A marker is an `ObjectPlugin` entry in the middle of ~200 hand-written chain walks. A walk that
// does not know it reads it as a plugin; the compile then fails to resolve that "plugin" and the model
// ERASES it. The audit catches both ends of that failure: a marker that broke a rule, and a PHANTOM — an
// entry that is neither a plugin (it has no identifier), nor a rack, nor a bin, nor a marker: what a
// marker looks like once some copy has rebuilt it as a plain plugin.

enum SendMarkerAudit {

    struct Violation: Equatable {
        /// The object (or stem) the entry lives on.
        let host: UUID
        /// Where, readable: `plugins[2]`, `plugins[1].rack.voices[0][3]`, `instruments[0]`.
        let path: String
        /// The rule: `orphan`, `duplicate`, `nested`, `on_aux`, `on_stem`, `in_instruments`, `phantom`,
        /// `in_send_plugins`, `send_chain_not_leaf`, `send_plugin_linked`.
        let rule: String
    }

    /// Every violation in the tree `items` (groups at any depth) and in the stems' chains.
    static func violations(items: [SoundObject], stems: [Stem] = []) -> [Violation] {
        var out: [Violation] = []

        /// Walks one series: `path` names it, `top` is true for the host's own `plugins` array.
        func walk(_ series: [ObjectPlugin], host: UUID, path: String, top: Bool,
                  onAux: Bool, onStem: Bool, known: Set<UUID>, seen: inout Set<UUID>) {
            for (i, p) in series.enumerated() {
                let here = "\(path)[\(i)]"
                if let m = p.sendMarker {
                    if onStem { out.append(Violation(host: host, path: here, rule: "on_stem")) }
                    else if onAux { out.append(Violation(host: host, path: here, rule: "on_aux")) }
                    else if !top { out.append(Violation(host: host, path: here, rule: "nested")) }
                    else if !known.contains(m.auxID) { out.append(Violation(host: host, path: here, rule: "orphan")) }
                    else if !seen.insert(m.auxID).inserted { out.append(Violation(host: host, path: here, rule: "duplicate")) }
                    continue
                }
                if let rack = p.rack {
                    for (v, voice) in rack.voices.enumerated() {
                        walk(voice, host: host, path: "\(here).rack.voices[\(v)]", top: false,
                             onAux: onAux, onStem: onStem, known: known, seen: &seen)
                    }
                } else if let block = p.fxBlock {
                    walk(block.plugins, host: host, path: "\(here).fxBlock.plugins", top: false,
                         onAux: onAux, onStem: onStem, known: known, seen: &seen)
                } else if p.identifier.isEmpty && p.formatName.isEmpty {
                    out.append(Violation(host: host, path: here, rule: "phantom"))
                }
            }
        }

        func visit(_ array: [SoundObject]) {
            for o in array {
                var seen: Set<UUID> = []
                let known = Set(o.sends.map(\.auxID))
                walk(o.plugins, host: o.id, path: "plugins", top: true, onAux: o.isAux, onStem: false,
                     known: known, seen: &seen)
                for (i, inst) in o.instruments.enumerated() {
                    if inst.sendMarker != nil { out.append(Violation(host: o.id, path: "instruments[\(i)]", rule: "in_instruments")) }
                    else if inst.identifier.isEmpty && inst.formatName.isEmpty && !inst.isContainer {
                        out.append(Violation(host: o.id, path: "instruments[\(i)]", rule: "phantom"))
                    }
                }
                // The plugins of a send (INC 3): plain plugins only — a marker there would be a send of a
                // send, a block or a bin is not allowed in v1 (@see SendChain.sanitised).
                for (j, send) in o.sends.enumerated() {
                    for (k, p) in send.plugins.enumerated() {
                        let here = "sends[\(j)].plugins[\(k)]"
                        if p.sendMarker != nil { out.append(Violation(host: o.id, path: here, rule: "in_send_plugins")) }
                        else if p.isContainer { out.append(Violation(host: o.id, path: here, rule: "send_chain_not_leaf")) }
                        else if p.identifier.isEmpty && p.formatName.isEmpty {
                            out.append(Violation(host: o.id, path: here, rule: "phantom"))
                        }
                        // NO LINK ON A SEND (decision of 10 October 2026, @see SendChain.sanitised).
                        if p.linkGroupID != nil || p.detachedLinkGroupID != nil {
                            out.append(Violation(host: o.id, path: here, rule: "send_plugin_linked"))
                        }
                    }
                }
                if case .group(let children, _) = o.kind { visit(children) }
            }
        }
        visit(items)

        for st in stems {
            var seen: Set<UUID> = []
            walk(st.plugins, host: st.id, path: "plugins", top: true, onAux: false, onStem: true,
                 known: [], seen: &seen)
        }
        return out
    }

    /// How many markers the tree holds (top level only: the ones that count).
    static func markerCount(items: [SoundObject]) -> Int {
        var n = 0
        func visit(_ array: [SoundObject]) {
            for o in array {
                n += ObjectPlugin.topLevelSendMarkers(in: o.plugins).count
                if case .group(let children, _) = o.kind { visit(children) }
            }
        }
        visit(items)
        return n
    }

    // MARK: - The engine's half

    /// One entry of the engine's list for a sender (`OBJEngineCore chainLayoutForObjectID:`).
    struct LayoutEntry: Equatable {
        let index: Int
        let role: String            // trimIn, trimOut, fader, windowFade, fx, send, other
        let key: String?            // fx: the model plugin id
        let aux: String?            // send: the aux id
        let tapPosition: Int?       // send: the code the plugin was told (0 post, 1 pre, 2 input, 3 chain)
    }

    /// Where the engine put each of `object`'s sends against where the model asks (PURE: the layout is
    /// data). `rule` strings: `index_before_<role>` / `index_after_<role>`, `tap_position`. Only sends
    /// that are in the layout are judged (a send the plan did not lay has no plugin).
    static func engineViolations(object: SoundObject, layout: [LayoutEntry]) -> [Violation] {
        var out: [Violation] = []
        func first(_ role: String) -> Int? { layout.first { $0.role == role }?.index }
        let trimIn = first("trimIn"), trimOut = first("trimOut"), fader = first("fader"), window = first("windowFade")
        func fx(_ id: UUID?) -> Int? {
            guard let id else { return nil }
            return layout.first { $0.role == "fx" && $0.key?.lowercased() == id.uuidString.lowercased() }?.index
        }
        for entry in layout where entry.role == "send" {
            guard let aux = entry.aux.flatMap({ UUID(uuidString: $0) }),
                  let position = object.sendPosition(auxID: aux) else { continue }
            let at = entry.index
            func bad(_ rule: String) { out.append(Violation(host: object.id, path: "send[\(aux.uuidString)]@\(at)", rule: rule)) }
            func after(_ other: Int?, _ name: String) { if let o = other, !(at > o) { bad("index_after_" + name) } }
            func before(_ other: Int?, _ name: String) { if let o = other, !(at < o) { bad("index_before_" + name) } }
            let code: Int
            switch position {
            case .postFader:
                code = 0
                after(fader, "fader"); after(window, "windowFade")
            case .preFader:
                code = 1
                after(trimOut, "trimOut"); before(fader, "fader")
            case .input:
                code = 2
                before(trimIn ?? fader, trimIn != nil ? "trimIn" : "fader")
            case .chain:
                code = 3
                after(trimIn, "trimIn")
                let n = ObjectPlugin.neighbours(ofMarkerFor: aux, in: object.plugins)
                after(fx(n?.after), "previous_plugin")
                if let nextIndex = fx(n?.before) { before(nextIndex, "next_plugin") }
                else { before(trimOut ?? fader, trimOut != nil ? "trimOut" : "fader") }
            }
            if let t = entry.tapPosition, t != code { bad("tap_position") }
        }
        return out
    }
}
