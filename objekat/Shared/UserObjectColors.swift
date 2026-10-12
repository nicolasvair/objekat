import Foundation

// MARK: - The colours the hand added to the object menu

/// The ordered list of colours added through the "+" of an object's colour menu, after the seven
/// base ones (@see `ObjectColorChoice`). It is the APP's memory, not the project's — a colour one
/// likes is wanted in every session — kept in `UserDefaults` as a flat array of "#RRGGBB" strings
/// under `objectColors.custom`, in the order they were added. A project never carries the list,
/// only the colour an object really has (`SoundObject.colorHex`).
///
/// A colour is never added twice, and never when it is one of the seven base colours. There is no
/// way to remove one in this version.
///
/// A test never touches the real domain: under `--no-recent` or `--headless` the list lives in a
/// variable that dies with the process (same discretion as `ScriptPanelMemory`). The behaviour is
/// identical, so a scenario can still assert it.
enum UserObjectColors {

    static let defaultsKey = "objectColors.custom"

    static var isEphemeral: Bool {
        let a = LaunchArguments.process
        return a.noRecentProjects || a.headless
    }

    nonisolated(unsafe) private static var ephemeral: [String] = []

    /// The added colours, 0xRRGGBB, in the order they were added. Anything in the stored list that
    /// does not parse, repeats, or is a base colour is dropped on reading.
    static func load() -> [Int] {
        let raw: [String]
        if isEphemeral { raw = ephemeral }
        else { raw = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [] }
        var out: [Int] = []
        for text in raw {
            guard let v = ObjectColorChoice.parse(text), let next = ObjectColorChoice.adding(v, to: out) else { continue }
            out = next
        }
        return out
    }

    /// Appends `rgb` to the list. Returns false (and writes nothing) if it was already offered.
    @discardableResult
    static func add(_ rgb: Int) -> Bool {
        guard let next = ObjectColorChoice.adding(rgb, to: load()) else { return false }
        save(next)
        return true
    }

    /// Test door: forgets every added colour.
    static func reset() { save([]) }

    private static func save(_ list: [Int]) {
        let text = list.map(ObjectColorChoice.format)
        if isEphemeral { ephemeral = text }
        else if text.isEmpty { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        else { UserDefaults.standard.set(text, forKey: defaultsKey) }
    }
}
