import Foundation

// MARK: - A block's editing zones (the selection tool)

/// The six sub-zones of a block under the selection tool. Their geometry is the same as the one
/// used by `updateCursor` and by `handleCanvasDrag` — a single definition for the cursor, the
/// gesture and this hover rendering.
enum ClipEditZone: Equatable {
    case fadeIn, fadeOut       // the upper half, left / right handles
    case trimLeft, resizeRight // the lower half, left / right handles
    case timeSelect            // the upper half, centre — selecting a range
    case move                  // the lower half, centre — moving
    case loopIn, loopOut       // full height, the loop's IN/OUT markers (@see [[loop-item-plan]])

    /// The zone aimed at inside a block, in coordinates LOCAL to the block. The single definition
    /// of the carve-up: the cursor (`updateCursor`), the gesture (`handleCanvasDrag`) and the
    /// double click (`handleCanvasTap`) all go through here.
    ///
    /// A fade THAT IS SET can be grabbed from anywhere in its grey triangle — beyond the handle
    /// too when it is long — but ONLY in the upper half: the lower half is left to trimming and
    /// resizing, which a somewhat long fade would otherwise confiscate.
    /// With no fade (0), the carve-up is exactly what it was.
    ///
    /// `loopInPx`/`loopOutPx`: the position (in px local to the block) of the loop's IN/OUT
    /// markers, or nil if the object does not loop / the marker falls outside the current block
    /// (V1 scope, @see [[loop-item-plan]] — a CLIP loop point can go beyond [0,bw] but is then
    /// not draggable from THIS block). They take priority over everything else: a narrow
    /// full-height target, tested before the handles/triangles that would otherwise cover the same pixel
    /// — except on an EDGE, where they only keep the upper half (@see `grabs`).
    static func resolve(localX: Double, localY: Double,
                        blockWidth bw: Double, blockHeight bh: Double,
                        handleW: Double,
                        fadeInPx: Double, fadeOutPx: Double,
                        loopInPx: Double? = nil, loopOutPx: Double? = nil,
                        hasFades: Bool = true) -> ClipEditZone {
        let loopTol = 5.0
        let upper = localY < bh * 0.50
        // A marker sitting ON an edge of the block (IN at the left edge — what a left trim of a
        // looping clip leaves, or a freshly looped clip's — OUT at the right edge) would otherwise
        // confiscate the whole height of the edge, and grabbing the edge to trim it moved the marker
        // instead. There the two share the height: the UPPER half is the marker's, the LOWER half is
        // the edge's (trim / resize). A marker clear of the edges keeps its full height.
        func grabs(_ markerPx: Double?) -> Bool {
            guard let m = markerPx, abs(localX - m) <= loopTol else { return false }
            let onEdge = abs(m) <= loopTol || abs(m - bw) <= loopTol
            return !onEdge || upper
        }
        if grabs(loopInPx) { return .loopIn }
        if grabs(loopOutPx) { return .loopOut }

        // The HANDLES first: each edge's own band answers for that edge whatever lies over it. A
        // fade that is set is therefore ALWAYS grabbable by at least the handle, however short it
        // is on screen, and a long fade from the opposite edge can no longer confiscate it.
        // An EMPTY MIDI clip has no fade of its own (a host plays it, plan 2.5): its upper handles are plain body.
        if handleW > 0 && localX < handleW      { return upper ? (hasFades ? .fadeIn : .timeSelect) : .trimLeft }
        if handleW > 0 && localX > bw - handleW { return upper ? (hasFades ? .fadeOut : .timeSelect) : .resizeRight }
        if bh > 0, upper, hasFades {
            // Fade triangles: (0,0)-(fiPx,0)-(0,bh) and (bw-foPx,0)-(bw,0)-(bw,bh).
            if fadeInPx > 1, (localX / fadeInPx + localY / bh) <= 1 { return .fadeIn }
            if fadeOutPx > 1, ((bw - localX) / fadeOutPx + localY / bh) <= 1 { return .fadeOut }
        }
        return upper ? .timeSelect : .move
    }

    /// The widest a side handle gets, in px — the SAME at every zoom (option B, 5 October 2026; 20 px, then 40 px the same day).
    static let handleMaxPx: Double = 40

    /// Below this displayed width a block has NO handle (all body), as before but at 30 px instead
    /// of 60 (user, 5 October 2026).
    static let handleMinBlockPx: Double = 30

    /// The width of a block's side handles: a FIXED `handleMaxPx` whatever the zoom, capped at a
    /// quarter of the block's DISPLAYED width (as before) so that a narrow block keeps a middle (its body, its
    /// range selection) between its two handles. Below `handleMinBlockPx` (30 px) a block has no
    /// handle at all. Shared by the hover, the gesture, the double click, the veil's
    /// re-layout, the crossfade zone's lower half and the automation hem.
    ///
    /// It used to be 25 % of the width capped at 50 px, and NOTHING below 60 px: zoomed out, a
    /// block lost its fade and trim zones too early, and the width of the zone changed under the
    /// hand with every notch of zoom.
    static func handleWidth(blockWidth bw: Double) -> Double {
        bw < handleMinBlockPx ? 0 : max(0, min(handleMaxPx, bw / 4))
    }
}
