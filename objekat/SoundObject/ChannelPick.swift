import Foundation

// MARK: - A channel choice written on a cable (session format 31)
//
// A STEREO cable of the signal view can be told which channel goes on: the left one, the right one or
// their sum — "Stereo" is the cable as it is, and writes nothing. The choice is an ENTRY OF THE SERIES
// (`ObjectPlugin.channelPick`), the fourth kind of container beside a parallel block (`rack`), a bin's
// block (`fxBlock`) and a send's marker (`sendMarker`):
//
//   • it is NOT a plugin: no name, no identifier, no card. It has an id of its own, which is the key of
//     its engine instance (`ObjChannelModePlugin`, the class the audio file's channel choice already
//     uses — no engine patch) and is unique in the project like any plugin id;
//   • it holds no series (`childSeries` is empty), so no walk descends into it, and it answers
//     "container" (`isContainer`), so every walk that skips the leaves skips it too — the precedent is
//     `SendMarker`, and so is its weak point: a hand-rolled walk that rebuilds an `ObjectPlugin` field
//     by field turns it into an EMPTY PLUGIN unless it carries `channelPick` (the audit's `phantom` rule);
//   • it lives in any series of the host's chain — the root, a parallel branch, a bin's definition and
//     instances — and NEVER in `instruments` nor in a send's plugins;
//   • where it stands is a CABLE POINT: a series and a VISIBLE index `0…n` (n = the cards of that series,
//     send markers and picks not counted). The pick sits immediately BEFORE the real entry of visible
//     index `i`, ahead of the send markers of that gap (order in a gap: the pick, then the markers: a send
//     laid on a chosen cable hears the chosen channel).
//
// THE ONE PLACE WHERE A CHOICE IS READ. The effect of the cable that enters a plugin P is, in this order:
// the pick of that gap; else P's inherited `monoFold` (read, never written any more once a pick says
// better); else `MonoFold.whenUnset`. Writing a choice on a cable that enters a one-input plugin writes the
// pick and clears P's `monoFold`; `engineFold(…)` then tells the engine P is fed its LEFT channel — which
// is exact, the pick having made the pair L = R, and which lays no fold-in (`left` has none).
//
// The head of a STEREO audio file's root series is a special place: its cable is the file's own channel
// choice (`SoundObject.channelMode`, the most economical: no node at all in the engine for LR). There is
// no separate pick under the head "+": a pick that arrives at the head of a clip's root (a retouched file)
// is converted by `SoundObject.sanitisingChannelPicks`.
//
// Everything here is PURE: no engine, no view-model. Q-numbers in the comments are the rulings of
// `plan_canaux_cables.md` (the user's decisions of 21 October 2026).

/// The channel a cable carries on (the "mode" of the engine's `ObjChannelModePlugin`). Stereo is not a
/// case: it is the absence of a pick.
struct ChannelPick: Codable, Equatable, Sendable {
    var mode: MonoFold

    /// The engine's integer code (`ObjChannelModePlugin::Mode`: 1 = left, 2 = right, 3 = centre). Fixed
    /// for good, like `ChannelMode.engineCode`: it is written into the plugin's state.
    var engineCode: Int {
        switch mode {
        case .left:  return 1
        case .right: return 2
        case .sum:   return 3
        }
    }
}

/// A point on a cable: a series (@see SynopticMapping.build for the ids) and the VISIBLE index of the
/// card it stands before — `0` = the head of the series, `n` = its tail (n = the series' card count).
struct CablePoint: Hashable, Sendable {
    var seriesID: UUID
    var index: Int
}

// MARK: - The entry

extension ObjectPlugin {

    /// True if this entry is the place of a channel choice on a cable (@see ChannelPick).
    var isChannelPick: Bool { channelPick != nil }

