// The card's recording inputs as the PROJECT keeps them — `RecordInputsConfig`, `InputRef` and the
// pairing rules, asserted with no screen and no engine (RecordInputs.swift depends on Foundation only).
// Pinned down: the JSON round trip, a project written before format 33 (no key at all), a hand-edited
// file that must degrade rather than fail, the editing rules (1-2 and 2-3 coexist, a blank name goes
// back to the default), and what the Inputs tab lists.
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/RecordInputs.swift test_record_inputs_codable.swift \
//         -o /tmp/tric && /tmp/tric
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ name: String, _ ok: Bool) {
    total += 1
    if !ok { fails.append(name); print("FAIL  \(name)") }
}

/// A stand-in for the one field `ProjectDocument` and `SoundObject` hold: an optional that must read as
/// absent when the file is odd, never fail the whole document.
struct Holder: Codable {
    var recordInputs: RecordInputsConfig?
    var recordInput: InputRef?
    /// As `SoundObject` holds it (format 34): nil = the default ("mute"); the default is written as ABSENT, and an
    /// unknown value reads as the default.
    var recordTakeMode: RecordTakeMode?
    enum CodingKeys: String, CodingKey { case recordInputs, recordInput, recordTakeMode }
    init(recordInputs: RecordInputsConfig? = nil, recordInput: InputRef? = nil, recordTakeMode: RecordTakeMode? = nil) {
        self.recordInputs = recordInputs
        self.recordInput = recordInput
        self.recordTakeMode = recordTakeMode
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordInputs = try? c.decodeIfPresent(RecordInputsConfig.self, forKey: .recordInputs)
        recordInput = try? c.decodeIfPresent(InputRef.self, forKey: .recordInput)
        recordTakeMode = (try? c.decodeIfPresent(RecordTakeMode.self, forKey: .recordTakeMode))?.stored
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(recordInputs, forKey: .recordInputs)
        try c.encodeIfPresent(recordInput, forKey: .recordInput)
        try c.encodeIfPresent(recordTakeMode?.stored, forKey: .recordTakeMode)
    }
}

@main
struct Main {
    static func main() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let dec = JSONDecoder()

        // MARK: InputRef

        let mono3 = InputRef(first: 2, count: 1)
        let pair12 = InputRef(first: 0, count: 2)
        check("keys are 1-based: a mono", mono3.key == "3")
        check("keys are 1-based: a pair", pair12.key == "1-2")
        check("channels of a pair", Array(pair12.channels) == [0, 1])
        check("a mono sorts before the pair starting on the same channel",
              InputRef(first: 1, count: 1) < InputRef(first: 1, count: 2))
        check("sorted by first channel", InputRef(first: 0, count: 2) < InputRef(first: 1, count: 1))

        // MARK: JSON round trip

        var cfg = RecordInputsConfig(deviceName: "Scarlett 18i20")
        cfg.pair(0, channelCount: 8)
        cfg.pair(1, channelCount: 8)            // overlap: 1-2 AND 2-3
        cfg.rename(mono3, to: "Voix")
        cfg.rename(pair12, to: "Guitare")
        let json = try enc.encode(Holder(recordInputs: cfg, recordInput: pair12))
        let back = try dec.decode(Holder.self, from: json)
        check("config round trips", back.recordInputs == cfg)
        check("InputRef round trips", back.recordInput == pair12)
        check("overlapping pairs survive the file", back.recordInputs?.pairs == [0, 1])
        check("names survive the file", back.recordInputs?.names == ["3": "Voix", "1-2": "Guitare"])

        let text = String(data: json, encoding: .utf8) ?? ""
        check("an empty config writes no key of its own",
              !(String(data: try enc.encode(RecordInputsConfig()), encoding: .utf8) ?? "").contains("pairs"))
        check("the json names the keys", text.contains("\"deviceName\"") && text.contains("\"pairs\""))

        // MARK: A project written before format 33

        let old = try dec.decode(Holder.self, from: Data("{}".utf8))
        check("no key at all reads as nil (format 32)", old.recordInputs == nil && old.recordInput == nil)

        // MARK: The zone's take mode (format 34)

