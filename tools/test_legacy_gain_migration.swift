// `LegacyGainMigration` (plan_synoptic_rework, M.2 / B.0.2) — the old chain trims and FX link output
// sections turned into gain stages at load, asserted with no screen and no engine.
//
// The legacy keys are written into the fixtures as JSON (encode → patch the dictionary → decode), the
// way a format-24 file carries them, so that this test keeps compiling once the stored fields are gone
// and only their decoding remains.
//
//     swiftc -parse-as-library \
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
//         ../objekat/SoundObject/GainStage.swift \
//         ../objekat/SoundObject/LegacyGainMigration.swift \
//         ../objekat/Shared/ObjekatPalette.swift \
//         ../objekat/Shared/ObjectColorChoice.swift \
//         ../objekat/Shared/Localization.swift \
//         ../objekat/EditViewModel/EditViewModel+Types.swift \
//         ../objekat/EditViewModel/SessionSchema.swift \
//         ../objekat/App/LaunchArguments.swift \
//         ../objekat/SoundObject/CrossProjectImport.swift \
//         ../objekat/SoundObject/PluginIDUniqueness.swift \
//         ../objekat/SoundObject/PluginIDReport.swift \
//         ../objekat/Shared/BridgeScope.swift \
//         ../objekat/Shared/ScriptCanvasMemory.swift \
//         test_legacy_gain_migration.swift \
//         -o /tmp/lgm && /tmp/lgm
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

// MARK: - JSON helpers: write a legacy key the way a format-24 file does

func jsonObject<T: Encodable>(_ v: T) -> [String: Any] {
    let data = try! JSONEncoder().encode(v)
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}
func decoded<T: Decodable>(_ type: T.Type, _ dict: [String: Any]) -> T {
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(T.self, from: data)
}
/// An object with old trims (and optionally its children replaced by legacy ones). Since M.4 the
/// old values live in DECODE-ONLY `legacy…` fields, never encoded: a fixture sets them directly (a JSON
/// round trip would drop them — and the old touch entries, which no longer resolve). The decoding
/// itself is asserted on its own, from raw JSON ("the legacy keys are decode-only").
func legacy(_ o: SoundObject, trimIn: Float? = nil, trimOut: Float? = nil,
            children: [SoundObject]? = nil) -> SoundObject {
    var o = o
    if let t = trimIn { o.legacyChainInGainDb = t }
    if let t = trimOut { o.legacyChainOutGainDb = t }
    if let children, case .group(_, let expanded) = o.kind { o.kind = .group(children: children, isExpanded: expanded) }
    return o
}
func legacyStem(_ s: Stem, trimIn: Float? = nil, trimOut: Float? = nil) -> Stem {
    var s = s
    if let t = trimIn { s.legacyChainInGainDb = t }
    if let t = trimOut { s.legacyChainOutGainDb = t }
    return s
}
func legacyLink(_ l: FXLink, gainDb: Float, pan: Float = 0, muted: Bool = false, enabled: Bool = true) -> FXLink {
    var l = l
    l.legacyGainDb = gainDb; l.legacyPan = pan; l.legacyMuted = muted; l.isEnabled = enabled
    return l
}
/// A detached block's legacy output section.
func legacyLocal(enabled: Bool = true, gainDb: Float = 0, pan: Float = 0, muted: Bool = false) -> FXLinkOutput {
    var o = FXLinkOutput(isEnabled: enabled)
    o.legacyGainDb = gainDb; o.legacyPan = pan; o.legacyMuted = muted
    return o
}
/// The legacy `ParamRef`s, written by name (they will stay decodable, never produced).
func legacyLane(_ type: String, _ points: [(Double, Float)]) -> AutomationLane {
    decoded(AutomationLane.self, ["param": ["type": type],
                                  "points": points.map { ["t": $0.0, "v": $0.1, "c": 0] }])
}
func legacyRef(_ type: String) -> ParamRef { decoded(AutomationLane.self, ["param": ["type": type], "points": []]).param }

/// Every plugin id of the document (leaves, carriers, blocks, instances, sends' plugins, stems).
func allIDs(_ items: [SoundObject], _ stems: [Stem]) -> [UUID] {
    func walk(_ ps: [ObjectPlugin]) -> [UUID] {
        ps.flatMap { p in [p.id] + p.childSeries.flatMap(walk) }
    }
    func obj(_ o: SoundObject) -> [UUID] {
        var out = walk(o.plugins) + walk(o.instruments) + o.sends.flatMap { walk($0.plugins) }
        if case .group(let ch, _) = o.kind { out += ch.flatMap(obj) }
        return out
    }
    return items.flatMap(obj) + stems.flatMap { walk($0.plugins) }
}

