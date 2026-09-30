import Foundation

// The names of the files a REGIONS export writes — the arithmetic, with no model behind it.
//
// Same reason as `ComposedName` / `SendColumns`: it is the half of the feature that depends on
// nothing (no view, no engine, no view-model, no localisation), so it can be compiled alone and
// asserted with no screen. @see tools/test_region_export_naming.swift
//
// Three rules, and the order they are applied in is part of the contract:
//   1. a region's name is SANITISED for the file system (no `/` `:` `\`, no control character, no
//      leading dot — a dotted name would hide the file, and `.objekat-export-…` is the export's own
//      working-file prefix — trimmed, and bounded in characters AND in bytes);
//   2. what is left EMPTY takes a fallback name (the caller's `Region <n>`, localised);
//   3. names that still COLLIDE take ` (2)`, ` (3)`… in the order they are given — which is the
//      regions' START-TIME order, so the same project always gives the same files. A collision is
//      tested case-insensitively and on the canonical form of the text, because APFS (the default
//      volume) is insensitive to both: "Verse" and "verse" would otherwise overwrite each other.

enum RegionExportNaming {

    /// Characters kept from a name. A file name is cut well before the file system's own limit: a
    /// region named with a whole sentence should still give a file one can read in a Finder column.
    static let maxCharacters = 100
    /// The bytes kept (UTF-8). The file systems allow 255 per component; ` (99)` and the extension
    /// are left room for.
    static let maxBytes = 200

    /// A region's name made safe to be a file's name. May return "" (a name that was only made of
    /// what is removed) — the caller then falls back.
    static func sanitise(_ raw: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\\" { continue }
            if CharacterSet.controlCharacters.contains(scalar) { continue }
            if CharacterSet.newlines.contains(scalar) { continue }
            kept.append(scalar)
        }
        var s = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > maxCharacters { s = String(s.prefix(maxCharacters)) }
        while s.utf8.count > maxBytes { s.removeLast() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a file name is compared by when looking for a collision.
    static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// One file name, and what happened to get it.
    struct Assigned: Equatable {
        /// The name without its extension.
        var base: String
        /// The region had no usable name: `base` is the fallback.
        var usedFallback: Bool
        /// Another file of the batch already had this name: `base` carries a suffix.
        var wasDeduplicated: Bool
    }

    /// Assigns a file name to each region, in the order given (the start-time order).
    /// - Parameters:
    ///   - names: the regions' own names, as typed.
    ///   - numbers: each region's number for the fallback — its place among ALL the project's
    ///     regions, not among the selected ones, so a fallback name does not change when another
    ///     region is ticked. Same length as `names`.
    ///   - fallback: makes the fallback name from a number ("Region 3").
    static func assign(names: [String], numbers: [Int],
                       fallback: (Int) -> String) -> [Assigned] {
        precondition(names.count == numbers.count)
        var taken = Set<String>()
        var out: [Assigned] = []
        out.reserveCapacity(names.count)
        for (i, raw) in names.enumerated() {
            var base = sanitise(raw)
            var usedFallback = false
            if base.isEmpty {
                usedFallback = true
                base = sanitise(fallback(numbers[i]))
                if base.isEmpty { base = "Region \(numbers[i])" }
            }
            var candidate = base
            var n = 1
            while taken.contains(collisionKey(candidate)) {
                n += 1
                candidate = "\(base) (\(n))"
            }
            taken.insert(collisionKey(candidate))
            out.append(Assigned(base: candidate, usedFallback: usedFallback,
                                wasDeduplicated: n > 1))
        }
        return out
    }
}
