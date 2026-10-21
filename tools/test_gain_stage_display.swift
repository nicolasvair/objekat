// `GainStageDisplay` — the gain the DRAWN waveform follows (the fader + the gain stages of the object's
// main serial chain) — and `ObjectPlugin.withGainStageStoredValues`, the model's mirror of a stage's
// live value, asserted with no screen and no engine.
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/SoundObject.swift \
//         ../objekat/SoundObject/ChannelPick.swift \
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
//         test_gain_stage_display.swift \
//         -o /tmp/gsd && /tmp/gsd
//
// (the same file list as test_legacy_gain_migration.swift, this file in its place).
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

func near(_ a: Float, _ b: Float, _ eps: Float = 1e-4) -> Bool { abs(a - b) <= eps }

@main
enum GainStageDisplayTest {
    static func main() {

        func stage(_ db: Float, face: GainStageFace = .gain, pan: Float = 0, muted: Bool = false,
                   link: UUID? = nil) -> ObjectPlugin {
            ObjectPlugin.makeGainStage(face: face, values: GainStageValues(gainDb: db, pan: pan, muted: muted),
                                       linkGroupID: link)
        }
        func plug(_ identifier: String = "compressor", format: String = "TracktionInternal") -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: identifier, manufacturer: "Tracktion", identifier: identifier,
                         formatName: format, stateXML: "<PLUGIN type=\"\(identifier)\" gainDb=\"12\"/>")
        }
        func rack(_ voices: [[ObjectPlugin]]) -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: "Parallel", manufacturer: "OBJEKAT", identifier: "rack",
                         formatName: "TracktionInternal", rack: PluginRack(voices: voices))
        }
        func bin(_ link: UUID, _ plugins: [ObjectPlugin], detached: Bool = false,
                 local: FXLinkOutput? = nil) -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: "Bin", manufacturer: "OBJEKAT", identifier: "fxlink",
                         formatName: "TracktionInternal",
                         fxBlock: FXLinkBlock(linkID: link, isDetached: detached, plugins: plugins, local: local))
        }
        func clip(volume: Float = 0, plugins: [ObjectPlugin] = [], sends: [AuxSend] = []) -> SoundObject {
            SoundObject(startTime: 0, duration: 4, lane: 0, volume: volume, plugins: plugins, sends: sends,
                        kind: .clip(filePath: "/tmp/a.wav", sourceOffset: 0, fileDuration: 4,
                                    speedRatio: 1, isReversed: false))
        }
        let none: Set<UUID> = []
        func shown(_ o: SoundObject, _ off: Set<UUID> = []) -> Float { o.waveformDisplayGainDb(offBins: off) }

        // MARK: the fader alone, and the root series
        do {
            check("no stage: the fader alone", near(shown(clip(volume: -7)), -7))
            check("one stage adds its gain", near(shown(clip(volume: -3, plugins: [stage(-6)])), -9))
            check("stages SUM in dB, around other plugins",
                  near(shown(clip(volume: 2, plugins: [stage(-6), plug(), stage(4), plug("AU", format: "AudioUnit")])), 0))
            check("the gain · pan face counts its gain", near(shown(clip(plugins: [stage(5, face: .gainPanMute)])), 5))
            check("a stage's PAN does not count", near(shown(clip(plugins: [stage(0, face: .gainPanMute, pan: -1)])), 0))
            check("a stage's MUTE does not flatten (as the object's own mute does not)",
                  near(shown(clip(plugins: [stage(-3, face: .gainPanMute, muted: true)])), -3))
            check("a third-party / other built-in plugin never counts, whatever its state says",
                  near(shown(clip(plugins: [plug(), plug("AU", format: "AudioUnit")])), 0))
            var off = stage(-12); off.isEnabled = false
            check("a disabled stage leaf does not count", near(shown(clip(plugins: [off, stage(3)])), 3))
            let marker = ObjectPlugin.makeSendMarker(for: UUID())
            check("a send marker on the trunk changes nothing; the stages either side count",
                  near(shown(clip(plugins: [stage(-2), marker, stage(-4)])), -6))
            check("a stage with no stored state is neutral", {
                var s = stage(9); s.stateXML = nil
                return near(shown(clip(plugins: [s])), 0)
            }())
            check("a stored value out of range is clamped to the engine's ±24 dB",
                  near(shown(clip(plugins: [{ var s = stage(0); s.stateXML = "<PLUGIN type=\"objGainStage\" gainDb=\"40\"/>"; return s }()])), 24))
        }

        // MARK: the -96 dB rule (silence stays silence)
        do {
            check("a fader at -96 stays -96 whatever the stages add",
                  near(shown(clip(volume: -96, plugins: [stage(24), stage(24)])), -96))
            check("stages can bring a fader to silence or below (the drawing reads 0)",
                  shown(clip(volume: -60, plugins: [stage(-24), stage(-24)])) <= -96)
            check("+dB above 0 is passed through as is (the drawing's clamp decides)",
                  near(shown(clip(volume: 6, plugins: [stage(24)])), 30))
        }

        // MARK: what does NOT count: parallel branches, sends
        do {
            check("a parallel branch's stages do not count",
                  near(shown(clip(plugins: [rack([[stage(-12)], [stage(6), plug()]]), stage(-1)])), -1))
            var send = AuxSend(auxID: UUID())
            send.plugins = [stage(-18)]
            check("a send's mini-chain does not count", near(shown(clip(plugins: [stage(2)], sends: [send])), 2))
        }

        // MARK: FX link blocks: serial, unless the bin is off
        do {
            let link = UUID()
            let o = clip(plugins: [stage(-1), bin(link, [plug(), stage(-5, face: .gainPanMute)])])
            check("an attached bin's stages count (a bin is serial)", near(shown(o, none), -6))
            check("an attached bin switched OFF: its stages do not count", near(shown(o, [link]), -1))
            check("another bin switched off changes nothing", near(shown(o, [UUID()]), -6))
            let det = clip(plugins: [bin(link, [stage(-5)], detached: true, local: FXLinkOutput(isEnabled: true))])
            check("a detached bin follows its OWN on/off (on), not the registry's", near(shown(det, [link]), -5))
            let detOff = clip(plugins: [bin(link, [stage(-5)], detached: true, local: FXLinkOutput(isEnabled: false))])
            check("a detached bin switched off locally: not counted", near(shown(detOff, none), 0))
            let detNil = clip(plugins: [bin(link, [stage(-5)], detached: true, local: nil)])
            check("a detached bin with no local rules counts as on", near(shown(detNil, none), -5))
        }

        // MARK: the pure function on raw arrays
        do {
            check("serialStagesGainDb on an empty chain is 0",
                  near(GainStageDisplay.serialStagesGainDb([], offBins: none), 0))
            check("effectiveDisplayGainDb = volume + stages",
                  near(GainStageDisplay.effectiveDisplayGainDb(volume: -4, plugins: [stage(-2)], offBins: none), -6))
        }

        // MARK: the mirror: withGainStageStoredValues
        do {
            let s = stage(-6)
            let m = s.withGainStageStoredValues(GainStageValues(gainDb: 3.5, pan: -0.25, muted: true))
            check("mirror: a fresh stage's state is rewritten", m.gainStageStoredValues
                  == GainStageValues(gainDb: 3.5, pan: -0.25, muted: true), "\(m.stateXML ?? "nil")")
            check("mirror: the id, face and link are kept",
                  m.id == s.id && m.gainStageFace == s.gainStageFace && m.linkGroupID == s.linkGroupID)

            // An engine-flushed tree: more attributes and children, double-quoted values, a float format.
            var e = stage(0)
            e.stateXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<PLUGIN type=\"objGainStage\" id=\"1042\" "
                       + "gainDb=\"-6.0\" enabled=\"1\"><MACROPARAMETERS id=\"1043\"/></PLUGIN>"
            let em = e.withGainStageStoredValues(GainStageValues(gainDb: -12, pan: 0, muted: false))
            check("mirror: an engine tree's existing gainDb is rewritten in place",
                  em.gainStageStoredValues?.gainDb == -12, "\(em.stateXML ?? "nil")")
            check("mirror: the absent pan / muted are added to the root element",
                  em.stateXML?.contains("pan=\"0\"") == true && em.stateXML?.contains("muted=\"0\"") == true)
            check("mirror: everything else of the tree is kept",
                  em.stateXML?.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<PLUGIN type=\"objGainStage\" id=\"1042\" gainDb=\"-12\" enabled=\"1\"") == true
                  && em.stateXML?.hasSuffix("><MACROPARAMETERS id=\"1043\"/></PLUGIN>") == true,
                  "\(em.stateXML ?? "nil")")
            check("mirror: the waveform reads the mirrored value",
                  near(shown(clip(volume: -1, plugins: [em])), -13))

            // A self-closing tag with no gain attribute at all.
            var bare = stage(0); bare.stateXML = "<PLUGIN type=\"objGainPanMute\"/>"
            let bm = bare.withGainStageStoredValues(GainStageValues(gainDb: 7, pan: 0.5, muted: false))
            check("mirror: attributes are added before the slash of a self-closing tag",
                  bm.stateXML == "<PLUGIN type=\"objGainPanMute\" gainDb=\"7\" pan=\"0.5\" muted=\"0\"/>",
                  "\(bm.stateXML ?? "nil")")
            var noState = stage(0); noState.stateXML = nil
            check("mirror: no state → the stage's own state",
                  noState.withGainStageStoredValues(GainStageValues(gainDb: -3)).gainStageStoredValues?.gainDb == -3)
            check("mirror: values are clamped to the engine's range",
                  s.withGainStageStoredValues(GainStageValues(gainDb: 99)).gainStageStoredValues?.gainDb == 24)
            let p = plug()
            check("mirror: not a stage → unchanged", p.withGainStageStoredValues(GainStageValues(gainDb: -3)) == p)
            check("mirror: idempotent (a second write of the same values changes nothing)",
                  em.withGainStageStoredValues(GainStageValues(gainDb: -12, pan: 0, muted: false)).stateXML == em.stateXML)
        }

        print("\(total - fails.count)/\(total) passed")
        if !fails.isEmpty { print("FAILED: \(fails)"); exit(1) }
    }
}
