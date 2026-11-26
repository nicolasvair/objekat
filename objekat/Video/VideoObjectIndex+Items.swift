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
            case .clip(let filePath, let sourceOffset, let fileDuration, let speed, let reversed):
                guard let facet = o.video else { continue }
                var loop: VideoLoopRange? = nil
                if let r = o.loopMarkerLocalRange { loop = VideoLoopRange(start: r.start, end: r.end) }
                out.append(VideoPictureEntry(
                    id: o.id, filePath: filePath, lane: o.lane, start: o.startTime, duration: o.duration,
                    sourceOffset: sourceOffset, speedRatio: speed, isReversed: reversed,
                    fileDuration: fileDuration, loop: loop, nominalFPS: facet.nominalFPS,
                    isMuted: audibility.isSilenced(o), ancestors: ancestors))
            case .group(let children, _):
                var loop: VideoLoopRange? = nil
                if let r = o.loopMarkerLocalRange { loop = VideoLoopRange(start: r.start, end: r.end) }
                let window = VideoGroupWindow(lane: o.lane, start: o.startTime, duration: o.duration,
                                              isInfinite: o.isInfiniteBus, loop: loop,
                                              isMuted: audibility.isSilenced(o))
                collect(children, ancestors: ancestors + [window], audibility: audibility, into: &out)
            case .aux, .midiClip:
                continue
            }
        }
    }
}
