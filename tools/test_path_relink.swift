// Relinking a path — the arithmetic, asserted with no screen.
//
// `PathRelink` depends on nothing at all, which is the whole reason it is a unit of its own: it is
// the half of the relink that never touches the disk, the model or a view. Two things are pinned
// down below, and both of them are places where being approximately right is worse than refusing.
//
// LEARNING a prefix from one repaired path is what makes the propagation possible — accidents come
// by packets, and a renamed drive loses every file under one root at once. APPLYING it must match
// on a COMPONENT BOUNDARY: a raw `hasPrefix` would read `/Users/n/Sons2` as living inside
// `/Users/n/Sons` and would rewrite, silently, the paths of a folder nobody named. And the RANKING
// must be reproducible, because a list that comes back in another order is a list in which one
// cannot find again what one was just looking at.
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/PathRelink.swift test_path_relink.swift \
//         -o /tmp/pathrelink && /tmp/pathrelink
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

@main
enum PathRelinkTest {
  static func main() {

    typealias Sub = PathRelink.Substitution
    typealias Cand = PathRelink.Candidate

    // MARK: - What a repaired path teaches
    //
    // The two paths are compared by components and the longest COMMON SUFFIX is taken away: what
    // the move did not touch says nothing, what is left on each side is the rule.

    check("a drive renamed teaches its root",
          PathRelink.learnedSubstitution(from: "/Volumes/A/s/x/bell.wav",
                                         to:   "/Users/n/Sons/x/bell.wav")
            == Sub(from: "/Volumes/A/s", to: "/Users/n/Sons"))

    check("the two roots need not be the same depth",
          PathRelink.learnedSubstitution(from: "/Volumes/SSD_A/sessions/2026/day1/take.wav",
                                         to:   "/Users/n/Sons/day1/take.wav")
            == Sub(from: "/Volumes/SSD_A/sessions/2026", to: "/Users/n/Sons"))

    check("…nor the same way round",
          PathRelink.learnedSubstitution(from: "/a/bell.wav",
                                         to:   "/x/y/z/bell.wav")
            == Sub(from: "/a", to: "/x/y/z"))

    // The suffix is taken as far as it goes. `Sons` recurs on both sides, so stopping at the first
    // directory would teach `/Volumes/Sons` → `/Users/n/Sons` — true of this file and of nothing
    // else, where the rule below holds for every sibling it has.
    check("the common suffix is the LONGEST one",
          PathRelink.learnedSubstitution(from: "/Volumes/Sons/x/bell.wav",
                                         to:   "/Users/n/Sons/x/bell.wav")
            == Sub(from: "/Volumes", to: "/Users/n"),
          "a component recurring deeper must not stop the walk")

    // The limit case: the shared suffix covers the WHOLE of one side, so there is no prefix left
    // to learn there. The rule would be "" → something, which matches every path in the session.
    check("a suffix covering all of the old path teaches nothing",
          PathRelink.learnedSubstitution(from: "/x/bell.wav",
                                         to:   "/Users/n/x/bell.wav") == nil)
    check("…and all of the new one, no more",
          PathRelink.learnedSubstitution(from: "/Users/n/x/bell.wav",
                                         to:   "/x/bell.wav") == nil)

    check("nothing in common at all teaches nothing",
          PathRelink.learnedSubstitution(from: "/a/b/bell.wav",
                                         to:   "/c/d/ring.wav") == nil)
    // Same folder, another name: that is a REPLACEMENT and not a repair, and a replacement never
    // propagates — one deliberate gesture on one object.
    check("a different file name teaches nothing either",
          PathRelink.learnedSubstitution(from: "/a/b/one.wav",
                                         to:   "/a/b/two.wav") == nil)

    check("the same path twice teaches nothing",
          PathRelink.learnedSubstitution(from: "/a/b/c.wav", to: "/a/b/c.wav") == nil)
    check("an empty old path teaches nothing",
          PathRelink.learnedSubstitution(from: "", to: "/a/b/c.wav") == nil)
    check("an empty new path teaches nothing",
          PathRelink.learnedSubstitution(from: "/a/b/c.wav", to: "") == nil)

    check("a relative pair stays relative",
          PathRelink.learnedSubstitution(from: "a/b/bell.wav", to: "c/bell.wav")
            == Sub(from: "a/b", to: "c"),
          "components cannot tell a/b from /a/b — the leading slash is carried, not deduced")

    // MARK: - Applying it to the next missing path

    let sub = Sub(from: "/Volumes/A/s", to: "/Users/n/Sons")

    check("the path it was learned from",
          PathRelink.applying(sub, to: "/Volumes/A/s/x/bell.wav") == "/Users/n/Sons/x/bell.wav")
    check("a sibling under the same root — the whole point of propagating",
          PathRelink.applying(sub, to: "/Volumes/A/s/y/ring.wav") == "/Users/n/Sons/y/ring.wav")
    check("a path under another root is refused",
          PathRelink.applying(sub, to: "/Volumes/B/s/x/bell.wav") == nil)
    check("a path shorter than the prefix is refused",
          PathRelink.applying(sub, to: "/Volumes/A") == nil)
    check("a path that IS the prefix becomes the new root",
          PathRelink.applying(sub, to: "/Volumes/A/s") == "/Users/n/Sons")

    // The trap: on the raw characters, `/Users/n/Sons` is a prefix of `/Users/n/Sons2`.
    let subSons = Sub(from: "/Users/n/Sons", to: "/Volumes/X")
    check("Sons2 is NOT inside Sons",
          PathRelink.applying(subSons, to: "/Users/n/Sons2/bell.wav") == nil,
          "a hasPrefix on the string would rewrite a folder nobody named")
    check("…while Sons itself still matches",
          PathRelink.applying(subSons, to: "/Users/n/Sons/bell.wav") == "/Volumes/X/bell.wav")

    check("a trailing slash on the new root says nothing",
          PathRelink.applying(Sub(from: "/a", to: "/b/"), to: "/a/c.wav") == "/b/c.wav")

    // Absoluteness is part of the match: a relative root is not the absolute one spelling the same.
    let subRel = Sub(from: "a/b", to: "c")
    check("a relative rule does not claim an absolute path",
          PathRelink.applying(subRel, to: "/a/b/bell.wav") == nil)
    check("…and does claim the relative one",
          PathRelink.applying(subRel, to: "a/b/bell.wav") == "c/bell.wav")

    // Learned, then applied to the very pair it came from: the rule must at least explain itself.
    check("learn then apply is a round trip",
          PathRelink.learnedSubstitution(from: "/Volumes/A/s/x/bell.wav",
                                         to:   "/Users/n/Sons/x/bell.wav")
            .flatMap { PathRelink.applying($0, to: "/Volumes/A/s/x/bell.wav") }
            == "/Users/n/Sons/x/bell.wav")
    check("…and it carries the siblings with it",
          PathRelink.learnedSubstitution(from: "/Volumes/A/s/x/bell.wav",
                                         to:   "/Users/n/Sons/x/bell.wav")
            .flatMap { PathRelink.applying($0, to: "/Volumes/A/s/other/take.aif") }
            == "/Users/n/Sons/other/take.aif")

    // MARK: - How sure one can be of a candidate

    let sized = Cand(path: "/x/bell.wav", size: 1024)
    let unsized = Cand(path: "/x/bell.wav", size: nil)

    check("name and size both agree: certain",
          PathRelink.confidence(of: sized, name: "bell.wav", size: 1024) == .certain)
    // Same name, another size: a bounce made again outside, or a different take under a name that
    // recurs. Offered, because it is the file one came looking for as often as not — and offered
    // LAST, because relinking to the wrong file is silent.
    check("name agreeing and size not: possible, not dropped",
          PathRelink.confidence(of: sized, name: "bell.wav", size: 2048) == .possible)
    check("nothing recorded for the missing file: likely",
          PathRelink.confidence(of: sized, name: "bell.wav", size: nil) == .likely,
          "every session written before the size was stored looks like this")
    check("nothing readable for the candidate: likely",
          PathRelink.confidence(of: unsized, name: "bell.wav", size: 1024) == .likely)
    check("neither side known: likely",
          PathRelink.confidence(of: unsized, name: "bell.wav", size: nil) == .likely)
    check("the name is matched the way the file system matches it",
          PathRelink.confidence(of: Cand(path: "/x/Bell.WAV", size: 1024),
                                name: "bell.wav", size: 1024) == .certain,
          "Bell.wav and bell.wav in one folder ARE one file on macOS")
    check("the grades are ordered worst first",
          PathRelink.Confidence.certain > PathRelink.Confidence.likely
            && PathRelink.Confidence.likely > PathRelink.Confidence.possible)

    // MARK: - The order they are offered in

    let a = Cand(path: "/a/bell.wav", size: 1024)   // certain
    let b = Cand(path: "/b/bell.wav", size: nil)    // likely
    let c = Cand(path: "/c/bell.wav", size: 2048)   // possible
    let other = Cand(path: "/d/ring.wav", size: 1024)

    check("best first, and the wrong name is not offered at all",
          PathRelink.rank([other, c, b, a], name: "bell.wav", size: 1024) == [a, b, c])
    check("a list with nothing matching comes back empty",
          PathRelink.rank([other], name: "bell.wav", size: 1024) == [])

    // Equal confidence is broken by the path, so the same folder scanned twice offers the same
    // order twice — otherwise one cannot find again what one was just looking at.
    let z = Cand(path: "/z/bell.wav", size: 1024)
    let m = Cand(path: "/m/bell.wav", size: 1024)
    check("ties are broken alphabetically",
          PathRelink.rank([z, a, m], name: "bell.wav", size: 1024) == [a, m, z])
    check("…whatever order they arrived in",
          PathRelink.rank([m, z, a], name: "bell.wav", size: 1024) == [a, m, z])

    check("with no size to compare, they are all likely and read alphabetically",
          PathRelink.rank([c, a, b], name: "bell.wav", size: nil) == [a, b, c])

    // MARK: -

    print("")
    if fails.isEmpty {
        print("\(total) assertions, all pass")
        exit(0)
    } else {
        print("\(fails.count) FAILED: \(fails.joined(separator: " · "))")
        exit(1)
    }
  }
}
