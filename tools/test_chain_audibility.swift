// `ChainAudibility` — "does the object's sound reach the output?" — asserted with no screen and no
// engine. The rule: an object is silent through its chain iff EVERY path from the source to the output
// is cut by at least one mute of the signal view (a gain stage's mute, a parallel branch's mute).
// In series a mute cuts; a parallel block is cut only when every branch is (recursively); several
// mutes accumulate. Not counted: sends, empty branches, a bypassed stage, a switched-off bin.
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
//         ../objekat/SoundObject/GainStage.swift \
//         ../objekat/SoundObject/ChainAudibility.swift \
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
//         test_chain_audibility.swift \
//         -o /tmp/chain_aud && /tmp/chain_aud
//
// (the same file list as test_gain_stage_display.swift, plus ChainAudibility.swift.)
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
enum ChainAudibilityTest {
    static func main() {

        // A "gain · pan · mute" stage, muted or not.
        func mute(_ muted: Bool = true, face: GainStageFace = .gainPanMute) -> ObjectPlugin {
            ObjectPlugin.makeGainStage(face: face, values: GainStageValues(gainDb: 0, pan: 0, muted: muted))
        }
        func plug(_ identifier: String = "compressor", format: String = "TracktionInternal") -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: identifier, manufacturer: "Tracktion", identifier: identifier,
                         formatName: format, stateXML: "<PLUGIN type=\"\(identifier)\" muted=\"1\"/>")
        }
        func rack(_ voices: [[ObjectPlugin]], mutes: [Bool]? = nil) -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: "Parallel", manufacturer: "OBJEKAT", identifier: "rack",
                         formatName: "TracktionInternal",
                         rack: PluginRack(voices: voices, voiceMutes: mutes))
        }
        func bin(_ link: UUID, _ plugins: [ObjectPlugin], detached: Bool = false,
                 local: FXLinkOutput? = nil) -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: "Bin", manufacturer: "OBJEKAT", identifier: "fxlink",
                         formatName: "TracktionInternal",
                         fxBlock: FXLinkBlock(linkID: link, isDetached: detached, plugins: plugins, local: local))
        }
        func clip(_ plugins: [ObjectPlugin] = [], sends: [AuxSend] = [], muted: Bool = false) -> SoundObject {
            SoundObject(startTime: 0, duration: 4, lane: 0, isMuted: muted, plugins: plugins, sends: sends,
                        kind: .clip(filePath: "/tmp/a.wav", sourceOffset: 0, fileDuration: 4,
                                    speedRatio: 1, isReversed: false))
        }
        let none: Set<UUID> = []
        func cut(_ plugins: [ObjectPlugin], _ off: Set<UUID> = []) -> Bool {
            clip(plugins).isSilencedByChain(offBins: off)
        }

        // MARK: a chain in series
        do {
            check("no plugin: not cut", !cut([]))
            check("a muted stage cuts", cut([mute()]))
            check("an unmuted stage does not", !cut([mute(false)]))
            check("the plain gain face, left unmuted, does not", !cut([mute(false, face: .gain)]))
            check("a plain plugin never cuts, whatever its state says", !cut([plug(), plug("AU", format: "AudioUnit")]))
            check("one muted stage among others cuts", cut([plug(), mute(false), mute(), plug()]))
            check("several mutes in series accumulate (still cut)", cut([mute(), mute(), mute()]))
            check("a mute first or last cuts the same", cut([mute(), plug()]) && cut([plug(), mute()]))
            var off = mute(); off.isEnabled = false
            check("a disabled (bypassed) muted stage lets the sound through", !cut([off]))
            check("a disabled muted stage + an enabled unmuted one: not cut", !cut([off, mute(false)]))
            check("a disabled muted stage + an enabled muted one: cut", cut([off, mute()]))
            var noState = mute(); noState.stateXML = nil
            check("a stage with no stored state is neutral (not muted)", !cut([noState]))
            let marker = ObjectPlugin.makeSendMarker(for: UUID())
            check("a send's marker lets the sound through", !cut([marker]))
            check("a muted stage either side of a marker still cuts", cut([plug(), marker, mute()]))
        }

        // MARK: parallel: cut only if EVERY branch is
        do {
            check("two branches, both muted by their own button: cut",
                  cut([rack([[plug()], [plug()]], mutes: [true, true])]))
            check("two branches, one muted: NOT cut",
                  !cut([rack([[plug()], [plug()]], mutes: [true, false])]))
            check("two branches, none muted: not cut", !cut([rack([[plug()], [plug()]])]))
            check("two branches, each cut by a muted stage inside it: cut",
                  cut([rack([[plug(), mute()], [mute()]])]))
            check("two branches, only one has a muted stage: NOT cut",
                  !cut([rack([[mute()], [plug()]])]))
            check("a branch cut by its button + the other by a stage inside it: cut",
                  cut([rack([[plug()], [mute()]], mutes: [true, false])]))
            check("three branches, two cut, one audible: NOT cut",
                  !cut([rack([[mute()], [plug()], [mute()]], mutes: [false, false, true])]))
            check("three branches, all cut (button, stage, button): cut",
                  cut([rack([[plug()], [mute()], [plug()]], mutes: [true, false, true])]))
            check("an EMPTY branch (the gain-only path) lets the sound through",
                  !cut([rack([[mute()], []])]))
            check("an empty branch muted by its button is cut like any other",
                  cut([rack([[mute()], []], mutes: [false, true])]))
            check("a block with no branch at all lets the sound through", !cut([rack([])]))
            check("voiceMutes shorter than the voices: the missing ones are not muted",
                  !cut([rack([[plug()], [plug()], [plug()]], mutes: [true, true])]))
            check("voiceMutes longer than the voices: the extra ones are ignored",
                  cut([rack([[plug()], [plug()]], mutes: [true, true, false, false])]))
            check("a single-branch block follows its one branch",
                  cut([rack([[plug()]], mutes: [true])]) && !cut([rack([[plug()]])]))
        }

        // MARK: nesting and mixing series with parallel
        do {
            // inner: both branches cut -> the outer branch holding it is cut.
            let innerCut = rack([[mute()], [plug()]], mutes: [false, true])
            let innerHalf = rack([[mute()], [plug()]])
            check("nested block fully cut makes its branch cut (other branch cut too: cut)",
                  cut([rack([[plug(), innerCut], [mute()]])]))
            check("nested block fully cut, the other outer branch audible: NOT cut",
                  !cut([rack([[innerCut], [plug()]])]))
            check("nested block only half cut: its branch is audible, so the outer is NOT cut",
                  !cut([rack([[innerHalf], [mute()]])]))
            check("nested, the outer branch is muted by its button and the inner one is audible: NOT cut",
                  !cut([rack([[innerHalf], [plug()]], mutes: [false, true])]))
            check("nested three deep, everything cut: cut",
                  cut([rack([[rack([[rack([[mute()], [mute()]])], [mute()]])], [mute()]])]))
            check("nested three deep, the deepest has one audible branch: NOT cut",
                  !cut([rack([[rack([[rack([[mute()], [plug()]])], [mute()]])], [mute()]])]))
            // series around a block.
            let halfBlock = rack([[mute()], [plug()]])
            check("a half-cut block alone does not cut", !cut([halfBlock]))
            check("a mute AFTER a half-cut block cuts the whole", cut([halfBlock, mute()]))
            check("a mute BEFORE a half-cut block cuts the whole", cut([mute(), halfBlock]))
            check("an unmuted stage after a half-cut block changes nothing",
                  !cut([rack([[plug(), mute()], [plug()]]), mute(false)]))
            check("two blocks in series, the first fully cut: cut",
                  cut([rack([[mute()], [mute()]]), rack([[plug()], [plug()]])]))
            check("two blocks in series, each half cut: NOT cut",
                  !cut([rack([[mute()], [plug()]]), rack([[plug()], [mute()]])]))
            check("a send marker before a half-cut block changes nothing",
                  !cut([ObjectPlugin.makeSendMarker(for: UUID()), rack([[mute()], [plug()]])]))
        }

        // MARK: FX link blocks (a series, unless the bin is off)
        do {
            let link = UUID()
            let b = bin(link, [plug(), mute()])
            check("an attached bin holding a muted stage cuts", cut([b], none))
            check("the same bin switched OFF is bypassed: not cut", !cut([b], [link]))
            check("another bin switched off changes nothing", cut([b], [UUID()]))
            check("an attached bin without a mute does not cut", !cut([bin(link, [plug(), mute(false)])]))
            let det = bin(link, [mute()], detached: true, local: FXLinkOutput(isEnabled: true))
            check("a detached bin follows its OWN on/off (on): cut, whatever the registry says",
                  cut([det], [link]))
            let detOff = bin(link, [mute()], detached: true, local: FXLinkOutput(isEnabled: false))
            check("a detached bin switched off locally: not cut", !cut([detOff], none))
            check("a detached bin with no local rules counts as on",
                  cut([bin(link, [mute()], detached: true, local: nil)]))
            check("a bin cut + the chain around it: still cut by the bin alone", cut([plug(), b, plug()]))
            check("a bin inside a branch counts for that branch",
                  cut([rack([[b], [mute()]])]) && !cut([rack([[b], [plug()]])]))
            check("a bypassed bin in a branch does not cut its branch",
                  !cut([rack([[b], [mute()]])], [link]))
        }

        // MARK: what is NOT part of it
        do {
            check("the object's own mute is not the chain's", !clip([], muted: true).isSilencedByChain(offBins: none))
            var send = AuxSend(auxID: UUID())
            send.plugins = [mute()]
            check("a muted stage on a SEND's mini-chain does not cut the object",
                  !clip([plug()], sends: [send]).isSilencedByChain(offBins: none))
            check("an object whose chain is cut is reported even with a send attached (sends are not counted)",
                  clip([mute()], sends: [AuxSend(auxID: UUID())]).isSilencedByChain(offBins: none))
            check("a stage at its bottom gain (-24 dB) is not a mute", !cut([{
                var s = mute(false)
                s.stateXML = "<PLUGIN type=\"objGainStage\" gainDb=\"-24\" pan=\"0\" muted=\"0\"/>"
                return s
            }()]))
            check("the stored text \"true\" counts as muted, like the model's own reader", cut([{
                var s = mute(false)
                s.stateXML = "<PLUGIN type=\"objGainPanMute\" gainDb=\"0\" pan=\"0\" muted=\"true\"/>"
                return s
            }()]))
        }

        // MARK: the object-level helper
        do {
            let a = clip([mute()]), b = clip([rack([[mute()], [plug()]])]), c = clip([])
            check("object with a cut chain", a.isSilencedByChain(offBins: none))
            check("object with a half-cut block", !b.isSilencedByChain(offBins: none))
            check("object with no plugin", !c.isSilencedByChain(offBins: none))
        }

        print("\(total - fails.count)/\(total) passed")
        if !fails.isEmpty { print("FAILED: \(fails)"); exit(1) }
    }
}
