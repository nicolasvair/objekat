// `RecordDropInheritance` (inputs panel, step 3) — when an input dropped on a zone copies its chain: a group that is
// ENTIRELY empty (no child, no instrument, no FX, no send) takes it, any other keeps its own. Pure, asserted with no
// screen. Same compile line as test_group_instrument_rule.swift, plus the unit under test.
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/SoundObject.swift \
//         ../objekat/SoundObject/InputChains.swift \
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
//         ../objekat/SoundObject/RecordInputs.swift \
//         ../objekat/SoundObject/PluginIDUniqueness.swift \
//         ../objekat/SoundObject/PluginIDReport.swift \
//         ../objekat/Shared/BridgeScope.swift \
//         ../objekat/Shared/ScriptCanvasMemory.swift \
//         ../objekat/SoundObject/RecordDropInheritance.swift \
//         test_record_drop_inheritance.swift \
//         -o /tmp/rdi && /tmp/rdi
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
enum RecordDropInheritanceTest {
    static func main() {
        func plug() -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: "EQ", manufacturer: "Objekat", identifier: "eq", formatName: "TracktionInternal")
        }
        func group(_ children: [SoundObject] = []) -> SoundObject {
            SoundObject(startTime: 0, duration: 4, lane: 0, kind: .group(children: children, isExpanded: false))
        }
        let audio = SoundObject(startTime: 0, duration: 4, lane: 0,
                                kind: .clip(filePath: "a.wav", sourceOffset: 0, fileDuration: 4, speedRatio: 1, isReversed: false))

        let bare = group()
        check("a bare group is entirely empty", RecordDropInheritance.isEntirelyEmpty(bare))
        check("... and a drop on it copies the chain", RecordDropInheritance.copiesChain(ontoExisting: bare))

        var zone = group()
        zone.recordSource = .audio(InputRef(first: 0, count: 1))
        check("a zone that already has a source but nothing else is still empty", RecordDropInheritance.isEntirelyEmpty(zone))

        check("a child makes it non-empty", !RecordDropInheritance.isEntirelyEmpty(group([audio])))
        var withInstrument = group(); withInstrument.instruments = [plug()]
        check("an instrument makes it non-empty", !RecordDropInheritance.isEntirelyEmpty(withInstrument))
        var withFX = group(); withFX.plugins = [plug()]
        check("an FX makes it non-empty", !RecordDropInheritance.isEntirelyEmpty(withFX))
        var withSend = group(); withSend.sends = [AuxSend(auxID: UUID())]
        check("a send makes it non-empty", !RecordDropInheritance.isEntirelyEmpty(withSend))
        check("... and a drop on it keeps its chain", !RecordDropInheritance.copiesChain(ontoExisting: withSend))

        check("an audio clip is never 'empty' (it takes no chain)", !RecordDropInheritance.isEntirelyEmpty(audio))
        let midi = SoundObject(startTime: 0, duration: 4, lane: 0, kind: .midiClip(notes: [], lengthBeats: 4))
        check("nor a MIDI clip", !RecordDropInheritance.isEntirelyEmpty(midi))
        var many = group(); many.plugins = [plug(), plug()]; many.instruments = [plug()]; many.sends = [AuxSend(auxID: UUID())]
        check("everything at once: non-empty", !RecordDropInheritance.isEntirelyEmpty(many))

        print("\(total - fails.count)/\(total) assertions passed")
        if !fails.isEmpty { exit(1) }
    }
}
