// Where a send takes its signal (INC 2 of the sends rework, session format 22) — the PURE half:
// the model's encoding (a format-21 object decodes post-fader and re-encodes without the new keys),
// the four positions and their round trip, "the marker wins over tap", the 5x5 transitions that keep
// the marker <-> send bijection, and `sanitisingSends` (orphan, duplicate, nested in a rack branch,
// nested in a bin, on an aux, idempotence). The "marker survives" tests of the transformations
// (copies, runs, removal…) are in the sections added by step 2.2 of the plan.
//
//     cd tools && swiftc -parse-as-library \
//         ../objekat/SoundObject/SoundObject.swift \
//         ../objekat/Shared/SendChain.swift \
//         ../objekat/SoundObject/Automation.swift \
//         ../objekat/SoundObject/AutomationCurveMath.swift \
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
//         test_send_position.swift \
//         -o /tmp/test_send_position && /tmp/test_send_position
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
enum SendPositionTest {
    static func main() {

        // MARK: - Fixtures

        func plugin(_ name: String) -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: name, manufacturer: "Objekat", identifier: name,
                         formatName: "TracktionInternal")
        }
        func rackOf(_ voices: [[ObjectPlugin]]) -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: "//", manufacturer: "", identifier: "", formatName: "",
                         rack: PluginRack(voices: voices, wetDb: Array(repeating: 0, count: voices.count)))
        }
        func binOf(_ inner: [ObjectPlugin]) -> ObjectPlugin {
            FXLink.blockEntry(linkID: UUID(), name: "bin", instances: inner)
        }
        func clip(plugins: [ObjectPlugin], sends: [AuxSend]) -> SoundObject {
            SoundObject(id: UUID(), startTime: 0, duration: 4, lane: 0, plugins: plugins, sends: sends,
                        kind: .clip(filePath: "a.wav", sourceOffset: 0, fileDuration: 4,
                                    speedRatio: 1, isReversed: false))
        }
        func auxObject(plugins: [ObjectPlugin] = [], sends: [AuxSend] = []) -> SoundObject {
            SoundObject(id: UUID(), startTime: 0, duration: 4, lane: 1, plugins: plugins, sends: sends,
                        kind: .aux)
        }
        func json(_ v: some Encodable) -> String {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys]
            return String(data: try! e.encode(v), encoding: .utf8)!
        }
        func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
            try? JSONDecoder().decode(type, from: Data(text.utf8))
        }
        func names(_ plugins: [ObjectPlugin]) -> [String] {
            plugins.map { $0.isSendMarker ? "m" : $0.name }
        }
        let auxA = UUID(), auxB = UUID()

        // MARK: - Encoding: format 21 in, format 21 shape out

        do {
            let a = UUID()
            let old = "{\"auxID\":\"\(a.uuidString)\",\"levelDb\":-6,\"enabled\":true}"
            let send = decode(AuxSend.self, old)
            check("a format-21 send decodes post-fader", send?.tap == .postFader)
            check("and re-encodes without a tap key", send.map { !json($0).contains("tap") } ?? false,
                  send.map(json) ?? "nil")

            let pre = AuxSend(auxID: a, levelDb: -3, tap: .preFader)
            check("a pre-fader send writes tap", json(pre).contains("\"tap\":\"preFader\""), json(pre))
            check("a pre-fader send round-trips", decode(AuxSend.self, json(pre)) == pre)
            let inp = AuxSend(auxID: a, levelDb: -3, tap: .input)
            check("an input send round-trips", decode(AuxSend.self, json(inp)) == inp)

            let junk = "{\"auxID\":\"\(a.uuidString)\",\"levelDb\":0,\"enabled\":true,\"tap\":\"sideways\"}"
            check("an unknown tap value reads as post-fader (no failure)",
                  decode(AuxSend.self, junk)?.tap == .postFader)

            let plain = plugin("EQ")
            check("a plain plugin writes no sendMarker key", !json(plain).contains("sendMarker"))
            let m = ObjectPlugin.makeSendMarker(for: a)
            check("a marker writes its aux", json(m).contains("\"sendMarker\":{\"auxID\":\"\(a.uuidString)\"}"))
            check("a marker round-trips", decode(ObjectPlugin.self, json(m)) == m)
            check("a marker is a container with no series", m.isContainer && m.childSeries.isEmpty
                  && !m.isRack && !m.isFXBlock)
            check("a plugin, a rack and a bin are not markers",
                  !plain.isSendMarker && !rackOf([[plain]]).isSendMarker && !binOf([plain]).isSendMarker)

            let obj = clip(plugins: [plugin("A"), plugin("B")], sends: [AuxSend(auxID: a, levelDb: -6)])
            check("an object with no marker and a default send encodes with neither key",
                  !json(obj).contains("sendMarker") && !json(obj).contains("\"tap\""))
            check("an object round-trips", decode(SoundObject.self, json(obj)) == obj)
        }

        // MARK: - The four positions and "the marker wins"

        do {
            let base = clip(plugins: [plugin("A"), plugin("B")],
                            sends: [AuxSend(auxID: auxA, levelDb: 0), AuxSend(auxID: auxB, levelDb: 0)])
            check("no send, no position", base.sendPosition(auxID: UUID()) == nil)
            check("default is post-fader", base.sendPosition(auxID: auxA) == .postFader)
            check("input", base.settingSendPosition(auxID: auxA, .input).sendPosition(auxID: auxA) == .input)
            check("pre-fader", base.settingSendPosition(auxID: auxA, .preFader).sendPosition(auxID: auxA) == .preFader)
            for i in 0...2 {
                let o = base.settingSendPosition(auxID: auxA, .chain(i))
                check("chain(\(i)) reads back", o.sendPosition(auxID: auxA) == .chain(i))
                let want: [String] = {
                    var w = ["A", "B"]; w.insert("m", at: i); return w
                }()
                check("chain(\(i)) lays the marker at \(i)", names(o.plugins) == want, "\(names(o.plugins))")
            }
            check("chain(99) is clamped to the end",
                  base.settingSendPosition(auxID: auxA, .chain(99)).sendPosition(auxID: auxA) == .chain(2))
            check("chain(-4) is clamped to the start",
                  base.settingSendPosition(auxID: auxA, .chain(-4)).sendPosition(auxID: auxA) == .chain(0))
            check("an unknown aux changes nothing",
                  base.settingSendPosition(auxID: UUID(), .chain(1)) == base)

            // The marker wins over tap (a hand-edited file holding both).
            var both = base.settingSendPosition(auxID: auxA, .chain(1))
            both.sends[0].tap = .preFader
            check("the marker wins over tap", both.sendPosition(auxID: auxA) == .chain(1))
            check("sanitising writes the canonical form (tap back to post-fader)",
                  both.sanitisingSends().sends[0].tap == .postFader
                  && both.sanitisingSends().sendPosition(auxID: auxA) == .chain(1))

            // Moving out of the chain removes the marker; into it resets tap.
            let pre = base.settingSendPosition(auxID: auxA, .preFader)
            let into = pre.settingSendPosition(auxID: auxA, .chain(1))
            check("into the chain resets tap", into.sends[0].tap == .postFader)
            let out = into.settingSendPosition(auxID: auxA, .input)
            check("out of the chain removes the marker", !out.plugins.contains(where: \.isSendMarker)
                  && out.sends[0].tap == .input, "\(names(out.plugins))")

            // Two markers in one gap: the second goes immediately before the entry, after the first.
            let two = base.settingSendPosition(auxID: auxA, .chain(1)).settingSendPosition(auxID: auxB, .chain(1))
            check("two markers in one gap: the newer sits right before the entry",
                  names(two.plugins) == ["A", "m", "m", "B"]
                  && two.plugins[1].sendMarker?.auxID == auxA && two.plugins[2].sendMarker?.auxID == auxB)
            check("and both read chain(1)", two.sendPosition(auxID: auxA) == .chain(1)
                  && two.sendPosition(auxID: auxB) == .chain(1))
        }

        // MARK: - 5 x 5 transitions keep the bijection

        do {
            let base = clip(plugins: [plugin("A"), plugin("B"), plugin("C")],
                            sends: [AuxSend(auxID: auxA, levelDb: -4), AuxSend(auxID: auxB, levelDb: -9)])
            let spots: [SendPosition] = [.input, .chain(0), .chain(2), .preFader, .postFader]
            var bad: [String] = []
            for from in spots {
                for to in spots {
                    // A second send sits somewhere else the whole time: it must not move.
                    let start = base.settingSendPosition(auxID: auxA, from)
                        .settingSendPosition(auxID: auxB, .chain(1))
                    let o = start.settingSendPosition(auxID: auxA, to)
                    let markersA = ObjectPlugin.topLevelSendMarkers(in: o.plugins).filter { $0.auxID == auxA }.count
                    var okLocal = o.sendPosition(auxID: auxA) == to
                    switch to { case .chain: okLocal = okLocal && markersA == 1; default: okLocal = okLocal && markersA == 0 }
                    okLocal = okLocal && o.sendPosition(auxID: auxB) == .chain(1)
                    okLocal = okLocal && o.sanitisingSends() == o
                    okLocal = okLocal && ObjectPlugin.chainEntryCount(o.plugins) == 3
                    okLocal = okLocal && o.sends.map(\.levelDb) == [-4, -9]
                    if !okLocal { bad.append("\(from)->\(to)") }
                }
            }
            check("all 25 transitions: read-back, one marker iff chain, the other send untouched, sanitising is a no-op",
                  bad.isEmpty, bad.joined(separator: ", "))
        }

        // MARK: - sanitisingSends

        do {
            let m = ObjectPlugin.makeSendMarker(for: auxA)
            let sendA = [AuxSend(auxID: auxA, levelDb: 0)]

            // Orphan: a marker whose aux has no send.
            let orphan = clip(plugins: [plugin("A"), ObjectPlugin.makeSendMarker(for: auxB)], sends: sendA)
            check("an orphan marker is removed", names(orphan.sanitisingSends().plugins) == ["A"])

            // Duplicate: the first is kept.
            let dup = clip(plugins: [plugin("A"), m, plugin("B"), ObjectPlugin.makeSendMarker(for: auxA)], sends: sendA)
            let dupFixed = dup.sanitisingSends()
            check("two markers for one aux: the first is kept", names(dupFixed.plugins) == ["A", "m", "B"]
                  && dupFixed.plugins[1].id == m.id, "\(names(dupFixed.plugins))")

            // Nested in a rack branch: hoisted after the rack.
            let inRack = clip(plugins: [plugin("A"), rackOf([[plugin("X"), m], [plugin("Y")]]), plugin("B")], sends: sendA)
            let rackFixed = inRack.sanitisingSends()
            check("a marker nested in a rack branch is hoisted just after the rack",
                  names(rackFixed.plugins) == ["A", "//", "m", "B"], "\(names(rackFixed.plugins))")
            check("and the rack lost it (its branches keep their plugins)",
                  rackFixed.plugins[1].rack?.voices.map { names($0) } == [["X"], ["Y"]])
            check("the hoisted marker reads chain(2)", rackFixed.sendPosition(auxID: auxA) == .chain(2))

            // Nested in a bin: hoisted after the bin block.
            let inBin = clip(plugins: [binOf([plugin("X"), m, plugin("Y")]), plugin("B")], sends: sendA)
            let binFixed = inBin.sanitisingSends()
            check("a marker nested in a bin is hoisted just after the bin",
                  names(binFixed.plugins) == ["bin", "m", "B"] || names(binFixed.plugins) == ["", "m", "B"],
                  "\(names(binFixed.plugins))")
            check("and the bin lost it", binFixed.plugins[0].fxBlock?.plugins.map { $0.name } == ["X", "Y"])

            // Rack inside a rack: hoisted after the top-level ancestor, in the order met.
            let deep = clip(plugins: [rackOf([[rackOf([[ObjectPlugin.makeSendMarker(for: auxB)]])]]), plugin("Z")],
                            sends: [AuxSend(auxID: auxA), AuxSend(auxID: auxB)])
            check("a marker two racks deep is hoisted after the top-level one",
                  names(deep.sanitisingSends().plugins) == ["//", "m", "Z"])

            // On an aux object: removed.
            let onAux = auxObject(plugins: [plugin("A"), m], sends: sendA)
            check("a marker on an aux object is removed", names(onAux.sanitisingSends().plugins) == ["A"])

            // Idempotence on every case above.
            let all = [orphan, dup, inRack, inBin, deep, onAux]
            check("sanitising is idempotent", all.allSatisfy { $0.sanitisingSends().sanitisingSends() == $0.sanitisingSends() })
            let clean = clip(plugins: [plugin("A"), m, plugin("B")], sends: sendA)
            check("a consistent object is left exactly as it is", clean.sanitisingSends() == clean)

            // A stem / Main chain never keeps one.
            check("stripping removes the markers at any depth",
                  names(ObjectPlugin.strippingSendMarkers([plugin("A"), rackOf([[m]]), m])) == ["A", "//"])
            check("containsSendMarker finds a nested one",
                  ObjectPlugin.containsSendMarker(in: [rackOf([[plugin("X"), m]])], where: { _ in true }))
        }

        // MARK: - Indices follow the array (plugin inserted, removed, reordered around a marker)

        do {
            let base = clip(plugins: [plugin("A"), plugin("B")], sends: [AuxSend(auxID: auxA)])
            let o = base.settingSendPosition(auxID: auxA, .chain(1))        // [A, m, B]
            var inserted = o; inserted.plugins.insert(plugin("N"), at: 0)    // [N, A, m, B]
            check("a plugin inserted BEFORE the marker pushes it to chain(2)", inserted.sendPosition(auxID: auxA) == .chain(2))
            var after = o; after.plugins.append(plugin("N"))                 // [A, m, B, N]
            check("a plugin appended after leaves it at chain(1)", after.sendPosition(auxID: auxA) == .chain(1))
            var removed = o
            let firstID = o.plugins[0].id
            removed.plugins.removeAll { $0.id == firstID }
            check("removing the first plugin leaves chain(0) — the marker kept its array place",
                  removed.sendPosition(auxID: auxA) == .chain(0), "\(names(removed.plugins))")
            var reordered = o; reordered.plugins.swapAt(0, 2)                // [B, m, A]
            check("reordering the two plugins around it leaves chain(1)", reordered.sendPosition(auxID: auxA) == .chain(1))
            var markerFirst = o; markerFirst.plugins.swapAt(0, 1)            // [m, A, B]
            check("moving the marker by array hand reads chain(0)", markerFirst.sendPosition(auxID: auxA) == .chain(0))
        }

        // MARK: - View indices (markers do not count) and the audit

        do {
            let a = plugin("A"), b = plugin("B"), c = plugin("C")
            let m = ObjectPlugin.makeSendMarker(for: auxA), m2 = ObjectPlugin.makeSendMarker(for: auxB)
            let series = [m, a, m2, b, c]          // markers at 0 and 2
            check("view index 0 -> right before the first non-marker (after the leading marker)",
                  ObjectPlugin.modelIndex(ofVisibleIndex: 0, in: series) == 1)
            check("view index 1 -> right before B (after the marker in that gap)",
                  ObjectPlugin.modelIndex(ofVisibleIndex: 1, in: series) == 3)
            check("view index 3 (past the end) -> the end of the array", ObjectPlugin.modelIndex(ofVisibleIndex: 3, in: series) == 5)
            check("view index of C is 2", ObjectPlugin.visibleIndex(ofModelIndex: 4, in: series) == 2)
            check("view index of A is 0", ObjectPlugin.visibleIndex(ofModelIndex: 1, in: series) == 0)
            check("with no marker both are the identity",
                  (0...3).allSatisfy { ObjectPlugin.modelIndex(ofVisibleIndex: $0, in: [a, b, c]) == $0
                                       && ObjectPlugin.visibleIndex(ofModelIndex: $0, in: [a, b, c]) == $0 })

            // The audit: each rule once, and a clean object.
            let sendA = [AuxSend(auxID: auxA)]
            func rules(_ items: [SoundObject], stems: [Stem] = []) -> [String] {
                SendMarkerAudit.violations(items: items, stems: stems).map(\.rule).sorted()
            }
            check("a clean object is clean", rules([clip(plugins: [a, m, b], sends: sendA)]).isEmpty)
            check("orphan", rules([clip(plugins: [a, m2], sends: sendA)]) == ["orphan"])
            check("duplicate", rules([clip(plugins: [m, a, ObjectPlugin.makeSendMarker(for: auxA)], sends: sendA)]) == ["duplicate"])
            check("nested", rules([clip(plugins: [rackOf([[m]])], sends: sendA)]) == ["nested"])
            check("on_aux", rules([auxObject(plugins: [m], sends: sendA)]) == ["on_aux"])
            var st = Stem(id: UUID(), name: "S", colorIndex: 0, format: .stereo); st.plugins = [m]
            check("on_stem", rules([], stems: [st]) == ["on_stem"])
            let phantom = ObjectPlugin(id: UUID(), name: "", manufacturer: "", identifier: "", formatName: "")
            check("phantom: a marker rebuilt as a plugin is caught", rules([clip(plugins: [a, phantom], sends: sendA)]) == ["phantom"])
            check("an object whose violations were sanitised audits clean",
                  rules([clip(plugins: [rackOf([[m]]), ObjectPlugin.makeSendMarker(for: auxB)], sends: sendA).sanitisingSends()]).isEmpty)
            check("markerCount counts the top-level ones, in groups too",
                  SendMarkerAudit.markerCount(items: [clip(plugins: [m], sends: sendA),
                      SoundObject(id: UUID(), startTime: 0, duration: 4, lane: 0,
                                  kind: .group(children: [clip(plugins: [m, a], sends: sendA)], isExpanded: false))]) == 2)
        }

        // MARK: - Marker places (what undo compares)

        do {
            let a = plugin("A"), b = plugin("B")
            let ma = ObjectPlugin.makeSendMarker(for: auxA), mb = ObjectPlugin.makeSendMarker(for: auxB)
            check("sendMarkerPlaces: aux -> index among the real entries",
                  ObjectPlugin.sendMarkerPlaces(in: [ma, a, mb, b]) == [auxA: 0, auxB: 1])
            check("sendMarkerPlaces: no marker, no place", ObjectPlugin.sendMarkerPlaces(in: [a, b]).isEmpty)
            check("sendMarkerPlaces: two markers in one gap share an index",
                  ObjectPlugin.sendMarkerPlaces(in: [a, ma, mb, b]) == [auxA: 1, auxB: 1])
        }

        // MARK: - Retargeting (step 2.11: "Change target…", send.retarget)

        do {
            let newAux = UUID()
            var base = clip(plugins: [plugin("A"), plugin("B")],
                            sends: [AuxSend(auxID: auxA, levelDb: -9, enabled: true), AuxSend(auxID: auxB, levelDb: -3)])
            base = base.settingSendPosition(auxID: auxA, .chain(1))
            base.automation = [AutomationLane(param: .send(auxID: auxA), points: []), AutomationLane(param: .volume, points: [])]
            base.automationTouchOrder = [.volume, .send(auxID: auxA)]
            let r = base.retargetingSend(from: auxA, to: newAux)
            check("retarget: the send now aims at the new aux, level and on/off kept",
                  r.sends.first(where: { $0.auxID == newAux })?.levelDb == -9
                  && r.sends.first(where: { $0.auxID == newAux })?.enabled == true
                  && !r.sends.contains(where: { $0.auxID == auxA }) && r.sends.count == 2)
            check("retarget: the position is kept (same chain slot)", r.sendPosition(auxID: newAux) == .chain(1))
            check("retarget: the marker follows, the old aux has none",
                  ObjectPlugin.sendMarkerChainIndex(auxID: newAux, in: r.plugins) == 1
                  && ObjectPlugin.sendMarkerChainIndex(auxID: auxA, in: r.plugins) == nil
                  && r.plugins.count == base.plugins.count)
            check("retarget: the marker keeps its id", r.plugins.first(where: \.isSendMarker)?.id == base.plugins.first(where: \.isSendMarker)?.id)
            check("retarget: the automation lane and the touch order follow",
                  r.automation.map(\.param) == [.send(auxID: newAux), .volume]
                  && r.automationTouchOrder == [.volume, .send(auxID: newAux)])
            check("retarget: stays sane (sanitisingSends is a no-op)", r.sanitisingSends() == r)
            check("retarget: to an aux that already has a send does nothing", base.retargetingSend(from: auxA, to: auxB) == base)
            check("retarget: from an aux with no send does nothing", base.retargetingSend(from: UUID(), to: newAux) == base)
            check("retarget: to itself does nothing", base.retargetingSend(from: auxA, to: auxA) == base)
            let pre = clip(plugins: [plugin("A")], sends: [AuxSend(auxID: auxA, levelDb: 0)]).settingSendPosition(auxID: auxA, .preFader)
            check("retarget: a tap-only send keeps its tap", pre.retargetingSend(from: auxA, to: newAux).sendPosition(auxID: newAux) == .preFader)
        }

        // MARK: - The split of an aux: the senders' send is duplicated WITH its position

        do {
            let auxA = UUID(), half = UUID()
            for position: SendPosition in [.input, .chain(0), .chain(1), .chain(2), .preFader, .postFader] {
                let base = clip(plugins: [plugin("A"), plugin("B")], sends: [AuxSend(auxID: auxA, levelDb: -7, enabled: false)])
                    .settingSendPosition(auxID: auxA, position)
                let d = base.duplicatingSend(from: auxA, to: half)
                check("duplicate \(position): two sends", d.sends.map(\.auxID) == [auxA, half])
                check("duplicate \(position): the copy has the original's position",
                      d.sendPosition(auxID: half) == position && d.sendPosition(auxID: auxA) == position,
                      "\(String(describing: d.sendPosition(auxID: half)))")
                check("duplicate \(position): level and on/off copied",
                      d.sends[1].levelDb == -7 && d.sends[1].enabled == false)
                check("duplicate \(position): stays sane", d.sanitisingSends() == d)
                check("duplicate \(position): the real plugins did not move",
                      d.plugins.filter { !$0.isSendMarker }.map(\.id) == base.plugins.filter { !$0.isSendMarker }.map(\.id))
            }
            let base = clip(plugins: [plugin("A")], sends: [AuxSend(auxID: auxA, levelDb: 0)])
                .settingSendPosition(auxID: auxA, .chain(0))
            let d = base.duplicatingSend(from: auxA, to: half)
            check("duplicate: the new marker sits right after the original's",
                  d.plugins.map { $0.sendMarker?.auxID } == [auxA, half, nil])
            check("duplicate: fresh marker id", Set(d.plugins.map(\.id)).count == 3)
            check("duplicate: a second call does nothing", d.duplicatingSend(from: auxA, to: half) == d)
            check("duplicate: no send to the source does nothing", base.duplicatingSend(from: UUID(), to: half) == base)
            check("duplicate: onto itself does nothing", base.duplicatingSend(from: auxA, to: auxA) == base)
        }

        // MARK: - Names

        do {
            check("position names", SendPosition.input.name == "input" && SendPosition.chain(3).name == "chain"
                  && SendPosition.preFader.name == "pre_fader" && SendPosition.postFader.name == "post_fader")
            check("named() inverts them", SendPosition.named("pre_fader") == .preFader
                  && SendPosition.named("chain", index: 2) == .chain(2)
                  && SendPosition.named("chain") == nil && SendPosition.named("nope") == nil)
            check("the session format is 24", SessionSchema.formatVersion == 24)
            check("the notice mentions both new keys",
                  SessionSchema.note.joined(separator: "\n").contains("sendMarker")
                  && SessionSchema.note.joined(separator: "\n").contains("preFader"))
        }

        // MARK: - The plugins ON a send (INC 3): the sanitiser, the duplicate, the removal

        do {
            let auxA = UUID(), auxB = UUID()
            let lp = plugin("lp"), sat = plugin("sat"), g = plugin("G")
            let dirty = clip(plugins: [g],
                             sends: [AuxSend(auxID: auxA, plugins: [lp, rackOf([[plugin("x")]]), binOf([plugin("y")]),
                                                                    ObjectPlugin.makeSendMarker(for: auxB), sat])])
            let clean = dirty.sanitisingSends()
            check("sanitise: a block, a bin and a marker in a send's plugins are dropped, the plain ones kept in order",
                  names(clean.sends[0].plugins) == ["lp", "sat"], "\(names(clean.sends[0].plugins))")
            check("sanitise: idempotent on a send's plugins", clean.sanitisingSends() == clean)
            let sound = clip(plugins: [g], sends: [AuxSend(auxID: auxA, plugins: [lp, sat])])
            check("sanitise: a sound mini-chain is left alone", sound.sanitisingSends() == sound)
            check("sanitise: the trunk is untouched by the send's cleaning", names(clean.plugins) == ["G"])

            // The mini-chain follows the send when its position changes (it is the SEND's, not the tap point's).
            for pos in [SendPosition.input, .chain(1), .preFader, .postFader] {
                let moved = sound.settingSendPosition(auxID: auxA, pos)
                check("position \(pos.name): the send keeps its plugins",
                      moved.sends[0].plugins == [lp, sat] && moved.sendPosition(auxID: auxA) == pos)
            }

            let dup = sound.settingSendPosition(auxID: auxA, .chain(1)).duplicatingSend(from: auxA, to: auxB)
            check("duplicate: the copy's plugins are the same, under fresh ids",
                  names(dup.sends[1].plugins) == ["lp", "sat"]
                  && Set(dup.sends[1].plugins.map(\.id)).isDisjoint(with: [lp.id, sat.id]))
            check("duplicate: the original's plugins are untouched", dup.sends[0].plugins == [lp, sat])
            check("duplicate: the trunk holds both markers and no send plugin", names(dup.plugins) == ["G", "m", "m"])

            var curved = sound.settingSendPosition(auxID: auxA, .chain(0))
            curved.automation = [AutomationLane(param: .plugin(pluginKey: sat.id, paramID: "p"), points: [AutomationPoint(t: 0, v: 1)]),
                                 AutomationLane(param: .send(auxID: auxA), points: [AutomationPoint(t: 0, v: -6)]),
                                 AutomationLane(param: .plugin(pluginKey: g.id, paramID: "p"), points: [AutomationPoint(t: 0, v: 1)])]
            curved.automationTouchOrder = [.plugin(pluginKey: lp.id, paramID: "p"), .plugin(pluginKey: g.id, paramID: "p")]
            let cut = curved.removingSends([auxA])
            check("remove: the entry, its marker, its plugins' lanes and its level's lane are gone",
                  cut.sends.isEmpty && names(cut.plugins) == ["G"]
                  && cut.automation.map(\.param) == [.plugin(pluginKey: g.id, paramID: "p")]
                  && cut.automationTouchOrder == [.plugin(pluginKey: g.id, paramID: "p")])
            check("remove: an orphan marker alone is removed too",
                  clip(plugins: [g, ObjectPlugin.makeSendMarker(for: auxB)], sends: []).removingSends([auxB]).plugins == [g])

            // The split of an aux duplicates the CURVES with the send (10 October): the level's lane
            // and the lanes of the send's plugins, re-aimed at the COPIES' ids; the trunk's are not.
            do {
                let pts1 = [AutomationPoint(t: 0, v: 0.2), AutomationPoint(t: 1.5, v: 0.9, c: 0.5)]
                let pts2 = [AutomationPoint(t: 0, v: -6), AutomationPoint(t: 2, v: -24)]
                var src = sound.settingSendPosition(auxID: auxA, .chain(0))
                src.automation = [AutomationLane(param: .plugin(pluginKey: sat.id, paramID: "drive"), points: pts1),
                                  AutomationLane(param: .send(auxID: auxA), points: pts2),
                                  AutomationLane(param: .plugin(pluginKey: g.id, paramID: "p"), points: pts1),
                                  AutomationLane(param: .volume, points: pts2)]
                src.automationTouchOrder = [.send(auxID: auxA), .volume, .plugin(pluginKey: sat.id, paramID: "drive"),
                                            .plugin(pluginKey: lp.id, paramID: "never")]
                let d = src.duplicatingSend(from: auxA, to: auxB)
                let newSat = d.sends[1].plugins[1].id, newLp = d.sends[1].plugins[0].id
                func lane(_ r: ParamRef) -> [AutomationPoint]? { d.automation.first { $0.param == r }?.points }
                check("duplicate curves: the level's lane is copied for the new aux, same points",
                      lane(.send(auxID: auxB)) == pts2 && lane(.send(auxID: auxA)) == pts2)
                check("duplicate curves: the plugin's lane is copied for the COPY's id, same points",
                      lane(.plugin(pluginKey: newSat, paramID: "drive")) == pts1
                      && lane(.plugin(pluginKey: sat.id, paramID: "drive")) == pts1 && newSat != sat.id)
                check("duplicate curves: exactly two lanes were added (the trunk's and the fader's are not copied)",
                      d.automation.count == src.automation.count + 2
                      && Array(d.automation.prefix(src.automation.count)) == src.automation)
                check("duplicate curves: no lane aims at an id the object does not hold, none is shared",
                      Set(d.automation.map(\.param)).count == d.automation.count
                      && d.automation.allSatisfy { l in
                          if case .plugin(let k, _) = l.param {
                              return ([g.id] + d.sends.flatMap(\.plugins).map(\.id)).contains(k)
                          }
                          return true })
                check("duplicate curves: the touch memory lists each copy right after its original (and only born lanes)",
                      d.automationTouchOrder == [.send(auxID: auxA), .send(auxID: auxB), .volume,
                                                 .plugin(pluginKey: sat.id, paramID: "drive"),
                                                 .plugin(pluginKey: newSat, paramID: "drive"),
                                                 .plugin(pluginKey: lp.id, paramID: "never")],
                      "\(d.automationTouchOrder)")
                check("duplicate curves: no copy is linked", d.sends[1].plugins.allSatisfy { $0.linkGroupID == nil })
                _ = newLp
                // the caller's own copies (live states): the lanes follow THOSE ids, by rank
                let mine = [plugin("lp"), plugin("sat")]
                let d2 = src.duplicatingSend(from: auxA, to: auxB, plugins: mine)
                check("duplicate curves: with the caller's copies the lane aims at the caller's id",
                      d2.automation.contains { $0.param == .plugin(pluginKey: mine[1].id, paramID: "drive") && $0.points == pts1 })
                // a list of another length: no guess, the plugin lanes are not copied (the level's is)
                let d3 = src.duplicatingSend(from: auxA, to: auxB, plugins: [plugin("only")])
                check("duplicate curves: a list of another length copies the level's lane only",
                      d3.automation.count == src.automation.count + 1 && d3.automation.last?.param == .send(auxID: auxB))
                check("duplicate curves: the result stays sane, and a second call does nothing",
                      d.sanitisingSends() == d && d.duplicatingSend(from: auxA, to: auxB) == d)
                // and the removal of the new half takes its curves away, leaving the original's
                let back = d.removingSends([auxB])
                check("duplicate curves: removing the new send restores the object", back == src, "\(back.automationTouchOrder)")
                // a send WITHOUT plugins: the level's lane alone
                var plain = clip(plugins: [g], sends: [AuxSend(auxID: auxA, levelDb: -3)])
                plain.automation = [AutomationLane(param: .send(auxID: auxA), points: pts2)]
                let dp = plain.duplicatingSend(from: auxA, to: auxB)
                check("duplicate curves: a send without plugins copies its level's lane",
                      dp.automation.map(\.param) == [.send(auxID: auxA), .send(auxID: auxB)] && dp.automation[1].points == pts2)
            }

            // The engine's half of the audit: where a POST-FADER send sits depends on what it carries.
            do {
                let host = clip(plugins: [g], sends: [AuxSend(auxID: auxA, plugins: [lp])])
                func layout(sendAt k: Int, carries: Int?) -> [SendMarkerAudit.LayoutEntry] {
                    var roles = ["trimIn", "fx", "trimOut", "fader", "windowFade"]
                    roles.insert("send", at: k)
                    return roles.enumerated().map { i, r in
                        SendMarkerAudit.LayoutEntry(index: i, role: r, key: r == "fx" ? g.id.uuidString : nil,
                                                    aux: r == "send" ? auxA.uuidString : nil,
                                                    tapPosition: r == "send" ? 0 : nil,
                                                    chainPlugins: r == "send" ? carries : nil)
                    }
                }
                func rules(_ l: [SendMarkerAudit.LayoutEntry], _ o: SoundObject) -> [String] {
                    SendMarkerAudit.engineViolations(object: o, layout: l).map(\.rule)
                }
                let bare = clip(plugins: [g], sends: [AuxSend(auxID: auxA)])
                check("audit: post-fader WITH plugins sits between the fader and the window-fade",
                      rules(layout(sendAt: 4, carries: 1), host) == [])
                check("audit: post-fader with plugins AFTER the window-fade is a violation",
                      rules(layout(sendAt: 5, carries: 1), host) == ["index_before_windowFade"])
                check("audit: post-fader with plugins BEFORE the fader is a violation",
                      rules(layout(sendAt: 3, carries: 1), host) == ["index_after_fader"])
                check("audit: post-fader WITHOUT plugins stays after the window-fade",
                      rules(layout(sendAt: 5, carries: 0), bare) == [] && rules(layout(sendAt: 4, carries: 0), bare) == ["index_after_windowFade"])
                check("audit: the engine's count wins over the model's; without it the model's is used",
                      rules(layout(sendAt: 5, carries: 0), host) == [] && rules(layout(sendAt: 4, carries: nil), host) == []
                      && rules(layout(sendAt: 5, carries: nil), bare) == [])
            }

            // On disk: `plugins` is written only when the send has some.
            check("encode: a send without plugin writes no `plugins` key", !json(AuxSend(auxID: auxA)).contains("plugins"))
            let round = decode(AuxSend.self, json(AuxSend(auxID: auxA, levelDb: -3, plugins: [lp, sat])))
            check("encode: a send's plugins round-trip", round?.plugins == [lp, sat] && round?.levelDb == -3)
        }

        print("\n\(total - fails.count)/\(total) passed")
        if !fails.isEmpty { print("FAILED: \(fails)"); exit(1) }
    }
}
