// A channel choice written on a cable (session format 31) — the PURE half: the entry's encoding (a
// format-30 plugin decodes without it and re-encodes without the key), what makes it a container that
// is not a card, the gaps and the visible <-> model mapping with picks AND send markers, writing and
// removing a choice, `sanitised` (one per cable, upstream wins, pick before markers, at any depth),
// `effectiveChoice` / `engineFold`, `places`, fresh ids, and `SoundObject.sanitisingChannelPicks`
// (instruments, sends' plugins, the head of a stereo clip becoming `channelMode`).
//
//     cd tools && swiftc -parse-as-library \
//         ../objekat/SoundObject/SoundObject.swift \
//         ../objekat/Shared/SendChain.swift \
//         ../objekat/SoundObject/Automation.swift \
//         ../objekat/SoundObject/AutomationCurveMath.swift \
//         ../objekat/SoundObject/AutomationCurveShape.swift \
//         ../objekat/SoundObject/Marker.swift \
//         ../objekat/SoundObject/ChannelMode.swift \
//         ../objekat/Shared/LaneEntryIndex.swift \
//         ../objekat/Timeline/ClipEditZonesOverlay.swift \
//         ../objekat/SoundObject/ConsolidateDefinition.swift \
//         ../objekat/SoundObject/FadeCurve.swift \
//         ../objekat/SoundObject/ComposedName.swift \
//         ../objekat/SoundObject/FXLink.swift \
//         ../objekat/SoundObject/SendPosition.swift \
//         ../objekat/SoundObject/SendMarkerAudit.swift \
//         ../objekat/SoundObject/ChannelPick.swift \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticWidthFlow.swift \
//         ../objekat/Shared/ObjekatPalette.swift \
//         ../objekat/Shared/ObjectColorChoice.swift \
//         ../objekat/Shared/Localization.swift \
//         ../objekat/SoundObject/GainStage.swift \
//         ../objekat/SoundObject/LegacyGainMigration.swift \
//         ../objekat/EditViewModel/EditViewModel+Types.swift \
//         ../objekat/EditViewModel/SessionSchema.swift \
//         ../objekat/App/LaunchArguments.swift \
//         ../objekat/Shared/BridgeScope.swift \
//         ../objekat/Shared/ScriptCanvasMemory.swift \
//         test_channel_picks.swift \
//         -o /tmp/test_channel_picks && /tmp/test_channel_picks
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

