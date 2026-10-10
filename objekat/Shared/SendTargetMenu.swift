import Foundation

// The "Send to…" menu (INC 2, step 2.11, docs/plan_sends_rework.md §A.j): PURE. The view-model hands it
// the auxes the sender can reach, each with its offer tier (@see BridgeScope.SendIndex.offerTier), the
// plan's refusal if any (already worded) and whether a send to it already exists; it answers the menu's
// sections, in the order of Q-U3 — the auxes of the sender's own group, then the rest of its stem, then
// those of the Main — with the refused and the already-used ones greyed AND SAYING WHY. The last line
// of the menu ("Choose an object on the timeline…") is the view's.

enum SendTargetMenu {

    struct Candidate: Equatable {
        let id: UUID
        let name: String
        /// 0 = the sender's own level (same group / same stem), 1 = elsewhere in its stem, 2 = the Main.
        let tier: Int
        /// The plan's refusal, as a sentence (nil = it would be accepted).
        let refusal: String?
        /// A send from this sender to this aux already exists (one per pair).
        let alreadySending: Bool
    }

    struct Entry: Equatable {
        let id: UUID
        let name: String
        /// nil = enabled; otherwise the entry is greyed and this is its tooltip.
        let disabledReason: String?
        var isEnabled: Bool { disabledReason == nil }
    }

    struct Section: Equatable {
        let tier: Int
        /// The catalogue key of the section's title.
        let titleKey: String
        let entries: [Entry]
    }

    static func titleKey(tier: Int) -> String {
        switch tier {
        case 0:  return "send.menu.tier.group"
        case 1:  return "send.menu.tier.stem"
        default: return "send.menu.tier.main"
        }
    }

    /// The sections, in tier order; inside a tier the candidates keep the order they came in (the
    /// project's own order). A tier with nothing in it has no section.
    static func sections(_ candidates: [Candidate], alreadySendingReason: String) -> [Section] {
        var out: [Section] = []
        for tier in 0...2 {
            let inTier = candidates.filter { min(max($0.tier, 0), 2) == tier }
            guard !inTier.isEmpty else { continue }
            let entries = inTier.map { c in
                Entry(id: c.id, name: c.name,
                      disabledReason: c.refusal ?? (c.alreadySending ? alreadySendingReason : nil))
            }
            out.append(Section(tier: tier, titleKey: titleKey(tier: tier), entries: entries))
        }
        return out
    }

    /// True if the menu has at least one entry that can be picked.
    static func hasEnabledEntry(_ sections: [Section]) -> Bool {
        sections.contains { $0.entries.contains(where: \.isEnabled) }
    }
}
