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
