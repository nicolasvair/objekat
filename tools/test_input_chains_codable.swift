// `InputChains` (E9, docs/plan_groupes_midi.md) — the Codable contract of the chains an input carries, asserted with
// no screen: every key optional, empty chains not written, a chain this build cannot read dropped ALONE, lookups.
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
//         ../objekat/SoundObject/RecordInputs.swift \
//         ../objekat/SoundObject/PluginIDUniqueness.swift \
//         ../objekat/SoundObject/PluginIDReport.swift \
//         ../objekat/Shared/BridgeScope.swift \
//         ../objekat/Shared/ScriptCanvasMemory.swift \
//         ../objekat/SoundObject/InputChains.swift \
//         test_input_chains_codable.swift \
//         -o /tmp/icc && /tmp/icc
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

func plugin(_ name: String = "EQ", stateXML: String? = "<state/>") -> ObjectPlugin {
    ObjectPlugin(id: UUID(), name: name, manufacturer: "Objekat", identifier: "eq",
                 formatName: "TracktionInternal", stateXML: stateXML)
}

@main
enum InputChainsCodableTest {
    static func main() throws {
        let enc = JSONEncoder(), dec = JSONDecoder()
        let hostA = UUID(), hostB = UUID(), hostM = UUID()
        let eq = plugin(), comp = plugin("Comp")
        let inst = plugin("DLSMusicDevice", stateXML: nil)
        let dev = MidiInputRef(id: "vmidiin_1", name: "Keys")
        let chains = InputChains(
            audio: ["3": InputChain(hostID: hostA, plugins: [eq, comp]),
                    "1-2": InputChain(hostID: hostB, plugins: [])],
            midi: ["vmidiin_1": MidiInputChain(hostID: hostM, input: dev, instrument: inst)])

        // Round trip, empty chains not written.
        let data = try enc.encode(chains)
        let back = try dec.decode(InputChains.self, from: data)
        check("round trip keeps the chains that hold something", back.audio.keys.sorted() == ["3"] && back.midi.keys.sorted() == ["vmidiin_1"])
        check("... with the same host ids and plugins", back.audio["3"]?.hostID == hostA && back.audio["3"]?.plugins == [eq, comp]
              && back.midi["vmidiin_1"]?.instrument == inst && back.midi["vmidiin_1"]?.hostID == hostM)
        check("an empty audio chain is not written", back.audio["1-2"] == nil)
        check("nothing at all encodes as an empty object and `isEmpty`", (try? enc.encode(InputChains())).flatMap { String(data: $0, encoding: .utf8) } == "{}"
              && InputChains().isEmpty && !chains.isEmpty)
        check("`written` drops the empty chains", chains.written.audio.keys.sorted() == ["3"])

        // Every key optional.
        check("{} decodes to nothing", (try? dec.decode(InputChains.self, from: Data("{}".utf8)))?.isEmpty == true)
        check("only `midi` present", (try? dec.decode(InputChains.self, from: try enc.encode(InputChains(midi: chains.midi))))?.audio.isEmpty == true)

        // A retouched file: one bad chain is dropped alone, a bad section does not fail the project.
        let good = String(data: try enc.encode(InputChain(hostID: hostA, plugins: [eq])), encoding: .utf8)!
        let mixed = "{\"audio\":{\"3\":\(good),\"4\":{\"nonsense\":true}}}"
        let m = try? dec.decode(InputChains.self, from: Data(mixed.utf8))
        check("a chain this build cannot read is dropped alone", m?.audio.keys.sorted() == ["3"])
        let broken = try? dec.decode(InputChains.self, from: Data("{\"audio\":42,\"midi\":\"x\"}".utf8))
        check("a section of the wrong type decodes to nothing, without throwing", broken?.isEmpty == true)

        // Lookups.
        check("audioKey / midiKey / contains", chains.audioKey(ofHost: hostA) == "3" && chains.midiKey(ofHost: hostM) == "vmidiin_1"
              && chains.contains(host: hostB) && !chains.contains(host: UUID()))
        check("allPlugins flattens the FX and the instruments", chains.allPlugins.count == 3)
        check("inputRef(forKey:)", InputChains.inputRef(forKey: "3") == InputRef(first: 2, count: 1)
              && InputChains.inputRef(forKey: "1-2") == InputRef(first: 0, count: 2)
              && InputChains.inputRef(forKey: "2-4") == nil && InputChains.inputRef(forKey: "0") == nil
              && InputChains.inputRef(forKey: "x") == nil)

        // FX behind a MIDI instrument (inputs panel, step 1): an optional `plugins`, read leniently.
        let fxOnly = MidiInputChain(hostID: hostM, input: dev, instrument: nil, plugins: [eq])
        check("a MIDI chain with FX alone is not empty; with nothing it is", !fxOnly.isEmpty
              && MidiInputChain(hostID: hostM, input: dev).isEmpty && !chains.midi["vmidiin_1"]!.isEmpty)
        let both = InputChains(midi: ["k": MidiInputChain(hostID: hostM, input: dev, instrument: inst, plugins: [eq, comp])])
        let bothBack = try dec.decode(InputChains.self, from: try enc.encode(both))
        check("MIDI chain round trip keeps the instrument and the FX in order", bothBack.midi["k"]?.instrument == inst
              && bothBack.midi["k"]?.plugins == [eq, comp])
        check("a chain of FX alone is written (not dropped as empty)", (try dec.decode(InputChains.self, from:
              try enc.encode(InputChains(midi: ["k": fxOnly])))).midi["k"]?.plugins == [eq])
        let noFXJSON = String(data: try enc.encode(InputChains(midi: chains.midi)), encoding: .utf8)!
        check("a chain without FX is written without a `plugins` key (as before)", !noFXJSON.contains("plugins"), noFXJSON)
        let old = "{\"midi\":{\"k\":{\"hostID\":\"\(hostM.uuidString)\",\"input\":{\"id\":\"k\",\"name\":\"Keys\"},"
            + "\"instrument\":\(String(data: try enc.encode(inst), encoding: .utf8)!)}}}"
        let oldBack = try? dec.decode(InputChains.self, from: Data(old.utf8))
        check("a chain saved before `plugins` existed is READ, not dropped", oldBack?.midi["k"]?.instrument == inst
              && oldBack?.midi["k"]?.plugins.isEmpty == true, old)
        let badFX = "{\"midi\":{\"k\":{\"hostID\":\"\(hostM.uuidString)\",\"input\":{\"id\":\"k\",\"name\":\"Keys\"},\"plugins\":\"x\"}}}"
        check("unreadable `plugins` leave the chain with none", (try? dec.decode(InputChains.self, from: Data(badFX.utf8)))?.midi["k"]?.plugins.isEmpty == true)
        check("allPlugins counts the FX behind an instrument", both.allPlugins.count == 3)

        print("\(total - fails.count)/\(total) assertions passed")
        if !fails.isEmpty { exit(1) }
    }
}
