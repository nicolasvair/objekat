import Foundation

// MARK: - The name of a recording zone, as the timeline writes it
//
// A recording zone is a group with an input. Like a group called "Group" that takes the name composed
// from its content, a zone is BORN WITHOUT a label: its default name is the name of its input, and it
// follows it (renaming the input renames the zone). Only a name somebody TYPED is a group name, and
// then the timeline writes the zone as "[mic] Input → [folder] Group name".
//
// A plain Foundation unit (asserted alone: tools/test_record_zone_name.swift).

enum RecordZoneName {

    /// The input's name to show IN FRONT of the group's name, nil when the zone shows no prefix
    /// (nothing typed: the default name IS the input's).
    ///
    /// - `label`: the group's label (nil = nobody named it).
    /// - `inputName`: the name of the zone's input; nil when the group has none (not a zone).
    ///
    /// A label equal to the input's name counts as the default: a zone made before the label was
    /// left empty carried exactly that, and would otherwise read "Input → Input".
    static func prefix(label: String?, inputName: String?) -> String? {
        guard let inputName, !inputName.isEmpty, let label else { return nil }
        let typed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty || typed == inputName.trimmingCharacters(in: .whitespacesAndNewlines) { return nil }
        return inputName
    }
}
