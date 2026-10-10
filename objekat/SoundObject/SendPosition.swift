import Foundation

// Where a send takes its signal — docs/plan_sends_rework.md §D.1.A (INC 2, session format 22).
//
// Four positions, two of them STORED ON THE SEND (`AuxSend.tap`), one WRITTEN IN THE CHAIN:
//
//     input       between the head (file / instrument) and the chain's IN gain          tap = .input
//     chain(i)    on the trunk, before the top-level entry i of `plugins`               a SendMarker entry
//     preFader    between the chain's OUT gain and the pan / volume / mute zone         tap = .preFader
//     postFader   under the fader and the window (the default, the oldest behaviour)    tap = .postFader
//
// Everything here is PURE: no engine, no view-model. The engine and the signal view read the answer of
// `sendPosition(auxID:)`; the gestures write through `settingSendPosition(auxID:_:)`; the load, every
// paste and the audit run `sanitisingSends()`.

/// A send's place, as a person reads it (the API's `position`: input, chain, pre_fader, post_fader).
enum SendPosition: Equatable {
    case input
    /// Before the top-level plugin entry `i` (send markers do not count); `i == count` = after the last
    /// one, still before the OUT gain.
    case chain(Int)
    case preFader
    case postFader

    /// The API / log name of the position.
    var name: String {
        switch self {
        case .input:     return "input"
        case .chain:     return "chain"
        case .preFader:  return "pre_fader"
        case .postFader: return "post_fader"
        }
    }

    /// The position a name stands for (`chain` needs its index).
    static func named(_ name: String, index: Int? = nil) -> SendPosition? {
        switch name {
        case "input":      return .input
        case "pre_fader":  return .preFader
        case "post_fader": return .postFader
        case "chain":      return index.map { .chain($0) }
        default:           return nil
        }
    }
}

// MARK: - Markers in a chain

extension ObjectPlugin {

    /// The top-level markers of `plugins`, in chain order.
    static func topLevelSendMarkers(in plugins: [ObjectPlugin]) -> [SendMarker] {
        plugins.compactMap(\.sendMarker)
    }

    /// The index of the marker for `auxID` among the top-level entries that are NOT markers (the
    /// `chain(i)` the marker stands for), or nil if the top level holds none.
    static func sendMarkerChainIndex(auxID: UUID, in plugins: [ObjectPlugin]) -> Int? {
        var entries = 0
        for p in plugins {
            if let m = p.sendMarker {
                if m.auxID == auxID { return entries }
            } else {
                entries += 1
            }
        }
        return nil
    }

    /// Where each top-level marker stands, as aux → `chain(i)` index. Two chains with the same answer have
    /// their markers in the same places (undo reads it to know whether a restore moved one).
    static func sendMarkerPlaces(in plugins: [ObjectPlugin]) -> [UUID: Int] {
        var out: [UUID: Int] = [:]
        var entries = 0
        for p in plugins {
            if let m = p.sendMarker { out[m.auxID] = entries } else { entries += 1 }
        }
        return out
    }

    /// The model index that stands for the view's index `visible` (markers do not count): immediately
    /// BEFORE the `visible`-th entry that is not a marker, after the markers sitting in that gap; the end
    /// of the array when `visible` is past the last entry.
    static func modelIndex(ofVisibleIndex visible: Int, in plugins: [ObjectPlugin]) -> Int {
        let wanted = max(0, visible)
        var seen = 0
        for (k, p) in plugins.enumerated() where !p.isSendMarker {
            if seen == wanted { return k }
            seen += 1
        }
        return plugins.count
    }

    /// The view's index of the entry at model index `model`: how many non-markers precede it.
    static func visibleIndex(ofModelIndex model: Int, in plugins: [ObjectPlugin]) -> Int {
        plugins.prefix(max(0, model)).reduce(0) { $0 + ($1.isSendMarker ? 0 : 1) }
    }

    /// The `chain(i)` index that puts a marker immediately BEFORE the top-level plugin `id` (markers do
    /// not count); nil if `id` is not a top-level non-marker entry.
    static func chainIndex(ofTopLevelPlugin id: UUID, in plugins: [ObjectPlugin]) -> Int? {
        var entries = 0
        for p in plugins where !p.isSendMarker {
            if p.id == id { return entries }
            entries += 1
        }
        return nil
    }

