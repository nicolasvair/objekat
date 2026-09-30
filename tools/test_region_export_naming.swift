// The file names of a REGIONS export — the arithmetic, asserted with no screen.
//
// `RegionExportNaming` depends on nothing (no view-model, no localisation: the fallback name is
// handed in as a closure), which is why it is a unit of its own. What is pinned down below is what
// a file system and a batch rely on: a name is always usable as a file name, two files of one batch
// never share a name (case and Unicode form included — APFS ignores both), and the same regions
// always give the same files.
//
//     swiftc -parse-as-library \
//         ../objekat/Export/RegionExportNaming.swift test_region_export_naming.swift \
//         -o /tmp/regionnaming && /tmp/regionnaming
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

func fallback(_ n: Int) -> String { "Region \(n)" }

func bases(_ names: [String]) -> [String] {
    RegionExportNaming.assign(names: names, numbers: (0..<names.count).map { $0 + 1 },
                              fallback: fallback).map(\.base)
}

@main
struct TestRegionExportNaming {
  static func main() {
    // ── Sanitising ───────────────────────────────────────────────────────────────────────────────
    check("a plain name is itself", RegionExportNaming.sanitise("Verse 1") == "Verse 1")
    check("slash, colon and backslash are stripped",
          RegionExportNaming.sanitise("a/b:c\\d") == "abcd", RegionExportNaming.sanitise("a/b:c\\d"))
    check("control characters are stripped",
          RegionExportNaming.sanitise("a\u{0}b\u{7}c\nd\te") == "abcde",
          RegionExportNaming.sanitise("a\u{0}b\u{7}c\nd\te"))
    check("surrounding space is trimmed", RegionExportNaming.sanitise("  Chorus \n") == "Chorus")
    check("a leading dot would hide the file", RegionExportNaming.sanitise("..hidden") == "hidden")
    check("only dots is nothing", RegionExportNaming.sanitise("...") == "")
    check("only forbidden characters is nothing", RegionExportNaming.sanitise(" / : \\ ") == "")
    check("an empty name is empty", RegionExportNaming.sanitise("") == "")
    check("accents and symbols survive", RegionExportNaming.sanitise("Été – 2ᵉ couplet") == "Été – 2ᵉ couplet")
    check("an inner dot survives", RegionExportNaming.sanitise("take 1.5") == "take 1.5")

    let long = String(repeating: "a", count: 300)
    check("a long name is cut to the character limit",
          RegionExportNaming.sanitise(long).count == RegionExportNaming.maxCharacters,
          "\(RegionExportNaming.sanitise(long).count)")
    let wide = String(repeating: "é", count: 150)   // 2 bytes each: 100 characters would be 200 bytes
    check("the byte limit holds", RegionExportNaming.sanitise(wide).utf8.count <= RegionExportNaming.maxBytes)
    let emoji = String(repeating: "🎵", count: 100) // 4 bytes each
    let cutEmoji = RegionExportNaming.sanitise(emoji)
    check("the byte limit holds for 4-byte characters",
          cutEmoji.utf8.count <= RegionExportNaming.maxBytes && cutEmoji.count == 50,
          "\(cutEmoji.count) chars / \(cutEmoji.utf8.count) bytes")

    // ── Assigning ────────────────────────────────────────────────────────────────────────────────
    check("distinct names are left alone",
          bases(["Intro", "Verse", "Chorus"]) == ["Intro", "Verse", "Chorus"])
    check("a duplicate takes (2), then (3), in the order given",
          bases(["Verse", "Verse", "Verse"]) == ["Verse", "Verse (2)", "Verse (3)"],
          bases(["Verse", "Verse", "Verse"]).joined(separator: "|"))
    check("case makes no difference to a collision",
          bases(["Verse", "verse"]) == ["Verse", "verse (2)"],
          bases(["Verse", "verse"]).joined(separator: "|"))
    // "é" as one scalar and as e + combining acute are the same name to the file system.
    let composed = "caf\u{E9}", decomposed = "cafe\u{301}"
    let nfc = RegionExportNaming.assign(names: [composed, decomposed], numbers: [1, 2], fallback: fallback)
    check("Unicode forms make no difference to a collision",
          nfc[1].wasDeduplicated && nfc[0].wasDeduplicated == false)
    check("a name that already looks like a suffix does not collide with a generated one",
          bases(["Verse", "Verse (2)", "Verse"]) == ["Verse", "Verse (2)", "Verse (3)"],
          bases(["Verse", "Verse (2)", "Verse"]).joined(separator: "|"))
    check("sanitising happens BEFORE the collision test",
          bases(["a/b", "ab"]) == ["ab", "ab (2)"], bases(["a/b", "ab"]).joined(separator: "|"))

    // ── Fallback ─────────────────────────────────────────────────────────────────────────────────
    let fb = RegionExportNaming.assign(names: ["", "  ", "/:"], numbers: [4, 7, 9], fallback: fallback)
    check("an empty name takes the fallback, with ITS number",
          fb.map(\.base) == ["Region 4", "Region 7", "Region 9"], fb.map(\.base).joined(separator: "|"))
    check("the fallback is flagged", fb.allSatisfy { $0.usedFallback })
    check("a real name is not flagged as a fallback",
          RegionExportNaming.assign(names: ["Verse"], numbers: [1], fallback: fallback)[0].usedFallback == false)
    let clash = RegionExportNaming.assign(names: ["Region 2", ""], numbers: [1, 2], fallback: fallback)
    check("a fallback can collide with a typed name and is then numbered",
          clash.map(\.base) == ["Region 2", "Region 2 (2)"], clash.map(\.base).joined(separator: "|"))
    check("the dedup flag is set on the renamed one only",
          clash[0].wasDeduplicated == false && clash[1].wasDeduplicated == true)
    check("a fallback closure that returns nothing still gives a name",
          RegionExportNaming.assign(names: [""], numbers: [3], fallback: { _ in "" })[0].base == "Region 3")

    // ── Reproducibility and uniqueness, over a sweep ─────────────────────────────────────────────
    let pool = ["", "A", "a", "A (2)", "B/C", "BC", "  ", "Z", "z (2)", "Z"]
    var allUnique = true
    var stable = true
    for n in 0...pool.count {
        let names = Array(pool.prefix(n))
        let nums = Array(0..<n).map { $0 + 1 }
        let first = RegionExportNaming.assign(names: names, numbers: nums, fallback: fallback).map(\.base)
        let second = RegionExportNaming.assign(names: names, numbers: nums, fallback: fallback).map(\.base)
        if first != second { stable = false }
        if Set(first.map(RegionExportNaming.collisionKey)).count != first.count { allUnique = false }
    }
    check("the same input gives the same files", stable)
    check("no two files of a batch share a name, whatever the input", allUnique)
    check("nothing in, nothing out", RegionExportNaming.assign(names: [], numbers: [], fallback: fallback).isEmpty)

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
