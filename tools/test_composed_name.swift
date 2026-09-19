// The name a group gives itself — the arithmetic, asserted with no screen.
//
// `ComposedName` depends on nothing at all, which is why it is a unit of its own: it is the half
// of the feature with no model, no view and no engine behind it. What is pinned down below is the
// budget — that the total never exceeds 50 characters WHATEVER the input, which is the one
// property a name band and a 240 pt panel actually rely on — and the redistribution, which is the
// thing that would silently degrade into a rigid 50/N without anybody noticing on screen.
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/ComposedName.swift test_composed_name.swift \
//         -o /tmp/composedname && /tmp/composedname
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
struct TestComposedName {
  static func main() {
    // ── Nothing to say ───────────────────────────────────────────────────────────────────────────
    check("no parts, no name", ComposedName.from([]).isEmpty)
    check("blank parts are not names", ComposedName.from(["", "   ", "\n"]).isEmpty)

    // ── They fit: nothing is touched ─────────────────────────────────────────────────────────────
    check("one short name is itself", ComposedName.from(["Kick"]) == "Kick")
    check("three short names, joined and whole",
          ComposedName.from(["Kick", "Snare", "Hat"]) == "Kick + Snare + Hat",
          ComposedName.from(["Kick", "Snare", "Hat"]))
    check("surrounding space is not part of a name",
          ComposedName.from(["  Kick  ", " Snare "]) == "Kick + Snare")

    // ── The overflow mark COUNTS, and says how many ──────────────────────────────────────────────
    let six = ComposedName.from(["Kick", "Snare", "Hat", "Clap", "Tom", "Ride"])
    check("past five items it counts the rest", six.hasSuffix(" +1"), six)
    check("…and shows exactly five", six.components(separatedBy: " + ").count == 5, six)
    let twenty = ComposedName.from((1...20).map { "Take\($0)" })
    check("twenty items still show five and count fifteen", twenty.hasSuffix(" +15"), twenty)

    // ── THE BUDGET — the property everything else exists to protect ──────────────────────────────
    // Whatever is thrown at it, the result fits. A name band that can be overrun by one pathological
    // project is a name band that cannot be laid out at all.
    var worstSeen = 0
    for n in 1...12 {
        for len in [1, 3, 8, 15, 40, 120] {
            let parts = (0..<n).map { String(repeating: "x", count: len) + "\($0)" }
            let out = ComposedName.from(parts)
            worstSeen = max(worstSeen, out.count)
            if out.count > ComposedName.totalBudget {
                check("budget held for n=\(n) len=\(len)", false, "\(out.count): \(out)")
            }
        }
    }
    check("the budget holds over every shape tried (worst \(worstSeen)/50)",
          worstSeen <= ComposedName.totalBudget)

    // A single enormous name is cropped to the budget, ellipsis INCLUDED — not budget + 1.
    let huge = ComposedName.from([String(repeating: "z", count: 400)])
    check("one huge name is cut to the budget exactly", huge.count == ComposedName.totalBudget, "\(huge.count)")
    check("…and says it was cut", huge.hasSuffix("…"))

    // ── The redistribution, which is the whole point of the chosen rule ──────────────────────────
    // Five items, budget 50 − 4×3 = 38, so an even share of 7. `Kick` (4) and `Hat` (3) are under
    // their share and hand back 7 characters between them; the long one must therefore come out
    // LONGER than the rigid share, which is exactly what the even split would never give it.
    let mixed = ComposedName.from(["Kick", "Snare", "Hat", "Clap", "Contrabass_ambiance"])
    check("the short names are kept whole",
          mixed.contains("Kick") && mixed.contains("Hat") && mixed.contains("Clap"), mixed)
    let longPart = mixed.components(separatedBy: " + ").last ?? ""
    check("the long one is given the room the short ones did not use",
          longPart.count > 7, "\(longPart.count): \(longPart)")
    check("and the whole still fits", mixed.count <= ComposedName.totalBudget, "\(mixed.count)")

    // Nobody is cropped when everybody fits, even at five items.
    let fiveShort = ComposedName.from(["Kick", "Snare", "Hat", "Clap", "Tom"])
    check("five short names are all whole", fiveShort == "Kick + Snare + Hat + Clap + Tom", fiveShort)
    check("…and no ellipsis is invented", !fiveShort.contains("…"))

    // ── `fitted` on its own ──────────────────────────────────────────────────────────────────────
    check("everything fits: handed back untouched",
          ComposedName.fitted(["ab", "cd"], into: 10) == ["ab", "cd"])
    check("a short part never grows",
          ComposedName.fitted(["a", "bbbbbbbbbb"], into: 8) == ["a", "bbbbbb…"],
          String(describing: ComposedName.fitted(["a", "bbbbbbbbbb"], into: 8)))
    let evenlyLong = ComposedName.fitted(["aaaaaa", "bbbbbb"], into: 8)
    check("two equally long parts split the room",
          evenlyLong.map(\.count).reduce(0, +) <= 8, String(describing: evenlyLong))
    // The odd character goes to the first rather than being dropped: the budget is spent to the end.
    let odd = ComposedName.fitted(["aaaaaaaa", "bbbbbbbb"], into: 9)
    check("an odd budget is spent, not rounded away",
          odd.map(\.count).reduce(0, +) == 9, String(describing: odd))

    // ── `truncated`, where the ellipsis is INSIDE the limit ──────────────────────────────────────
    check("a short text is not touched", ComposedName.truncated("abc", to: 10) == "abc")
    check("exactly at the limit is not touched", ComposedName.truncated("abcde", to: 5) == "abcde")
    check("one over is cut with an ellipsis", ComposedName.truncated("abcdef", to: 5) == "abcd…")
    check("the ellipsis counts towards the limit", ComposedName.truncated("abcdef", to: 5).count == 5)
    check("no room for a name and an ellipsis: nothing", ComposedName.truncated("abcdef", to: 1) == "")
    check("two is the smallest that can say it was cut",
          ComposedName.truncated("abcdef", to: 2) == "a…")

    // ── Reproducibility: the same input gives the same name, twice ───────────────────────────────
    let a = ComposedName.from(["Kick", "Snare", "Contrabass_ambiance", "Hat", "Clap", "Tom"])
    let b = ComposedName.from(["Kick", "Snare", "Contrabass_ambiance", "Hat", "Clap", "Tom"])
    check("a name does not change between two readings", a == b, "\(a) / \(b)")

    print("")
    if fails.isEmpty {
        print("\(total) assertions, all pass")
        exit(0)
    } else {
        print("\(fails.count) FAILURE(S) out of \(total):")
        fails.forEach { print("  - " + $0) }
        exit(1)
    }

  }
}
