// `ObjectFeatureBadges` — the feature badges an object carries after its name (FX, FX link, aux
// sends, sidechain send, sidechain reception; 16 October 2026; automation, 17 October 2026), asserted with no screen. The same
// model dependencies as `test_plugin_id_uniqueness.swift`, minus the uniqueness units, plus the two
// files under test; run from `tools/`:
//
//     cd tools && swiftc -parse-as-library \
//         ../objekat/SoundObject/SoundObject.swift \
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
//         ../objekat/Shared/FeatureIcons.swift \
//         ../objekat/Shared/ObjectFeatureBadges.swift \
//         test_object_feature_badges.swift \
//         -o /tmp/ofb && /tmp/ofb
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
enum ObjectFeatureBadgesTest {
    static func main() {

        // MARK: - Fixture builders

        func plugin(id: UUID = UUID(), linkGroupID: UUID? = nil, detached: UUID? = nil,
                    enabled: Bool = true, key: UUID? = nil, name: String = "EQ") -> ObjectPlugin {
            ObjectPlugin(id: id, name: name, manufacturer: "FabFilter", identifier: "eq",
                         formatName: "AudioUnit", isEnabled: enabled,
                         linkGroupID: linkGroupID, detachedLinkGroupID: detached, colorIndex: 1,
                         sidechain: key.map { SidechainSource(sourceID: $0) })
        }
        func builtIn(_ identifier: String = "4bandEq") -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: identifier, manufacturer: "Tracktion", identifier: identifier,
                         formatName: "TracktionInternal", colorIndex: 2)
        }
        func gain(_ face: GainStageFace = .gain) -> ObjectPlugin { .makeGainStage(face: face) }
        func block(linkID: UUID = UUID(), instances: [ObjectPlugin], detached: Bool = false) -> ObjectPlugin {
            var b = FXLink.blockEntry(linkID: linkID, name: "Bin", instances: instances, id: UUID())
            b.fxBlock?.isDetached = detached
            return b
        }
        func rack(_ voices: [[ObjectPlugin]]) -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: "Parallel", manufacturer: "", identifier: "", formatName: "",
                         rack: PluginRack(voices: voices), colorIndex: 0)
        }
        func clip(id: UUID = UUID(), plugins: [ObjectPlugin] = [], instruments: [ObjectPlugin] = [],
                  sends: [AuxSend] = [], volume: Float = 0, pan: Float = 0) -> SoundObject {
            var o = SoundObject(id: id, startTime: 0, duration: 4, lane: 0,
                                plugins: plugins, instruments: instruments,
                                kind: .clip(filePath: "a.wav", sourceOffset: 0, fileDuration: 4,
                                            speedRatio: 1, isReversed: false))
            o.sends = sends
            o.volume = volume
            o.pan = pan
            return o
        }
        func group(id: UUID = UUID(), plugins: [ObjectPlugin] = [], children: [SoundObject]) -> SoundObject {
            SoundObject(id: id, startTime: 0, duration: 4, lane: 0, plugins: plugins,
                        kind: .group(children: children, isExpanded: true))
        }
        func stem(plugins: [ObjectPlugin]) -> Stem {
            Stem(id: UUID(), name: "Bus", colorIndex: 0, format: .stereo, plugins: plugins)
        }
        func badges(_ o: SoundObject, _ sources: Set<UUID> = []) -> [FeatureBadge] {
            ObjectFeatureBadges.badges(for: o, sidechainSources: sources)
        }

        // MARK: 1. Nothing

        check("a bare clip carries no badge", badges(clip()).isEmpty)
        check("volume and pan are never a badge", badges(clip(volume: -12, pan: 0.5)).isEmpty)

        // MARK: 2. FX

        check("one third-party plugin → FX", badges(clip(plugins: [plugin()])) == [.fx])
        check("a BYPASSED plugin still counts", badges(clip(plugins: [plugin(enabled: false)])) == [.fx])
        check("a built-in effect counts", badges(clip(plugins: [builtIn()])) == [.fx])
        check("a gain stage alone is not FX", badges(clip(plugins: [gain()])).isEmpty)
        check("a gain · pan stage alone is not FX", badges(clip(plugins: [gain(.gainPanMute)])).isEmpty)
        check("gain stages around a plugin → FX once",
              badges(clip(plugins: [gain(), plugin(), gain()])) == [.fx])
        check("a send's marker alone is not FX",
              badges(clip(plugins: [.makeSendMarker(for: UUID())])).isEmpty)
        check("a plugin down a rack branch → FX", badges(clip(plugins: [rack([[gain()], [plugin()]])])) == [.fx])
        check("a rack of gain stages only is not FX", badges(clip(plugins: [rack([[gain()], [gain()]])])).isEmpty)
        check("an instrument alone is not FX", badges(clip(instruments: [plugin(name: "Synth")])).isEmpty)
        check("a plugin able to REJOIN a legacy link (detached) counts as FX",
              badges(clip(plugins: [plugin(detached: UUID())])) == [.fx])

        // MARK: 3. FX link

        let bin = UUID()
        check("an attached bin's block → FX link, not FX",
              badges(clip(plugins: [block(linkID: bin, instances: [plugin(linkGroupID: UUID())])])) == [.fxLink])
        check("a DETACHED block still → FX link",
              badges(clip(plugins: [block(linkID: bin, instances: [plugin()], detached: true)])) == [.fxLink])
        check("an empty bin's block → FX link", badges(clip(plugins: [block(instances: [])])) == [.fxLink])
        check("a bin holding only a gain stage → FX link",
              badges(clip(plugins: [block(instances: [gain()])])) == [.fxLink])
        check("a bin + a plain plugin of the object's own → FX and FX link",
              badges(clip(plugins: [plugin(), block(instances: [plugin()])])) == [.fx, .fxLink])
        check("a bin down a rack branch → FX link",
              badges(clip(plugins: [rack([[block(instances: [plugin()])], []])])) == [.fxLink])
        check("a legacy ⌘-linked plugin → FX link, not FX",
              badges(clip(plugins: [plugin(linkGroupID: UUID())])) == [.fxLink])
        check("a legacy link + a plain plugin → FX and FX link",
              badges(clip(plugins: [plugin(linkGroupID: UUID()), plugin()])) == [.fx, .fxLink])
        check("a LINKED instrument is not the FX link badge",
              badges(clip(instruments: [plugin(linkGroupID: UUID())])).isEmpty)

        // MARK: 4. Aux sends

        let aux = UUID()
        check("one send → aux send", badges(clip(sends: [AuxSend(auxID: aux)])) == [.auxSend])
        check("an OFF send still shows", badges(clip(sends: [AuxSend(auxID: aux, enabled: false)])) == [.auxSend])
        check("a SILENT send still shows",
              badges(clip(sends: [AuxSend(auxID: aux, levelDb: -200)])) == [.auxSend])
        check("a send's plugin is not FX",
              badges(clip(sends: [AuxSend(auxID: aux, plugins: [plugin()])])) == [.auxSend])

        // MARK: 5. Sidechain

        let kick = clip()
        let bass = clip(plugins: [plugin(key: kick.id)])
        check("a keyed plugin → FX + reception", badges(bass) == [.fx, .sidechainReception])
        check("a keyed INSTRUMENT → reception only",
              badges(clip(instruments: [plugin(key: kick.id)])) == [.sidechainReception])
        check("a keyed plugin on a SEND → aux send + reception",
              badges(clip(sends: [AuxSend(auxID: aux, plugins: [plugin(key: kick.id)])]))
                == [.auxSend, .sidechainReception])
        check("a keyed instance inside a bin → FX link + reception",
              badges(clip(plugins: [block(instances: [plugin(key: kick.id)])])) == [.fxLink, .sidechainReception])
        check("a keyed plugin down a rack → reception",
              badges(clip(plugins: [rack([[plugin(key: kick.id)]])])) == [.fx, .sidechainReception])
        check("the source is told by the set", badges(kick, [kick.id]) == [.sidechainSend])
        check("a source NOT in the set shows nothing", badges(kick, [UUID()]).isEmpty)

        // MARK: 5b. Automation

        func automated(_ o: SoundObject, _ lanes: [AutomationLane]) -> SoundObject {
            var o = o; o.automation = lanes; return o
        }
        let volumeCurve = AutomationLane(param: .volume, points: [AutomationPoint(t: 0, v: -6)])
        check("a curve with a point → automation", badges(automated(clip(), [volumeCurve])) == [.automation])
        check("a curve with NO point is not an automation",
              badges(automated(clip(), [AutomationLane(param: .volume)])).isEmpty)
        check("a plugin parameter's curve counts too",
              badges(automated(clip(plugins: [plugin()]),
                               [AutomationLane(param: .pan, points: []),
                                AutomationLane(param: .pan, points: [AutomationPoint(t: 1, v: 0.2)])]))
                == [.fx, .automation])
        check("a group does not inherit a child's curve",
              badges(group(children: [automated(clip(), [volumeCurve])])).isEmpty)
        check("a group's own curve → automation",
              badges(automated(group(children: [clip()]), [volumeCurve])) == [.automation])

        // MARK: 6. The order, all six at once

        let everything = automated(clip(id: kick.id,
                                        plugins: [plugin(key: UUID()), block(instances: [plugin()])],
                                        sends: [AuxSend(auxID: aux)]),
                                   [volumeCurve])
        check("all six, in order: FX, FX link, aux send, sidechain send, reception, automation",
              badges(everything, [kick.id])
                == [.fx, .fxLink, .auxSend, .sidechainSend, .sidechainReception, .automation])
        check("FeatureBadge.allCases is the drawing order",
              FeatureBadge.allCases == [.fx, .fxLink, .auxSend, .sidechainSend, .sidechainReception, .automation])
        check("the automation badge reads the shared automation glyph",
              FeatureBadge.automation.symbol == FeatureIcons.automated)
        check("the cache key tells two different lists apart",
              FeatureBadge.cacheKey([.fx, .auxSend]) != FeatureBadge.cacheKey([.fx, .fxLink])
                && FeatureBadge.cacheKey([]) == "")

        // MARK: 7. A group: its own chain only

        let child = clip(plugins: [plugin()], sends: [AuxSend(auxID: aux)])
        check("a group does not inherit its children's badges", badges(group(children: [child])).isEmpty)
        check("a group's own plugin → FX", badges(group(plugins: [plugin()], children: [child])) == [.fx])

        // MARK: 8. The sidechain-source set

        let src1 = UUID(), src2 = UUID(), src3 = UUID(), src4 = UUID(), src5 = UUID(), src6 = UUID()
        let deep = group(children: [group(children: [clip(plugins: [plugin(key: src1)])])])
        let items = [
            deep,
            clip(instruments: [plugin(key: src2)]),
            clip(sends: [AuxSend(auxID: aux, plugins: [plugin(key: src3)])]),
            clip(plugins: [rack([[block(instances: [plugin(key: src4)])]])]),
            clip(plugins: [plugin()]),
        ]
        let stems = [stem(plugins: [plugin(key: src5)]), stem(plugins: [plugin()])]
        let set = ObjectFeatureBadges.sidechainSources(items: items, stems: stems)
        check("a key in a nested group child is found", set.contains(src1))
        check("a key on an instrument is found", set.contains(src2))
        check("a key on a send's plugin is found", set.contains(src3))
        check("a key in a bin down a rack is found", set.contains(src4))
        check("a key on a STEM's chain is found", set.contains(src5))
        check("nothing else is in the set", set == [src1, src2, src3, src4, src5] && !set.contains(src6))
        check("an empty project has no source",
              ObjectFeatureBadges.sidechainSources(items: [], stems: []).isEmpty)

        // MARK: 9. The project-wide map (what the drawing reads)

        let keyed = clip(plugins: [plugin(key: kick.id)])
        let nestedChild = clip(sends: [AuxSend(auxID: aux)])
        let plain = clip()
        let mapItems = [kick, keyed, group(children: [group(children: [nestedChild])]), plain]
        let map = ObjectFeatureBadges.badgeMap(items: mapItems, stems: [])
        check("map: the key source is told without any set handed in", map[kick.id] == [.sidechainSend])
        check("map: the keyed object", map[keyed.id] == [.fx, .sidechainReception])
        check("map: a child two groups down is in the map", map[nestedChild.id] == [.auxSend])
        check("map: a badge-less object is LEFT OUT", map[plain.id] == nil)
        check("map: badge-less groups are left out too", map.count == 3)
        check("map: a stem's key makes its source an object's badge",
              ObjectFeatureBadges.badgeMap(items: [plain], stems: [stem(plugins: [plugin(key: plain.id)])])[plain.id]
                == [.sidechainSend])

        print("")
        if fails.isEmpty {
            print("ALL PASS — \(total) assertions")
            exit(0)
        } else {
            print("\(fails.count) FAILED of \(total)")
            exit(1)
        }
    }
}
