// The picture object's MODEL (plan-video §2.2): a `.clip` carrying a `VideoFacet`, written only when
// present, absent = an ordinary clip (every session before format 39), carried by `derivedCopy`
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
//         ../objekat/SoundObject/MidiSequenceWindow.swift \
//         ../objekat/Shared/LoopRetrim.swift \
//         ../objekat/Shared/ClipEditZone.swift \
//         ../objekat/Shared/Compat/CompatPolicy.swift \
//         ../objekat/Shared/VideoTimeMap.swift \
//         ../objekat/Shared/WaveformShaping.swift \
//         ../objekat/Shared/AudibilitySnapshot.swift \
//         ../objekat/Video/VideoObjectIndex+Items.swift \
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

func fadeOutSet(_ o: inout SoundObject, _ v: Double) { o.fadeOut = v }

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

        // The index the resolver reads, built from the model (VideoObjectIndex+Items)
        var inner = clip(video: facet)
        inner.startTime = 2; inner.duration = 5; inner.lane = 1
        var other = clip()                                    // an ordinary clip: not in the index
        other.lane = 0
        let g = SoundObject(id: UUID(), startTime: 10, duration: 20, lane: 3,
                            kind: .group(children: [inner, other], isExpanded: true))
        var outer = SoundObject(id: UUID(), startTime: 0, duration: 100, lane: 2,
                                kind: .group(children: [g], isExpanded: true))
        var rootPic = clip(video: facet); rootPic.lane = 5
        let idx = VideoObjectIndex(items: [outer, rootPic])
        check("the index holds the two pictures and nothing else", idx.entries.count == 2)
        let deep = idx.entries.first { $0.id == inner.id }
        check("a picture carries its ancestors, root first",
              deep?.ancestors.map(\.lane) == [2, 3] && deep?.ancestors.map(\.start) == [0, 10])
        check("a picture keeps its own window", deep?.start == 2 && deep?.duration == 5 && deep?.lane == 1)
        check("a picture at the root has no ancestors", idx.entries.first { $0.id == rootPic.id }?.ancestors.isEmpty == true)
        outer.isInfinite = true
        check("an infinite group is flagged as such in the index",
              VideoObjectIndex(items: [outer]).entries.first?.ancestors.first?.isInfinite == (outer.isInfiniteBus))

        // The fades travel from the model to the index: the picture's own, and each group's
        let bend = FadeCurve(shape: .convex, amount: 0.6)
        var fadedPic = clip(video: facet)
        fadedPic.fadeIn = 1.5; fadeOutSet(&fadedPic, 0.75); fadedPic.fadeInCurve = bend
        var fadedGroup = SoundObject(id: UUID(), startTime: 0, duration: 30, lane: 0,
                                     kind: .group(children: [fadedPic], isExpanded: true))
        fadedGroup.fadeIn = 3; fadedGroup.fadeOut = 2; fadedGroup.fadeOutCurve = FadeCurve(shape: .sCurve, amount: 1)
        let fx = VideoObjectIndex(items: [fadedGroup]).entries.first
        check("a picture's fades and curves reach the index",
              fx?.fadeIn == 1.5 && fx?.fadeOut == 0.75 && fx?.fadeInCurve == bend && fx?.fadeOutCurve == .linear)
        let gw = fx?.ancestors.first
        check("a group's fades and curves reach its window",
              gw?.fadeIn == 3 && gw?.fadeOut == 2 && gw?.fadeOutCurve == FadeCurve(shape: .sCurve, amount: 1)
              && gw?.fadeInCurve == .linear)
        check("through the model, the picture's opacity is group fade x object fade",
              abs((VideoResolver.layer(of: fx!, at: 1.75)?.opacity ?? -1)
                  - (1.75 / 3) * bend.gain(0.5)) < 1e-12)

        // Silence: the picture follows the SAME rule a sound does (`AudibilitySnapshot.isSilenced`) —
        // its mute, its stem's, a solo elsewhere — and so do the groups above it.
        let stem1 = UUID()
        var pic1 = clip(video: facet); pic1.stemID = stem1          // propagated from its group, as `assignStem` does
        var aud1 = clip(); aud1.stemID = stem1
        var grp1 = SoundObject(id: UUID(), startTime: 0, duration: 10, lane: 0,
                               kind: .group(children: [pic1, aud1], isExpanded: true))
        grp1.stemID = stem1
        let pic2 = clip(video: facet)
        let grp2 = SoundObject(id: UUID(), startTime: 20, duration: 10, lane: 1,
                               kind: .group(children: [pic2], isExpanded: true))
        func silence(_ items: [SoundObject], _ snap: AudibilitySnapshot) -> (p1: Bool, g1: Bool, p2: Bool) {
            let ix = VideoObjectIndex(items: items, audibility: snap)
            return (ix.entries.first { $0.id == pic1.id }?.isMuted == true,
                    ix.entries.first { $0.id == pic1.id }?.ancestors.first?.isMuted == true,
                    ix.entries.first { $0.id == pic2.id }?.isMuted == true)
        }
        let tree = [grp1, grp2]
        var r = silence(tree, AudibilitySnapshot())
        check("silence: nothing muted, nothing hidden", !r.p1 && !r.g1 && !r.p2)
        var mutedPic = grp1; if case .group(var kids, let e) = mutedPic.kind { kids[0].isMuted = true; mutedPic.kind = .group(children: kids, isExpanded: e) }
        r = silence([mutedPic, grp2], AudibilitySnapshot())
        check("silence: the picture's own mute hides it, not its group", r.p1 && !r.g1 && !r.p2)
        var mutedGrp = grp1; mutedGrp.isMuted = true
        r = silence([mutedGrp, grp2], AudibilitySnapshot())
        check("silence: a muted group is flagged (its pictures are hidden by the resolver)", r.g1 && !r.p2)
        r = silence(tree, AudibilitySnapshot(mutedStemIDs: [stem1]))
        check("silence: a muted STEM hides the picture and its group (the picture inherits the stem)",
              r.p1 && r.g1 && !r.p2)
        r = silence(tree, AudibilitySnapshot(mutedStemIDs: [stem1]))
        check("silence: a picture on the Main is never stem-muted", !r.p2)
        r = silence(tree, AudibilitySnapshot(soloRoots: [grp1.id], soloActive: true,
                                             soloAudible: [grp1.id, pic1.id, aud1.id]))
        check("silence: the solo of a group keeps its picture, hides the other group's",
              !r.p1 && !r.g1 && r.p2)
        r = silence(tree, AudibilitySnapshot(soloRoots: [aud1.id], soloActive: true,
                                             soloAudible: [aud1.id, grp1.id]))
        check("silence: the solo of the group's AUDIO child hides its picture (a non-soloed sibling), not the group",
              r.p1 && !r.g1 && r.p2)
        r = silence(tree, AudibilitySnapshot(soloRoots: [pic1.id], soloActive: true,
                                             soloAudible: [pic1.id, grp1.id]))
        check("silence: the solo of the picture itself shows it", !r.p1 && !r.g1 && r.p2)
        r = silence([mutedPic, grp2], AudibilitySnapshot(soloRoots: [pic1.id], soloActive: true,
                                                         soloAudible: [pic1.id, grp1.id]))
        check("silence: a direct solo lifts the picture's own mute", !r.p1)
        r = silence([mutedGrp, grp2], AudibilitySnapshot(soloRoots: [pic1.id], soloActive: true,
                                                         soloAudible: [pic1.id, grp1.id],
                                                         soloRootAncestors: [grp1.id]))
        check("silence: a direct solo below a muted group reopens the group's window", !r.g1 && !r.p1)

        // Format and notice
        check("session format is 39", SessionSchema.formatVersion == 39)
        check("the notice documents the `video` key",
              SessionSchema.note.contains { $0.hasPrefix("video (format 39)") }
              && SessionSchema.note.joined().contains("samples/video/"))
        check("the notice names the current format", SessionSchema.note[0].contains("format 39"))

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
