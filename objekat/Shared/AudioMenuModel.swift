import Foundation

/// The pure half of the audio menu (the wrench in the transport bar): what its rows are, which one is
/// ticked, what a click on a row means. No view, no engine, no catalogue — the words come in through
/// `AudioMenuLabels` and the facts through `AudioMenuState`, so the whole of it compiles and is
/// asserted alone (`tools/test_audio_menu_model.swift`).
///
/// The rows are the shared tree picker's (`Shared/TreePickerPopover.swift`): a native `Menu` closes on
/// every click, and one sets a card, then a rate, then a buffer in one go. They are BRANCHES that open
/// inline, one at a time, so a long list of cards does not push the rest out of the popover.
struct AudioMenuState: Equatable {
    /// The cards one can play on, in the engine's order.
    var outputDevices: [String] = []
    /// The card really open (the engine's snapshot), never the one asked for.
    var currentOutput: String? = nil
    var sampleRates: [Double] = []
    var currentSampleRate: Double = 0
    /// One sentence under the rates, said ONLY when the engine moved the card's own rate.
    var sampleRateNote: String? = nil
    /// The buffer sizes the card offers (the menu keeps the useful ones).
    var bufferSizes: [Int] = []
    var currentBufferSize: Int = 0
    /// The cards one can record from OTHER than the output card (its own inputs are the row « same card »).
    var inputCards: [AudioMenuInputCard] = []
    /// The input card CHOSEN (its UID); nil = the output card's own inputs, which is the default.
    var currentInput: String? = nil
    /// One sentence under the input rows: the microphone is switching, or opening failed. Nil says nothing.
    var inputNote: String? = nil
}

/// An input card of the menu: its UID is its identity (a name is not one — two identical interfaces).
struct AudioMenuInputCard: Equatable {
    var uid: String
    var name: String
}

struct AudioMenuLabels: Equatable {
    var output: String
    var input: String
    var sameInputCard: String
    var sampleRate: String
    var buffer: String
    var noOutputDevice: String
}

/// What a click on a row of the menu asks for.
enum AudioMenuAction: Equatable {
    case output(String)
    /// nil = the output card's own inputs.
    case input(String?)
    case sampleRate(Double)
    case buffer(Int)
}

enum AudioMenuModel {
    // MARK: Ids

    private static let outPrefix = "out:"
    private static let inPrefix = "in:"
    private static let sameInputRow = "in-same"
    private static let ratePrefix = "rate:"
    private static let bufferPrefix = "buf:"

    static func outputID(_ name: String) -> String { outPrefix + name }
    static func inputID(_ uid: String?) -> String { uid.map { inPrefix + $0 } ?? sameInputRow }
    static func rateID(_ hz: Double) -> String { ratePrefix + String(hz) }
    static func bufferID(_ frames: Int) -> String { bufferPrefix + String(frames) }

    /// The meaning of a row's id; nil for an id the menu does not know.
    static func action(forID id: String) -> AudioMenuAction? {
        if id.hasPrefix(outPrefix) { return .output(String(id.dropFirst(outPrefix.count))) }
        if id == sameInputRow { return .input(nil) }
        if id.hasPrefix(inPrefix) { return .input(String(id.dropFirst(inPrefix.count))) }
        if id.hasPrefix(ratePrefix), let hz = Double(id.dropFirst(ratePrefix.count)) { return .sampleRate(hz) }
        if id.hasPrefix(bufferPrefix), let n = Int(id.dropFirst(bufferPrefix.count)) { return .buffer(n) }
        return nil
    }

    // MARK: The sections

    /// ONE untitled section of branches, each saying its current value and opening on a click (the picker's
    /// accordion): output card, input card, rate, buffer. The rows under a branch keep their ids, so
    /// `action(forID:)` knows nothing of the branches — their own ids start with `branch.` and match no prefix.
    static func sections(_ state: AudioMenuState, labels: AudioMenuLabels) -> [TreePickerSection] {
        var branches: [TreePickerNode] = []

        var outputNodes = state.outputDevices.map {
            TreePickerNode(id: outputID($0), name: $0, checked: $0 == state.currentOutput)
        }
        if outputNodes.isEmpty { outputNodes = [.note("output.none", labels.noOutputDevice)] }
        branches.append(.branch("branch.output", labels.output,
                                detail: state.currentOutput ?? labels.noOutputDevice, children: outputNodes))

        var inputNodes = [TreePickerNode(id: inputID(nil), name: labels.sameInputCard, checked: state.currentInput == nil)]
        inputNodes += state.inputCards.map {
            TreePickerNode(id: inputID($0.uid), name: $0.name, checked: $0.uid == state.currentInput)
        }
        if let note = state.inputNote { inputNodes.append(.note("input.note", note)) }
        // The ticked card's name; a choice no card carries (the engine resets it) reads as the default.
        let inputDetail = state.inputCards.first { $0.uid == state.currentInput }?.name ?? labels.sameInputCard
        branches.append(.branch("branch.input", labels.input, detail: inputDetail,
                                startsOpen: state.inputNote != nil, children: inputNodes))

        if !state.sampleRates.isEmpty {
            var nodes = state.sampleRates.map {
                TreePickerNode(id: rateID($0), name: formatRate($0), checked: $0 == state.currentSampleRate)
            }
            if let note = state.sampleRateNote { nodes.append(.note("rate.note", note)) }
            branches.append(.branch("branch.rate", labels.sampleRate, detail: state.currentSampleRate > 0 ? formatRate(state.currentSampleRate) : nil,
                                    startsOpen: state.sampleRateNote != nil, children: nodes))
        }

        let buffers = usefulBufferSizes(state.bufferSizes, current: state.currentBufferSize)
        if !buffers.isEmpty {
            branches.append(.branch(
                "branch.buffer", labels.buffer,
                detail: state.currentBufferSize > 0
                    ? formatBuffer(state.currentBufferSize, sampleRate: state.currentSampleRate) : nil,
                children: buffers.map {
                    TreePickerNode(id: bufferID($0), name: formatBuffer($0, sampleRate: state.currentSampleRate),
                                   checked: $0 == state.currentBufferSize)
                }))
        }
        return [TreePickerSection(id: "audio", title: nil, nodes: branches, collapsible: false)]
    }

    // MARK: Buffer sizes

    /// The sizes kept in the menu: the usual powers of 2. CoreAudio exposes plenty of others
    /// (14, 96, 176…) which serve no purpose and drown the list.
    static let standardBufferSizes: [Int] = [32, 64, 128, 256, 512, 1024, 2048]

    /// The CURRENT value is always kept, even outside the list, so that a row is ticked.
    static func usefulBufferSizes(_ available: [Int], current: Int) -> [Int] {
        var kept = available.filter { standardBufferSizes.contains($0) }
        // An exotic device exposing no power of 2: its list as it is rather than an empty menu.
        if kept.isEmpty { kept = available }
        if current > 0, !kept.contains(current) { kept.append(current) }
        return kept.sorted()
    }

    // MARK: Formatting

    static func formatRate(_ hz: Double) -> String {
        let k = hz / 1000
        return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
    }

    static func formatBuffer(_ frames: Int, sampleRate: Double) -> String {
        guard sampleRate > 0 else { return "\(frames)" }
        let ms = Double(frames) / sampleRate * 1000
        return String(format: "%d — %.1f ms", frames, ms)
    }
}