    /// True if this entry is NOT a card of the chain: a send's marker or a channel choice. Both are
    /// invisible in the signal view's cards and both stand in the gaps between the cards. EVERY walk that
    /// counts or indexes the cards the way a person reads them asks this, not `isSendMarker`; a walk that
    /// means "a send" (the send's marker only) keeps `isSendMarker`.
    var isChainMarker: Bool { sendMarker != nil || channelPick != nil }

    /// A choice of `mode` for a cable: no plugin identity, a fresh id of its own (the engine's key for
    /// its instance).
    static func makeChannelPick(mode: MonoFold, id: UUID = UUID()) -> ObjectPlugin {
        ObjectPlugin(id: id, name: "", manufacturer: "", identifier: "", formatName: "",
                     colorIndex: 0, monoFold: nil, channelPick: ChannelPick(mode: mode))
    }

    /// The same choice with an id of its own (a copy of the host that holds it): ids are unique in the
    /// project and the id is the engine's key.
    func copiedChannelPick() -> ObjectPlugin {
        var q = self
        q.id = UUID()
        return q
    }
}

// MARK: - A series' cable points

/// The cable points of a series and the picks that stand on them. Every function takes a SERIES (the
/// `[ObjectPlugin]` of the root, of a branch, of a bin's block) in MODEL order, markers and picks included.
enum ChannelPicks {

    // MARK: Counting

    /// How many cards the series has (the largest cable index): the entries that are not a marker or a pick.
    static func visibleCount(_ series: [ObjectPlugin]) -> Int {
        series.reduce(0) { $0 + ($1.isChainMarker ? 0 : 1) }
    }

    /// The cable points of a series with `cards` cards: `0…cards`.
    static func points(seriesID: UUID, cards: Int) -> [CablePoint] {
        (0...max(0, cards)).map { CablePoint(seriesID: seriesID, index: $0) }
    }

    // MARK: Visible <-> model

    /// The model index where the GAP before visible index `i` starts: just after the entry of visible index
    /// `i - 1` (0 for the head). A pick is stored here — ahead of the markers of the gap. `i` past the last
    /// card gives the end of the array.
    static func gapStart(ofVisible i: Int, in series: [ObjectPlugin]) -> Int {
        if i <= 0 { return 0 }
        var seen = 0
        for (k, p) in series.enumerated() where !p.isChainMarker {
            seen += 1
            if seen == i { return k + 1 }
        }
        return series.count
    }

    /// The model index where the gap before visible index `i` ENDS: the entry of visible index `i` itself,
    /// or the end of the array past the last card. A send marker is stored here — after the pick and the
    /// markers already in the gap.
    static func gapEnd(ofVisible i: Int, in series: [ObjectPlugin]) -> Int {
        let wanted = max(0, i)
        var seen = 0
        for (k, p) in series.enumerated() where !p.isChainMarker {
            if seen == wanted { return k }
            seen += 1
        }
        return series.count
    }

    /// The visible index of the gap the model index `k` stands in (how many cards precede it).
    static func visibleIndex(ofModelIndex k: Int, in series: [ObjectPlugin]) -> Int {
        series.prefix(max(0, k)).reduce(0) { $0 + ($1.isChainMarker ? 0 : 1) }
    }

    /// The card of visible index `i`, nil past the last one.
    static func card(atVisible i: Int, in series: [ObjectPlugin]) -> ObjectPlugin? {
        var seen = 0
        for p in series where !p.isChainMarker {
            if seen == i { return p }
            seen += 1
        }
        return nil
    }

    // MARK: Reading

    /// The model index of the pick standing on cable `i` of the series; nil if the cable carries none.
    static func pickIndex(atVisible i: Int, in series: [ObjectPlugin]) -> Int? {
        let lo = gapStart(ofVisible: i, in: series), hi = gapEnd(ofVisible: i, in: series)
        guard lo < hi else { return nil }
        return series[lo..<hi].firstIndex(where: { $0.isChannelPick })
    }

    /// The pick standing on cable `i`, nil if none.
    static func pick(atVisible i: Int, in series: [ObjectPlugin]) -> ObjectPlugin? {
        pickIndex(atVisible: i, in: series).map { series[$0] }
    }

