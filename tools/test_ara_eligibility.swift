// ARAEligibility (`Shared/ARAEligibility.swift`) — which objects may carry an ARA source, asserted
// with no screen against tools/fixtures/ara_eligibility_cases.json. From `tools/`:
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/SoundObject.swift \
//         ../objekat/SoundObject/Automation.swift \
//         ../objekat/SoundObject/AutomationCurveMath.swift \
//         ../objekat/SoundObject/Marker.swift \
//         ../objekat/SoundObject/ChannelMode.swift \
//         ../objekat/Shared/LaneEntryIndex.swift \
//         ../objekat/Timeline/ClipEditZonesOverlay.swift \
//         ../objekat/Shared/ScriptCanvasMemory.swift \
//         ../objekat/SoundObject/ConsolidateDefinition.swift \
//         ../objekat/SoundObject/FadeCurve.swift \
//         ../objekat/SoundObject/ComposedName.swift \
//         ../objekat/SoundObject/FXLink.swift \
//         ../objekat/Shared/ObjekatPalette.swift \
//         ../objekat/Shared/Localization.swift \
//         ../objekat/EditViewModel/EditViewModel+Types.swift \
//         ../objekat/EditViewModel/SessionSchema.swift \
//         ../objekat/App/LaunchArguments.swift \
//         ../objekat/Shared/ARAEligibility.swift \
//         test_ara_eligibility.swift -o /tmp/ae && /tmp/ae [fixtures/ara_eligibility_cases.json]
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

func makeSource() -> ARASource {
    ARASource(plugin: ObjectPlugin(id: UUID(), name: "Melodyne", manufacturer: "Celemony",
                                   identifier: "/Library/Audio/Plug-Ins/VST3/Melodyne.vst3", formatName: "VST3"),
              archive: nil)
}

func makeObject(_ d: [String: Any]) -> SoundObject {
    let kindName = d["kind"] as? String ?? "clip"
    let kind: SoundObject.Kind
    switch kindName {
    case "group":
        let kids = (d["children"] as? [[String: Any]] ?? []).map(makeObject)
        kind = .group(children: kids, isExpanded: false)
    case "aux":  kind = .aux
    case "midi": kind = .midiClip(notes: [], lengthBeats: 4)
    default:
        kind = .clip(filePath: "/tmp/x.wav", sourceOffset: 0, fileDuration: 10,
                     speedRatio: d["speed"] as? Double ?? 1.0, isReversed: d["reversed"] as? Bool ?? false)
    }
    var o = SoundObject(startTime: 0, duration: 10, lane: 0,
                        consolidateID: (d["consolidated"] as? Bool ?? false) ? UUID() : nil,
                        loopEnabled: d["loop"] as? Bool ?? false, kind: kind)
    if d["source"] as? Bool ?? false { o.araSource = makeSource() }
    return o
}

@main
enum ARAEligibilityTest {
    static func main() {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "fixtures/ara_eligibility_cases.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("cannot read \(path)"); exit(2)
        }
        for c in root["eligibility"] as? [[String: Any]] ?? [] {
            let name = c["name"] as! String
            let o = makeObject(c["object"] as? [String: Any] ?? [:])
            let anc = (c["ancestors"] as? [[String: Any]] ?? []).map {
                makeObject(["kind": "group", "loop": $0["loop"] as? Bool ?? false])
            }
            let got = ARAEligibility.refusal(for: o, ancestors: anc, isFileMissing: c["fileMissing"] as? Bool ?? false)
            let want = (c["expected"] as? String).flatMap { ARARefusal(rawValue: $0) }
            check("eligibility: \(name)", got == want, "got \(String(describing: got)) want \(String(describing: want))")
        }
        for c in root["loop"] as? [[String: Any]] ?? [] {
            let name = c["name"] as! String
            let got = ARAEligibility.refusalOfLoop(on: makeObject(c["object"] as? [String: Any] ?? [:]))
            let want = (c["expected"] as? String).flatMap { ARARefusal(rawValue: $0) }
            check("loop: \(name)", got == want, "got \(String(describing: got)) want \(String(describing: want))")
        }
        for r in ARARefusal.allCases { check("reason of \(r.rawValue) is not empty", !r.reason.isEmpty) }
        print(fails.isEmpty ? "ALL OK (\(total))" : "\(fails.count) FAIL / \(total)")
        exit(fails.isEmpty ? 0 : 1)
    }
}
