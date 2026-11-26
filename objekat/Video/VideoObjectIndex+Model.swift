import Foundation

// MARK: - The view-model's door onto the picture index (plan-video §4.3)
//
// The walk itself is `VideoObjectIndex.init(items:)` (VideoObjectIndex+Items.swift).

extension EditViewModel {

    /// The picture objects of the document, with their ancestors' windows and what the listening
    /// composition (mute, stem mute, solo) says of each. Cached until `items` or `audibility` changes —
    /// the display link asks for it at the screen's rate, through a copy published by
    /// `VideoPreviewController`, never by reading the view-model from the render thread.
    var videoObjectIndex: VideoObjectIndex {
        if let c = videoObjectIndexCache { return c }
        let built = VideoObjectIndex(items: items, audibility: audibility)
        videoObjectIndexCache = built
        return built
    }
}
