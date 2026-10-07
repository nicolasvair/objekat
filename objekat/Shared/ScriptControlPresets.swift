import Foundation

// MARK: - A number that is chosen among a few values: `presets` (revision 6b)

// A `number` control may declare `presets` — an ordered list of the only values it can hold. The form then
// draws a row of buttons (one selected at a time, like a segmented control) instead of a slider, and every
// door a value comes in by — the hand, a script's `update`, an `input` command, a remembered value, a restored
// step setting — SNAPS what it is given to the nearest preset. The value stays a plain number everywhere (in
// `values`, in a step's `params`, in the memory), so a script reads it as it always did; `min`/`max` stay the
// range of the declaration (the presets lie within it).
//
// A pure rule on `Double`s, with no model and no JSON behind it, so it can be compiled alone and asserted
// (@see tools/test_script_control_presets.swift). `nonisolated`: the project defaults to MainActor.

nonisolated enum ScriptControlPresets {

    /// The preset nearest to `v`; on a tie, the one that comes FIRST in the list (so, in an ascending list,
    /// the lower). A non-finite `v` has no nearest: nil. nil also for an empty list.
    static func nearest(_ v: Double, in presets: [Double]) -> Double? {
        guard v.isFinite, var best = presets.first else { return nil }
        var bestDistance = abs(v - best)
        for p in presets.dropFirst() {
            let d = abs(v - p)
            if d < bestDistance { best = p; bestDistance = d }
        }
        return best
    }

    /// Why a declared list is not acceptable, or nil when it is: at least one preset, every one finite,
    /// inside `min…max`, no duplicate.
    static func problem(_ presets: [Double], min: Double, max: Double) -> String? {
        if presets.isEmpty { return "presets must hold at least one number" }
        for p in presets {
            if !p.isFinite { return "a preset is not a finite number" }
            if p < min || p > max { return "preset \(p) is outside min…max" }
        }
        if Set(presets).count != presets.count { return "presets must be distinct" }
        return nil
    }

    /// The text of a preset's button: the number alone (the unit is the row's), a true minus sign, an
    /// explicit plus for a positive one — "−60", "0", "+3", "−0.5".
    static func label(_ v: Double) -> String {
        let isWhole = v == v.rounded()
        let body = isWhole ? String(format: "%.0f", abs(v)) : String(format: "%g", abs(v))
        if v < 0 { return "\u{2212}" + body }
        if v > 0 { return "+" + body }
        return body
    }
}
