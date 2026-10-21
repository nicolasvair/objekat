// The CONTENT ROOT of a consolidated object (@see SoundObject.contentRoot(fromSidecar:def:)) — what a
// sidecar's root is once everything that belongs to an instance is taken off it, asserted with no
// screen. Two kinds of sidecar:
//
//   OLD  (def.rootIsContent == false, every sidecar written before format 26): the root still wears
//        the mix of the instance it was baked from — fader, narrower window, fades, sends, the
//        instance's volume / pan / send curves. The old render bypassed all of it, so the wave is the
//        content with a NEUTRAL root over its FULL EXTENT.
//   NEW  (rootIsContent == true): the root IS content — nothing but the sends is touched.
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
//         ../objekat/SoundObject/ConsolidateContentRoot.swift \
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
//         test_consolidate_content_root.swift \
//         -o /tmp/ccr && /tmp/ccr
//
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
enum ConsolidateContentRootTest {
    static func main() {

        func plugin(_ name: String) -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: name, manufacturer: "Objekat", identifier: name,
                         formatName: "TracktionInternal")
        }
        func wav(_ start: Double, _ dur: Double) -> SoundObject {
            SoundObject(startTime: start, duration: dur, lane: 0,
                        kind: .clip(filePath: "samples/k.wav", sourceOffset: 0, fileDuration: dur,
                                    speedRatio: 1, isReversed: false))
        }

        let aux = UUID()
        let rootFX = plugin("eq")
        let sendFX = plugin("delay")
        let kids = [wav(2, 4), wav(5, 6)]            // children span [2, 11]
        let pts = [AutomationPoint(t: 0, v: 0), AutomationPoint(t: 1, v: 1)]

        // The root as an OLD build sidecar holds it: window [4, 9) narrower than the children's
        // [2, 11], the instance's mix, fades, one send carrying a plugin, and four curves.
        var old = SoundObject(startTime: 4, duration: 5, lane: 0, volume: -6, pan: 0.3,
                              fadeIn: 0.5, fadeOut: 0.25, isMuted: true,
                              plugins: [rootFX],
                              sends: [AuxSend(auxID: aux, levelDb: -3, plugins: [sendFX])],
                              automation: [AutomationLane(param: .volume, points: pts),
                                           AutomationLane(param: .pan, points: pts),
                                           AutomationLane(param: .send(auxID: aux), points: pts),
                                           AutomationLane(param: .plugin(pluginKey: sendFX.id, paramID: "t"), points: pts),
                                           AutomationLane(param: .plugin(pluginKey: rootFX.id, paramID: "gain"), points: pts)],
                              automationTouchOrder: [.volume],
                              loopEnabled: true, loopRangeStart: 1, loopRangeEnd: 3,
                              markers: [Marker(time: 1, name: "m")],
                              kind: .group(children: kids, isExpanded: true))
        old.stemID = UUID()
        old.label = "kick"
        old.colorIndex = 3

        let oldDef = ConsolidateDefinition(id: UUID(), name: "k", wave: "k.wav")
        var newDef = oldDef
        newDef.rootIsContent = true

        // MARK: - OLD sidecar

        let r = SoundObject.contentRoot(fromSidecar: old, def: oldDef)
        check("old: the fader is neutral",  r.volume == 0 && r.pan == 0 && !r.isMuted, "\(r.volume) \(r.pan) \(r.isMuted)")
        check("old: the fades are zero",    r.fadeIn == 0 && r.fadeOut == 0)
        check("old: the group's window is its full extent [2, 11]", r.startTime == 2 && r.duration == 9,
              "\(r.startTime) \(r.duration)")
        check("old: the window covers exactly what bakeSpan says", r.bakeSpan.start == r.startTime
              && r.bakeSpan.end == r.startTime + r.duration)
        check("old: the sends are removed", r.sends.isEmpty)
        let params = r.automation.map(\.param)
        check("old: the volume and pan curves are removed", !params.contains(.volume) && !params.contains(.pan))
        check("old: the send curve and the send plugin's curve are removed",
              !params.contains(.send(auxID: aux)) && !params.contains(.plugin(pluginKey: sendFX.id, paramID: "t")))
        check("old: the curve on the root's own FX stays (it is baked)",
              params == [.plugin(pluginKey: rootFX.id, paramID: "gain")], "\(params)")
        check("old: the 'last parameter touched' memory is cleared", r.automationTouchOrder.isEmpty)
        check("old: the start moved 2 s earlier, so the root's curves, markers and loop range follow by +2",
              r.automation[0].points.map(\.t) == [2, 3] && r.markers[0].time == 3
              && r.loopRangeStart == 3 && r.loopRangeEnd == 5,
              "\(r.automation[0].points.map(\.t)) \(r.markers[0].time) \(String(describing: r.loopRangeStart))")
        check("old: the loop stays on (the old bake kept the container's loop range)", r.loopEnabled)
        check("old: the children, the root's FX, its stem, name and colour are not touched",
              r.plugins == [rootFX] && r.stemID == old.stemID && r.label == "kick" && r.colorIndex == 3
              && { if case .group(let ch, _) = r.kind { return ch == kids }; return false }())
        let again = SoundObject.contentRoot(fromSidecar: r, def: oldDef)
        check("old: idempotent", again == r)

        // A window that already covers the children is left where it is.
        let wide = SoundObject(startTime: 0, duration: 20, lane: 0, volume: -2,
                               kind: .group(children: kids, isExpanded: true))
        let rw = SoundObject.contentRoot(fromSidecar: wide, def: oldDef)
        check("old: a window wider than the children is unchanged (and the fader neutral)",
              rw.startTime == 0 && rw.duration == 20 && rw.volume == 0)

        // An infinite group has no window to normalise.
        var inf = wide; inf.isInfinite = true; inf.startTime = 5; inf.duration = 1
        let ri = SoundObject.contentRoot(fromSidecar: inf, def: oldDef)
        check("old: an infinite group keeps its window", ri.startTime == 5 && ri.duration == 1)

        // A clip root keeps its source window; its fader and fades go neutral.
        var clip = wav(3, 4)
        clip.volume = -9; clip.pan = -0.5; clip.fadeIn = 1; clip.fadeOut = 1
        clip.sends = [AuxSend(auxID: aux)]
        let rc = SoundObject.contentRoot(fromSidecar: clip, def: oldDef)
        check("old clip: fader neutral, fades zero, sends removed",
              rc.volume == 0 && rc.pan == 0 && rc.fadeIn == 0 && rc.fadeOut == 0 && rc.sends.isEmpty)
        check("old clip: window and source range untouched", rc.startTime == 3 && rc.duration == 4 && rc.kind == clip.kind)

        // MARK: - NEW sidecar

        let n = SoundObject.contentRoot(fromSidecar: old, def: newDef)
        check("new: the fader, the fades and the window are intact",
              n.volume == -6 && n.pan == 0.3 && n.isMuted && n.fadeIn == 0.5 && n.fadeOut == 0.25
              && n.startTime == 4 && n.duration == 5)
        check("new: the loop and the markers are intact",
              n.loopEnabled && n.loopRangeStart == 1 && n.loopRangeEnd == 3 && n.markers == old.markers)
        let np = n.automation.map(\.param)
        check("new: the volume and pan curves are content, kept",
              np.contains(.volume) && np.contains(.pan) && np.contains(.plugin(pluginKey: rootFX.id, paramID: "gain")))
        check("new: the sends are removed, and the curves aimed at them with them",
              n.sends.isEmpty && !np.contains(.send(auxID: aux))
              && !np.contains(.plugin(pluginKey: sendFX.id, paramID: "t")), "\(np)")
        check("new: idempotent", SoundObject.contentRoot(fromSidecar: n, def: newDef) == n)

        // MARK: - The writer of the new rule

        let w = old.asContentRootDefinition
        let wp = w.automation.map(\.param)
        check("writer: keeps the fader, the window, the fades, the loop",
              w.volume == -6 && w.startTime == 4 && w.fadeIn == 0.5 && w.loopEnabled)
        check("writer: keeps the volume / pan curves (content), drops sends and what aims at them",
              wp.contains(.volume) && wp.contains(.pan) && w.sends.isEmpty && !wp.contains(.send(auxID: aux))
              && !wp.contains(.plugin(pluginKey: sendFX.id, paramID: "t")))
        check("writer: the legacy writer still shares the root out (volume / pan curves leave)",
              !old.asConsolidateDefinition.automation.map(\.param).contains(.volume))
        check("writer then reader (new rule) is the identity on a root with no send",
              SoundObject.contentRoot(fromSidecar: w, def: newDef) == w)

        // MARK: - bakeSpan

        check("bakeSpan: window narrower than the children -> the children's envelope",
              old.bakeSpan.start == 2 && old.bakeSpan.end == 11)
        check("bakeSpan: a clip is its own window", clip.bakeSpan.start == 3 && clip.bakeSpan.end == 7)

        print("\n\(total - fails.count)/\(total) passed")
        exit(fails.isEmpty ? 0 : 1)
    }
}
