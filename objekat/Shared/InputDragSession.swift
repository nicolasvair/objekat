import AppKit
import UniformTypeIdentifiers

// MARK: - The input drag in flight, readable while it hovers
//
// The twin of `PluginDragSession` for a row of the Inputs tab dragged onto the timeline. A drop target
// gets only an `NSItemProvider` whose payload loads asynchronously — too late to answer the cursor — so
// the SOURCE says what it carries once, when the drag begins, and the timeline's delegate reads
// `current` to draw the ghost and to say "no" in time. Read as ABSENT as soon as no mouse button is down
// (a drag cancelled over nothing tells nobody).
//
// What the drop itself uses is not this session but the payload, decoded off the provider: both travel
// as `public.plain-text` (an undeclared custom type is not instantiated by the pasteboard), and the
// MARKER inside the JSON is what tells an input from a plugin — a plugin payload does not decode as
// this, nor this as a plugin's.

struct InputDragPayload: Codable, Equatable {
    var marker = "objekat.input"
    var first: Int
    var count: Int

    init(_ ref: InputRef) { first = ref.first; count = ref.count }

    var ref: InputRef? {
        guard marker == "objekat.input", first >= 0, count == 1 || count == 2 else { return nil }
        return InputRef(first: first, count: count)
    }
}

@MainActor
final class InputDragSession {
    static let shared = InputDragSession()

    private var ref: InputRef?

    /// The provider of a row's drag; also tells the targets what is being carried.
    func begin(_ r: InputRef) -> NSItemProvider {
        ref = r
        let data = (try? JSONEncoder().encode(InputDragPayload(r))) ?? Data()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                            visibility: .all) { completion in
            completion(data, nil); return nil
        }
        return provider
    }

    func end() { ref = nil }

    /// The input being dragged; nil when there is none — or when no mouse button is down any more.
    var current: InputRef? {
        if ref != nil, NSEvent.pressedMouseButtons == 0 { ref = nil }
        return ref
    }

    /// Reads an input off a provider (nil for anything else: a plugin, a file…).
    /// `done` runs on the main actor, with nil for anything that is not an input.
    nonisolated static func read(_ provider: NSItemProvider, _ done: @escaping @MainActor (InputRef?) -> Void) {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
              !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            Task { @MainActor in done(nil) }
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
            Task { @MainActor in
                done(data.flatMap { try? JSONDecoder().decode(InputDragPayload.self, from: $0) }?.ref)
            }
        }
    }
}
