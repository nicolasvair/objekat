// The prefix a recording zone's name carries in the timeline — `RecordZoneName.prefix`, asserted with no
// screen and no engine (RecordZoneName.swift depends on Foundation only).
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/RecordZoneName.swift test_record_zone_name.swift \
//         -o /tmp/trzn && /tmp/trzn
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ name: String, _ ok: Bool) {
    total += 1
    if !ok { fails.append(name); print("FAIL  \(name)") }
}

@main
struct Main {
    static func main() {
        // Born without a label: the default name is the input's, no prefix.
        check("no label -> no prefix", RecordZoneName.prefix(label: nil, inputName: "Voix") == nil)
        // A name typed by hand: the input's name comes in front.
        check("typed label -> input prefix", RecordZoneName.prefix(label: "Refrain", inputName: "Voix") == "Voix")
        // A zone of an older project: the label IS the input's name at creation -> default.
        check("label == input name -> default", RecordZoneName.prefix(label: "Voix", inputName: "Voix") == nil)
        check("label == input name (blanks) -> default",
              RecordZoneName.prefix(label: " Voix ", inputName: "Voix") == nil)
        // Not a zone: no input, never a prefix.
        check("no input -> no prefix", RecordZoneName.prefix(label: "Refrain", inputName: nil) == nil)
        check("empty input name -> no prefix", RecordZoneName.prefix(label: "Refrain", inputName: "") == nil)
        // A blank label is no name.
        check("blank label -> default", RecordZoneName.prefix(label: "  ", inputName: "Voix") == nil)
        // Case matters: "voix" typed over "Voix" is a name somebody chose.
        check("different case -> typed", RecordZoneName.prefix(label: "voix", inputName: "Voix") == "Voix")

        print(fails.isEmpty ? "OK  \(total) assertions" : "FAILED \(fails.count)/\(total)")
        exit(fails.isEmpty ? 0 : 1)
    }
}
