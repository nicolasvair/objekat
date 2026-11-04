import AppKit
import Carbon   // TIS* / UCKeyTranslate: an Apple system framework, so the AGPL rule is unaffected

/// The keyboard layout in use, as the « Computer Keyboard » input needs it: a NAME (AZERTY, QWERTY, or the
/// layout's own name when it is neither) and the letter each PHYSICAL key types, for the tooltips that name the
/// real keys. The decision (which family does this top row spell?) is pure and lives in `KeyboardLayoutName`.
///
/// Refreshed at creation and whenever the system says the selected input source changed (the menu bar's
/// switcher), so a name read through observation renames itself live. Nothing is polled.
@MainActor @Observable
final class KeyboardLayoutWatcher {
    static let shared = KeyboardLayoutWatcher()

    /// The name to show; nil when the layout cannot be read (the callers then fall back on the plain name).
    private(set) var name: String?
    private(set) var family: KeyboardLayoutFamily?
    /// keyCode → the character that key types, lowercased, for every key the computer keyboard input uses.
    private var characters: [UInt16: String] = [:]

    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        refresh()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// What the « Computer Keyboard » input is called on screen: « Clavier AZERTY » / « QWERTY keyboard »…, or the
    /// plain localised name when the layout could not be read. The one place that decides it (the Inputs panel,
    /// the synoptic's menu, the zones' names, the API); the internal name `Computer Keyboard` stays the contract.
    var inputDisplayName: String {
        name.map { L("midi.computer_keyboard.layout", $0) } ?? L("midi.computer_keyboard")
    }

    /// The key's character in capitals as the tooltips write it, or "?" when the layout does not give one.
    func label(forKeyCode keyCode: UInt16) -> String {
        characters[keyCode]?.uppercased() ?? "?"
    }

    /// Re-reads the layout. Published properties are only written when they change (they are observed).
    func refresh() {
        let read = Self.readLayout()
        let topRow = KeyboardLayoutName.topRowKeyCodes.map { read.characters[$0] ?? "" }.joined().lowercased()
        let newFamily = KeyboardLayoutName.family(topRow: topRow)
        let newName = KeyboardLayoutName.displayName(family: newFamily, localizedLayoutName: read.localizedName)
        if newFamily != family { family = newFamily }
        if newName != name { name = newName }
        if read.characters != characters { characters = read.characters }
    }

    // MARK: Reading the system

    /// The keyCodes whose character is wanted: the six of the family test and every key the input uses.
    private static var wantedKeyCodes: Set<UInt16> {
        Set(KeyboardLayoutName.topRowKeyCodes)
            .union(ComputerKeyboardMap.noteOffsets.keys)
            .union([ComputerKeyboardMap.octaveDownKeyCode, ComputerKeyboardMap.octaveUpKeyCode])
    }

    private static func readLayout() -> (localizedName: String?, characters: [UInt16: String]) {
        var source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        // An input method (Japanese, Chinese…) has no layout data of its own: its ASCII-capable layout stands in.
        if TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) == nil {
            source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        }
        var localizedName: String?
        if let rawName = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
            localizedName = Unmanaged<CFString>.fromOpaque(rawName).takeUnretainedValue() as String
        }
        guard let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return (localizedName, [:])
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return (localizedName, [:]) }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var result: [UInt16: String] = [:]
        for keyCode in wantedKeyCodes {
            var deadKeys: UInt32 = 0
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKeys, buffer.count, &length, &buffer)
            guard status == noErr, length > 0 else { continue }
            result[keyCode] = String(utf16CodeUnits: buffer, count: length).lowercased()
        }
        // `source` must outlive every read of its layout data: the reads end here.
        withExtendedLifetime(source) {}
        return (localizedName, result)
    }
}