        let addJSON = try enc.encode(Holder(recordInput: pair12, recordTakeMode: .add))
        check("add is written", (String(data: addJSON, encoding: .utf8) ?? "").contains("\"recordTakeMode\":\"add\""))
        check("add round trips", try dec.decode(Holder.self, from: addJSON).recordTakeMode == .add)
        let muteJSON = try enc.encode(Holder(recordInput: pair12, recordTakeMode: .mute))
        check("mute (the default) is written as an ABSENT key",
              !(String(data: muteJSON, encoding: .utf8) ?? "").contains("recordTakeMode"))
        check("... and reads back as the default (nil)", try dec.decode(Holder.self, from: muteJSON).recordTakeMode == nil)
        check("no key at all = mute (a project written before format 34)", old.recordTakeMode == nil)
        check("an explicit \"mute\" in a file reads as the default", try dec.decode(Holder.self, from: Data(#"{"recordTakeMode":"mute"}"#.utf8)).recordTakeMode == nil)
        check("an unknown mode reads as the default, not as a failure",
              try dec.decode(Holder.self, from: Data(#"{"recordInput":{"first":0,"count":1},"recordTakeMode":"overdub"}"#.utf8)).recordTakeMode == nil)
        check("a wrong type reads as the default", try dec.decode(Holder.self, from: Data(#"{"recordTakeMode":3}"#.utf8)).recordTakeMode == nil)
        check("only add silences nothing", RecordTakeMode.mute.mutesPrevious && !RecordTakeMode.add.mutesPrevious)
        check("stored: add stays, mute goes", RecordTakeMode.add.stored == .add && RecordTakeMode.mute.stored == nil)
        check("two modes", RecordTakeMode.allCases == [.mute, .add])

        // MARK: A hand-edited file degrades, it does not fail

        let odd1 = try dec.decode(Holder.self, from: Data(#"{"recordInput":{"first":0,"count":5}}"#.utf8))
        check("a reference with count 5 reads as absent", odd1.recordInput == nil)
        let odd2 = try dec.decode(Holder.self, from: Data(#"{"recordInput":{"first":-1,"count":1}}"#.utf8))
        check("a negative channel reads as absent", odd2.recordInput == nil)
        let odd3 = try dec.decode(Holder.self, from: Data(#"{"recordInputs":{"pairs":"x","names":[1,2]}}"#.utf8))
        check("wrong types inside the config read as empty, not as a failure",
              odd3.recordInputs == RecordInputsConfig())
        let odd4 = try dec.decode(Holder.self, from: Data(#"{"recordInputs":{"pairs":[3,1],"future":true}}"#.utf8))
        check("an unknown key is ignored", odd4.recordInputs?.pairs == [3, 1])

        // MARK: Editing

        var e = RecordInputsConfig()
        check("pairing 1-2 on a 2-channel card", e.pair(0, channelCount: 2))
        check("pairing twice changes nothing", !e.pair(0, channelCount: 2))
        check("a pair must fit the card", !e.pair(1, channelCount: 2))
        check("a negative first channel is refused", !e.pair(-1, channelCount: 8))
        check("pairs stay ascending", { var x = RecordInputsConfig(); x.pair(4, channelCount: 8)
                                         x.pair(0, channelCount: 8); x.pair(2, channelCount: 8)
                                         return x.pairs == [0, 2, 4] }())
        check("unpair removes it", e.unpair(0) && e.pairs.isEmpty)
        check("unpairing what is not paired changes nothing", !e.unpair(0))

        e.rename(pair12, to: "  Voix  ")
        check("a name is trimmed", e.customName(for: pair12) == "Voix")
        check("renaming to the same name changes nothing", !e.rename(pair12, to: "Voix"))
        e.pair(0, channelCount: 4); e.unpair(0)
        check("unpairing keeps the name: pairing again finds it", e.customName(for: pair12) == "Voix")
        check("a blank name goes back to the default", e.rename(pair12, to: "   ") && e.customName(for: pair12) == nil)
        check("... and blanking a default name changes nothing", !e.rename(pair12, to: nil))
        check("isEmpty after everything is undone", e.isEmpty)

        var s = RecordInputsConfig()
        check("setPairs drops what the card cannot hold",
              s.setPairs([5, 0, 0, 2, -3, 7], channelCount: 6) && s.pairs == [0, 2])
        check("setPairs with the same pairs changes nothing", !s.setPairs([2, 0], channelCount: 6))

        // MARK: What the tab lists

        let vis = InputPairing.visibleInputs(channelCount: 4, pairs: [])
        check("4 channels, no pair: 4 monos", vis.count == 4 && vis.allSatisfy { !$0.isStereo })
        let vis2 = InputPairing.visibleInputs(channelCount: 4, pairs: [0])
        check("1-2 paired: the pair FIRST, then the four monos (they stay)",
              vis2 == [InputRef(first: 0, count: 2)] + (0 ..< 4).map { InputRef(first: $0, count: 1) })
        let vis3 = InputPairing.visibleInputs(channelCount: 4, pairs: [1, 0])
        check("1-2 AND 2-3: both pairs (by first channel), then the four monos",
              vis3 == [InputRef(first: 0, count: 2), InputRef(first: 1, count: 2)] + (0 ..< 4).map { InputRef(first: $0, count: 1) })
        check("a pair outside the card is not listed",
              InputPairing.visibleInputs(channelCount: 2, pairs: [1]).count == 2
              && !InputPairing.visibleInputs(channelCount: 2, pairs: [1]).contains { $0.isStereo })
        check("no channel, nothing to list", InputPairing.visibleInputs(channelCount: 0, pairs: [0]).isEmpty)
        check("a mono is present while no pair holds it",
              InputPairing.isPresent(mono3, channelCount: 4, pairs: [0]))
        check("... and still present once a pair holds it (the monos stay)",
              InputPairing.isPresent(mono3, channelCount: 4, pairs: [1]))
        check("a mono on a smaller card is absent, not forgotten",
              !InputPairing.isPresent(mono3, channelCount: 2, pairs: []))

        // MARK: Pairing from a selection

        let m1 = InputRef(first: 1, count: 1), m2 = InputRef(first: 2, count: 1)
        check("two neighbouring monos can be paired", InputPairing.pairableFirst([m2, m1]) == 1)
        check("two distant monos cannot", InputPairing.pairableFirst([m1, InputRef(first: 3, count: 1)]) == nil)
        check("a single input cannot", InputPairing.pairableFirst([m1]) == nil)
        check("three cannot", InputPairing.pairableFirst([m1, m2, InputRef(first: 3, count: 1)]) == nil)
        check("a stereo input cannot", InputPairing.pairableFirst([pair12, InputRef(first: 2, count: 1)]) == nil)

        // MARK: MidiInputRef (session format 35). The exclusivity with the card input and the zoneInstruments key
        // live in SoundObject: asserted in test_cross_project_import.swift.

        struct MidiHolder: Codable { var recordMidiInput: MidiInputRef? }
        let mref = MidiInputRef(id: "vmidiin_1", name: "Keystation 49")
        let mdata = try enc.encode(MidiHolder(recordMidiInput: mref))
        check("MidiInputRef round trip", try dec.decode(MidiHolder.self, from: mdata).recordMidiInput == mref)
        check("... written as {id, name}", String(data: mdata, encoding: .utf8) == "{\"recordMidiInput\":{\"id\":\"vmidiin_1\",\"name\":\"Keystation 49\"}}")
        check("a project from before format 35 (no key) reads nil",
              try dec.decode(MidiHolder.self, from: Data("{}".utf8)).recordMidiInput == nil)
        check("a name that is missing reads as empty (the id still finds the device)",
              try dec.decode(MidiHolder.self, from: Data("{\"recordMidiInput\":{\"id\":\"x\"}}".utf8)).recordMidiInput == MidiInputRef(id: "x", name: ""))
        check("an empty id is refused by the reference itself",
              (try? dec.decode(MidiHolder.self, from: Data("{\"recordMidiInput\":{\"id\":\"\",\"name\":\"n\"}}".utf8))) == nil)
        check("a reference with no id is refused",
              (try? dec.decode(MidiHolder.self, from: Data("{\"recordMidiInput\":{\"name\":\"n\"}}".utf8))) == nil)
        check("RecordSource tells the two apart and hashes them apart",
              RecordSource.audio(InputRef(first: 0, count: 1)) != RecordSource.midi(mref)
              && Set([RecordSource.audio(InputRef(first: 0, count: 1)), .midi(mref), .midi(mref)]).count == 2)

        print(fails.isEmpty ? "ALL PASS (\(total))" : "\(fails.count) FAILED of \(total)")
        exit(fails.isEmpty ? 0 : 1)
    }
}
