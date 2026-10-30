import Foundation

// MARK: - The sound card's recording inputs, as the PROJECT knows them
//
// The engine describes the card's inputs (`Shared/OBJInputLayout.h`): one mono input per channel,
// one stereo input per declared pair of NEIGHBOURING channels. What the project owns is only the two
// things a person decides: which pairs exist, and what each input is called. Both are keyed by CHANNEL
// NUMBER and not by device (decision 3 of docs/plan_enregistrement_audio.md): a project opened on
// another card falls back on the same numbers, and an input the card no longer has is "absent", not
// forgotten.
//
// A plain Foundation unit with no model behind it, so it is compiled and asserted alone
// (tools/test_record_inputs_codable.swift).

/// One recording input of the card: a mono channel, or two neighbouring channels read as a stereo
/// pair. 0-BASED (`first` 0 is the card's channel 1); the screen and the names say 1-based.
struct InputRef: Codable, Hashable, Sendable, Comparable {
    var first: Int
    /// 1 = mono, 2 = stereo (`first`, `first + 1`).
    var count: Int

    init(first: Int, count: Int) {
        self.first = first
        self.count = count
    }

    var isStereo: Bool { count == 2 }

    /// The card channels it reads.
    var channels: Range<Int> { first ..< first + count }

    /// The 1-based key a custom name is stored under, and what the default name is made of:
    /// "3" for the third channel, "1-2" for the pair of the first two.
    var key: String {
        isStereo ? "\(first + 1)-\(first + 2)" : "\(first + 1)"
    }

    /// Channel order, a mono before a pair that starts on the same channel.
    static func < (a: InputRef, b: InputRef) -> Bool {
        a.first != b.first ? a.first < b.first : a.count < b.count
    }

    // A reference this build cannot make sense of (a count other than 1 or 2, a negative channel —
    // a hand-edited file) is refused here, so that the optional field holding it reads as absent
    // rather than failing the whole project.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let first = try c.decode(Int.self, forKey: .first)
        let count = try c.decode(Int.self, forKey: .count)
        guard first >= 0, count == 1 || count == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .count, in: c,
                                                   debugDescription: "not a valid input reference")
        }
        self.first = first
        self.count = count
    }
}

/// What a recording zone does to the takes already in it when a new take is recorded (session format 34).
/// A choice of the ZONE (`SoundObject.recordTakeMode`; nil = `.mute`, the default, so a project written
/// before format 34 behaves as it always did).
enum RecordTakeMode: String, Codable, CaseIterable, Sendable {
    /// The previous takes that cross the zone's window are muted when the recording starts.
    case mute
    /// Nothing is muted: the new take is added and the older ones stay audible.
    case add

    /// Whether a new take silences the previous ones.
    var mutesPrevious: Bool { self == .mute }

    /// The value a zone stores: the default is stored as ABSENT (one spelling for "mute").
    var stored: RecordTakeMode? { self == .mute ? nil : self }
}

/// What a project keeps about the card's inputs: `ProjectDocument.recordInputs`.
struct RecordInputsConfig: Codable, Equatable, Sendable {
    /// The card the pairs and names were made on. INDICATIVE only: nothing is matched against it.
    var deviceName: String? = nil
    /// The FIRST channel (0-based) of each declared stereo pair, ascending. Pairs may overlap:
    /// 1-2 and 2-3 are two inputs, both listed (decision 4).
    var pairs: [Int] = []
    /// Custom names by `InputRef.key`. An input without an entry is called by its default name.
    var names: [String: String] = [:]

    init(deviceName: String? = nil, pairs: [Int] = [], names: [String: String] = [:]) {
        self.deviceName = deviceName
        self.pairs = pairs
        self.names = names
    }

    /// Nothing worth writing: such a config is stored as an absent key.
    var isEmpty: Bool { deviceName == nil && pairs.isEmpty && names.isEmpty }

    // Every key optional: a file written by a later build, or by hand, reads as far as it can.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceName = try? c.decodeIfPresent(String.self, forKey: .deviceName)
        pairs = (try? c.decodeIfPresent([Int].self, forKey: .pairs)) ?? []
        names = (try? c.decodeIfPresent([String: String].self, forKey: .names)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(deviceName, forKey: .deviceName)
        if !pairs.isEmpty { try c.encode(pairs, forKey: .pairs) }
        if !names.isEmpty { try c.encode(names, forKey: .names) }
    }

    enum CodingKeys: String, CodingKey { case deviceName, pairs, names }

    // MARK: Editing (each returns whether anything changed)

    /// Declares the pair (`first`, `first + 1`). False when it does not fit a card of `channelCount`
    /// channels or already exists.
    @discardableResult
    mutating func pair(_ first: Int, channelCount: Int) -> Bool {
        guard first >= 0, first + 1 < channelCount, !pairs.contains(first) else { return false }
        pairs = (pairs + [first]).sorted()
        return true
    }

