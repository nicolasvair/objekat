// The plugins of a send (INC 3 of the sends rework, session format 23) — the PURE half: the derived
// chain-host id, the content rule (leaves only), the ONE walker of an object's three plugin roots,
// the model's encoding (a format-22 send decodes to an empty chain and re-encodes without the key),
// what keeps the plugins (a move, a retarget) and the copy tools every copier goes through.
// docs/plan_sends_rework.md §D.2.
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
//         ../objekat/Shared/Localization.swift \
//         ../objekat/EditViewModel/EditViewModel+Types.swift \
//         ../objekat/EditViewModel/SessionSchema.swift \
//         ../objekat/App/LaunchArguments.swift \
//         ../objekat/Shared/BridgeScope.swift \
//         ../objekat/Shared/ScriptCanvasMemory.swift \
//         test_send_chain.swift \
//         -o /tmp/test_send_chain && /tmp/test_send_chain
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
enum SendChainTest {
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
        func clip(plugins: [ObjectPlugin] = [], instruments: [ObjectPlugin] = [], sends: [AuxSend]) -> SoundObject {
            SoundObject(id: UUID(), startTime: 0, duration: 4, lane: 0, plugins: plugins, instruments: instruments,
                        sends: sends,
                        kind: .clip(filePath: "a.wav", sourceOffset: 0, fileDuration: 4,
                                    speedRatio: 1, isReversed: false))
        }
        func json(_ v: some Encodable) -> String {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys]
            return String(data: try! e.encode(v), encoding: .utf8)!
        }
        func decode<T: Decodable>(_ type: T.Type, _ s: String) -> T {
            try! JSONDecoder().decode(type, from: Data(s.utf8))
        }

        // MARK: - The host id

        do {
            let s = UUID(), a = UUID(), b = UUID()
            let h = SendChain.hostID(sender: s, aux: a)
            check("hostID: deterministic", h == SendChain.hostID(sender: s, aux: a))
            check("hostID: another aux, another host", h != SendChain.hostID(sender: s, aux: b))
            check("hostID: another sender, another host", h != SendChain.hostID(sender: b, aux: a))
            check("hostID: the pair is ordered (sender, aux) != (aux, sender)", h != SendChain.hostID(sender: a, aux: s))
            check("hostID: never the sender's id nor the aux's", h != s && h != a)
            check("hostID: an object sending to itself (never valid) still gets a host of its own",
                  SendChain.hostID(sender: s, aux: s) != s)
            var seen = Set<UUID>()
            let ids = (0..<40).map { _ in UUID() }
            for x in ids { for y in ids { seen.insert(SendChain.hostID(sender: x, aux: y)) } }
            check("hostID: 1600 pairs, 1600 hosts", seen.count == 1600, "\(seen.count)")
            check("hostID: none of them is one of the ids", seen.isDisjoint(with: Set(ids)))
            let known = SendChain.hostID(sender: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                                         aux: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)
            check("hostID: a version-5, RFC 4122 UUID", known.uuidString.split(separator: "-")[2].hasPrefix("5")
                  && "89AB".contains(known.uuidString.split(separator: "-")[3].first!), known.uuidString)
        }

        // MARK: - The content rule

        do {
            let a = plugin("a"), b = plugin("b"), c = plugin("c")
            let dirty = [a, rackOf([[plugin("r1")], [plugin("r2")]]), b, binOf([plugin("in bin")]),
                         ObjectPlugin.makeSendMarker(for: UUID()), c]
            let clean = SendChain.sanitised(dirty)
            check("sanitised: the leaves stay, in order", clean.map(\.id) == [a.id, b.id, c.id])
            check("sanitised: a block, a bin and a marker go", clean.allSatisfy { !$0.isContainer })
            check("sanitised: idempotent", SendChain.sanitised(clean) == clean)
            check("sanitised: an empty chain stays empty", SendChain.sanitised([]).isEmpty)
            check("accepts: a plain plugin", SendChain.accepts(a))
            check("accepts: not a block", !SendChain.accepts(rackOf([[a]])))
            check("accepts: not a bin", !SendChain.accepts(binOf([a])))
            check("accepts: not a marker", !SendChain.accepts(ObjectPlugin.makeSendMarker(for: UUID())))
        }

        // MARK: - The walk

        do {
            let t1 = plugin("t1"), t2 = plugin("t2"), r1 = plugin("r1"), r2 = plugin("r2"), inBin = plugin("bin")
            let inst = plugin("inst")
            let s1 = plugin("s1"), s2 = plugin("s2"), s3 = plugin("s3")
            let auxA = UUID(), auxB = UUID(), auxC = UUID()
            let o = clip(plugins: [t1, ObjectPlugin.makeSendMarker(for: auxA), rackOf([[r1], [r2]]), binOf([inBin]), t2],
                         instruments: [inst],
                         sends: [AuxSend(auxID: auxA, plugins: [s1, s2]), AuxSend(auxID: auxB),
                                 AuxSend(auxID: auxC, levelDb: -60, enabled: false, plugins: [s3])])
            let all = SendChain.allRoots(of: o).map(\.id)
            check("allRoots: trunk leaves, then instruments, then every send's plugins",
                  all == [t1.id, r1.id, r2.id, inBin.id, t2.id, inst.id, s1.id, s2.id, s3.id], "\(all.count)")
            check("allRoots: each exactly once", Set(all).count == all.count)
            check("allRoots: a switched-off send's plugins are walked too", all.contains(s3.id))
            check("sendPlugins: the third root alone", SendChain.sendPlugins(of: o).map(\.id) == [s1.id, s2.id, s3.id])
            check("auxID(holding:): the send that carries the plugin", SendChain.auxID(holding: s3.id, in: o) == auxC)
            check("auxID(holding:): a trunk plugin is on no send", SendChain.auxID(holding: t1.id, in: o) == nil)
            check("allRoots: an object without sends", SendChain.allRoots(of: clip(plugins: [t1], sends: [])).map(\.id) == [t1.id])
        }

        // MARK: - Codable, format 23

        do {
            let aux = UUID()
            let bare = AuxSend(auxID: aux, levelDb: -6)
            check("codable: no `plugins` key when the send carries none", !json(bare).contains("plugins"), json(bare))
            let p = plugin("lowpass")
            let carrying = AuxSend(auxID: aux, levelDb: -6, enabled: true, tap: .preFader, plugins: [p, plugin("sat")])
            check("codable: the key is written when it does", json(carrying).contains("\"plugins\""))
            let back = decode(AuxSend.self, json(carrying))
            check("codable: round trip (ids, order, level, tap)", back == carrying)
            let v22 = "{\"auxID\":\"\(aux.uuidString)\",\"levelDb\":-6,\"enabled\":true,\"tap\":\"preFader\"}"
            let old = decode(AuxSend.self, v22)
            check("codable: a format-22 send decodes to an empty chain", old.plugins.isEmpty && old.tap == .preFader && old.levelDb == -6)
            check("codable: and re-encodes without the key (22 == 23 for it)", !json(old).contains("plugins"))
            let dirty = AuxSend(auxID: aux, plugins: [p])
            var raw = try! JSONSerialization.jsonObject(with: Data(json(dirty).utf8)) as! [String: Any]
            var list = raw["plugins"] as! [[String: Any]]
            let marker = try! JSONSerialization.jsonObject(with: Data(json(ObjectPlugin.makeSendMarker(for: UUID())).utf8)) as! [String: Any]
            let block = try! JSONSerialization.jsonObject(with: Data(json(rackOf([[plugin("x")]])).utf8)) as! [String: Any]
            let bin = try! JSONSerialization.jsonObject(with: Data(json(binOf([plugin("y")])).utf8)) as! [String: Any]
            list.insert(marker, at: 0); list.append(block); list.append(bin)
            raw["plugins"] = list
            let handWritten = String(data: try! JSONSerialization.data(withJSONObject: raw), encoding: .utf8)!
            let cleaned = decode(AuxSend.self, handWritten)
            check("codable: a hand-written marker / block / bin in a send's plugins is dropped at decode",
                  cleaned.plugins.map(\.id) == [p.id], "\(cleaned.plugins.count)")
            check("the session format is 23", SessionSchema.formatVersion == 23)
            check("the notice says where a send's plugins live", SessionSchema.note.contains { $0.contains("PLUGINS ON a send (format 23)") })
            check("equality: two sends differing by their plugins are different", bare != AuxSend(auxID: aux, levelDb: -6, plugins: [p]))
        }

        // MARK: - What keeps the plugins

        do {
            let auxA = UUID(), auxB = UUID()
            let s1 = plugin("s1"), s2 = plugin("s2"), t = plugin("t")
            let o = clip(plugins: [t], sends: [AuxSend(auxID: auxA, levelDb: -6, plugins: [s1, s2])])
            for position in [SendPosition.input, .chain(0), .chain(1), .preFader, .postFader] {
                let moved = o.settingSendPosition(auxID: auxA, position)
                check("settingSendPosition(\(position.name)): the plugins stay",
                      moved.sends.first?.plugins.map(\.id) == [s1.id, s2.id])
                check("settingSendPosition(\(position.name)): the host does not change",
                      SendChain.hostID(sender: moved.id, aux: auxA) == SendChain.hostID(sender: o.id, aux: auxA))
            }
            let re = o.settingSendPosition(auxID: auxA, .chain(0)).retargetingSend(from: auxA, to: auxB)
            check("retarget: the plugins stay, same ids, on the new aux",
                  re.sends.count == 1 && re.sends[0].auxID == auxB && re.sends[0].plugins.map(\.id) == [s1.id, s2.id])
            check("retarget: the host is the new pair's", SendChain.hostID(sender: re.id, aux: auxB) != SendChain.hostID(sender: o.id, aux: auxA))
            let cleanedObject = clip(plugins: [], sends: [AuxSend(auxID: auxA, plugins: [s1])]).sanitisingSends()
            check("sanitisingSends: a send's plain plugins are left alone", cleanedObject.sends[0].plugins.map(\.id) == [s1.id])
        }

        // MARK: - The copy tools

        do {
            let auxA = UUID(), auxB = UUID()
            let s1 = plugin("s1"), s2 = plugin("s2"), s3 = plugin("s3")
            let sends = [AuxSend(auxID: auxA, levelDb: -6, plugins: [s1, s2]), AuxSend(auxID: auxB, plugins: [s3])]
            var table: [UUID: UUID] = [:]
            let fresh = SendChain.mapPluginIDs(in: sends) { old in let n = UUID(); table[old] = n; return n }
            check("mapPluginIDs: every send plugin gets the mapped id",
                  fresh[0].plugins.map(\.id) == [table[s1.id]!, table[s2.id]!] && fresh[1].plugins.map(\.id) == [table[s3.id]!])
            check("mapPluginIDs: no id shared with the original",
                  Set(fresh.flatMap(\.plugins).map(\.id)).isDisjoint(with: [s1.id, s2.id, s3.id]))
            check("mapPluginIDs: level, switch, tap and aux untouched",
                  fresh.map(\.auxID) == [auxA, auxB] && fresh[0].levelDb == -6)
            check("pluginIDRemap: pairs the two arrays' mini-chains", SendChain.pluginIDRemap(from: sends, to: fresh) == table)
            var shorter = fresh
            shorter[0].plugins.removeLast()
            let partial = SendChain.pluginIDRemap(from: sends, to: shorter)
            check("pluginIDRemap: a chain that changed length pairs nothing, the other still does",
                  partial == [s3.id: table[s3.id]!], "\(partial.count)")
            let viaBlock = SendChain.mapping(sends) { $0 + [ObjectPlugin.makeSendMarker(for: UUID())] }
            check("mapping: the result is sanitised (a marker never enters a mini-chain)",
                  viaBlock.flatMap(\.plugins).allSatisfy { !$0.isContainer })
            check("mapping: a send without plugins is returned as it is (the transform is not called)",
                  SendChain.mapping([AuxSend(auxID: auxA)]) { _ in [s1] } == [AuxSend(auxID: auxA)])
            check("strippingPlugins: the routes stay, the mini-chains go",
                  SendChain.strippingPlugins(sends).map(\.auxID) == [auxA, auxB]
                  && SendChain.strippingPlugins(sends).allSatisfy { $0.plugins.isEmpty })
        }

        print("\n\(total - fails.count)/\(total) passed")
        if !fails.isEmpty { print("FAILED: \(fails)"); exit(1) }
    }
}
