// The payload of a drag from the Inputs tab (card inputs AND MIDI inputs) as the timeline's drop reads it —
// asserted with no screen: the lane order (MIDI first), the first format (`first` / `count`) still read,
// an invalid item spoiling the whole drag, a wrong marker, an empty MIDI id, the JSON round trip.
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/RecordInputs.swift ../objekat/Shared/InputDragSession.swift \
//         test_input_drag_payload.swift -o /tmp/tidp && /tmp/tidp
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ name: String, _ ok: Bool) {
    total += 1
    if !ok { fails.append(name); print("FAIL  \(name)") }
}

func roundTrip(_ p: InputDragPayload) -> InputDragPayload? {
    guard let d = try? JSONEncoder().encode(p) else { return nil }
    return try? JSONDecoder().decode(InputDragPayload.self, from: d)
}

@main
struct Main {
    static func main() {
        let a = InputRef(first: 0, count: 1), b = InputRef(first: 1, count: 2)
        let m1 = MidiInputRef(id: "dev1", name: "Keys"), m2 = MidiInputRef(id: "all_midi_in", name: "All")

        // Audio only: as before.
        let audioOnly = InputDragPayload(sources: [.audio(a), .audio(b)])
        check("audio only: sources", audioOnly.sources == [.audio(a), .audio(b)])
        check("audio only: no midi key", audioOnly.midi == nil)
        check("audio only: refs", audioOnly.refs == [a, b])
        check("audio only: same as the audio initialiser", InputDragPayload([a, b]) == audioOnly)

        // MIDI only.
        let midiOnly = InputDragPayload(sources: [.midi(m1), .midi(m2)])
        check("midi only: ids", midiOnly.midi == ["dev1", "all_midi_in"])
        check("midi only: no card inputs", midiOnly.inputs == nil && midiOnly.refs.isEmpty)
        check("midi only: sources carry the id alone, in order",
              midiOnly.sources == [.midi(MidiInputRef(id: "dev1", name: "")), .midi(MidiInputRef(id: "all_midi_in", name: ""))])

        // Mixed: MIDI FIRST whatever the order given.
        let mixed = InputDragPayload(sources: [.audio(a), .midi(m1), .audio(b), .midi(m2)])
        check("mixed: midi first, then the card's, each in order given",
              mixed.sources == [.midi(MidiInputRef(id: "dev1", name: "")), .midi(MidiInputRef(id: "all_midi_in", name: "")),
                                .audio(a), .audio(b)])
        check("mixed: survives the JSON round trip", roundTrip(mixed) == mixed && roundTrip(mixed)?.sources == mixed.sources)

        // The first format: ONE input as first / count.
        var legacy = InputDragPayload([])
        legacy.inputs = nil; legacy.first = 2; legacy.count = 1
        check("legacy: read as one card input", legacy.sources == [.audio(InputRef(first: 2, count: 1))])
        let legacyJSON = #"{"marker":"objekat.input","first":3,"count":2}"#.data(using: .utf8)!
        let decodedLegacy = try? JSONDecoder().decode(InputDragPayload.self, from: legacyJSON)
        check("legacy: decodes from a file with no inputs / midi key",
              decodedLegacy?.sources == [.audio(InputRef(first: 3, count: 2))])

        // Invalid.
        var wrong = mixed; wrong.marker = "objekat.plugin"
        check("wrong marker: nothing", wrong.sources.isEmpty && wrong.refs.isEmpty)
        var emptyID = midiOnly; emptyID.midi = ["dev1", ""]
        check("an empty MIDI id spoils the drag", emptyID.sources.isEmpty)
        var badChannel = mixed; badChannel.inputs = [.init(first: -1, count: 1)]
        check("an invalid card input spoils the whole drag (the MIDI ones too)", badChannel.sources.isEmpty)
        var threeWide = mixed; threeWide.inputs = [.init(first: 0, count: 3)]
        check("a width of 3 is refused", threeWide.sources.isEmpty)
        let empty = InputDragPayload(sources: [])
        check("nothing carried: nothing read", empty.sources.isEmpty)
        let junk = #"{"marker":"objekat.input"}"#.data(using: .utf8)!
        check("a marker alone carries nothing",
              (try? JSONDecoder().decode(InputDragPayload.self, from: junk))?.sources.isEmpty == true)

        if fails.isEmpty { print("OK  \(total) assertions"); exit(0) }
        print("\(fails.count) of \(total) failed"); exit(1)
    }
}
