import Foundation

// MARK: - What a hand on a crossfade means — the part with no view and no model behind it
//
// Three questions the crossfade gesture asks, none of which needs a timeline to be answered, and
// which is why they live here, where `tools/test_crossfade_grab.swift` can compile and assert them
// alone (the reason `CutSelection` / `SendColumns` / `PianoRollFraming` are units):
//
//  • a fade handle grabbed on an object, OUTSIDE the zone its crossfade occupies, is a grab of that
//    crossfade — which pair, and which of its parts;
//  • with several objects selected, which OTHER crossfades follow the one under the hand;
//  • where each pair's zone must go for one and the same travel of the hand.

/// The part of a crossfade zone a hand has taken hold of.
enum CrossfadePart: Equatable {
    /// The bottom triangle: slide the seam, width unchanged.
    case move
    /// The top triangle: widen/narrow symmetrically about the centre, and bend both curves.
    case both
    /// A side: that edge of the zone travels, the opposite one is pinned.
    case sideStart, sideEnd
}

enum CrossfadeGrab {

    /// One end of an object's fade, as the block's own carve-up names it (@see ClipEditZone).
    enum FadeEdge { case fadeIn, fadeOut }

    struct Pair: Hashable {
        let left: UUID
        let right: UUID
    }

    // MARK: - A fade handle that overhangs the zone

    /// The crossfade a fade handle belongs to, when the hand took hold of the handle OUTSIDE the
    /// zone.
    ///
    /// A block's handle band is a quarter of its width, up to 50 px; a crossfade is often narrower
    /// than that. The part of the band that sticks out of the zone fell through to the per-block
    /// fade, which changes ONE fade and leaves the other at the old overlap — the pair stopped being
    /// a crossfade (`isCrossfadePair` wants both fades equal to the overlap) and the two clips were
    /// left superposed. The handle of an edge that is engaged in a crossfade is that crossfade's
    /// side, wherever on the band the hand lands.
    ///
    /// A fade-IN is the left edge of its object, so its crossfade is the one with the partner on the
    /// LEFT, and the part is the zone's start; a fade-OUT is the mirror image. An object with no
    /// partner on that side has no crossfade there: `nil`, the plain fade gesture is what it gets.
    static func pair(forFade edge: FadeEdge, of id: UUID,
                     partnerLeft: UUID?, partnerRight: UUID?)
        -> (pair: Pair, part: CrossfadePart)? {
        switch edge {
        case .fadeIn:
            guard let l = partnerLeft else { return nil }
            return (Pair(left: l, right: id), .sideStart)
        case .fadeOut:
            guard let r = partnerRight else { return nil }
            return (Pair(left: id, right: r), .sideEnd)
        }
    }

    // MARK: - Which other crossfades follow

    /// The crossfades, other than the one under the hand, that follow it.
    ///
    /// The model is the fades' own: grabbing something that is part of the selection drives the whole
    /// selection, grabbing something that is not drives only itself — so a zone neither of whose two
    /// objects is selected is a gesture alone, and nothing else moves.
    ///
    /// What "follows" depends on the PART, and it is the fade's "same side" carried over:
    ///  • a side (`.sideStart` / `.sideEnd`) is ONE edge, and it is an object's — the start of the
    ///    zone is its right-hand object's left edge, its end the left-hand object's right edge. So
    ///    every selected object that has a crossfade on that very side brings it along, exactly as
    ///    every selected object takes the same end of its fade in the plain gesture;
    ///  • the whole zone (`.both`, `.move`) has no side: every crossfade that touches a selected
    ///    object follows, on whichever side of it it lies.
    ///
    /// A zone whose two objects are both selected is named once (a set), and the order is the
    /// caller's to fix — it depends on times this function knows nothing about.
    static func followers(part: CrossfadePart,
                          grabbed: Pair,
                          selected: Set<UUID>,
                          partners: (UUID) -> (left: UUID?, right: UUID?))
        -> Set<Pair> {
        guard selected.contains(grabbed.left) || selected.contains(grabbed.right) else { return [] }
        var out = Set<Pair>()
        for id in selected {
            let p = partners(id)
            switch part {
            case .sideStart:
                if let l = p.left { out.insert(Pair(left: l, right: id)) }
            case .sideEnd:
                if let r = p.right { out.insert(Pair(left: id, right: r)) }
            case .both, .move:
                if let l = p.left { out.insert(Pair(left: l, right: id)) }
                if let r = p.right { out.insert(Pair(left: id, right: r)) }
            }
        }
        out.remove(grabbed)
        return out
    }

    // MARK: - Where a zone goes for a given travel

    /// What the gesture asks of ONE zone for a travel `shift` of the hand, from the zone as it
    /// stood when the hand came down: the width asked for (it may go NEGATIVE — that is the gesture
    /// asking for more than the zone has, and what is past zero becomes a plain fade) and where the
    /// zone would like to START.
    ///
    /// `shift` is the travel of the edge that is held, snapped for the one the hand is on — in
    /// SECONDS, signed to the right. It is what makes the other zones follow: they receive the
    /// SAME `shift`, never a snap of their own (two zones each landing on their own grid line would
    /// not be one gesture), so a zone keeps the width and the place it had relative to the hand.
    ///  • `.move` — the start travels by `shift`, the width is kept;
    ///  • `.both` — symmetric about the centre, right widens and left narrows: the width changes by
    ///    TWICE the travel, since both edges go by it;
    ///  • `.sideStart` — the start travels by `shift`, the end stays: the width loses it;
    ///  • `.sideEnd` — the end travels by `shift`, the start stays: the width gains it.
    static func target(part: CrossfadePart, anchorStart: Double, anchorEnd: Double,
                       shift: Double) -> (rawWidth: Double, idealStart: Double) {
        let w0 = anchorEnd - anchorStart
        switch part {
        case .move:
            return (w0, anchorStart + shift)
        case .both:
            let raw = w0 + 2 * shift
            return (raw, (anchorStart + anchorEnd) / 2 - max(0, raw) / 2)
        case .sideStart:
            let raw = w0 - shift
            return (raw, anchorEnd - max(0, raw))
        case .sideEnd:
            return (w0 + shift, anchorStart)
        }
    }
}