    /// Every pick of the series by cable index (the first of a gap if a retouched file holds several).
    static func picks(in series: [ObjectPlugin]) -> [Int: MonoFold] {
        var out: [Int: MonoFold] = [:]
        var cards = 0
        for p in series {
            if let pk = p.channelPick { if out[cards] == nil { out[cards] = pk.mode } }
            else if !p.isChainMarker { cards += 1 }
        }
        return out
    }

    /// The effect of cable `i` as a person reads it: the pick of that gap; else, for a cable that enters a
    /// plugin with ONE input (`intoOneInput`), that plugin's inherited fold (`MonoFold.played`); else nil =
    /// Stereo, the cable as it is. `intoOneInput` is the caller's to say — the engine reports a plugin's
    /// bus, this unit knows none.
    static func effectiveChoice(atVisible i: Int, in series: [ObjectPlugin], intoOneInput: Bool) -> MonoFold? {
        if let pk = pick(atVisible: i, in: series)?.channelPick { return pk.mode }
        guard intoOneInput, let p = card(atVisible: i, in: series), !p.isContainer else { return nil }
        return MonoFold.played(p.monoFold)
    }

    /// The fold the engine is told for the leaf plugin of visible index `i`: `left` when a pick stands
    /// right before it (the pair is already L = R, so reading the left channel is exact and lays no
    /// fold-in); else what its own record says (`MonoFold.played`, nil = none sent).
    static func engineFold(forVisible i: Int, in series: [ObjectPlugin]) -> MonoFold? {
        guard let p = card(atVisible: i, in: series), !p.isContainer else { return nil }
        if pickIndex(atVisible: i, in: series) != nil { return .left }
        return MonoFold.played(p.monoFold)
    }

    // MARK: Writing

    /// The series with the choice of cable `i` set to `mode` (nil = Stereo: the pick goes). A pick already
    /// there KEEPS its id and its place (the engine instance is reused, an undo patches in place); a new
    /// one is born at the start of the gap, ahead of the markers there. Extra picks of the gap (a retouched
    /// file) are dropped: one pick per cable. `id` names a new pick.
    static func setting(_ mode: MonoFold?, atVisible i: Int, in series: [ObjectPlugin],
                        id: UUID = UUID()) -> [ObjectPlugin] {
        var out = series
        let lo = gapStart(ofVisible: i, in: out), hi = gapEnd(ofVisible: i, in: out)
        let existing = (lo..<hi).filter { out[$0].isChannelPick }
        let kept = existing.first
        for k in existing.dropFirst().reversed() { out.remove(at: k) }
        guard let mode else {
            if let kept { out.remove(at: kept) }
            return out
        }
        if let kept {
            out[kept].channelPick = ChannelPick(mode: mode)
        } else {
            out.insert(.makeChannelPick(mode: mode, id: id), at: lo)
        }
        return out
    }

    // MARK: Sanitising

    /// The series made consistent (idempotent, pure), at this level and below:
    ///   • at most ONE pick per cable — when a card between two chosen cables is removed, or a file
    ///     is retouched, the gaps merge and the pick UPSTREAM wins (Q6), the one downstream goes;
    ///   • in a gap the pick comes first, then the send markers (a send hears the chosen channel, Q2).
    /// Every other entry keeps its place and its value.
    static func sanitised(_ series: [ObjectPlugin]) -> [ObjectPlugin] {
        var out: [ObjectPlugin] = []
        var gap: [ObjectPlugin] = []              // the picks and markers since the last card
        func flush() {
            guard !gap.isEmpty else { return }
            if let first = gap.first(where: { $0.isChannelPick }) { out.append(first) }
            out.append(contentsOf: gap.filter { !$0.isChannelPick })
            gap.removeAll()
        }
        for p in series {
            if p.isChainMarker { gap.append(p); continue }
            flush()
            out.append(p.mappingChildSeries(sanitised))
        }
        flush()
        return out
    }

