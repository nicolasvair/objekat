// `GroupInstrumentRule` (docs/plan_groupes_midi.md, E2) — the rule of a group that carries an instrument, asserted with
// no screen: every refusal, the depth, the host, the silence that crosses a sub-group. Pure: the objects are handed in.
// The compile line is the one of test_cross_project_import.swift (SoundObject's dependency chain), minus
// CrossProjectImport, plus the unit under test.
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
//         ../objekat/SoundObject/RecordInputs.swift \
//         ../objekat/SoundObject/PluginIDUniqueness.swift \
//         ../objekat/SoundObject/PluginIDReport.swift \
//         ../objekat/Shared/BridgeScope.swift \
//         ../objekat/Shared/ScriptCanvasMemory.swift \
//         ../objekat/SoundObject/GroupInstrumentRule.swift \
//         test_group_instrument_rule.swift \
//         -o /tmp/gir && /tmp/gir
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
enum GroupInstrumentRuleTest {
    static func main() {

        // MARK: - Fixtures

        func inst() -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: "DLS", manufacturer: "Apple", identifier: "aumu-dls", formatName: "AudioUnit")
        }
        func audio() -> SoundObject {
            SoundObject(startTime: 0, duration: 4, lane: 0,
                        kind: .clip(filePath: "a.wav", sourceOffset: 0, fileDuration: 4, speedRatio: 1, isReversed: false))
        }
        func auxObj() -> SoundObject { SoundObject(startTime: 0, duration: 4, lane: 0, kind: .aux) }
        func midi(withInstrument: Bool = false) -> SoundObject {
            var m = SoundObject(startTime: 0, duration: 4, lane: 0, kind: .midiClip(notes: [], lengthBeats: 4))
            if withInstrument { m.instruments = [inst()] }
            return m
        }
        func group(_ children: [SoundObject] = [], instrument: Bool = false, id: UUID = UUID()) -> SoundObject {
            var g = SoundObject(id: id, startTime: 0, duration: 4, lane: 0, kind: .group(children: children, isExpanded: false))
            if instrument { g.instruments = [inst()] }
            return g
        }
        func consolidated() -> SoundObject {
            var c = audio(); c.consolidateID = UUID(); return c
        }
        func consolidatedGroup() -> SoundObject {
            var g = group(); g.consolidateID = UUID(); return g
        }
        let input = InputRef(first: 0, count: 1)

        // MARK: - Adding to a group: no instrument anywhere in the chain => anything goes

        do {
            let plain = group()
            let above = group([plain])
            check("plain chain: audio accepted", GroupInstrumentRule.refusal(adding: [audio()], toChain: [plain, above]) == nil)
            check("plain chain: aux accepted", GroupInstrumentRule.refusal(adding: [auxObj()], toChain: [plain]) == nil)
            check("plain chain: a group with an instrument accepted", GroupInstrumentRule.refusal(adding: [group(instrument: true)], toChain: [plain]) == nil)
            check("empty chain (the root): anything", GroupInstrumentRule.refusal(adding: [audio(), auxObj()], toChain: []) == nil)
        }

        // MARK: - Adding to an instrument group

        do {
            let host = group(instrument: true)
            let chain = [host]
            check("audio clip refused", GroupInstrumentRule.refusal(adding: [audio()], toChain: chain) == .audioChild)
            check("aux refused", GroupInstrumentRule.refusal(adding: [auxObj()], toChain: chain) == .auxChild)
            check("consolidated instance refused (before audio)", GroupInstrumentRule.refusal(adding: [consolidated()], toChain: chain) == .consolidatedChild)
            check("consolidated group instance refused", GroupInstrumentRule.refusal(adding: [consolidatedGroup()], toChain: chain) == .consolidatedChild)
            check("MIDI clip with its own instrument refused", GroupInstrumentRule.refusal(adding: [midi(withInstrument: true)], toChain: chain) == .childWithInstrument)
            check("sub-group with an instrument refused", GroupInstrumentRule.refusal(adding: [group(instrument: true)], toChain: chain) == .childWithInstrument)
            check("empty MIDI clip accepted", GroupInstrumentRule.refusal(adding: [midi()], toChain: chain) == nil)
            check("empty sub-group accepted", GroupInstrumentRule.refusal(adding: [group()], toChain: chain) == nil)
            check("sub-group of empty clips accepted", GroupInstrumentRule.refusal(adding: [group([midi(), midi()])], toChain: chain) == nil)
            check("MIDI-input zone accepted", {
                var z = group(); z.recordMidiInput = MidiInputRef(id: "x", name: "Keys")
                return GroupInstrumentRule.refusal(adding: [z], toChain: chain) == nil
            }())
            check("audio-input zone refused", {
                var z = group(); z.recordInput = input
                return GroupInstrumentRule.refusal(adding: [z], toChain: chain) == .audioInput
            }())
        }

        // MARK: - Depth

        do {
            let host = group(instrument: true)
            let sub = group()
            check("the target is a sub-group UNDER an instrument group: audio refused", GroupInstrumentRule.refusal(adding: [audio()], toChain: [sub, host]) == .audioChild)
            let deep = group([group([group([audio()])])])
            check("audio three levels down in an added group refused", GroupInstrumentRule.refusal(adding: [deep], toChain: [host]) == .audioChild)
            check("aux buried in an added group refused", GroupInstrumentRule.refusal(adding: [group([group([auxObj()])])], toChain: [host]) == .auxChild)
            check("instrument buried in an added group refused", GroupInstrumentRule.refusal(adding: [group([group([midi(withInstrument: true)])])], toChain: [host]) == .childWithInstrument)
            check("consolidated buried in an added group refused", GroupInstrumentRule.refusal(adding: [group([group([consolidated()])])], toChain: [host]) == .consolidatedChild)
            check("the instrument sits several levels up the chain: still refused",
                  GroupInstrumentRule.refusal(adding: [audio()], toChain: [group(), group(), host]) == .audioChild)
        }

        // MARK: - A selection accepted in part refuses the whole thing, the first fault wins

        do {
            let host = group(instrument: true)
            check("one fault among clean objects refuses the lot", GroupInstrumentRule.refusal(adding: [midi(), midi(), audio()], toChain: [host]) == .audioChild)
            check("the first fault, in order, is reported", GroupInstrumentRule.refusal(adding: [auxObj(), audio()], toChain: [host]) == .auxChild)
            check("nothing added: nothing refused", GroupInstrumentRule.refusal(adding: [], toChain: [host]) == nil)
        }

        // MARK: - Putting an instrument on a group

        do {
            check("empty group takes an instrument", GroupInstrumentRule.refusal(puttingInstrumentOn: group(), ancestors: []) == nil)
            check("group of empty clips takes an instrument", GroupInstrumentRule.refusal(puttingInstrumentOn: group([midi(), group([midi()])]), ancestors: [group()]) == nil)
            check("group with audio refuses it", GroupInstrumentRule.refusal(puttingInstrumentOn: group([audio()]), ancestors: []) == .audioChild)
            check("group with a deep aux refuses it", GroupInstrumentRule.refusal(puttingInstrumentOn: group([group([auxObj()])]), ancestors: []) == .auxChild)
            check("group with a consolidated child refuses it", GroupInstrumentRule.refusal(puttingInstrumentOn: group([consolidated()]), ancestors: []) == .consolidatedChild)
            check("group with a child that has an instrument refuses it", GroupInstrumentRule.refusal(puttingInstrumentOn: group([midi(withInstrument: true)]), ancestors: []) == .childWithInstrument)
            check("group with a sub-group that has an instrument refuses it", GroupInstrumentRule.refusal(puttingInstrumentOn: group([group(instrument: true)]), ancestors: []) == .childWithInstrument)
            check("a group under an instrument group refuses it (parent)", GroupInstrumentRule.refusal(puttingInstrumentOn: group(), ancestors: [group(instrument: true)]) == .insideInstrumentGroup)
            check("a group under an instrument group refuses it (grandparent)", GroupInstrumentRule.refusal(puttingInstrumentOn: group(), ancestors: [group(), group(instrument: true)]) == .insideInstrumentGroup)
            check("a consolidated group instance refuses it", GroupInstrumentRule.refusal(puttingInstrumentOn: consolidatedGroup(), ancestors: []) == .consolidatedChild)
            check("an audio-input zone refuses it", {
                var z = group(); z.recordInput = input
                return GroupInstrumentRule.refusal(puttingInstrumentOn: z, ancestors: []) == .audioInput
            }())
            check("a MIDI-input zone takes it", {
                var z = group(); z.recordMidiInput = MidiInputRef(id: "x", name: "Keys")
                return GroupInstrumentRule.refusal(puttingInstrumentOn: z, ancestors: []) == nil
            }())
            check("a MIDI clip is not this rule's business", GroupInstrumentRule.refusal(puttingInstrumentOn: midi(), ancestors: [group(instrument: true)]) == nil)
            check("the audio of a sibling (not below) does not matter", GroupInstrumentRule.refusal(puttingInstrumentOn: group([midi()]), ancestors: [group([audio()])]) == nil)
        }

        // MARK: - Assigning an audio source

        do {
            check("audio source on a plain group", GroupInstrumentRule.refusal(settingAudioInputOn: group(), ancestors: []) == nil)
            check("audio source on an instrument group refused", GroupInstrumentRule.refusal(settingAudioInputOn: group(instrument: true), ancestors: []) == .audioInput)
            check("audio source under an instrument group refused", GroupInstrumentRule.refusal(settingAudioInputOn: group(), ancestors: [group(instrument: true)]) == .audioInput)
            check("audio source on a group holding an instrument sub-group is fine", GroupInstrumentRule.refusal(settingAudioInputOn: group([group(instrument: true)]), ancestors: []) == nil)
        }

        // MARK: - Host

        do {
            let hostID = UUID()
            let host = group(instrument: true, id: hostID)
            let empty = midi()
            check("host: the parent", GroupInstrumentRule.host(of: empty, ancestors: [host]) == hostID)
            check("host: the first one up the chain", GroupInstrumentRule.host(of: empty, ancestors: [group(), host, group()]) == hostID)
            let nearer = group(instrument: true)
            check("host: the NEAREST instrument group wins", GroupInstrumentRule.host(of: empty, ancestors: [nearer, host]) == nearer.id)
            check("no instrument group above: no host", GroupInstrumentRule.host(of: empty, ancestors: [group(), group()]) == nil)
            check("no ancestor at all: no host", GroupInstrumentRule.host(of: empty, ancestors: []) == nil)
            check("a clip with its own instrument has no host", GroupInstrumentRule.host(of: midi(withInstrument: true), ancestors: [host]) == nil)
            check("an audio clip has no host", GroupInstrumentRule.host(of: audio(), ancestors: [host]) == nil)
            check("a group has no host", GroupInstrumentRule.host(of: group(), ancestors: [host]) == nil)
        }

        // MARK: - Silence

        do {
            let host = group(instrument: true)
            let sub1 = group(), sub2 = group()
            let clip = midi()
            func silenced(_ ids: Set<UUID>) -> (SoundObject) -> Bool { { ids.contains($0.id) } }

            check("nothing silenced: audible", !GroupInstrumentRule.midiSilenced(of: clip, ancestors: [sub1, sub2, host], isSilenced: silenced([])))
            check("the clip itself silenced", GroupInstrumentRule.midiSilenced(of: clip, ancestors: [host], isSilenced: silenced([clip.id])))
            check("a sub-group between the clip and the host silences it", GroupInstrumentRule.midiSilenced(of: clip, ancestors: [sub1, sub2, host], isSilenced: silenced([sub1.id])))
            check("a sub-group higher, still under the host, silences it", GroupInstrumentRule.midiSilenced(of: clip, ancestors: [sub1, sub2, host], isSilenced: silenced([sub2.id])))
            check("the HOST silenced does not silence the notes (its fader is on its output)", !GroupInstrumentRule.midiSilenced(of: clip, ancestors: [sub1, host], isSilenced: silenced([host.id])))
            let aboveHost = group()
            check("a group ABOVE the host does not silence the notes", !GroupInstrumentRule.midiSilenced(of: clip, ancestors: [host, aboveHost], isSilenced: silenced([aboveHost.id])))
            check("no host: the whole chain is read", GroupInstrumentRule.midiSilenced(of: clip, ancestors: [sub1, aboveHost], isSilenced: silenced([aboveHost.id])))
            check("no ancestor: only the clip counts", !GroupInstrumentRule.midiSilenced(of: clip, ancestors: [], isSilenced: silenced([])))
        }

        // MARK: - Vocabulary

        do {
            check("carriesInstrument: group", GroupInstrumentRule.carriesInstrument(group(instrument: true)))
            check("carriesInstrument: MIDI clip", GroupInstrumentRule.carriesInstrument(midi(withInstrument: true)))
            check("carriesInstrument: not an empty clip", !GroupInstrumentRule.carriesInstrument(midi()))
            check("isEmptyClip", GroupInstrumentRule.isEmptyClip(midi()) && !GroupInstrumentRule.isEmptyClip(midi(withInstrument: true)) && !GroupInstrumentRule.isEmptyClip(group()))
            check("every refusal has its own raw value", Set(GroupInstrumentRefusal.allCases.map(\.rawValue)).count == 6)
        }

        print("\n\(total - fails.count)/\(total) assertions pass")
        exit(fails.isEmpty ? 0 : 1)
    }
}