    /// Removes the pair starting on `first`. The names are kept: pairing again finds them.
    @discardableResult
    mutating func unpair(_ first: Int) -> Bool {
        guard pairs.contains(first) else { return false }
        pairs.removeAll { $0 == first }
        return true
    }

    /// Replaces ALL the pairs (invalid ones dropped, duplicates collapsed) — the machine's door.
    @discardableResult
    mutating func setPairs(_ firsts: [Int], channelCount: Int) -> Bool {
        let next = InputPairing.validate(firsts, channelCount: channelCount)
        guard next != pairs else { return false }
        pairs = next
        return true
    }

    /// Names an input; an empty (or blank) name goes back to the default. Surrounding blanks are
    /// trimmed. False when nothing changed.
    @discardableResult
    mutating func rename(_ ref: InputRef, to name: String?) -> Bool {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return names.removeValue(forKey: ref.key) != nil }
        guard names[ref.key] != trimmed else { return false }
        names[ref.key] = trimmed
        return true
    }

    func customName(for ref: InputRef) -> String? { names[ref.key] }
}

/// The pairing rules, pure.
enum InputPairing {

    /// The declared pairs that can exist on a card of `channelCount` channels: each one's two
    /// channels inside the card, ascending, no duplicate. Overlap is allowed.
    static func validate(_ firsts: [Int], channelCount: Int) -> [Int] {
        var out: [Int] = []
        for f in firsts.sorted() where f >= 0 && f + 1 < channelCount && out.last != f { out.append(f) }
        return out
    }

    /// What the Inputs tab lists: every valid pair FIRST (by first channel), then EVERY mono. A pair does
    /// not take its monos away (same rule as the engine, `objinput::describe`): 2-3 can still be made
    /// after 1-2, and the monos are what one picks to make a pair.
    static func visibleInputs(channelCount: Int, pairs: [Int]) -> [InputRef] {
        guard channelCount > 0 else { return [] }
        let valid = validate(pairs, channelCount: channelCount)
        return valid.map { InputRef(first: $0, count: 2) }
            + (0 ..< channelCount).map { InputRef(first: $0, count: 1) }
    }

    /// Two selected inputs that can become a stereo pair: both MONO, on neighbouring channels.
    /// The pair's first channel, or nil.
    static func pairableFirst(_ selection: [InputRef]) -> Int? {
        guard selection.count == 2, selection.allSatisfy({ !$0.isStereo }) else { return nil }
        let s = selection.sorted()
        return s[1].first == s[0].first + 1 ? s[0].first : nil
    }

    /// Whether `ref` still exists on a card of `channelCount` channels holding `pairs`.
    static func isPresent(_ ref: InputRef, channelCount: Int, pairs: [Int]) -> Bool {
        visibleInputs(channelCount: channelCount, pairs: pairs).contains(ref)
    }
}


// MARK: - The MIDI inputs, as the PROJECT knows them (rec3-midi)

/// One MIDI input a recording zone listens to. Keyed by Tracktion's device ID and carrying the device's name
/// as it was: a project opened where the id is different (another machine, a device plugged on another
/// port) finds the input again by its NAME when exactly one present device bears it, else the input is
/// "absent" — and the assignment is kept (the same rule as an audio input the card no longer has).
struct MidiInputRef: Codable, Hashable, Sendable {
    var id: String
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    // A reference with no id (a hand-edited file) is refused here, so that the optional field holding it reads
    // as absent rather than failing the whole project.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "empty MIDI input id")
        }
        self.id = id
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
    }

    enum CodingKeys: String, CodingKey { case id, name }
}

/// A MIDI input the engine offers right now (`OBJEngineCore.midiInputDevices`).
struct MidiInputInfo: Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var isVirtual: Bool
    var enabled: Bool

    /// The reference that names it.
    var ref: MidiInputRef { MidiInputRef(id: id, name: name) }
}

enum MidiInputResolver {
    /// The present device `ref` stands for: the one with its id, else the only one with its name, else nil.
    static func resolve(_ ref: MidiInputRef, in devices: [MidiInputInfo]) -> MidiInputInfo? {
        if let byID = devices.first(where: { $0.id == ref.id }) { return byID }
        guard !ref.name.isEmpty else { return nil }
        let byName = devices.filter { $0.name == ref.name }
        return byName.count == 1 ? byName[0] : nil
    }

    /// What the panel lists, in order: "All MIDI Ins" first, then the others by name.
    static func ordered(_ devices: [MidiInputInfo]) -> [MidiInputInfo] {
        devices.sorted { a, b in
            let aAll = a.id == allInputsID, bAll = b.id == allInputsID
            if aAll != bAll { return aAll }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Tracktion's id for its "All MIDI Ins" virtual device.
    static let allInputsID = "all_midi_in"
}

/// What a recording zone listens to: a card input or a MIDI input — never both (a zone has ONE source).
enum RecordSource: Hashable, Sendable {
    case audio(InputRef)
    case midi(MidiInputRef)
}
