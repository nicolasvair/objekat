// Session format 26 (a consolidated object's definition holds NO mix, an instance no longer has an
// `independentAttrs` mask) — the migration of a format-25 file, asserted with no screen.
//
// What a format-25 file looked like: a definition { volume, pan, isMuted } shared by the synced
// instances, and on an instance `independentAttrs` (a bit mask: 1 volume, 2 pan, 4 mute) naming the
// attributes that had left the shared value. The old synchronisation kept each instance's OWN
// volume/pan/mute equal to the shared one — or, for a detached attribute, deliberately apart. So the
// migration rewrites NOTHING: the three old keys are read and dropped, and every instance plays the
// value it already carries.
//
//   A  synced instance          : volume -6 (= the definition's)       -> -6 after
//   B  detached instance        : volume -12, independentAttrs = 1     -> -12 after
//
// Same compile line as `test_cross_project_import.swift` (the full model chain behind `SoundObject`):
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/SoundObject.swift \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticWidthFlow.swift \
//         ../objekat/SoundObject/ChannelPick.swift \
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
//         ../objekat/Shared/ObjekatPalette.swift \
//         ../objekat/Shared/ObjectColorChoice.swift \
//         ../objekat/Shared/Localization.swift \
//         ../objekat/SoundObject/GainStage.swift \
//         ../objekat/SoundObject/LegacyGainMigration.swift \
//         ../objekat/EditViewModel/EditViewModel+Types.swift \
//         ../objekat/EditViewModel/SessionSchema.swift \
//         ../objekat/App/LaunchArguments.swift \
//         ../objekat/SoundObject/CrossProjectImport.swift \
//         ../objekat/SoundObject/PluginIDUniqueness.swift \
//         ../objekat/SoundObject/PluginIDReport.swift \
//         ../objekat/Shared/BridgeScope.swift \
//         ../objekat/Shared/ScriptCanvasMemory.swift \
//         test_consolidate_format26.swift \
//         -o /tmp/cf26 && /tmp/cf26
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
enum ConsolidateFormat26Test {
    static func main() {

        let defID = UUID()
        let idA = UUID(), idB = UUID()

        func instance(_ id: UUID, volume: Float, pan: Float = 0, muted: Bool = false,
                      startTime: Double) -> SoundObject {
            SoundObject(id: id, startTime: startTime, duration: 4, lane: 0,
                        volume: volume, pan: pan, isMuted: muted, consolidateID: defID,
                        kind: .clip(filePath: "samples/consolidate/kick.wav", sourceOffset: 0,
                                    fileDuration: 4, speedRatio: 1, isReversed: false))
        }

        // MARK: - Build a format-25 file the way the old build wrote it

        let enc = JSONEncoder()
        let a = instance(idA, volume: -6, pan: 0.3, muted: true, startTime: 0)
        let b = instance(idB, volume: -12, pan: -0.2, startTime: 8)
        let def = ConsolidateDefinition(id: defID, name: "Kick", wave: "kick.wav", revision: 2, wasGroup: true)
        let doc = ProjectDocument(items: [a, b], stems: nil, consolidateDefinitions: [def])
        var dict = try! JSONSerialization.jsonObject(with: try! enc.encode(doc)) as! [String: Any]

        // The old definition: the shared mix, written next to everything else.
        var defs = dict["objectDefinitions"] as! [[String: Any]]
        defs[0]["volume"] = -6.0
        defs[0]["pan"] = 0.3
        defs[0]["isMuted"] = true
        dict["objectDefinitions"] = defs
        // The old instances: B had detached its volume (bit 0) and pan (bit 1).
        var items = dict["items"] as! [[String: Any]]
        for i in items.indices where (items[i]["id"] as? String) == idB.uuidString {
            items[i]["independentAttrs"] = 3
        }
        dict["items"] = items
        dict["version"] = 25
        let oldFile = try! JSONSerialization.data(withJSONObject: dict)

        // MARK: - Decoding it

        let back = try! JSONDecoder().decode(ProjectDocument.self, from: oldFile)
        let ia = back.items.first { $0.id == idA }!
        let ib = back.items.first { $0.id == idB }!
        check("the synced instance A keeps its own volume (-6)", ia.volume == -6, "\(ia.volume)")
        check("the synced instance A keeps its own pan and mute", ia.pan == 0.3 && ia.isMuted)
        check("the detached instance B keeps its own volume (-12), not the definition's", ib.volume == -12, "\(ib.volume)")
        check("B keeps its own pan too, and stays unmuted", ib.pan == -0.2 && !ib.isMuted)
        check("both are still instances of the same definition",
              ia.consolidateID == defID && ib.consolidateID == defID)
        let d = back.consolidateDefinitions?.first
        check("the definition still decodes (name / wave / revision / wasGroup)",
              d?.id == defID && d?.name == "Kick" && d?.wave == "kick.wav" && d?.revision == 2 && d?.wasGroup == true)
        check("an old definition has rootIsContent == false (absent key)", d?.rootIsContent == false)

        // MARK: - Re-encoding it

        let reDoc = ProjectDocument(items: back.items, stems: back.stems,
                                    consolidateDefinitions: back.consolidateDefinitions)
        let reData = try! enc.encode(reDoc)
        let re = try! JSONSerialization.jsonObject(with: reData) as! [String: Any]
        let reDefs = re["objectDefinitions"] as! [[String: Any]]
        check("the definition no longer writes volume / pan / isMuted",
              reDefs[0]["volume"] == nil && reDefs[0]["pan"] == nil && reDefs[0]["isMuted"] == nil,
              "\(reDefs[0].keys.sorted())")
        check("the definition writes rootIsContent", reDefs[0]["rootIsContent"] != nil)
        let reItems = re["items"] as! [[String: Any]]
        check("no instance writes independentAttrs any more",
              reItems.allSatisfy { $0["independentAttrs"] == nil })
        check("the instances' own volumes survive the round trip",
              reItems.contains { ($0["id"] as? String) == idA.uuidString && ($0["volume"] as? Double) == -6 }
              && reItems.contains { ($0["id"] as? String) == idB.uuidString && ($0["volume"] as? Double) == -12 })
        check("the file is written as format 26", (re["version"] as? Int) == 26 && SessionSchema.formatVersion == 26,
              "\(String(describing: re["version"]))")
        // (The notice at the top of the file legitimately NAMES the old key — look at the items only.)
        let itemsText = String(data: try! JSONSerialization.data(withJSONObject: reItems), encoding: .utf8) ?? ""
        check("the raw items no longer contain the key \"independentAttrs\"", !itemsText.contains("independentAttrs"))

        // MARK: - rootIsContent

        var fresh = def
        fresh.rootIsContent = true
        let freshJSON = try! JSONSerialization.jsonObject(with: enc.encode(fresh)) as! [String: Any]
        check("a new bake's definition writes rootIsContent: true", (freshJSON["rootIsContent"] as? Bool) == true)
        let freshBack = try! JSONDecoder().decode(ConsolidateDefinition.self, from: enc.encode(fresh))
        check("rootIsContent: true survives a round trip", freshBack.rootIsContent)
        check("a definition writes exactly its seven keys, no mix key",
              Set(freshJSON.keys) == ["id", "name", "wave", "revision", "wasGroup", "rootIsContent", "dependsOn"],
              "\(freshJSON.keys.sorted())")

        // A minimal, hand-written definition (the tolerant decoding): only the three mandatory keys.
        let minimal = "{\"id\":\"\(defID.uuidString)\",\"name\":\"n\",\"wave\":\"w.wav\"}".data(using: .utf8)!
        let m = try? JSONDecoder().decode(ConsolidateDefinition.self, from: minimal)
        check("a minimal definition decodes with neutral fields",
              m != nil && m?.revision == 0 && m?.wasGroup == false && m?.rootIsContent == false && m?.dependsOn.isEmpty == true)

        // MARK: - The notice

        let note = SessionSchema.note.joined(separator: "\n")
        check("the notice describes rootIsContent", note.contains("rootIsContent"))
        check("the notice says an instance keeps its own mix", note.contains("Each instance keeps ITS OWN mix"))

        print("\n\(total - fails.count)/\(total) passed")
        exit(fails.isEmpty ? 0 : 1)
    }
}
