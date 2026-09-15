import CoreGraphics
import Foundation

// MARK: - Choosing cards in the signal view: the geometry, and nothing else
//
// No view here, no model, not even a card type of its own beyond an id and a rectangle — which is
// all the two rules below need. That is the point: the gestures that pick cards are the half of
// the feature an eye would otherwise have to check, and a unit with no dependency can be compiled
// on its own and asserted against with no screen (@see tools/test_synoptic_marquee.swift).

enum SynopticMarquee {

    /// What the two rules see of a card: where it is, and who it is.
    struct Card {
        let id: UUID
        let frame: CGRect
        init(id: UUID, frame: CGRect) { self.id = id; self.frame = frame }
    }

    /// A MARQUEE takes the cards it contains ENTIRELY — the same rule the timeline's rubber band
    /// applies to clips (@see TimelineView.selectInDisplayLanes), and deliberately not an
    /// intersection. On a canvas where parallel branches sit side by side, a rectangle drawn down
    /// one branch grazes its neighbour's cards on the way past, and taking what one merely brushed
    /// is how a selection stops being something one can aim.
    ///
    /// `rect` is taken standardised, so a rectangle drawn upwards or leftwards reads the same; a
    /// flat one (no width or no height) takes nothing, which is what a click that never travelled
    /// should do.
    static func fullyInside(_ rect: CGRect, cards: [Card]) -> [UUID] {
        let r = rect.standardized
        guard r.width > 0, r.height > 0 else { return [] }
        return cards.filter { r.contains($0.frame) }.map(\.id)
    }

    /// ⇧+click GROWS the selection to the box that holds what was already taken plus the card
    /// aimed at, and everything that box touches comes with it. Word for word the clips' rule
    /// (@see TimelineView.extendSelectionTo, which spans lane × time the same way) rather than a
    /// range along the chain: the signal view is a canvas, branches run side by side on it, and a
    /// hand that draws a diagonal across two branches means the two.
    ///
    /// INTERSECTION here, where the marquee above asks for containment — and the difference is the
    /// gesture, not an oversight: a marquee is drawn where one wants it, whereas this box is
    /// DEDUCED from cards, so its edges fall ON them and never around them.
    ///
    /// An empty selection ⇒ the target alone, which is what ⇧ on a fresh canvas should do.
    static func boundingBox(of selected: Set<UUID>, extendedTo targetID: UUID,
                            cards: [Card]) -> [UUID] {
        guard let target = cards.first(where: { $0.id == targetID }) else { return [] }
        let held = cards.filter { selected.contains($0.id) }
        guard !held.isEmpty else { return [targetID] }
        let box = held.reduce(target.frame) { $0.union($1.frame) }
        return cards.filter { $0.frame.intersects(box) }.map(\.id)
    }
}
