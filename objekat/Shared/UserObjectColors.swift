import Foundation

// MARK: - The object colour palette, as the hand edited it

/// The ordered palette of an object's colour menu — the seven base colours (@see `ObjectColorChoice`)
/// and the ones added through the "+", as ONE list the hand edits: the "+" appends a colour, ⌥ + click
/// on a swatch removes it (a base colour too), "Restore the default colours" goes back to the base row.
/// It is the APP's memory, not the project's — a palette one likes is wanted in every session — kept
/// in `UserDefaults` as an array of "#RRGGBB" strings under `objectColors.palette`.
///
/// WHY NO EDIT CAN EVER CHANGE AN OBJECT'S COLOUR: an object does not point INTO this list. It stores
/// its own colour as 0xRRGGBB (`SoundObject.colorHex`, written "#RRGGBB" in the session file); the old
/// pastels (`SoundObject.colorIndex`) index `ObjekatPalette.objects`, a FIXED table this list is not and
/// never touches. So removing, re-adding or reordering a swatch here only changes what the menu
/// OFFERS — every object, in this project or in any file opened later, keeps exactly the colour it had.
///
/// Until the hand edits it, there is no `objectColors.palette` key and the palette is the base row
/// followed by the first version's added colours (`objectColors.custom`, still read). The first edit
/// writes the whole list and drops the old key. An EMPTY palette is a legitimate state (every swatch
/// removed: only the "+" is left) and is stored as such.
///
/// A test never touches the real domain: under `--no-recent` or `--headless` the palette lives in a
/// variable that dies with the process (same discretion as `ScriptPanelMemory`). The behaviour is
/// identical, so a scenario can still assert it.
enum UserObjectColors {

    /// The palette as the hand edited it ("#RRGGBB", in order). Absent = never edited.
    static let paletteKey = "objectColors.palette"
    /// The first version's list (the colours added after the base row). Read, never written.
    static let defaultsKey = "objectColors.custom"

    static var isEphemeral: Bool {
        let a = LaunchArguments.process
        return a.noRecentProjects || a.headless
    }

    nonisolated(unsafe) private static var ephemeralPalette: [String]? = nil
    nonisolated(unsafe) private static var ephemeralCustom: [String] = []

    /// The palette offered, 0xRRGGBB, in order. Anything stored that does not parse or repeats is
    /// dropped on reading.
    static func load() -> [Int] {
        if let raw = storedPalette() { return parse(raw) }
        let custom = parse(storedCustom()).reduce(into: [Int]()) { out, v in
            if let next = ObjectColorChoice.adding(v, to: out) { out = next }
        }
        return ObjectColorChoice.defaultPalette(custom: custom)
    }

    /// True while the palette is the base row (nothing added, nothing removed, nothing moved).
    static var isDefault: Bool { load() == ObjectColorChoice.baseHex }

    /// Appends `rgb` at the end of the palette. Returns false (and writes nothing) if it is already there.
    @discardableResult
    static func add(_ rgb: Int) -> Bool {
        guard let next = ObjectColorChoice.palette(load(), appending: rgb) else { return false }
        save(next)
        return true
    }

    /// Removes `rgb` from the palette (a base colour as well). Returns false if it was not there.
    @discardableResult
    static func remove(_ rgb: Int) -> Bool {
        guard let next = ObjectColorChoice.palette(load(), removing: rgb) else { return false }
        save(next)
        return true
    }

    /// Back to the base row: the edited palette and the first version's list are both forgotten.
    static func resetToDefault() {
        if isEphemeral { ephemeralPalette = nil; ephemeralCustom = [] }
        else {
            UserDefaults.standard.removeObject(forKey: paletteKey)
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    /// Test door: the same as `resetToDefault`.
    static func reset() { resetToDefault() }

    // MARK: Storage

    private static func parse(_ raw: [String]) -> [Int] {
        var out: [Int] = []
        for text in raw {
            guard let v = ObjectColorChoice.parse(text), !out.contains(v) else { continue }
            out.append(v)
        }
        return out
    }

    private static func storedPalette() -> [String]? {
        isEphemeral ? ephemeralPalette : UserDefaults.standard.stringArray(forKey: paletteKey)
    }

    private static func storedCustom() -> [String] {
        isEphemeral ? ephemeralCustom : (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    private static func save(_ list: [Int]) {
        let text = list.map(ObjectColorChoice.format)
        if isEphemeral { ephemeralPalette = text; ephemeralCustom = [] }
        else {
            UserDefaults.standard.set(text, forKey: paletteKey)
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }
}
