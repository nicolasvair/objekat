// The picture object's MODEL (plan-video §2.2): a `.clip` carrying a `VideoFacet`, written only when
// present, absent = an ordinary clip (every session before format 37), carried by `derivedCopy`
// (cut halves, copies, pastes), unreadable facet = absent (never a failed load). Plus the format
// number, its notice, and the `samples/video` folder joining the project's audio sub-folders.
//
// From `tools/`:
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
//         ../objekat/SoundObject/ConsolidateFolders.swift \
//         ../objekat/Video/VideoFacet.swift \
//         ../objekat/SoundObject/InputChains.swift \
//         test_video_model.swift -o /tmp/vmodel && /tmp/vmodel
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

func clip(video: VideoFacet? = nil) -> SoundObject {
    var o = SoundObject(id: UUID(), startTime: 1, duration: 4, lane: 0,
                        kind: .clip(filePath: "/tmp/movie.mp4", sourceOffset: 0, fileDuration: 10,
                                    speedRatio: 1, isReversed: false))
    o.video = video
    return o
}

@main
enum VideoModelTest {
    static func main() throws {
        let facet = VideoFacet(pixelSize: VideoSize(width: 1920, height: 1080), nominalFPS: 23.976)
        let enc = JSONEncoder()
        let dec = JSONDecoder()

        // Round trip
        let pic = clip(video: facet)
        check("a picture is a picture, and a clip", pic.isPicture && pic.isClip && !pic.isSoundClip)
        let back = try dec.decode(SoundObject.self, from: enc.encode(pic))
        check("round trip keeps the facet", back.video == facet)
        check("round trip keeps the clip", back.isClip && back.isPicture)

        // Written only when present
        let plain = clip()
        check("an ordinary clip is not a picture, and is a sound clip", !plain.isPicture && plain.isSoundClip)
        var dict = try JSONSerialization.jsonObject(with: enc.encode(plain)) as! [String: Any]
        check("an ordinary clip writes no `video` key", dict["video"] == nil)
        let picDict = try JSONSerialization.jsonObject(with: enc.encode(pic)) as! [String: Any]
        let v = picDict["video"] as? [String: Any]
        check("a picture writes `video` with pixelSize and nominalFPS",
              v != nil && (v?["pixelSize"] as? [String: Any])?["width"] as? Int == 1920 && v?["nominalFPS"] != nil)

        // Absent / unreadable
        dict["video"] = nil
        check("no key decodes as an ordinary clip", (try? dec.decode(SoundObject.self, from: JSONSerialization.data(withJSONObject: dict)))?.video == nil)
        dict["video"] = ["pixelSize": "wide", "nominalFPS": "fast"]
        let junk = try? dec.decode(SoundObject.self, from: JSONSerialization.data(withJSONObject: dict))
        check("an unreadable facet reads as absent, the load does not fail", junk != nil && junk?.video == nil)

        // derivedCopy
        let derived = pic.derivedCopy(startTime: 2, duration: 1, lane: 1, fadeIn: 0, fadeOut: 0, plugins: [], kind: pic.kind)
        check("derivedCopy carries the picture facet", derived.video == facet && derived.isPicture)
        let derivedPlain = plain.derivedCopy(startTime: 2, duration: 1, lane: 1, fadeIn: 0, fadeOut: 0, plugins: [], kind: plain.kind)
        check("derivedCopy of an ordinary clip stays ordinary", derivedPlain.video == nil)

        // A group is never a picture; the picture inside a group is
        var group = SoundObject(id: UUID(), startTime: 0, duration: 10, lane: 0, kind: .group(children: [pic], isExpanded: false))
        check("a group is not a picture", !group.isPicture && !group.isSoundClip)
        group.video = nil
        let gb = try dec.decode(SoundObject.self, from: enc.encode(group))
        if case .group(let kids, _) = gb.kind { check("the picture survives inside its group", kids.count == 1 && kids[0].video == facet) }
        else { check("the group decodes as a group", false) }

        // Format and notice
        check("session format is 37", SessionSchema.formatVersion == 37)
        check("the notice documents the `video` key",
              SessionSchema.note.contains { $0.hasPrefix("video (format 37)") }
              && SessionSchema.note.joined().contains("samples/video/"))
        check("the notice names the current format", SessionSchema.note[0].contains("format 37"))

        // Folders
        check("samples/video is a project audio sub-folder", ConsolidateFolders.audioSubfolders.contains("samples/video"))
        let folder = ConsolidateFolders.videoFolder(projectFolder: URL(fileURLWithPath: "/p/proj"))
        check("videoFolder path", folder.path == "/p/proj/samples/video")

        print("\n\(total - fails.count)/\(total) passed")
        if !fails.isEmpty {
            print("FAILURES:")
            for f in fails { print(" - \(f)") }
            exit(1)
        }
    }
}