    /// The real (non-marker) top-level entries on each side of the marker for `auxID`: the one before
    /// it and the one after it, nil at the ends. nil overall if there is no such marker.
    static func neighbours(ofMarkerFor auxID: UUID,
                           in plugins: [ObjectPlugin]) -> (after: UUID?, before: UUID?)? {
        guard let k = plugins.firstIndex(where: { $0.sendMarker?.auxID == auxID }) else { return nil }
        let prev = plugins[..<k].last(where: { !$0.isSendMarker })?.id
        let next = plugins[(k + 1)...].first(where: { !$0.isSendMarker })?.id
        return (prev, next)
    }

    /// How many top-level entries are not markers: the largest valid `chain(i)`.
    static func chainEntryCount(_ plugins: [ObjectPlugin]) -> Int {
        plugins.reduce(0) { $0 + ($1.isSendMarker ? 0 : 1) }
    }

    /// `plugins` without the markers `drop` selects, at any depth (a marker belongs at the top level,
    /// but a retouched file may hold one deeper). Pure; the other entries are returned as they are.
    static func removingSendMarkers(from plugins: [ObjectPlugin],
                                    where drop: (SendMarker) -> Bool) -> [ObjectPlugin] {
        plugins.compactMap { p in
            if let m = p.sendMarker { return drop(m) ? nil : p }
            return p.mappingChildSeries { removingSendMarkers(from: $0, where: drop) }
        }
    }

    /// `plugins` with every marker removed (the chain of a stem or of the Main, which never send).
    static func strippingSendMarkers(_ plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        removingSendMarkers(from: plugins) { _ in true }
    }

    /// True if any marker, at any depth, satisfies `test`.
    static func containsSendMarker(in plugins: [ObjectPlugin], where test: (SendMarker) -> Bool) -> Bool {
        plugins.contains { p in
            if let m = p.sendMarker { return test(m) }
            return p.childSeries.contains { containsSendMarker(in: $0, where: test) }
        }
    }
}

// MARK: - Reading and writing a send's position

extension SoundObject {

    /// The effective position of the send towards `auxID`, or nil if the object has no such send.
    /// A top-level marker for the aux WINS over `tap`: it is where the send really is.
    func sendPosition(auxID: UUID) -> SendPosition? {
        guard let send = sends.first(where: { $0.auxID == auxID }) else { return nil }
        if let i = ObjectPlugin.sendMarkerChainIndex(auxID: auxID, in: plugins) { return .chain(i) }
        switch send.tap {
        case .postFader: return .postFader
        case .preFader:  return .preFader
        case .input:     return .input
        }
    }

    /// The object with the send towards `auxID` moved to `position`; unchanged if it has no such send.
    ///   • out of the chain: the marker (wherever it is) goes and `tap` is written;
    ///   • into the chain: the marker is placed immediately before top-level entry `i` (after the
    ///     markers already sitting in that gap; `i` is clamped, `count` = at the end) and `tap` goes
    ///     back to `.postFader`, so that losing a marker (a bake, a hand-edited file) falls back to the
    ///     oldest, best-known behaviour.
    func settingSendPosition(auxID: UUID, _ position: SendPosition) -> SoundObject {
        guard let si = sends.firstIndex(where: { $0.auxID == auxID }) else { return self }
        var o = self
        o.plugins = ObjectPlugin.removingSendMarkers(from: o.plugins) { $0.auxID == auxID }
        switch position {
        case .postFader: o.sends[si].tap = .postFader
        case .preFader:  o.sends[si].tap = .preFader
        case .input:     o.sends[si].tap = .input
        case .chain(let wanted):
            o.sends[si].tap = .postFader
            let i = min(max(0, wanted), ObjectPlugin.chainEntryCount(o.plugins))
            var seen = 0
            var at = o.plugins.count
            for (k, p) in o.plugins.enumerated() where !p.isSendMarker {
                if seen == i { at = k; break }
                seen += 1
            }
            o.plugins.insert(ObjectPlugin.makeSendMarker(for: auxID), at: at)
        }
        return o
    }

