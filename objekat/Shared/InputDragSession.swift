import AppKit
import UniformTypeIdentifiers

// MARK: - The input drag in flight, readable while it hovers
//
// The twin of `PluginDragSession` for the rows of the Inputs tab dragged onto the timeline (the selected
// ones, or the one row). A drop target
// gets only an `NSItemProvider` whose payload loads asynchronously — too late to answer the cursor — so
// the SOURCE says what it carries once, when the drag begins, and the timeline's delegate reads
// `current` to draw the ghost and to say "no" in time. Read as ABSENT as soon as no mouse button is down
// (a drag cancelled over nothing tells nobody).
//
// What the drop itself uses is not this session but the payload, decoded off the provider: both travel
// as `public.plain-text` (an undeclared custom type is not instantiated by the pasteboard), and the
// MARKER inside the JSON is what tells an input from a plugin — a plugin payload does not decode as
// this, nor this as a plugin's.
//
// The rows may be MIDI inputs (rec3-midi): the payload then also carries `midi`, the ids of the MIDI inputs
// (the names are the receiver's to look up — a drop only needs the device). A mixed drag lists the MIDI
// ones FIRST, then the card's: that is the order of the lanes they take.

struct InputDragPayload: Codable, Equatable {
    var marker = "objekat.input"
    /// The inputs carried, in the order of the lanes they will take. Absent from the payload of the first
    /// format, which carried ONE input as `first` / `count` — still read (and not written any more).
    var inputs: [Item]?
    var first: Int?
    var count: Int?
    /// The MIDI inputs carried (Tracktion's device ids), in the order of the lanes they will take, before `inputs`.
    var midi: [String]?

    struct Item: Codable, Equatable {
        var first: Int
        var count: Int
    }

    init(_ refs: [InputRef]) { inputs = refs.map { Item(first: $0.first, count: $0.count) } }

    /// A payload for sources that may be MIDI inputs: MIDI first, then the card's, each in the order given.
    init(sources: [RecordSource]) {
        let audio = sources.compactMap { s -> InputRef? in if case .audio(let r) = s { return r } else { return nil } }
        let ids = sources.compactMap { s -> String? in if case .midi(let m) = s { return m.id } else { return nil } }
        inputs = audio.isEmpty ? nil : audio.map { Item(first: $0.first, count: $0.count) }
        midi = ids.isEmpty ? nil : ids
    }

    /// Everything the payload carries, in lane order (MIDI first). The MIDI references hold the id alone (an
    /// empty name): `EditViewModel` finds the device by it. Empty when the payload is not an input's or holds
    /// something invalid.
    var sources: [RecordSource] {
        guard marker == "objekat.input" else { return [] }
        let ids = midi ?? []
        guard ids.allSatisfy({ !$0.isEmpty }) else { return [] }
        let hasAudio = inputs != nil || (first != nil && count != nil)
        let audio = hasAudio ? refs : []
        if hasAudio && audio.isEmpty { return [] }     // an invalid card input spoils the whole drag
        return ids.map { RecordSource.midi(MidiInputRef(id: $0, name: "")) } + audio.map { RecordSource.audio($0) }
    }

    /// What the payload carries; empty when it is not an input's (a wrong marker, an invalid channel).
    var refs: [InputRef] {
        guard marker == "objekat.input" else { return [] }
        let items = inputs ?? ((first != nil && count != nil) ? [Item(first: first!, count: count!)] : [])
        guard !items.isEmpty, items.allSatisfy({ $0.first >= 0 && ($0.count == 1 || $0.count == 2) }) else { return [] }
        return items.map { InputRef(first: $0.first, count: $0.count) }
    }
}

@MainActor
final class InputDragSession {
    static let shared = InputDragSession()

    private var carried: [RecordSource]?

    /// What a row's drag carries: the whole selection (in the order of the channels) when the row dragged
    /// is part of it, otherwise the row alone.
    static func carried(_ row: InputRef, selection: Set<InputRef>) -> [InputRef] {
        selection.contains(row) ? selection.sorted() : [row]
    }

    /// The provider of a drag of one input.
    func begin(_ r: InputRef) -> NSItemProvider { begin([r]) }

    /// The provider of a drag of several inputs; also tells the targets what is being carried.
    func begin(_ rs: [InputRef]) -> NSItemProvider { begin(sources: rs.map { .audio($0) }) }

    /// The provider of a drag of sources that may be MIDI inputs (MIDI first, as the lanes will take them).
    func begin(sources rs: [RecordSource]) -> NSItemProvider {
        let ordered = rs.filter { if case .midi = $0 { return true } else { return false } }
            + rs.filter { if case .audio = $0 { return true } else { return false } }
        carried = ordered
        let data = (try? JSONEncoder().encode(InputDragPayload(sources: ordered))) ?? Data()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                            visibility: .all) { completion in
            completion(data, nil); return nil
        }
        return provider
    }

    func end() { carried = nil }

    /// The inputs being dragged; nil when there are none — or when no mouse button is down any more.
    var current: [RecordSource]? {
        if carried != nil, NSEvent.pressedMouseButtons == 0 { carried = nil }
        return carried
    }

    /// Reads the inputs off a provider (nil for anything else: a plugin, a file…).
    /// `done` runs on the main actor, with nil for anything that is not an input.
    nonisolated static func read(_ provider: NSItemProvider, _ done: @escaping @MainActor ([RecordSource]?) -> Void) {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
              !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            Task { @MainActor in done(nil) }
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
            Task { @MainActor in
                let sources = data.flatMap { try? JSONDecoder().decode(InputDragPayload.self, from: $0) }?.sources
                done(sources?.isEmpty == false ? sources : nil)
            }
        }
    }
}
