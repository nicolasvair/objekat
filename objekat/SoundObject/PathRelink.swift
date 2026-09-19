import Foundation

// MARK: - Relinking a path — the arithmetic of it, and nothing else
//
// What a relink LEARNS from one repaired path, how it APPLIES what it learned to the next one, and
// how a candidate file is GRADED against the one that went missing. No view, no model, no disk:
// this unit never asks whether a file exists — it is handed paths and sizes and it answers with
// paths and grades, the existence check belonging to whoever calls it. It is a unit of its own for
// the reason `SendColumns` and `PianoRollFraming` are: it is the half of the relink that has
// nothing behind it, so it compiles alone and is asserted with no screen
// (@see tools/test_path_relink.swift).
//
// The rule the whole thing rests on: **accidents come by packets.** A session whose drive was
// renamed has not lost one file, it has lost every file under one root — so repairing the first
// one teaches a prefix, and that prefix is what is offered for the rest.
//
// And the rule it must never break: relinking to the WRONG file is worse than a missing file,
// because a missing file says so and a wrong one simply plays. Hence nothing here decides
// anything on its own — it proposes, in an order, and the worst of the proposals is still shown
// (@see `confidence`) rather than being dropped behind the user's back.

enum PathRelink {

    /// A prefix swap: every path starting with `from` (on a component boundary) is read under `to`.
    ///
    /// Hashable as well as Equatable because the propagation counts its candidates INTO a
    /// dictionary keyed by the substitution (@see `EditViewModel.resolvableByPropagation`), several
    /// missing paths being able to teach several different roots in one session.
    struct Substitution: Equatable, Hashable {
        let from: String
        let to: String
    }

    // MARK: - Learning a substitution from one repaired path

    /// What the pair (what was written in the session, what the user just pointed at) teaches.
    ///
    /// The two paths are compared BY COMPONENTS and the longest COMMON SUFFIX is taken away: what
    /// is left on each side is the substitution. `/Volumes/A/s/x/bell.wav` repaired to
    /// `/Users/n/Sons/x/bell.wav` teaches `/Volumes/A/s` → `/Users/n/Sons`, the `x/bell.wav` being
    /// the part the move did not touch and therefore the part that says nothing.
    ///
    /// The suffix is taken as far as it goes, not to the first directory: a root renamed under a
    /// folder whose name recurs deeper (`/Volumes/Sons/x/bell.wav` → `/Users/n/Sons/x/bell.wav`)
    /// teaches `/Volumes` → `/Users/n`, which is the substitution that actually holds for the
    /// file's siblings.
    ///
    /// `nil` — nothing GENERALISABLE was learned, and a substitution one cannot generalise is a
    /// propagation offered over nothing:
    /// - the two paths are the same, or either is empty;
    /// - no component at all is shared, not even the file name (the user pointed at a differently
    ///   named file, which is a REPLACEMENT and not a repair — two gestures, and only one of them
    ///   propagates);
    /// - the common suffix covers the WHOLE of one of the two paths. That is the limit case worth
    ///   spelling out: `/x/bell.wav` repaired to `/Users/n/x/bell.wav` shares everything the short
    ///   path has, so what is left on that side is nothing at all — the substitution would be
    ///   "" → `/Users/n`, i.e. a rule matching every path in the session. A rule that matches
    ///   everything explains nothing.
    static func learnedSubstitution(from old: String, to new: String) -> Substitution? {
        guard !old.isEmpty, !new.isEmpty, old != new else { return nil }

        let o = components(old)
        let n = components(new)

        var shared = 0
        while shared < o.count, shared < n.count,
              o[o.count - 1 - shared] == n[n.count - 1 - shared] {
            shared += 1
        }
        guard shared > 0 else { return nil }

        let oHead = o.prefix(o.count - shared)
        let nHead = n.prefix(n.count - shared)
        guard !oHead.isEmpty, !nHead.isEmpty else { return nil }

        return Substitution(from: join(oHead, absolute: old.hasPrefix("/")),
                            to:   join(nHead, absolute: new.hasPrefix("/")))
    }

    // MARK: - Applying it to the next missing path