    /// The object with the send towards `old` aimed at `new` instead ("Change target…", `send.retarget`):
    /// same level, on/off, tap, marker place, automation lane and touch order. Pure and unconditional —
    /// the caller has checked that `new` is free and allowed. Unchanged if there is no send to `old`
    /// or if `new` already has one.
    func retargetingSend(from old: UUID, to new: UUID) -> SoundObject {
        guard old != new, let si = sends.firstIndex(where: { $0.auxID == old }),
              !sends.contains(where: { $0.auxID == new }) else { return self }
        var o = self
        o.sends[si].auxID = new
        func remap(_ series: [ObjectPlugin]) -> [ObjectPlugin] {
            series.map { p in
                if p.sendMarker?.auxID == old {
                    var q = p
                    q.sendMarker = SendMarker(auxID: new)
                    return q
                }
                return p.mappingChildSeries(remap)
            }
        }
        o.plugins = remap(o.plugins)
        for i in o.automation.indices where o.automation[i].param == .send(auxID: old) {
            o.automation[i].param = .send(auxID: new)
        }
        o.automationTouchOrder = o.automationTouchOrder.map { $0 == .send(auxID: old) ? .send(auxID: new) : $0 }
        return o
    }

    /// The object with a SECOND send, towards `new`, that is the copy of its send towards `old` (the split
    /// of an aux: both halves stay fed the same way): same level, on/off and position — `tap` by value,
    /// and for a send taken in the chain a marker for `new` laid immediately after `old`'s (two taps at the
    /// same point are equivalent, their order is cosmetic). Unchanged if there is no send to `old` or if
    /// `new` already has one. Pure.
    /// `plugins`: the new send's mini-chain — COPIES of the original's, under fresh ids (the caller's
    /// `copiedSends`, which reads the live states), IN THE ORIGINAL'S ORDER, one for one. nil = a cold
    /// copy made here (fresh ids, the states the model holds): two sends never share a plugin id.
    ///
    /// AUTOMATION: the curves follow the copy (user decision of 10 October 2026 — both halves of a cut
    /// aux sound the same). The lane of the original's LEVEL (`.send(auxID: old)`) is copied for
    /// `.send(auxID: new)`, and every lane aimed at one of the original's plugins is copied for the
    /// plugin that is its copy — the NEW id, never a shared one, never a link (@see SendChain.sanitised).
    /// The points are the same (they are in the SENDER's time, which a cut of the aux does not move);
    /// the touch memory lists each copy right after its original. A lane whose plugin has no copy (the
    /// caller passed a list of another length, or `sanitised` turned the copy away) is not copied.
    func duplicatingSend(from old: UUID, to new: UUID, plugins: [ObjectPlugin]? = nil) -> SoundObject {
        guard old != new, let source = sends.first(where: { $0.auxID == old }),
              !sends.contains(where: { $0.auxID == new }) else { return self }
        var o = self
        var copy = source                 // by value: every field of the send, present and future
        copy.auxID = new
        let fresh = plugins ?? source.plugins.map { p in var q = p; q.id = UUID(); return q }
        copy.plugins = SendChain.sanitised(fresh)
        o.sends.append(copy)
        if let k = o.plugins.firstIndex(where: { $0.sendMarker?.auxID == old }) {
            o.plugins.insert(ObjectPlugin.makeSendMarker(for: new), at: k + 1)
        }

        // original plugin id -> its copy's id (by rank; only the copies that survived `sanitised`)
        var idMap: [UUID: UUID] = [:]
        if fresh.count == source.plugins.count {
            let kept = Set(copy.plugins.map(\.id))
            for (a, b) in zip(source.plugins, fresh) where kept.contains(b.id) && a.id != b.id { idMap[a.id] = b.id }
        }
        func twin(_ ref: ParamRef) -> ParamRef? {
            switch ref {
            case .send(let a) where a == old:   return .send(auxID: new)
            case .plugin(let key, let paramID): return idMap[key].map { .plugin(pluginKey: $0, paramID: paramID) }
            default:                            return nil
            }
        }
        var added: [AutomationLane] = []
        for lane in o.automation {
            guard let t = twin(lane.param), !o.automation.contains(where: { $0.param == t }) else { continue }
            added.append(AutomationLane(param: t, points: lane.points))
        }
        o.automation += added
        let born = Set(added.map(\.param))
        o.automationTouchOrder = o.automationTouchOrder.flatMap { ref -> [ParamRef] in
            if let t = twin(ref), born.contains(t) { return [ref, t] }
            return [ref]
        }
        return o
    }

