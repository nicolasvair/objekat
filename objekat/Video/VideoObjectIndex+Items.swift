import Foundation

// MARK: - The picture objects of the document, as the resolver reads them (plan-video §4.3)
//
// `VideoObjectIndex` (Shared/VideoTimeMap.swift) knows no model type, so that the resolver stays a
// pure function. This file is the only place that reads `SoundObject` to fill it: a walk of the tree,
// keeping for each picture the windows of the groups above it, and nothing else. It lives apart from
// the view-model's accessor (`VideoObjectIndex+Model.swift`) so that `tools/test_video_model.swift`
// can compile it without the view-model.

extension VideoObjectIndex {

    /// Walks `items` and keeps the picture objects (a `.clip` carrying a `VideoFacet`). O(N) over
    /// the tree, built lazily and dropped with `items` and with the listening state (@see
    /// `EditViewModel.videoObjectIndex`).
    ///
    /// `isMuted` of a picture and of each group window is NOT the object's own flag: it is "this object
    /// would be reduced to silence were it a sound" — `AudibilitySnapshot.isSilenced`, the one rule the
    /// engine's faders and the timeline's veil already read: the object's mute, its stem's mute, a solo
    /// elsewhere (a picture is a leaf like a clip: the solo of a group keeps its picture, the solo of a
    /// sibling sound hides it), the direct solo lifting a mute on its way. A picture inherits its group's
    /// stem (`assignStem` propagates it), so a muted stem hides the pictures of the groups it carries.
    init(items: [SoundObject], audibility: AudibilitySnapshot = AudibilitySnapshot()) {
        var out: [VideoPictureEntry] = []
        Self.collect(items, ancestors: [], audibility: audibility, into: &out)
        self.init(entries: out)
    }

    private static func collect(_ objs: [SoundObject], ancestors: [VideoGroupWindow],
                                audibility: AudibilitySnapshot, into out: inout [VideoPictureEntry]) {
        for o in objs {
            switch o.kind {
            case .clip:
                if let entry = pictureEntry(of: o, isMuted: audibility.isSilenced(o), ancestors: ancestors) {
                    out.append(entry)
                }
            case .group(let children, _):
                let window = groupWindow(of: o, isMuted: audibility.isSilenced(o))
                collect(children, ancestors: ancestors + [window], audibility: audibility, into: &out)
            case .aux, .midiClip:
                continue
            }
        }
    }

    /// What the resolver reads of a PICTURE object — nil for anything else (an ordinary clip has no
    /// `video` facet). The ONE construction: the walk above and the preview of an object being edited
    /// (`previewing(replacing:)`) both go through it, so they cannot disagree about a field.
    static func pictureEntry(of o: SoundObject, isMuted: Bool,
                             ancestors: [VideoGroupWindow]) -> VideoPictureEntry? {
        guard case .clip(let filePath, let sourceOffset, let fileDuration, let speed, let reversed) = o.kind,
              let facet = o.video else { return nil }
        var loop: VideoLoopRange? = nil
        if let r = o.loopMarkerLocalRange { loop = VideoLoopRange(start: r.start, end: r.end) }
        return VideoPictureEntry(
            id: o.id, filePath: filePath, lane: o.lane, start: o.startTime, duration: o.duration,
            sourceOffset: sourceOffset, speedRatio: speed, isReversed: reversed,
            fileDuration: fileDuration, loop: loop, nominalFPS: facet.nominalFPS,
            isMuted: isMuted,
            fadeIn: o.fadeIn, fadeOut: o.fadeOut,
            fadeInCurve: o.fadeInCurve, fadeOutCurve: o.fadeOutCurve, ancestors: ancestors)
    }

    /// What the resolver reads of a GROUP above pictures (@see `pictureEntry`).
    static func groupWindow(of o: SoundObject, isMuted: Bool) -> VideoGroupWindow {
        var loop: VideoLoopRange? = nil
        if let r = o.loopMarkerLocalRange { loop = VideoLoopRange(start: r.start, end: r.end) }
        return VideoGroupWindow(id: o.id, lane: o.lane, start: o.startTime, duration: o.duration,
                                isInfinite: o.isInfiniteBus, loop: loop, isMuted: isMuted,
                                fadeIn: o.fadeIn, fadeOut: o.fadeOut,
                                fadeInCurve: o.fadeInCurve, fadeOutCurve: o.fadeOutCurve)
    }

    /// True when the index holds one of these objects, as a picture or as a group above a picture: the
    /// question a gesture asks before it bothers to build a preview (a crossfade between two sounds
    /// has nothing to show).
    func touches(_ ids: Set<UUID>) -> Bool {
        entries.contains { e in
            ids.contains(e.id) || e.ancestors.contains { $0.id.map(ids.contains) ?? false }
        }
    }

    /// The index as it would be with these objects REPLACED by their edited copies: what the preview
    /// shows while a gesture that has not written the model yet moves their edges and fades (a
    /// crossfade being dragged or created). A picture takes its window, its source offset and speed,
    /// its loop, its fades and curves from its copy; a group above pictures takes its window, loop,
    /// fades and curves. The listening state (`isMuted`) and the ancestors of a picture are KEPT: the
    /// copies know nothing of the stems or the solo, and the gesture moves no object between groups.
    ///
    /// The result is, for what the resolver reads, what `init(items:)` would build over the edited
    /// tree (`tools/test_video_model.swift`) — never a second arithmetic.
    func previewing(replacing objects: [SoundObject]) -> VideoObjectIndex {
        guard !objects.isEmpty else { return self }
        let byID = Dictionary(objects.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var out = self
        for i in out.entries.indices {
            if let o = byID[out.entries[i].id],
               let fresh = Self.pictureEntry(of: o, isMuted: out.entries[i].isMuted,
                                             ancestors: out.entries[i].ancestors) {
                out.entries[i] = fresh
            }
            for j in out.entries[i].ancestors.indices {
                guard let gid = out.entries[i].ancestors[j].id, let g = byID[gid], g.isGroup else { continue }
                out.entries[i].ancestors[j] = Self.groupWindow(of: g, isMuted: out.entries[i].ancestors[j].isMuted)
            }
        }
        return out
    }
}
