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

    /// A MARQUEE takes every card it TOUCHES — a card half caught is caught. Containment was the
    /// first rule here (the clips' rubber band applies it, and on a canvas where parallel branches
    /// sit side by side it was meant to keep a rectangle drawn down one branch from sweeping up its
    /// neighbour); the hand said otherwise on the first day of use. A card is 124 pt wide in a
    /// narrow column, so asking for the whole of it means aiming AROUND it, and a rectangle one has
    /// to draw wider than the thing one wants is not a rectangle one aims — while what a brushed
    /// neighbour costs is one ⌘+click. So the two rules of this file agree now, and the only
    /// difference left between them is where the rectangle comes from.
    ///
    /// `rect` is taken standardised, so a rectangle drawn upwards or leftwards reads the same; a
    /// flat one (no width or no height) takes nothing, which is what a click that never travelled
    /// should do — and it is stated rather than left to `intersects`, which answers false for an
    /// empty rectangle by its own rule and not by ours.
    static func touching(_ rect: CGRect, cards: [Card]) -> [UUID] {
        let r = rect.standardized
        guard r.width > 0, r.height > 0 else { return [] }
        return cards.filter { r.intersects($0.frame) }.map(\.id)
    }

    /// ⇧+click GROWS the selection to the box that holds what was already taken plus the card
    /// aimed at, and everything that box touches comes with it. Word for word the clips' rule
    /// (@see TimelineView.extendSelectionTo, which spans lane × time the same way) rather than a
    /// range along the chain: the signal view is a canvas, branches run side by side on it, and a
    /// hand that draws a diagonal across two branches means the two.
    ///
    /// Intersection here as in the marquee above, and for this one it was never in doubt: the box
    /// is DEDUCED from cards, so its edges fall ON them and never around them — containment would
    /// have dropped the two cards it is drawn FROM.
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
