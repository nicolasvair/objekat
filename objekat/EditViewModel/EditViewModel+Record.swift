import Foundation

// MARK: - The card's recording inputs, as the project keeps them
//
// The model (`RecordInputsConfig`) holds the pairs and the names; the engine only needs the pairs, to
// describe its devices (`OBJEngineCore.setAudioInputStereoPairs`, which is harmless while the inputs
// are closed: they will be described with these pairs when they open).
//
// Two doors, and the difference is the whole point:
//  - `setRecordInputs` is the LOAD door — a project opening, a tab restored, a new project. It
//    replaces the config and tells the engine. It never marks the project modified.
//  - `editRecordInputs` is the HAND's (and the API's) door. Outside the undo (@see
//    project_undo_convention: a setting of the session is not an edit of the matter), but the
//    project IS marked modified, so the names and pairs are written on the next save.

extension EditViewModel {

    func setRecordInputs(_ config: RecordInputsConfig) {
        if recordInputs != config { recordInputs = config }
        engine?.setAudioInputStereoPairs(config.pairs.map { NSNumber(value: $0) })
    }

    /// Changes the config through `change` (which answers whether it changed anything), pushes the
    /// pairs to the engine and marks the project modified. Returns whether anything changed.
    @discardableResult
    func editRecordInputs(_ change: (inout RecordInputsConfig) -> Bool) -> Bool {
        var next = recordInputs
        guard change(&next) else { return false }
        if next.deviceName == nil { next.deviceName = AudioDeviceStatus.shared.snapshot.name }
        recordInputs = next
        engine?.setAudioInputStereoPairs(next.pairs.map { NSNumber(value: $0) })
        isDirty = true
        return true
    }
}

// MARK: - What the Inputs tab and the `input.*` commands do

extension EditViewModel {

    /// The card's channel count while its inputs are open, else 0.
    var recordChannelCount: Int {
        guard let engine, engine.audioInputsOpen() else { return 0 }
        return engine.audioInputChannelNames().count
    }

    /// The bound a pairing is checked against: the card's channel count while open, else a limit so
    /// wide that nothing is cut — the pairs are channel NUMBERS, and a pair the present card cannot
    /// hold is "absent", not forgotten (it comes back with a card that has the channels). Validation
    /// against the real card is `InputPairing.visibleInputs`'s job, at the moment it is listed.
    var recordChannelLimit: Int { recordChannelCount > 0 ? recordChannelCount : 1_000 }

    /// The name shown for an input: the one the project gave it, else "In 3" / "In 1-2".
    func inputName(_ ref: InputRef) -> String {
        if let custom = recordInputs.customName(for: ref) { return custom }
        return ref.isStereo ? L("inputs.name.stereo", ref.first + 1, ref.first + 2)
                            : L("inputs.name.mono", ref.first + 1)
    }

    func renameInput(_ ref: InputRef, to name: String) {
        editRecordInputs { $0.rename(ref, to: name) }
    }

    /// Reads channels `first` and `first + 1` as ONE stereo input.
    @discardableResult
    func pairInputs(first: Int) -> Bool {
        let limit = recordChannelLimit
        return editRecordInputs { $0.pair(first, channelCount: limit) }
    }

    @discardableResult
    func unpairInputs(first: Int) -> Bool {
        editRecordInputs { $0.unpair(first) }
    }

    /// Replaces every pair (the machine's door).
    @discardableResult
    func setInputPairs(_ firsts: [Int]) -> Bool {
        let limit = recordChannelLimit
        return editRecordInputs { $0.setPairs(firsts, channelCount: limit) }
    }

    /// Opens the card's inputs. nil on success, otherwise why not.
    func enableRecordInputs() -> String? {
        guard let engine else { return "no engine" }
        return engine.openAudioInputs()
    }

    /// Hears (or stops hearing) an input in the mix. nil on success, otherwise why not.
    func setInputMonitor(_ ref: InputRef, on: Bool) -> String? {
        guard let engine else { return "no engine" }
        return engine.setAudioInputMonitor(on, first: ref.first, count: ref.count)
    }

    /// The inputs being heard right now (the engine owns this; it is not saved).
    var monitoredInputs: [InputRef] {
        (engine?.audioInputMonitors() ?? []).compactMap { d in
            guard let f = d["first"]?.intValue, let c = d["count"]?.intValue else { return nil }
            return InputRef(first: f, count: c)
        }
    }

    /// What the tab lists, in order: every pair, then the monos no pair holds.
    var visibleRecordInputs: [InputRef] {
        InputPairing.visibleInputs(channelCount: recordChannelCount, pairs: recordInputs.pairs)
    }
}
