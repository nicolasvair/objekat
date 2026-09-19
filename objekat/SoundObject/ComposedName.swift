import Foundation

// MARK: - The name a group gives itself
//
// A group with no name of its own used to be called "Group", which says what it IS and never
// which one it is — in a project with thirty of them, thirty rows carrying the same word. It
// names itself after what it CONTAINS instead: `Kick + Snare + Hat`.
//
// Everything here is pure arithmetic on strings, which is why it is a unit of its own rather than
// a private helper of `SoundObject`: it is the half of the feature with nothing behind it — no
// model, no view, no engine — so it can be compiled alone and asserted with no screen
// (`tools/test_composed_name.swift`), exactly as `PathRelink`, `SendColumns`, `SynopticMarquee`
// and `PianoRollFraming` are.
//
// THE MANUAL NAME ALWAYS WINS. None of this is reached when `label != nil`: a name somebody typed
// is a decision, and a decision is not recomputed. @see `SoundObject.displayName`, the one door.
enum ComposedName {

    /// The whole name never exceeds this. Fifty characters is about what a 240 pt panel shows at
    /// 10 pt, and a name band in the timeline shows less — past this the tail is not read, it is
    /// merely carried about.
    static let totalBudget = 50
    /// Beyond this many children the list stops and counts. Five names plus a count is a thing one
    /// reads at a glance; eight names of six characters each is a thing one deciphers.
    static let maxItems = 5
    static let separator = " + "

    /// Builds a name out of the parts, longest-lived rule first: keep every part whole if they
    /// fit, crop them fairly if they do not, and count the ones left out.
    ///
    /// `parts` arrives in the order the caller wants it read — for a group, the highest lane
    /// downwards (@see `SoundObject.composedGroupName`), because that is the order the eye takes
    /// a stack of lanes in.
    static func from(_ parts: [String]) -> String {
        let cleaned = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                           .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "" }

        let shown = Array(cleaned.prefix(maxItems))
        let hidden = cleaned.count - shown.count
        // The overflow mark is counted BEFORE the names are cropped, not added to a finished
        // string: a suffix appended afterwards is a suffix that pushes the total past its budget,
        // which is the one thing the budget is for.
        let suffix = hidden > 0 ? " +\(hidden)" : ""
        let room = max(0, totalBudget - suffix.count - separator.count * (shown.count - 1))

        // A part `fitted` had to drop (no room for even one character and an ellipsis) is taken
        // out rather than joined as an empty string, which would leave a dangling " + " naming
        // nothing. With a budget of 50 and at most 5 names this cannot arise today; it is guarded
        // because the two constants above are exactly the sort of thing a later session retunes.
        let kept = fitted(shown, into: room).filter { !$0.isEmpty }
        return kept.joined(separator: separator) + suffix
    }

    /// Shares `room` characters between `parts`, giving back what the short ones do not use.
    ///
    /// The even split (`room / n`) is the floor and not the rule. A name shorter than its share
    /// hands the remainder back, and the surplus goes round again to those still over their
    /// share — so `Kick`, which needs four of its ten, pays for `Contrabass_ambiance`, which
    /// needs more. The alternative, cropping every part at `room / n` whatever it is, spends the
    /// budget on blanks and cuts names it had the room to keep whole.
    ///
    /// It repeats until nothing more can be given back, rather than sharing out once: one pass
    /// leaves the second-longest name cropped while the budget freed by the shortest sits unused.
    /// It terminates because every pass either settles at least one part or changes nothing at
    /// all, and a settled part is never reopened.
    static func fitted(_ parts: [String], into room: Int) -> [String] {
        guard !parts.isEmpty else { return [] }
        let lengths = parts.map { $0.count }
        guard lengths.reduce(0, +) > room else { return parts }   // they all fit: nothing to do

        // `settled[i]` = this part is short enough to keep whole, and its length is final.
        var settled = [Bool](repeating: false, count: parts.count)
        var budget = room
        var claimants = parts.count

        while claimants > 0 {
            let share = budget / claimants
            // Those at or under their share are settled, and what they leave goes back into the
            // pot for the next pass.
            let giving = lengths.indices.filter { !settled[$0] && lengths[$0] <= share }
            if giving.isEmpty { break }
            for i in giving {
                settled[i] = true
                budget -= lengths[i]
                claimants -= 1
            }
        }

        // What is left over is split between the parts still too long. The remainder of that
        // division goes to the FIRST of them rather than being dropped, so the budget is spent to
        // the character and the result does not depend on the order twice over.
        let share = claimants > 0 ? budget / claimants : 0
        var extra = claimants > 0 ? budget % claimants : 0

        return parts.indices.map { i in
            if settled[i] { return parts[i] }
            var allowed = share
            if extra > 0 { allowed += 1; extra -= 1 }
            return truncated(parts[i], to: allowed)
        }
    }

    /// `text` cut to `limit` characters INCLUDING the ellipsis, which is what makes the budget
    /// arithmetic above honest — a "…" added on top of a limit is a character over it.
    ///
    /// Under two characters there is no room for a name and an ellipsis both, and a lone "…"
    /// says less than nothing in a list of names: the part is dropped instead, and the caller
    /// sees one fewer name rather than a row of dots.
    static func truncated(_ text: String, to limit: Int) -> String {
        if text.count <= limit { return text }
        guard limit >= 2 else { return "" }
        return String(text.prefix(limit - 1)) + "…"
    }
}