@main
enum LegacyGainMigrationTest {
    static func main() {

        func clip(lane: Int = 0, plugins: [ObjectPlugin] = [], sends: [AuxSend] = [],
                  automation: [AutomationLane] = [], touch: [ParamRef] = []) -> SoundObject {
            SoundObject(startTime: 0, duration: 4, lane: lane, plugins: plugins, sends: sends,
                        automation: automation, automationTouchOrder: touch,
                        kind: .clip(filePath: "/tmp/a.wav", sourceOffset: 0, fileDuration: 4,
                                    speedRatio: 1, isReversed: false))
        }
        func plug(_ name: String = "Comp") -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: name, manufacturer: "Tracktion", identifier: "compressor",
                         formatName: "TracktionInternal", stateXML: "<PLUGIN type=\"compressor\"/>")
        }
        func gainOf(_ p: ObjectPlugin) -> Float? { p.gainStageStoredValues?.gainDb }

        let auxA = SoundObject(startTime: 0, duration: 4, lane: 5, kind: .aux)
        let auxB = SoundObject(startTime: 0, duration: 4, lane: 6, kind: .aux)

        // MARK: trims around markers
        do {
            let comp = plug()
            let markerHead = ObjectPlugin.makeSendMarker(for: auxA.id)
            let markerTail = ObjectPlugin.makeSendMarker(for: auxB.id)
            let o = legacy(clip(plugins: [markerHead, comp, markerTail],
                                sends: [AuxSend(auxID: auxA.id), AuxSend(auxID: auxB.id)]),
                           trimIn: -6, trimOut: 3)
            var doc = ProjectDocument(items: [o, auxA, auxB], stems: [])
            let r = LegacyGainMigration.migrate(&doc)
            let p = doc.items[0].plugins
            check("trim in −6 → a gain stage at index 0", p.first?.gainStageFace == .gain && gainOf(p[0]) == -6,
                  "\(p.map(\.name))")
            check("…before the marker that sat after the old trim", p.count == 5 && p[1].isSendMarker)
            check("trim out +3 → a gain stage at the END", p.last?.gainStageFace == .gain && gainOf(p[4]) == 3)
            check("…after the trailing marker", p[3].isSendMarker && p[3].sendMarker?.auxID == auxB.id)
            check("the plugin keeps its place between the two markers", p[2].id == comp.id)
            check("the trims are left neutral", doc.items[0].legacyChainInGainDb == 0 && doc.items[0].legacyChainOutGainDb == 0)
            check("report: 2 trims", r == .init(trims: 2, fxOutputs: 0, automationLanes: 0, clamped: 0), "\(r)")
        }

        // MARK: neutral trims, curve on a 0 dB trim, curve mapping and touch order
        do {
            var doc = ProjectDocument(items: [legacy(clip(plugins: [plug()]), trimIn: 0, trimOut: 0)], stems: [])
            let r = LegacyGainMigration.migrate(&doc)
            check("0 dB with no curve → nothing laid", doc.items[0].plugins.count == 1 && r.isEmpty, "\(r)")
        }
        do {
            let lane = legacyLane("chainInGain", [(0, -18), (2, 6), (3, 0)])
            let other = AutomationLane(param: .volume, points: [AutomationPoint(t: 0, v: -3)])
            let o = legacy(clip(plugins: [plug()], automation: [lane, other],
                                touch: [legacyRef("chainInGain"), .volume, legacyRef("chainOutGain")]),
                           trimIn: 0)
            var doc = ProjectDocument(items: [o], stems: [])
            let r = LegacyGainMigration.migrate(&doc)
            let obj = doc.items[0]
            let stage = obj.plugins.first
            check("0 dB WITH a curve → a stage", stage?.gainStageFace == .gain && gainOf(stage!) == 0)
            let target = ParamRef.plugin(pluginKey: stage?.id ?? UUID(), paramID: "gain")
            let moved = obj.automation.first { $0.param == target }
            check("the curve is re-aimed at the stage's gain", moved != nil)
            let vs = moved?.points.map(\.v) ?? []
            check("points mapped (dB+24)/48", vs.count == 3
                  && abs(vs[0] - 0.125) < 1e-6 && abs(vs[1] - 0.625) < 1e-6 && abs(vs[2] - 0.5) < 1e-6, "\(vs)")
            check("times and order of the points kept", moved?.points.map(\.t) == [0, 2, 3])
            check("the other lanes are untouched", obj.automation.contains(other) && obj.automation.count == 2)
            check("no legacy lane left", !obj.automation.contains { $0.param == legacyRef("chainInGain") })
            check("touch order re-aimed, a dead trim entry dropped",
                  obj.automationTouchOrder == [target, .volume], "\(obj.automationTouchOrder)")
            check("report: 1 trim, 1 lane", r == .init(trims: 1, fxOutputs: 0, automationLanes: 1, clamped: 0), "\(r)")
        }

        // MARK: stems, the Main, groups recursively
        do {
            let stem = legacyStem(Stem(id: UUID(), name: "Drums", colorIndex: 0, format: .stereo,
                                       plugins: [plug()]), trimIn: -3, trimOut: 2)
            let main = legacyStem(Stem(id: UUID(), name: "Main", colorIndex: 1, format: .stereo), trimIn: -1)
            let child1 = legacy(clip(), trimOut: 4)
            let inner  = legacy(SoundObject(startTime: 0, duration: 4, lane: 1,
                                            kind: .group(children: [], isExpanded: false)),
                                trimIn: -2, children: [legacy(clip(), trimIn: 5)])
            let group  = legacy(SoundObject(startTime: 0, duration: 4, lane: 0,
                                            kind: .group(children: [], isExpanded: false)),
                                children: [child1, inner])
            var doc = ProjectDocument(items: [group], stems: [stem, main])
            let r = LegacyGainMigration.migrate(&doc)
            let s = doc.stems![0], m = doc.stems![1]
            check("a stem: trim in at index 0, trim out at the end",
                  s.plugins.count == 3 && gainOf(s.plugins[0]) == -3 && gainOf(s.plugins[2]) == 2
                  && s.plugins[1].gainStageFace == nil)
            check("the Main: trim in → a stage", m.plugins.count == 1 && gainOf(m.plugins[0]) == -1)
            check("the stems' trims are neutral",
                  s.legacyChainInGainDb == 0 && s.legacyChainOutGainDb == 0 && m.legacyChainInGainDb == 0)
            guard case .group(let ch, _) = doc.items[0].kind, case .group(let gch, _) = ch[1].kind else {
                check("group shape kept", false); return
            }
            check("a group's child", ch[0].plugins.count == 1 && gainOf(ch[0].plugins[0]) == 4)
            check("a nested group", ch[1].plugins.count == 1 && gainOf(ch[1].plugins[0]) == -2)
            check("a grandchild", gch[0].plugins.count == 1 && gainOf(gch[0].plugins[0]) == 5)
            check("report: 6 trims", r.trims == 6 && r.fxOutputs == 0, "\(r)")
        }

        // MARK: FX link: definition + one instance per ATTACHED member, detached local
        let binID = UUID()
        let defComp = plug("Pro-C")
        func inst(_ d: ObjectPlugin, detached: Bool = false) -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: d.name, manufacturer: d.manufacturer, identifier: d.identifier,
                         formatName: d.formatName, stateXML: d.stateXML,
                         linkGroupID: detached ? nil : d.id, detachedLinkGroupID: detached ? d.id : nil)
        }
        func block(detached: Bool = false, local: FXLinkOutput? = nil) -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: "bin", manufacturer: "", identifier: "", formatName: "",
                         fxBlock: FXLinkBlock(linkID: binID, isDetached: detached,
                                              plugins: [inst(defComp, detached: detached)], local: local))
        }
        do {
            let link = legacyLink(FXLink(id: binID, name: "Kick", plugins: [defComp]), gainDb: -4.5, pan: 0.25)
            let a = clip(lane: 0, plugins: [block()])
            let b = clip(lane: 1, plugins: [plug(), block()])
            let c = clip(lane: 2, plugins: [block(detached: true, local: legacyLocal(gainDb: -6, muted: true))])
            let d = clip(lane: 3, plugins: [block(detached: true)])
            let rack = ObjectPlugin(id: UUID(), name: "rack", manufacturer: "", identifier: "", formatName: "",
                                    rack: PluginRack(voices: [[block()], [plug()]]))
            let e = clip(lane: 4, plugins: [rack])
            var doc = ProjectDocument(items: [a, b, c, d, e], stems: [])
            doc.fxLinks = [link]
            let before = allIDs(doc.items, [])
            let r = LegacyGainMigration.migrate(&doc)
            let L = doc.fxLinks![0]
            let def = L.plugins.last!
            check("the bin's definition gains a gain+pan+mute leaf at its end",
                  L.plugins.count == 2 && def.gainStageFace == .gainPanMute)
            check("…with the output's gain and pan",
                  def.gainStageStoredValues == GainStageValues(gainDb: -4.5, pan: 0.25, muted: false),
                  "\(String(describing: def.gainStageStoredValues))")
            check("the bin's output is neutral, its on/off kept", !L.hasLegacyOutput && L.isEnabled)
            func lastInBlock(_ o: SoundObject) -> ObjectPlugin? { o.plugins.last { $0.isFXBlock }?.fxBlock?.plugins.last }
            for (n, o) in [("A", doc.items[0]), ("B", doc.items[1])] {
                let i = lastInBlock(o)
                check("attached member \(n): a linked instance at the block's end",
                      i?.linkGroupID == def.id && i?.gainStageFace == .gainPanMute
                      && i?.gainStageStoredValues == def.gainStageStoredValues && i?.id != def.id)
            }
            let rackBlock = doc.items[4].plugins[0].rack?.voices[0][0].fxBlock
            check("a member inside a rack's branch gets its instance too",
                  rackBlock?.plugins.count == 2 && rackBlock?.plugins.last?.linkGroupID == def.id)
            let cb = doc.items[2].plugins[0].fxBlock!
            check("a detached block with a local output → an independent stage",
                  cb.plugins.count == 2 && cb.plugins[1].gainStageFace == .gainPanMute
                  && cb.plugins[1].linkGroupID == nil && cb.plugins[1].detachedLinkGroupID == nil
                  && cb.plugins[1].gainStageStoredValues == GainStageValues(gainDb: -6, pan: 0, muted: true))
            check("…and its local is gone (it was on)", cb.local == nil)
            let db = doc.items[3].plugins[0].fxBlock!
            check("a detached block with no local gets nothing (it played neutral)", db.plugins.count == 1)
            check("report: 2 FX outputs", r == .init(trims: 0, fxOutputs: 2, automationLanes: 0, clamped: 0), "\(r)")
            let after = allIDs(doc.items, [])
            check("every new id is fresh", Set(after).count == after.count
                  && Set(after).isSuperset(of: before) && !before.contains(def.id))
            check("no duplicate plugin id (uniqueness audit)",
                  PluginIDUniqueness.duplicates(items: doc.items, stems: []).isEmpty)

            // Idempotence
            let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
            let once = try! enc.encode(doc)
            let r2 = LegacyGainMigration.migrate(&doc)
            let twice = try! enc.encode(doc)
            check("idempotent: a second run reports nothing", r2.isEmpty, "\(r2)")
            check("idempotent: and leaves the document identical", once == twice)
        }

        // MARK: clamping, a detached block that was OFF
        do {
            let link = legacyLink(FXLink(id: binID, name: "Kick", plugins: [defComp]), gainDb: -40, muted: true,
                                  enabled: false)
            let off = clip(lane: 1, plugins: [block(detached: true,
                                                     local: legacyLocal(enabled: false, gainDb: 30))])
            var doc = ProjectDocument(items: [legacy(clip(plugins: [block()]), trimIn: -30), off], stems: [])
            doc.fxLinks = [link]
            let r = LegacyGainMigration.migrate(&doc)
            let def = doc.fxLinks![0].plugins.last!
            check("an output of −40 dB (muted) is clamped to −24, mute kept",
                  def.gainStageStoredValues == GainStageValues(gainDb: -24, pan: 0, muted: true))
            check("a trim of −30 dB is clamped to −24", gainOf(doc.items[0].plugins[0]) == -24)
            check("a bin that was off stays off", doc.fxLinks![0].isEnabled == false)
            let fb = doc.items[1].plugins[0].fxBlock!
            check("a detached block that was off keeps its off, its gain becomes a stage (+30 → +24)",
                  fb.local == FXLinkOutput(isEnabled: false) && gainOf(fb.plugins.last!) == 24)
            check("report: 3 clamped", r.clamped == 3 && r.trims == 1 && r.fxOutputs == 2, "\(r)")
        }

        // MARK: a clamped automation point
        do {
            let o = legacy(clip(automation: [legacyLane("chainOutGain", [(0, -30), (1, 0)])]))
            var doc = ProjectDocument(items: [o], stems: [])
            let r = LegacyGainMigration.migrate(&doc)
            let lane = doc.items[0].automation.first
            check("a point at −30 dB is brought to the bottom of the range",
                  lane?.points.first?.v == 0 && r.clamped == 1 && r.automationLanes == 1, "\(r)")
        }

        // MARK: a sidecar subtree (no registry): frozen outputs of attached blocks
        do {
            let frozen = legacyLocal(gainDb: -4.5, pan: 0.25)
            let m1 = clip(lane: 0, plugins: [block(local: frozen)])
            let m2 = clip(lane: 1, plugins: [block(local: frozen)])
            var sub = legacy(SoundObject(startTime: 0, duration: 4, lane: 0,
                                         kind: .group(children: [], isExpanded: false)),
                             trimOut: -2, children: [m1, m2])
            let r = LegacyGainMigration.migrate(&sub)
            guard case .group(let ch, _) = sub.kind else { check("sidecar group kept", false); return }
            let i1 = ch[0].plugins[0].fxBlock!.plugins.last!, i2 = ch[1].plugins[0].fxBlock!.plugins.last!
            check("sidecar: each attached member gets a stage instance",
                  i1.gainStageFace == .gainPanMute && i2.gainStageFace == .gainPanMute
                  && i1.gainStageStoredValues == GainStageValues(gainDb: -4.5, pan: 0.25, muted: false))
            check("sidecar: both name ONE definition id", i1.linkGroupID != nil && i1.linkGroupID == i2.linkGroupID
                  && i1.id != i2.id)
            check("sidecar: the frozen local keeps only its on/off",
                  ch[0].plugins[0].fxBlock!.local == FXLinkOutput(isEnabled: true))
            check("sidecar: the group's own trim too", gainOf(sub.plugins.last!) == -2)
            check("sidecar report: 1 trim, 1 FX output", r == .init(trims: 1, fxOutputs: 1, automationLanes: 0, clamped: 0), "\(r)")
            check("sidecar: idempotent", LegacyGainMigration.migrate(&sub).isEmpty)
        }

        // MARK: the legacy keys are decode-only (M.4): read, never written back
        do {
            var ld = jsonObject(FXLink(id: binID, name: "Kick", plugins: [defComp]))
            ld["gainDb"] = -3; ld["pan"] = 0.5; ld["muted"] = true
            let link = decoded(FXLink.self, ld)
            let local = decoded(FXLinkOutput.self, ["isEnabled": false, "gainDb": -6])
            var od = jsonObject(clip()); od["chainInGainDb"] = -6; od["chainOutGainDb"] = 2
            let obj = decoded(SoundObject.self, od)
            var sd = jsonObject(Stem(id: UUID(), name: "S", colorIndex: 0, format: .stereo)); sd["chainInGainDb"] = -1
            let stem = decoded(Stem.self, sd)
            check("decoded: the legacy values are read",
                  link.legacyGainDb == -3 && link.legacyPan == 0.5 && link.legacyMuted && local.legacyGainDb == -6
                  && obj.legacyChainInGainDb == -6 && obj.legacyChainOutGainDb == 2 && stem.legacyChainInGainDb == -1)
            func text<T: Encodable>(_ v: T) -> String { String(data: try! JSONEncoder().encode(v), encoding: .utf8)! }
            check("encoded without migration: a bin writes no gainDb / pan / muted",
                  !text(link).contains("gainDb") && !text(link).contains("\"pan\"") && !text(link).contains("muted"), text(link))
            check("encoded: a detached block's local writes its on/off only",
                  text(local) == "{\"isEnabled\":false}", text(local))
            check("encoded: an object and a stem write no trim key",
                  !text(obj).contains("chainInGainDb") && !text(obj).contains("chainOutGainDb")
                  && !text(stem).contains("chainInGainDb"))
        }

        // MARK: what a file written now carries
        do {
            let link = legacyLink(FXLink(id: binID, name: "Kick", plugins: [defComp]), gainDb: -3)
            let stem = legacyStem(Stem(id: UUID(), name: "Main", colorIndex: 0, format: .stereo), trimIn: -1, trimOut: 1)
            var doc = ProjectDocument(items: [legacy(clip(plugins: [block()],
                                                          automation: [legacyLane("chainInGain", [(0, -6)])]),
                                                     trimIn: -6, trimOut: 2)],
                                      stems: [stem])
            doc.fxLinks = [link]
            LegacyGainMigration.migrate(&doc)
            doc.schemaNote = nil   // the notice NAMES the old keys, to explain them
            let text = String(data: try! JSONEncoder().encode(doc), encoding: .utf8)!
            for key in ["chainInGainDb", "chainOutGainDb", "\"chainInGain\"", "\"chainOutGain\"",
                        "\"gainDb\":-3", "\"local\""] {
                var at = ""
                if let r = text.range(of: key) {
                    let lo = text.index(r.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
                    at = String(text[lo..<r.upperBound])
                }
                check("the encoded result carries no \(key)", !text.contains(key), at)
            }
            check("the format written is 25", doc.version == 25 && text.contains("\"version\":25"))
            check("the transient report is not encoded", !text.contains("legacyGainMigration"))
        }

        print("\n\(total - fails.count)/\(total) passed")
        if !fails.isEmpty { print("FAILED: \(fails)"); exit(1) }
    }
}