    /// The object WITHOUT its sends towards `gone`: the entries, their markers (at any depth), the lanes
    /// aimed at their level, their PLUGINS and the lanes aimed at those, and the touch memory of all of
    /// it. The ONE pure definition of "a send is deleted" (the card's ×, `send.remove`, an aux
    /// deleted, the orphan purge, the bake's "remove"). Unchanged if it has none of them.
    func removingSends(_ gone: Set<UUID>) -> SoundObject {
        guard sends.contains(where: { gone.contains($0.auxID) })
              || ObjectPlugin.containsSendMarker(in: plugins, where: { gone.contains($0.auxID) }) else { return self }
        var o = self
        let pluginIDs = Set(o.sends.filter { gone.contains($0.auxID) }.flatMap(\.plugins).map(\.id))
        o.sends.removeAll { gone.contains($0.auxID) }
        o.plugins = ObjectPlugin.removingSendMarkers(from: o.plugins) { gone.contains($0.auxID) }
        func dies(_ ref: ParamRef) -> Bool {
            switch ref {
            case .send(let a):          return gone.contains(a)
            case .plugin(let key, _):   return pluginIDs.contains(key)
            default:                    return false
            }
        }
        o.automation.removeAll { dies($0.param) }
        o.automationTouchOrder.removeAll(where: dies)
        return o
    }

    /// The object with its markers and its sends made consistent (idempotent, pure). Run on load, after
    /// every paste / import, and asserted by the audit:
    ///   • a marker NESTED in a rack branch or a bin's block is HOISTED to the top level, just after its
    ///     top-level ancestor (less destructive than dropping it; a send inside a parallel block or a bin
    ///     is forbidden, the trunk is not);
    ///   • a marker without a send entry is removed (an orphan);
    ///   • two markers for one aux: the first is kept;
    ///   • on an aux object (aux and Main do not send) every marker is removed;
    ///   • a send's `plugins` hold plain plugins only (a block, a bin, a marker there is dropped), and
    ///     none of them is linked (a link membership there is cleared);
    ///   • a send that has its marker holds `tap == .postFader` (the marker wins; the canonical form).
    /// `instruments` never hold a marker and are left alone.
    func sanitisingSends() -> SoundObject {
        var o = self

        // 1. Hoist.
        var top: [ObjectPlugin] = []
        for p in o.plugins {
            if p.isSendMarker { top.append(p); continue }
            var nested: [ObjectPlugin] = []
            func strip(_ series: [ObjectPlugin]) -> [ObjectPlugin] {
                series.compactMap { q in
                    if q.isSendMarker { nested.append(q); return nil }
                    return q.mappingChildSeries(strip)
                }
            }
            top.append(p.mappingChildSeries(strip))
            top.append(contentsOf: nested)
        }

        // 2. Orphans, duplicates, aux objects.
        let known = Set(o.sends.map(\.auxID))
        var kept: Set<UUID> = []
        top = top.filter { p in
            guard let m = p.sendMarker else { return true }
            if o.isAux || !known.contains(m.auxID) || kept.contains(m.auxID) { return false }
            kept.insert(m.auxID)
            return true
        }
        o.plugins = top

        // 2b. A send's own plugins: plain plugins only, never linked (@see SendChain.sanitised); an aux never sends,
        // its `sends` are left as they are (the load's purge owns that rule).
        for i in o.sends.indices where !o.sends[i].plugins.isEmpty {
            let clean = SendChain.sanitised(o.sends[i].plugins)
            if clean != o.sends[i].plugins { o.sends[i].plugins = clean }
        }

        // 3. Canonical form: the marker wins, `tap` says post-fader.
        for i in o.sends.indices where kept.contains(o.sends[i].auxID) && o.sends[i].tap != .postFader {
            o.sends[i].tap = .postFader
        }
        return o
    }
}