    /// `path` read under the substitution, or `nil` if the substitution has nothing to say about it.
    ///
    /// **The match is on a COMPONENT BOUNDARY, never on the raw string** — that is the trap this
    /// function exists to close. A `hasPrefix` on the characters would match `/Users/n/Sons2` with
    /// the prefix `/Users/n/Sons`, and the propagation would then quietly rewrite the paths of a
    /// folder nobody named, into a place they were never in. `Sons2` is not inside `Sons`.
    ///
    /// Absoluteness has to agree for the same reason: components alone cannot tell `a/b` from
    /// `/a/b`, and a relative root is not the absolute one that happens to spell the same.
    ///
    /// The comparison is exact, case included. macOS's own file system is usually case-insensitive,
    /// so a substitution learned there will spell its root the way the user's own dialog spelled
    /// it — matching loosely here would only widen a rule the user never widened.
    static func applying(_ sub: Substitution, to path: String) -> String? {
        guard !path.isEmpty, !sub.to.isEmpty else { return nil }
        guard path.hasPrefix("/") == sub.from.hasPrefix("/") else { return nil }

        let from = components(sub.from)
        guard !from.isEmpty else { return nil }        // a rule matching everything is not a rule

        let p = components(path)
        guard p.count >= from.count else { return nil }
        for i in 0..<from.count {
            guard p[i] == from[i] else { return nil }
        }

        var out = components(sub.to)
        out.append(contentsOf: p.dropFirst(from.count))
        return join(out, absolute: sub.to.hasPrefix("/"))
    }

    // MARK: - Grading a candidate

    /// A file one COULD relink to: where it is, and how big it is when that could be read.
    struct Candidate: Equatable {
        let path: String
        let size: Int64?
    }

    /// How sure one can be that a candidate is the file that went missing. Ordered worst first, so
    /// the raw values ARE the ranking.
    enum Confidence: Int, Comparable {
        /// The name matches and the sizes do NOT — and the floor a candidate whose name matches
        /// nothing would land on, `rank` dropping it before that can be read as a proposal.
        /// Still offered when the name does match — see `confidence`.
        case possible
        /// The name matches and one of the two sizes is unknown.
        case likely
        /// The name matches and so does the size.
        case certain

        static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How a candidate grades against the missing file's `name` and `size` (`nil` = never recorded,
    /// which is what every session written before the size was stored looks like).
    ///
    /// **A name that matches with a size that does not is still offered, and offered LAST.** It is
    /// the ordinary shape of a sound re-exported outside — same name, one bounce later, a few
    /// kilobytes apart — so dropping it would hide the very file the user came looking for. But it
    /// is also the shape of a different take sitting under the same name in another folder, and
    /// relinking to THAT is silent: nothing turns red, nothing refuses, the session simply plays
    /// something else. So it stays in the list and it stays at the bottom of it, where a choice is
    /// made deliberately rather than by pressing return.
    ///
    /// A name that does not match at all is not graded here — there is nothing below `.possible`
    /// to grade it as, and dropping a candidate is `rank`'s business, not this function's. Read it
    /// as: this grades a candidate one has already decided is a candidate.
    static func confidence(of candidate: Candidate, name: String, size: Int64?) -> Confidence {
        guard matchesName(candidate.path, name) else { return .possible }
        guard let want = size, let have = candidate.size else { return .likely }
        return want == have ? .certain : .possible
    }

    /// The candidates worth showing, best first: those whose name matches at all, by decreasing
    /// confidence.
    ///
    /// **The order is TOTAL and therefore reproducible** — ties are broken by the path itself,
    /// alphabetically. Sorting on the confidence alone would leave equal candidates in whatever
    /// order the directory walk happened to produce, so the same folder scanned twice could offer
    /// the same two files the other way round, and the user would not find again what they had
    /// just been looking at. The tiebreak is the plain `<` of the strings rather than a localised
    /// comparison, for the same reason: it must not depend on who is running it.
    ///
    /// The name is compared case-insensitively (macOS's file system is, so `Bell.wav` and
    /// `bell.wav` in one folder ARE one file), and a candidate whose name matches nothing is
    /// dropped rather than shown last — a relink list one has to read past is a list nobody reads.
    static func rank(_ candidates: [Candidate], name: String, size: Int64?) -> [Candidate] {
        candidates
            .filter { matchesName($0.path, name) }
            .sorted { a, b in
                let ca = confidence(of: a, name: name, size: size)
                let cb = confidence(of: b, name: name, size: size)
                if ca != cb { return ca > cb }
                return a.path < b.path
            }
    }

    // MARK: - Paths, read as components

    /// A path's components, empties dropped — so a trailing slash and a doubled one say nothing,
    /// which is what a hand-typed or dialog-returned path needs.
    private static func components(_ path: String) -> [String] {
        path.split(whereSeparator: { $0 == "/" }).map(String.init)
    }

    /// The inverse, the leading slash being carried rather than deduced: components cannot tell an
    /// absolute path from a relative one, so whoever splits has to remember which it was.
    private static func join<S: Sequence>(_ parts: S, absolute: Bool) -> String
    where S.Element == String {
        (absolute ? "/" : "") + parts.joined(separator: "/")
    }

    private static func matchesName(_ path: String, _ name: String) -> Bool {
        guard let last = components(path).last else { return false }
        return last.caseInsensitiveCompare(name) == .orderedSame
    }
}