@main
enum ChannelPicksTest {
    static func main() {

        // MARK: - Fixtures

        func plugin(_ name: String, fold: MonoFold? = .sum) -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: name, manufacturer: "Objekat", identifier: name,
                         formatName: "TracktionInternal", monoFold: fold)
        }
        func pick(_ m: MonoFold) -> ObjectPlugin { .makeChannelPick(mode: m) }
        func marker(_ a: UUID) -> ObjectPlugin { .makeSendMarker(for: a) }
        func rackOf(_ voices: [[ObjectPlugin]]) -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: "//", manufacturer: "", identifier: "", formatName: "",
                         rack: PluginRack(voices: voices, wetDb: Array(repeating: 0, count: voices.count)))
        }
        func binOf(_ inner: [ObjectPlugin]) -> ObjectPlugin {
            FXLink.blockEntry(linkID: UUID(), name: "bin", instances: inner)
        }
        func clip(plugins: [ObjectPlugin] = [], sends: [AuxSend] = [], instruments: [ObjectPlugin] = [],
                  channelMode: ChannelMode = .lr) -> SoundObject {
            SoundObject(id: UUID(), startTime: 0, duration: 4, lane: 0, plugins: plugins,
                        instruments: instruments, sends: sends,
                        channelMode: channelMode,
                        kind: .clip(filePath: "a.wav", sourceOffset: 0, fileDuration: 4,
                                    speedRatio: 1, isReversed: false))
        }
        func json(_ v: some Encodable) -> String {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys]
            return String(data: try! e.encode(v), encoding: .utf8)!
        }
        func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
            try? JSONDecoder().decode(type, from: Data(text.utf8))
        }
        /// "A", "m" for a send marker, "<L>" "<R>" "<S>" for a pick.
        func names(_ plugins: [ObjectPlugin]) -> [String] {
            plugins.map { p in
                if p.isSendMarker { return "m" }
                if let k = p.channelPick { return k.mode == .left ? "<L>" : (k.mode == .right ? "<R>" : "<S>") }
                return p.name
            }
        }
        let auxA = UUID(), auxB = UUID()

        // MARK: - The entry

        do {
            let p = pick(.left)
            check("a pick is a container with no series", p.isContainer && p.childSeries.isEmpty
                  && !p.isRack && !p.isFXBlock && !p.isSendMarker)
            check("a pick is a pick and a chain marker", p.isChannelPick && p.isChainMarker)
            check("a send marker is a chain marker, not a pick", marker(auxA).isChainMarker && !marker(auxA).isChannelPick)
            let plain = plugin("EQ")
            check("a plain plugin, a rack and a bin are no chain marker",
                  !plain.isChainMarker && !rackOf([[plain]]).isChainMarker && !binOf([plain]).isChainMarker)
            check("a pick has no plugin identity", p.name.isEmpty && p.identifier.isEmpty && p.formatName.isEmpty)
            check("a pick is born with no monoFold", p.monoFold == nil)
            check("a pick writes its mode", json(p).contains("\"channelPick\":{\"mode\":\"left\"}"), json(p))
            check("a pick writes no monoFold key", !json(p).contains("monoFold"), json(p))
            for m in MonoFold.allCases {
                check("a \(m.rawValue) pick round-trips", decode(ObjectPlugin.self, json(pick(m))) == pick(m).self
                      || decode(ObjectPlugin.self, json(pick(m)))?.channelPick == ChannelPick(mode: m))
            }
            let q = pick(.sum)
            check("a pick round-trips whole", decode(ObjectPlugin.self, json(q)) == q)
            check("a plain plugin writes no channelPick key", !json(plain).contains("channelPick"))
            let old = "{\"id\":\"\(UUID().uuidString)\",\"name\":\"EQ\",\"manufacturer\":\"x\",\"identifier\":\"eq\","
                    + "\"formatName\":\"TracktionInternal\",\"monoFold\":\"right\"}"
            let d = decode(ObjectPlugin.self, old)
            check("a format-30 plugin decodes with no pick, its fold kept", d != nil && d?.channelPick == nil && d?.monoFold == .right)
            check("... and re-encodes without the key", d.map { !json($0).contains("channelPick") } ?? false)
            check("the engine codes are the mode's (left 1, right 2, sum 3)",
                  ChannelPick(mode: .left).engineCode == 1 && ChannelPick(mode: .right).engineCode == 2
                  && ChannelPick(mode: .sum).engineCode == 3)
            let c = p.copiedChannelPick()
            check("a copy has a fresh id and the same mode", c.id != p.id && c.channelPick == p.channelPick)
        }

        // MARK: - Counting and the gaps

        do {
            // [<L>, A, m, <R>, B, C, m2, <S>]
            let s: [ObjectPlugin] = [pick(.left), plugin("A"), marker(auxA), pick(.right), plugin("B"),
                                     plugin("C"), marker(auxB), pick(.sum)]
            check("visibleCount skips picks and markers", ChannelPicks.visibleCount(s) == 3)
            check("points: 0...n", ChannelPicks.points(seriesID: UUID(), cards: 3).map(\.index) == [0, 1, 2, 3])
            check("an empty series has the one point 0", ChannelPicks.points(seriesID: UUID(), cards: 0).map(\.index) == [0])
            check("gapStart(0) = 0", ChannelPicks.gapStart(ofVisible: 0, in: s) == 0)
            check("gapEnd(0) = A", ChannelPicks.gapEnd(ofVisible: 0, in: s) == 1)
            check("gapStart(1) = just after A", ChannelPicks.gapStart(ofVisible: 1, in: s) == 2)
            check("gapEnd(1) = B", ChannelPicks.gapEnd(ofVisible: 1, in: s) == 4)
            check("gapStart(2) = just after B", ChannelPicks.gapStart(ofVisible: 2, in: s) == 5)
            check("gapEnd(2) = C", ChannelPicks.gapEnd(ofVisible: 2, in: s) == 5)
            check("gapStart(3) = just after C", ChannelPicks.gapStart(ofVisible: 3, in: s) == 6)
            check("gapEnd(3) = the end", ChannelPicks.gapEnd(ofVisible: 3, in: s) == 8)
            check("past the end clamps", ChannelPicks.gapStart(ofVisible: 9, in: s) == 8
                  && ChannelPicks.gapEnd(ofVisible: 9, in: s) == 8)
            check("negative clamps to the head", ChannelPicks.gapStart(ofVisible: -2, in: s) == 0
                  && ChannelPicks.gapEnd(ofVisible: -2, in: s) == 1)
            check("visibleIndex(ofModelIndex:)", (0...8).map { ChannelPicks.visibleIndex(ofModelIndex: $0, in: s) }
                  == [0, 0, 1, 1, 1, 2, 3, 3, 3])
            check("card(atVisible:)", ChannelPicks.card(atVisible: 1, in: s)?.name == "B"
                  && ChannelPicks.card(atVisible: 3, in: s) == nil)
            let found: [Int?] = [0, 1, 2, 3].map { ChannelPicks.pickIndex(atVisible: $0, in: s) }
            let wanted: [Int?] = [0, 3, nil, 7]
            check("pickIndex per cable", found == wanted, "\(found)")
            check("picks(in:) by cable", ChannelPicks.picks(in: s) == [0: .left, 1: .right, 3: .sum]
                  || ChannelPicks.picks(in: s) == [0: .left, 2: .right, 3: .sum], "\(ChannelPicks.picks(in: s))")
        }

        // The mapping above is easy to get wrong by one: spell it out on a smaller series.
        do {
            let s: [ObjectPlugin] = [plugin("A"), pick(.right), marker(auxA), plugin("B")]
            check("cable 1 carries the pick standing between A and B", ChannelPicks.pickIndex(atVisible: 1, in: s) == 1)
            check("cable 0 and 2 carry none", ChannelPicks.pickIndex(atVisible: 0, in: s) == nil
                  && ChannelPicks.pickIndex(atVisible: 2, in: s) == nil)
            check("picks(in:) = [1: right]", ChannelPicks.picks(in: s) == [1: .right])
            // The existing marker rule still lands AFTER the gap's pick: the visible-th card's index.
            check("a marker for cable 1 goes at the card, after the pick and the marker",
                  ChannelPicks.gapEnd(ofVisible: 1, in: s) == 3)
        }

        // MARK: - Writing a choice

        do {
            let a = plugin("A"), b = plugin("B")
            let s0 = [a, b]
            for i in 0...2 {
                let s = ChannelPicks.setting(.left, atVisible: i, in: s0)
                var want = ["A", "B"]; want.insert("<L>", at: i)
                check("setting left at \(i) lays the pick at \(i)", names(s) == want, "\(names(s))")
                check("... and it reads back", ChannelPicks.picks(in: s) == [i: .left])
                check("... Stereo removes it", names(ChannelPicks.setting(nil, atVisible: i, in: s)) == ["A", "B"])
            }
            // Re-setting keeps id and place.
            let s1 = ChannelPicks.setting(.left, atVisible: 1, in: s0)
            let s2 = ChannelPicks.setting(.sum, atVisible: 1, in: s1)
            check("changing the mode keeps the pick's id and place",
                  s2.count == 3 && s2[1].id == s1[1].id && s2[1].channelPick?.mode == .sum)
            check("setting the same mode changes nothing", ChannelPicks.setting(.left, atVisible: 1, in: s1) == s1)
            check("Stereo on a cable with none changes nothing", ChannelPicks.setting(nil, atVisible: 0, in: s0) == s0)
            let fixedID = UUID()
            check("a new pick takes the id given", ChannelPicks.setting(.right, atVisible: 0, in: s0, id: fixedID)[0].id == fixedID)

            // Ahead of the markers of the gap.
            let m = [a, marker(auxA), b]
            check("a pick is laid ahead of the gap's markers",
                  names(ChannelPicks.setting(.right, atVisible: 1, in: m)) == ["A", "<R>", "m", "B"])
            // A marker laid afterwards (at the card) stays behind the pick.
            let withPick = ChannelPicks.setting(.right, atVisible: 1, in: [a, b])
            var laid = withPick
            laid.insert(marker(auxA), at: ChannelPicks.gapEnd(ofVisible: 1, in: laid))
            check("a send marker laid on a chosen cable lands after the pick", names(laid) == ["A", "<R>", "m", "B"])

            // The tail.
            check("a pick at the tail", names(ChannelPicks.setting(.sum, atVisible: 2, in: m)) == ["A", "m", "B", "<S>"])
            // An empty series.
            check("a pick in an empty series", names(ChannelPicks.setting(.left, atVisible: 0, in: [])) == ["<L>"])
            // Extra picks in a gap collapse to one.
            let dup: [ObjectPlugin] = [a, pick(.left), pick(.right), b]
            let one = ChannelPicks.setting(.sum, atVisible: 1, in: dup)
            check("two picks in a gap collapse to one when written", names(one) == ["A", "<S>", "B"])
            check("... the first one's id kept", one[1].id == dup[1].id)
        }

        // MARK: - Sanitising

        do {
            let a = plugin("A"), b = plugin("B")
            let ok: [ObjectPlugin] = [pick(.left), a, pick(.right), b]
            check("a consistent series is unchanged", ChannelPicks.sanitised(ok) == ok)
            let twice: [ObjectPlugin] = [a, pick(.left), pick(.right), b]
            check("two picks in a gap: the upstream one wins", names(ChannelPicks.sanitised(twice)) == ["A", "<L>", "B"])
            let sep: [ObjectPlugin] = [a, pick(.left), marker(auxA), pick(.right), b]
            check("... even with a marker between them", names(ChannelPicks.sanitised(sep)) == ["A", "<L>", "m", "B"])
            let order: [ObjectPlugin] = [a, marker(auxA), marker(auxB), pick(.sum), b]
            check("the pick comes before the markers of its gap",
                  names(ChannelPicks.sanitised(order)) == ["A", "<S>", "m", "m", "B"])
            check("the markers keep their order", ChannelPicks.sanitised(order)[2].sendMarker?.auxID == auxA
                  && ChannelPicks.sanitised(order)[3].sendMarker?.auxID == auxB)
            check("idempotent", ChannelPicks.sanitised(ChannelPicks.sanitised(order)) == ChannelPicks.sanitised(order))
            // Q6: a card removed between two chosen cables.
            let x = plugin("X")
            let between: [ObjectPlugin] = [pick(.left), x, pick(.right), a]
            let removed = between.filter { $0.id != x.id }
            check("Q6: removing the card between two chosen cables keeps the upstream pick",
                  names(ChannelPicks.sanitised(removed)) == ["<L>", "A"])
            // Deep.
            let deep = [rackOf([[a, pick(.left), pick(.right), b], [pick(.sum), pick(.left)]]),
                        binOf([pick(.right), marker(auxA), pick(.left), plugin("C")])]
            let clean = ChannelPicks.sanitised(deep)
            check("a rack's branches are sanitised", names(clean[0].rack!.voices[0]) == ["A", "<L>", "B"]
                  && names(clean[0].rack!.voices[1]) == ["<S>"])
            check("a bin's block is sanitised", names(clean[1].fxBlock!.plugins) == ["<R>", "m", "C"])
            check("the container keeps its id and kind", clean[0].id == deep[0].id && clean[0].isRack
                  && clean[1].id == deep[1].id && clean[1].isFXBlock)
        }

        // MARK: - Removing and counting, at any depth

        do {
            let a = plugin("A")
            let tree = [pick(.left), rackOf([[a, pick(.right)], []]), binOf([pick(.sum), plugin("B")])]
            check("containsPick sees any depth", ChannelPicks.containsPick(in: tree)
                  && !ChannelPicks.containsPick(in: [a, rackOf([[a]])]))
            check("allPicks lists them in walk order",
                  ChannelPicks.allPicks(in: tree).map { $0.channelPick!.mode } == [.left, .right, .sum])
            let stripped = ChannelPicks.removingPicks(from: tree)
            check("removingPicks leaves none and keeps the rest", !ChannelPicks.containsPick(in: stripped)
                  && stripped.count == 2 && names(stripped[0].rack!.voices[0]) == ["A"]
                  && names(stripped[1].fxBlock!.plugins) == ["B"])
            let fresh = ChannelPicks.freshenedPicks(in: tree)
            let oldIDs = Set(ChannelPicks.allPicks(in: tree).map(\.id))
            let newIDs = Set(ChannelPicks.allPicks(in: fresh).map(\.id))
            check("freshenedPicks gives every pick a new id", newIDs.count == 3 && newIDs.isDisjoint(with: oldIDs))
            check("... and touches nothing else", fresh[1].id == tree[1].id && fresh[2].id == tree[2].id
                  && fresh[1].rack!.voices[0][0].id == a.id)
        }

        // MARK: - What the cable means

        do {
            let a = plugin("A", fold: .right), b = plugin("B", fold: nil)
            let s: [ObjectPlugin] = [a, pick(.left), b]
            check("no pick, into a one-input plugin: its own fold",
                  ChannelPicks.effectiveChoice(atVisible: 0, in: s, intoOneInput: true) == .right)
            check("no pick, into a plugin with two inputs: Stereo",
                  ChannelPicks.effectiveChoice(atVisible: 0, in: s, intoOneInput: false) == nil)
            check("a pick wins over the plugin's fold, one-input or not",
                  ChannelPicks.effectiveChoice(atVisible: 1, in: s, intoOneInput: true) == .left
                  && ChannelPicks.effectiveChoice(atVisible: 1, in: s, intoOneInput: false) == .left)
            check("no key on the plugin: whenUnset (sum)",
                  ChannelPicks.effectiveChoice(atVisible: 1, in: [a, b], intoOneInput: true) == MonoFold.whenUnset)
            check("the tail has no plugin to inherit from",
                  ChannelPicks.effectiveChoice(atVisible: 2, in: [a, b], intoOneInput: true) == nil)
            check("a container inherits nothing",
                  ChannelPicks.effectiveChoice(atVisible: 0, in: [rackOf([[a]])], intoOneInput: true) == nil)
            check("engineFold: a pick right before the plugin says left",
                  ChannelPicks.engineFold(forVisible: 1, in: s) == .left)
            check("engineFold: no pick, the plugin's own (played)",
                  ChannelPicks.engineFold(forVisible: 0, in: s) == .right
                  && ChannelPicks.engineFold(forVisible: 1, in: [a, b]) == MonoFold.played(nil))
            check("engineFold: a pick before a SUM plugin also says left",
                  ChannelPicks.engineFold(forVisible: 0, in: [pick(.sum), plugin("S", fold: .sum)]) == .left)
            check("engineFold: a rack is not a plugin", ChannelPicks.engineFold(forVisible: 0, in: [rackOf([[a]])]) == nil)
            check("engineFold: past the end", ChannelPicks.engineFold(forVisible: 5, in: s) == nil)
        }

        // MARK: - Places (what undo compares)

        do {
            let p1 = pick(.left), p2 = pick(.right)
            let r = rackOf([[plugin("A"), p2], []])
            let a = ChannelPicks.places(in: [p1, plugin("X"), r])
            check("places lists every pick once", a.count == 2)
            check("... root: container nil, cable 0", a.contains(.init(id: p1.id, mode: .left, container: nil, branch: 0, index: 0)))
            check("... a branch: the rack's id, branch 0, cable 1",
                  a.contains(.init(id: p2.id, mode: .right, container: r.id, branch: 0, index: 1)))
            let moved = ChannelPicks.places(in: [plugin("X"), p1, r])
            check("moving a pick changes the places", moved != a)
            var changed = p1; changed.channelPick = ChannelPick(mode: .sum)
            check("changing a mode changes the places", ChannelPicks.places(in: [changed, plugin("X"), r]) != a)
            let idsOfY = Set(ChannelPicks.places(in: [p1, plugin("Y"), r]).map(\.id))
            let idsOfA = Set(a.map(\.id))
            check("places ignores the plugins' own values", idsOfY == idsOfA)
        }

        // MARK: - On an object

        do {
            let a = plugin("A")
            let sendWithPick = AuxSend(auxID: auxA, levelDb: 0, plugins: [plugin("S"), pick(.left)])
            var o = clip(plugins: [a, pick(.left), pick(.right), plugin("B")], sends: [sendWithPick],
                         instruments: [pick(.sum), plugin("I")])
            o.sends[0].plugins = [plugin("S"), pick(.left)]       // bypasses nothing: the init may sanitise
            let s = o.sanitisingChannelPicks()
            check("the chain is sanitised", names(s.plugins) == ["A", "<L>", "B"], "\(names(s.plugins))")
            check("instruments hold no pick", names(s.instruments) == ["I"], "\(names(s.instruments))")
            check("a send's plugins hold no pick", names(s.sends[0].plugins) == ["S"], "\(names(s.sends[0].plugins))")
            check("idempotent", s.sanitisingChannelPicks() == s)
            let plainObject = clip(plugins: [a])
            check("an object with no pick is unchanged", plainObject.sanitisingChannelPicks() == plainObject)

            // The head of a stereo clip's root becomes the file's own channel choice (Q7).
            for (m, cm) in [(MonoFold.left, ChannelMode.l), (.right, .r), (.sum, .c)] {
                let h = clip(plugins: [pick(m), a, pick(.sum), plugin("B")])
                let kept = h.sanitisingChannelPicks(headIsFileLevel: false)
                check("\(m.rawValue): without file level the head pick stays", kept.plugins.first?.channelPick?.mode == m
                      && kept.channelMode == .lr)
                let conv = h.sanitisingChannelPicks(headIsFileLevel: true)
                check("\(m.rawValue): at file level the head pick becomes channelMode \(cm.rawValue)",
                      conv.channelMode == cm && names(conv.plugins) == ["A", "<S>", "B"], "\(conv.channelMode) \(names(conv.plugins))")
            }
            let h2 = clip(plugins: [pick(.right), a], channelMode: .l).sanitisingChannelPicks(headIsFileLevel: true)
            check("a file that already has a choice keeps it (upstream wins); the pick goes",
                  h2.channelMode == .l && names(h2.plugins) == ["A"])
            let h3 = clip(plugins: [a, pick(.right)]).sanitisingChannelPicks(headIsFileLevel: true)
            check("only the HEAD converts; a tail pick stays", h3.channelMode == .lr && names(h3.plugins) == ["A", "<R>"])
            let h4 = clip(plugins: [marker(auxA), pick(.left), a], sends: [AuxSend(auxID: auxA, levelDb: 0)])
                .sanitisingChannelPicks(headIsFileLevel: true)
            check("the head pick is read before the head's markers, which stay",
                  h4.channelMode == .c ? false : (h4.channelMode == .l && names(h4.plugins) == ["m", "A"]),
                  "\(h4.channelMode) \(names(h4.plugins))")
        }

        // MARK: - The object round trip

        do {
            let o = clip(plugins: [pick(.left), plugin("A"), binOf([plugin("B"), pick(.right)])])
            check("an object with picks round-trips", decode(SoundObject.self, json(o)) == o)
            check("an object with no pick writes no channelPick key", !json(clip(plugins: [plugin("A")])).contains("channelPick"))
        }

        print("\n\(total - fails.count)/\(total) assertions pass")
        if !fails.isEmpty {
            print("FAILED:")
            for f in fails { print(" - " + f) }
            exit(1)
        }
    }
}
