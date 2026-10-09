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

    /// The object with its markers and its sends made consistent (idempotent, pure). Run on load, after
    /// every paste / import, and asserted by the audit:
    ///   • a marker NESTED in a rack branch or a bin's block is HOISTED to the top level, just after its
    ///     top-level ancestor (less destructive than dropping it; a send inside a parallel block or a bin
    ///     is forbidden, the trunk is not);
    ///   • a marker without a send entry is removed (an orphan);
    ///   • two markers for one aux: the first is kept;
    ///   • on an aux object (aux and Main do not send) every marker is removed;
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

        // 3. Canonical form: the marker wins, `tap` says post-fader.
        for i in o.sends.indices where kept.contains(o.sends[i].auxID) && o.sends[i].tap != .postFader {
            o.sends[i].tap = .postFader
        }
        return o
    }
}