    /// `plugins` without any pick, at any depth (the places that forbid them: `instruments`, the plugins
    /// of a send). Pure; every other entry is returned as it is.
    static func removingPicks(from plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.compactMap { p in
            if p.isChannelPick { return nil }
            return p.mappingChildSeries(removingPicks)
        }
    }

    /// True if any entry, at any depth, is a pick.
    static func containsPick(in plugins: [ObjectPlugin]) -> Bool {
        plugins.contains { $0.isChannelPick || $0.childSeries.contains(where: containsPick) }
    }

    /// Every pick at any depth, in walk order.
    static func allPicks(in plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.flatMap { p -> [ObjectPlugin] in
            p.isChannelPick ? [p] : p.childSeries.flatMap(allPicks)
        }
    }

    /// `plugins` with each pick given a fresh id, at any depth: the copy of a host, or the import of a
    /// batch, where the ids of the original must not survive (the id is the engine's key).
    static func freshenedPicks(in plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.map { p in
            p.isChannelPick ? p.copiedChannelPick() : p.mappingChildSeries(freshenedPicks)
        }
    }

    // MARK: Places (what undo compares)

    /// Where a pick stands: its id, its mode and its cable. Two chains with the same places have their
    /// picks in the same spots — the undo reads it to know whether a restore moved one, which a patch in
    /// place (no plugin reloaded) cannot do without a recompile.
    struct Place: Hashable {
        var id: UUID
        var mode: MonoFold
        var container: UUID?      // nil = the root series
        var branch: Int           // the voice index inside a parallel block, else 0
        var index: Int            // the cable index in that series
    }

    static func places(in plugins: [ObjectPlugin]) -> Set<Place> {
        var out: Set<Place> = []
        func walk(_ series: [ObjectPlugin], container: UUID?, branch: Int) {
            var cards = 0
            for p in series {
                if let pk = p.channelPick {
                    out.insert(Place(id: p.id, mode: pk.mode, container: container, branch: branch, index: cards))
                } else if !p.isChainMarker {
                    cards += 1
                }
                for (b, child) in p.childSeries.enumerated() { walk(child, container: p.id, branch: b) }
            }
        }
        walk(plugins, container: nil, branch: 0)
        return out
    }
}

// MARK: - On an object

extension SoundObject {

    /// The object with its picks made consistent (idempotent, pure). Run on load, after every paste and
    /// import, and asserted by the audit:
    ///   • the chain's picks are sanitised (one per cable, pick before markers, @see ChannelPicks.sanitised);
    ///   • `instruments` and every send's `plugins` hold none (a pick there is dropped);
    ///   • when `headIsFileLevel` (a clip whose file has exactly two channels), a pick at the very head of
    ///     the root series is the file's channel choice written another way: it becomes `channelMode` —
    ///     unless the file already has a choice, which is upstream and wins — and the pick goes (Q7).
    /// `Equatable` tells the caller whether anything changed.
    func sanitisingChannelPicks(headIsFileLevel: Bool = false) -> SoundObject {
        var o = self
        o.plugins = ChannelPicks.sanitised(o.plugins)
        o.instruments = ChannelPicks.removingPicks(from: o.instruments)
        for i in o.sends.indices where ChannelPicks.containsPick(in: o.sends[i].plugins) {
            o.sends[i].plugins = ChannelPicks.removingPicks(from: o.sends[i].plugins)
        }
        if headIsFileLevel, let k = ChannelPicks.pickIndex(atVisible: 0, in: o.plugins),
           let pk = o.plugins[k].channelPick {
            if o.channelMode == .lr {
                switch pk.mode {
                case .left:  o.channelMode = .l
                case .right: o.channelMode = .r
                case .sum:   o.channelMode = .c
                }
            }
            o.plugins.remove(at: k)
        }
        return o
    }
}
