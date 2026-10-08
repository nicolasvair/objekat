// The ARA source's MODEL (`ARASource`/`ARAArchive` in SoundObject.swift): Codable round trip with
// a 2 MB base64 archive, a format-19 session without the key, `derivedCopy` carrying the source with
// a NEW plugin id, and `PluginIDUniqueness` finding and repairing two sources with the same id.
// From `tools/` (same dependencies as test_plugin_id_uniqueness.swift):
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
//         ../objekat/SoundObject/PluginIDUniqueness.swift \
//         ../objekat/SoundObject/PluginIDReport.swift \
//         ../objekat/Shared/ARAUndoPolicy.swift \
//         test_ara_model.swift -o /tmp/am && /tmp/am
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

func melodyne(id: UUID = UUID()) -> ObjectPlugin {
    ObjectPlugin(id: id, name: "Melodyne", manufacturer: "Celemony",
                 identifier: "/Library/Audio/Plug-Ins/VST3/Melodyne.vst3", formatName: "VST3")
}

func clip(source: ARASource? = nil, id: UUID = UUID()) -> SoundObject {
    var o = SoundObject(id: id, startTime: 1, duration: 4, lane: 0,
                        kind: .clip(filePath: "/tmp/x.wav", sourceOffset: 0, fileDuration: 10,
                                    speedRatio: 1, isReversed: false))
    o.araSource = source
    return o
}

@main
enum ARAModelTest {
    static func main() throws {
        // 1. Codable round trip, 2 MB of random bytes.
        var bytes = [UInt8](repeating: 0, count: 2_000_000)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        let b64 = Data(bytes).base64EncodedString()
        let archive = ARAArchive(data: b64, sourceID: "src-1", modificationID: "mod-9",
                                 documentArchiveID: "com.celemony.ara.doc", bytes: bytes.count)
        let src = ARASource(plugin: melodyne(), archive: archive)
        let obj = clip(source: src)
        let enc = JSONEncoder()
        let json = try enc.encode(obj)
        let back = try JSONDecoder().decode(SoundObject.self, from: json)
        check("round trip keeps the source", back.araSource == src)
        check("archive bytes identical", Data(base64Encoded: back.araSource!.archive!.data) == Data(bytes))
        check("source with no archive round-trips",
              (try? JSONDecoder().decode(SoundObject.self, from: enc.encode(clip(source: ARASource(plugin: melodyne(), archive: nil)))))?.araSource?.archive == nil)

        // 2. A session without the key (format 19) decodes without a source.
        let plain = try enc.encode(clip())
        var dict = try JSONSerialization.jsonObject(with: plain) as! [String: Any]
        check("a clip with no source writes no araSource key", dict["araSource"] == nil)
        dict["araSource"] = nil
        let noKey = try JSONSerialization.data(withJSONObject: dict)
        check("format-19 style JSON decodes with araSource == nil",
              (try? JSONDecoder().decode(SoundObject.self, from: noKey))?.araSource == nil)
        check("session format is 20", SessionSchema.formatVersion == 20)

        // 3. derivedCopy: the source follows, with a NEW plugin id, never linked.
        var linked = src
        linked.plugin.linkGroupID = UUID()
        let derived = clip(source: linked).derivedCopy(startTime: 2, duration: 1, lane: 1, fadeIn: 0, fadeOut: 0, plugins: [], kind: obj.kind)
        check("derivedCopy carries a source", derived.araSource != nil)
        check("derivedCopy gets a NEW plugin id", derived.araSource?.plugin.id != src.plugin.id)
        check("derivedCopy keeps the archive", derived.araSource?.archive == archive)
        check("derivedCopy drops any link", derived.araSource?.plugin.linkGroupID == nil)
        let given = ARASource(plugin: melodyne(), archive: ARAArchive(data: "AA==", sourceID: "s", modificationID: "m", documentArchiveID: "d", bytes: 1))
        let derived2 = obj.derivedCopy(startTime: 2, duration: 1, lane: 1, fadeIn: 0, fadeOut: 0, plugins: [], araSource: .some(given), kind: obj.kind)
        check("derivedCopy takes the source the caller hands over", derived2.araSource == given)

        // 4. PluginIDUniqueness: two sources, same plugin id, two objects.
        let shared = UUID()
        let a = clip(source: ARASource(plugin: melodyne(id: shared), archive: nil))
        let b = clip(source: ARASource(plugin: melodyne(id: shared), archive: nil))
        let items = [a, b]
        let dups = PluginIDUniqueness.duplicates(items: items, stems: [])
        check("duplicate ARA source ids are detected", dups.contains { $0.id == shared }, "\(dups)")
        let fixed = PluginIDUniqueness.deduplicated(items: items, stems: []).items
        check("repair gives the second object a new id",
              fixed[0].araSource?.plugin.id == shared && fixed[1].araSource?.plugin.id != shared)
        check("after repair no duplicate remains", PluginIDUniqueness.duplicates(items: fixed, stems: []).isEmpty)

        // 5. Q1: the undo adopts the LIVE archive of a source it leaves alive.
        func arch(_ tag: String) -> ARAArchive {
            ARAArchive(data: tag, sourceID: "s", modificationID: tag, documentArchiveID: "d", bytes: tag.count)
        }
        let pid = UUID()
        let stale = clip(source: ARASource(plugin: melodyne(id: pid), archive: arch("OLD")))
        var live = stale
        live.araSource?.archive = arch("LIVE")
        let adopted = ARAUndoPolicy.adoptingLive([stale], live: [live])
        check("Q1: same plugin id -> the live archive wins", adopted[0].araSource?.archive == arch("LIVE"))
        check("Q1: the adopted object equals the live one (differential undo leaves it alone)", adopted[0] == live)
        var replugged = live
        replugged.araSource?.plugin.id = UUID()
        check("Q1: another plugin id (a recreated source) keeps the snapshot's archive",
              ARAUndoPolicy.adoptingLive([stale], live: [replugged])[0].araSource?.archive == arch("OLD"))
        check("Q1: a source the live model does not have (undone removal) keeps the snapshot's archive",
              ARAUndoPolicy.adoptingLive([stale], live: [clip()])[0].araSource?.archive == arch("OLD"))
        check("Q1: nothing live -> the snapshot is returned as is",
              ARAUndoPolicy.adoptingLive([stale], live: [])[0] == stale)
        let inner = clip(source: ARASource(plugin: melodyne(id: pid), archive: arch("OLD")))
        var innerLive = inner
        innerLive.araSource?.archive = arch("LIVE")
        let grp = SoundObject(id: UUID(), startTime: 0, duration: 1, lane: 0, fadeIn: 0, fadeOut: 0,
                              kind: .group(children: [inner], isExpanded: true))
        var grpLive = grp
        grpLive.kind = .group(children: [innerLive], isExpanded: true)
        if case .group(let kids, _) = ARAUndoPolicy.adoptingLive([grp], live: [grpLive])[0].kind {
            check("Q1: a child of a group is adopted too", kids[0].araSource?.archive == arch("LIVE"))
        } else { check("Q1: group kept", false) }

        print(fails.isEmpty ? "ALL OK (\(total))" : "\(fails.count) FAIL / \(total)")
        exit(fails.isEmpty ? 0 : 1)
    }
}
