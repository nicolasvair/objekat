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
        /// The rule: `orphan`, `duplicate`, `nested`, `on_aux`, `on_stem`, `in_instruments`, `phantom`.
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
}
