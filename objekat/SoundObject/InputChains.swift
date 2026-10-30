import Foundation

// MARK: - What an input carries: FX on a card input, an instrument on a MIDI input
//
// docs/plan_groupes_midi.md, 2.6 / E9. A chain belongs to the PROJECT (key `ProjectDocument.inputChains`, a sibling of
// `recordInputs`, which stays a Foundation-pure unit): it colours what is HEARD of the input — a recording is taken
// from the device, before any of it. Each chain has a `hostID`: the id the plugin pipeline addresses it by, exactly like
// a stem's (`plugin.*`, the synoptic, the editors). The id is stable as long as the chain exists.
//
//  - audio: FX, keyed by `InputRef.key` ("3", "1-2") like the names — a pair taken apart keeps its chain under "1-2";
//  - MIDI: ONE instrument, keyed by the device id; the name travels with it so a device that comes back under another
//    id is found by `MidiInputResolver` (an absent one leaves the chain dormant).
//
// An empty chain is not worth a key: it is not written (`isEmpty`). Every key is optional on reading.

struct InputChain: Codable, Equatable {
    var hostID: UUID
    var plugins: [ObjectPlugin]

    var isEmpty: Bool { plugins.isEmpty }
}

struct MidiInputChain: Codable, Equatable {
    var hostID: UUID
    var input: MidiInputRef
    var instrument: ObjectPlugin?

    var isEmpty: Bool { instrument == nil }
}

struct InputChains: Codable, Equatable {
    /// By `InputRef.key`.
    var audio: [String: InputChain] = [:]
    /// By the device id of `MidiInputChain.input`.
    var midi: [String: MidiInputChain] = [:]

    init(audio: [String: InputChain] = [:], midi: [String: MidiInputChain] = [:]) {
        self.audio = audio
        self.midi = midi
    }

    /// Nothing worth writing.
    var isEmpty: Bool { audio.values.allSatisfy(\.isEmpty) && midi.values.allSatisfy(\.isEmpty) }

    /// The same chains without the empty ones — what a file holds.
    var written: InputChains {
        InputChains(audio: audio.filter { !$0.value.isEmpty }, midi: midi.filter { !$0.value.isEmpty })
    }

    // Every key optional, and a chain this build cannot read is dropped alone (a retouched file must not fail the project).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audio = Self.lenient(try? c.decodeIfPresent([String: Lenient<InputChain>].self, forKey: .audio))
        midi = Self.lenient(try? c.decodeIfPresent([String: Lenient<MidiInputChain>].self, forKey: .midi))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let w = written
        if !w.audio.isEmpty { try c.encode(w.audio, forKey: .audio) }
        if !w.midi.isEmpty { try c.encode(w.midi, forKey: .midi) }
    }

    enum CodingKeys: String, CodingKey { case audio, midi }

    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private static func lenient<T>(_ raw: [String: Lenient<T>]?) -> [String: T] {
        (raw ?? [:]).compactMapValues(\.value)
    }

    // MARK: Lookup

    /// The key of the audio chain `hostID` names.
    func audioKey(ofHost hostID: UUID) -> String? {
        audio.first { $0.value.hostID == hostID }?.key
    }

    /// The device id of the MIDI chain `hostID` names.
    func midiKey(ofHost hostID: UUID) -> String? {
        midi.first { $0.value.hostID == hostID }?.key
    }

    func contains(host hostID: UUID) -> Bool {
        audioKey(ofHost: hostID) != nil || midiKey(ofHost: hostID) != nil
    }

    /// Every plugin the chains carry, flattened (the instruments included).
    var allPlugins: [ObjectPlugin] {
        audio.values.flatMap { chain in chain.plugins.flatMap { p -> [ObjectPlugin] in
            p.isContainer ? p.childSeries.flatMap { $0 } : [p] } }
        + midi.values.compactMap(\.instrument)
    }

    /// The `InputRef` a key stands for: "3" is mono on channel 3 (first 2), "1-2" the pair (first 0).
    static func inputRef(forKey key: String) -> InputRef? {
        let parts = key.split(separator: "-").map(String.init)
        if parts.count == 1, let n = Int(parts[0]), n >= 1 { return InputRef(first: n - 1, count: 1) }
        if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), a >= 1, b == a + 1 {
            return InputRef(first: a - 1, count: 2)
        }
        return nil
    }
}
