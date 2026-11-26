import Foundation

// MARK: - The picture of an imported video (plan-video §2.2)
//
// A picture object is an ORDINARY `.clip` that carries a `VideoFacet` — the video file's path is its
// `filePath`, its window and `sourceOffset` are the picture's own, cutting / trimming / looping /
// copying / relinking reach it through the clip they already read. What makes it different is what it
// has NOT: no engine clip (it makes no sound, and the engine would otherwise try to read the movie's
// audio, or refuse the format), no chain, no sends, no stem. Everything that would act on its sound
// is refused at the door (`SoundObject.isPicture`).

/// A picture's size in pixels, as DISPLAYED (the file's rotation already applied).
struct VideoSize: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
}

struct VideoFacet: Codable, Equatable, Sendable {
    /// The displayed size, rotation applied.
    var pixelSize: VideoSize
    /// Indicative only: the real time of every frame comes from its presentation timestamp.
    var nominalFPS: Double
}
