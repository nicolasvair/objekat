import Foundation

// MARK: - The picture objects of the document, as the resolver reads them (plan-video §4.3)
//
// `VideoObjectIndex` (Shared/VideoTimeMap.swift) knows no model type, so that the resolver stays a
// pure function. This file is the only place that reads `SoundObject` to fill it: a walk of the tree,
// keeping for each picture the windows of the groups above it, and nothing else.

extension VideoObjectIndex {

    /// Walks `items` and keeps the picture objects (a `.clip` carrying a `VideoFacet`). O(N) over
    /// the tree, built lazily and dropped with `items` (@see `EditViewModel.videoObjectIndex`).
    init(items: [SoundObject]) {
        var out: [VideoPictureEntry] = []
        Self.collect(items, ancestors: [], into: &out)
        self.init(entries: out)
    }

    private static func collect(_ objs: [SoundObject], ancestors: [VideoGroupWindow],
                                into out: inout [VideoPictureEntry]) {
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
                    isMuted: o.isMuted, ancestors: ancestors))
            case .group(let children, _):
                var loop: VideoLoopRange? = nil
                if let r = o.loopMarkerLocalRange { loop = VideoLoopRange(start: r.start, end: r.end) }
                let window = VideoGroupWindow(lane: o.lane, start: o.startTime, duration: o.duration,
                                              isInfinite: o.isInfiniteBus, loop: loop, isMuted: o.isMuted)
                collect(children, ancestors: ancestors + [window], into: &out)
            case .aux, .midiClip:
                continue
            }
        }
    }
}

extension EditViewModel {

    /// The picture objects of the document, with their ancestors' windows. Cached until `items`
    /// changes — the display link asks for it at the screen's rate, through a copy published by
    /// `VideoPreviewController`, never by reading the view-model from the render thread.
    var videoObjectIndex: VideoObjectIndex {
        if let c = videoObjectIndexCache { return c }
        let built = VideoObjectIndex(items: items)
        videoObjectIndexCache = built
        return built
    }
}
