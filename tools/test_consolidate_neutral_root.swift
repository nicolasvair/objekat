// The NEUTRAL content root of a consolidated object (@see SoundObject.isNeutralContentRoot) and the
// stage with that root left out (@see SoundObject.withNeutralContentRootFlattened), asserted with no
// screen. A content root is neutral when it is a mere frame around its children: nothing of its own
// (FX, fader, fades, sends, automation, loop, markers, recording input), a window that is exactly the
// span of its children. Evaluated live, so the slightest edit of the root makes it visible again.
//
// Compile line (from this folder):
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/InputChains.swift \
//         ../objekat/Shared/ClipEditZone.swift \
//         ../objekat/Shared/LoopRetrim.swift \
//         ../objekat/SoundObject/MidiSequenceWindow.swift \
//         ../objekat/SoundObject/SoundObject.swift \
//         ../objekat/Video/VideoFacet.swift \
//         ../objekat/SoundObject/RecordInputs.swift \
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
//         ../objekat/Shared/Compat/CompatPolicy.swift \
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
//         test_consolidate_neutral_root.swift \
//         -o /tmp/cnr && /tmp/cnr
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
enum ConsolidateNeutralRootTest {
    static func main() {
        func plugin(_ name: String) -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: name, manufacturer: "Objekat", identifier: name,
                         formatName: "TracktionInternal")
        }
        func wav(_ start: Double, _ dur: Double, lane: Int = 0) -> SoundObject {
            SoundObject(startTime: start, duration: dur, lane: lane,
                        kind: .clip(filePath: "samples/k.wav", sourceOffset: 0, fileDuration: dur,
                                    speedRatio: 1, isReversed: false))
        }
        let kids = [wav(2, 4), wav(5, 6, lane: 1)]            // children span [2, 11]
        func root(_ edit: (inout SoundObject) -> Void = { _ in }) -> SoundObject {
            var g = SoundObject(startTime: 2, duration: 9, lane: 0,
                                kind: .group(children: kids, isExpanded: true))
            edit(&g)
            return g
        }
        let pts = [AutomationPoint(t: 0, v: 0), AutomationPoint(t: 1, v: 1)]

        // MARK: - the predicate

        check("neutral: a bare group whose window is its children's span", root().isNeutralContentRoot)
        check("neutral: a name, a colour and a stem are not an effect",
              root { $0.label = "A"; $0.colorIndex = 4; $0.stemID = UUID() }.isNeutralContentRoot)
        check("neutral: a nested group below it does not matter", {
            var inner = SoundObject(startTime: 2, duration: 4, lane: 0,
                                    kind: .group(children: [wav(2, 4)], isExpanded: false))
            inner.volume = -3
            return root { $0.kind = .group(children: [inner, wav(5, 6, lane: 1)], isExpanded: true) }.isNeutralContentRoot
        }())

        check("not neutral: a clip", !wav(0, 1).isNeutralContentRoot)
        check("not neutral: an infinite group", !root { $0.isInfinite = true }.isNeutralContentRoot)
        check("not neutral: a plugin (an FX)", !root { $0.plugins = [plugin("eq")] }.isNeutralContentRoot)
        check("not neutral: a gain stage is a plugin too",
              !root { $0.plugins = [plugin("ObjGain")] }.isNeutralContentRoot)
        check("not neutral: an instrument", !root { $0.instruments = [plugin("synth")] }.isNeutralContentRoot)
        check("not neutral: an ARA source", !root {
            $0.araSource = ARASource(plugin: plugin("melodyne"), archive: nil)
        }.isNeutralContentRoot)
        check("not neutral: volume", !root { $0.volume = -6 }.isNeutralContentRoot)
        check("not neutral: pan", !root { $0.pan = 0.3 }.isNeutralContentRoot)
        check("not neutral: muted", !root { $0.isMuted = true }.isNeutralContentRoot)
        check("not neutral: fade in", !root { $0.fadeIn = 0.5 }.isNeutralContentRoot)
        check("not neutral: fade out", !root { $0.fadeOut = 0.25 }.isNeutralContentRoot)
        check("not neutral: a send", !root { $0.sends = [AuxSend(auxID: UUID(), levelDb: -3)] }.isNeutralContentRoot)
        check("not neutral: an automation curve",
              !root { $0.automation = [AutomationLane(param: .volume, points: pts)] }.isNeutralContentRoot)
        check("not neutral: a loop", !root { $0.loopEnabled = true; $0.loopRangeStart = 1; $0.loopRangeEnd = 3 }.isNeutralContentRoot)
        check("not neutral: a MARKER of its own", !root { $0.markers = [Marker(time: 1, name: "m")] }.isNeutralContentRoot)
        check("not neutral: a recording input", !root { $0.recordInput = InputRef(first: 0, count: 2) }.isNeutralContentRoot)
        check("not neutral: a MIDI recording input",
              !root { $0.recordMidiInput = MidiInputRef(id: "x", name: "x") }.isNeutralContentRoot)
        check("not neutral: a channel mode", !root { $0.channelMode = .l }.isNeutralContentRoot)
        check("not neutral: a window narrower than the children (they hang out)",
              !root { $0.duration = 5 }.isNeutralContentRoot)
        check("not neutral: a window wider than the children",
              !root { $0.duration = 12 }.isNeutralContentRoot)
        check("not neutral: a window starting later than the children",
              !root { $0.startTime = 3; $0.duration = 8 }.isNeutralContentRoot)
        check("not neutral: no child at all", !root { $0.kind = .group(children: [], isExpanded: true) }.isNeutralContentRoot)
        check("live: back to neutral once the fader is back to 0", {
            var g = root { $0.volume = -6 }
            let was = g.isNeutralContentRoot
            g.volume = 0
            return !was && g.isNeutralContentRoot
        }())

        // MARK: - the stage with the root left out

        func stage(_ a: SoundObject) -> SoundObject {
            var s = SoundObject(startTime: 1, duration: 20, lane: 3, volume: -2,
                                kind: .group(children: [a], isExpanded: true))
            s.plugins = [plugin("stageFX")]
            s.label = "stage"
            return s
        }
        let flat = stage(root()).withNeutralContentRootFlattened()
        if case .group(let ch, let expanded) = flat.kind {
            check("flatten: the root's children are the stage's, in order", ch == kids, "\(ch.count)")
            check("flatten: the stage stays expanded as it was", expanded)
        } else { check("flatten: still a group", false) }
        check("flatten: everything of the stage is kept",
              flat.id == stage(root()).id || (flat.lane == 3 && flat.volume == -2 && flat.label == "stage"
              && flat.plugins.count == 1 && flat.startTime == 1 && flat.duration == 20))
        let s2 = stage(root { $0.volume = -6 })
        check("flatten: a root that is not neutral is left alone", s2.withNeutralContentRootFlattened() == s2)
        let s3 = stage(wav(0, 4))
        check("flatten: a clip content is left alone", s3.withNeutralContentRootFlattened() == s3)
        var s4 = stage(root())
        s4.kind = .group(children: [root(), wav(0, 1)], isExpanded: true)
        check("flatten: two children (not a stage) are left alone", s4.withNeutralContentRootFlattened() == s4)
        let nested = stage(root { $0.kind = .group(children: [root(), wav(2, 9, lane: 1)], isExpanded: true) })
        let nflat = nested.withNeutralContentRootFlattened()
        check("flatten: ONE level only (a neutral group below stays a group)", {
            if case .group(let ch, _) = nflat.kind { return ch.count == 2 && ch[0].isGroup }
            return false
        }())

        print("\n\(total - fails.count)/\(total) passed")
        exit(fails.isEmpty ? 0 : 1)
    }
}
